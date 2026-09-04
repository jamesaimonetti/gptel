# Plan: Fix Anthropic prompt-cache hit rate and cut input volume

## Context and goals

The usage log shows 14.5M input tokens vs only 551K cache reads (~4% hit
rate).  With input at $5/M vs cache reads at $0.50/M on claude models, the
cache-miss pattern is the dominant cost.  This plan turns the diagnosis
below into concrete, code-grounded work on this branch
(`feature/usage-report-grouping`).

Root causes (verified against the current tree):

1. **The `message` breakpoint sits on the *last* (incoming) message.**
   `gptel--parse-list` (gptel-anthropic.el:433-437) and
   `gptel--parse-buffer` (gptel-anthropic.el:500-510) append
   `:cache_control (:type "ephemeral")` to the **last** message in the
   array — the prompt that changes on every request.  Per Anthropic's
   docs, cache *writes* happen only at a breakpoint and reads look back
   for an *earlier write*; a breakpoint on a per-request block means a
   full write + full miss on every turn.  This matches the "breakpoints
   aren't placed where the stable content is" diagnosis exactly.

2. **Growing agentic sessions (>20 new blocks) outrun the lookback
   window.**  With one breakpoint and a run of tool_use / non-tool
   messages growing per turn, the previous write can fall outside the
   20-block lookback window and the system can't find it, silently
   re-paying a full write.  Between tool-call turns the history grows
   quickly (assistant text + tool_use + tool_result + assistant text +
   new prompt), so this fires within a handful of tool loops.

3. **5-minute TTL expires during thinking / tool-wait / idle gaps.**
   Messages and tools use the default 5-minute "ephemeral" TTL
   (gptel-anthropic.el:437, 510, 265); the commit history shows the
   1h TTL was deliberately reverted for messages (e5ab85a) because
   1h writes cost 2x.  The `extended-cache-ttl-2025-04-11` header is
   already sent by default (gptel-anthropic.el:727), so `:ttl "1h"` is
   *accepted* — it's just not currently emitted on message/tool blocks.

4. **Dynamic content in the cached prefix.**  gptel context
   (`gptel-use-context` = `system` by default) prepends
   `gptel-context--string` into `gptel-system-prompt`
   (gptel-context.el:402-427), so an edited/active file or buffer
   changes the system-block prefix and invalidates the system cache
   read.  Tool *defaults* are stable, but per-request `:tools` /
   `:temperature` / `:max_tokens` / `:stream` / media are request
   params that do not participate in the cached prefix (they're outside
   `messages`, `tools`, `system`), so they invalidate only per
   Anthropic's invalidation table (tool_choice, thinking params,
   images in messages).

5. **Tool results are carried verbatim forever.**  gptel never compacts
   them; a long-lived agent session resends full file/command output
   every turn (the "input driver" in the diagnosis).

Scope of this plan: v1 = breakpoint placement + TTL policy (the two
highest-leverage fixes, both isolated to the Anthropic backend and to
defaults); v2 = compaction and the usage report upgrade.  Batch API,
verbose-context auto-shrink and welding are deliberately out of scope
(see Resolutions and Mechanical consequences).

## Design

### A. v1 — Breakpoint placement (gptel-anthropic.el)

Goal: `[tools] → [system] → [history up to the last stable block] →
[breakpoint] → [newest turn]`, matching Anthropic's documented
"cache the growing history" pattern.

Strategy: keep cache_control on the **last message of the *stable*
prefix** instead of on the last message overall.  Concretely:

- `gptel--parse-list` and `gptel--parse-buffer`: put the message
  breakpoint on `(car (last (butlast full-prompt)))` — the second-to-last
  message — **when** the array has ≥ 2 messages.  When there is only one
  message (a fresh conversation), there is no stable prefix yet: fall back
  to caching the system block (already cached) and leave the single
  message uncached, or keep last-message caching (ephemeral) so tool-call
  turns (which are multi-message) are covered.  Choosing the fallback is
  the one behavioral decision; default = keep last-message caching for the
  single-message case (it's harmless there: no prior history to hit, and
  it matches upstream behavior) **and** cache the second-to-last when ≥2.

- For `gptel--parse-buffer`, the last message is the incoming user prompt
  (point is at the end of the buffer); the second-to-last is the
  previous assistant turn — exactly the "last stable block" position.
  The incoming prompt stays uncached (fresh input tokens only — the
  irreducible per-turn cost, and the part that must keep changing).

- This is a **two-line change in each function** (target the
  `butlast`/second-to-last element instead of `last`) plus the
  ≥2 guard.  It keeps the requests' message shape byte-identical for
  non-cache paths (cache_control is only appended when
  `gptel-cache` includes `message`).

Mechanical consequences of A:

- In a normal multi-turn conversation each request now writes only the
  *new* turn (assistant + prompt) to cache and reads the previous
  full-history write — the documented "multi-turn conversation" pattern
  (input_tokens minimal, cache_read large, cache_creation = new turn).
- In an agentic session the same rule applies; the history prefix shared
  between consecutive tool-call rounds is the assistant(tool_use) +
  tool_result part, which is now the cached prefix.  This is the single
  change most responsible for cutting the 14.5M/551K ratio.

### B. v1 — TTL policy (gptel-anthropic.el)

Goal: survive idle gaps without paying 2x on hot turns.

- Add one defcustom:

```elisp
(defcustom gptel-anthropic-cache-ttl "5m"
  "Cache TTL for Anthropic prompt caching: \"5m\" or \"1h\".
  1h writes cost 2x base input (vs 1.25x for 5m) but survive
  multi-minute idle gaps and long tool runs.  Break-even is ~2
  reads per write instead of 1."
  :type '(choice (const :tag "5 minutes (default, 1.25x write)" "5m")
                 (const :tag "1 hour (2x write)" "1h")))
```

- Emit it on the system block (request-data, gptel-anthropic.el:248-252)
  and on the message breakpoint (parse-list:437, parse-buffer:508-510):
  `(:type "ephemeral" :ttl gptel-anthropic-cache-ttl)`.  Tools stay at
  `"5m"` per upstream (e5ab85a) unless the user chooses `"1h"` — mixing
  is legal (1h must precede 5m; tools precede system precede messages,
  so tools must be 5m when messages are 1h... but really simplest:
  apply the chosen TTL uniformly).  Resolution 5 settles this.
- The `extended-cache-ttl` header is already default; no header work.

### C. v2 — Compaction for tool-result history (new gptel-compact.el?)

Goal: stop resending full tool results forever (the biggest *raw
input* driver after the cache fix).

- Add a rg/regex-agnostic extractor for tool blocks in the prompt
  buffer: scan backwards from point for `gptel` `(tool . id)` regions
  (as `gptel--parse-buffer` does), and for results older than a
  threshold (defcustom `gptel-compact-tool-results-after`, default nil =
  off), replace the block body with a short summary:
  "(tool `name` result (N chars) trimmed)" — or, when
  `gptel-compact-summarize-tool-results` is non-nil, a 1-2 sentence
  llm-generated summary via a normal gptel request.
- Safer non-llm first step: **trim** tool result *content* to a cap
  (defcustom `gptel-tool-result-max-chars`, default nil) at parse time
  in `gptel--parse-buffer`'s `(tool . ,id)` branch — replaces the
  buffer text only in the *request copy*, never the source buffer
  (the prompt buffer is a temp copy; see `gptel--with-buffer-copy`).
- Keep pruning simple: `gptel--num-messages-to-send` already trims old
  turns; compaction is a separate, opt-in extra for long agentic runs.

### D. v2 — Cache-health report (gptel-usage.el)

Goal: visible, per-request cache behavior so the plan can be verified
with real numbers (the original diagnosis was from these logs).

- v1 of the log already has `:cached`/`:cache` columns; add a defcustom
  toggle `gptel-usage-annotate-cache-ratio` (default t) that appends a
  "Cache% = CacheRd / (Input + CacheRd + CacheWr)" column to
  `gptel-usage--aggregate` rows and the `Total` row.
- When `gptel-usage-report-grouping` is non-`all`, the per-period tables
  automatically show the trend — no extra work beyond the column.
- Optionally: per-request stderr log line on `gptel-anthropic` when
  `gptel-log-level` is `debug`, summarizing
  `cache_read_input_tokens` / `cache_creation_input_tokens` /
  `input_tokens` for the current turn (the "smoking gun" check in the
  diagnosis).  Cheap: `gptel--anthropic-update-tokens`
  (gptel-anthropic.el:43) already has all three numbers.

## Files and edits summary

| File | Change |
|---|---|
| `gptel-anthropic.el` | A: message breakpoint → second-to-last message (parse-list:433, parse-buffer:500), ≥2-message guard, single-message fallback. B: `gptel-anthropic-cache-ttl` defcustom + emit on system (248) and messages (437/510). D (`debug`): cache-ratio log line in `gptel--anthropic-update-tokens`. |
| `gptel-usage.el` | D: `Cache%` column in `gptel-usage--aggregate` + table writers (`gptel-usage--report-table`, `gptel-usage--report-day-table`), toggle defcustom. |
| `gptel-request.el` | C (optional): no changes if compaction is done in the prompt-buffer copy via `gptel--parse-buffer`; otherwise a `gptel-compact--` hook in `gptel-prompt-transform-functions` (runs in the temp buffer, before `gptel--realize-query`, gptel-request.el:2350). |
| `gptel-compact.el` (new, optional) | C: tool-result trimming / optional llm summarizer. |
| `README.org`, `NEWS` | document `gptel-anthropic-cache-ttl`, new breakpoint behavior, Cache% column, compaction. |

## Resolutions / decisions

1. **Single-message fallback**: keep last-message caching when the
   message array has one entry (fresh conversation).  There is no stable
   prefix to hit; system is already cached; and upstream behavior is
   preserved for tool-call turns (multi-message).  Changing the fallback
   to "no message breakpoint" is a one-line alternative if the user
   prefers minimal writes.

2. **Second breakpoint for long sessions is deferred to v2**: proper
   support means tracking where the previous request's write stopped
   (per-buffer state across turn boundaries), which is more than a
   plist-put.  With the second-to-last placement, each turn's write is
   close to the current breakpoint and the 20-block window is almost
   never exceeded (a tool loop adds ~2-4 blocks per round).  Revisit
   only if the report shows growth >20 blocks per turn.

3. **TTL default stays `"5m"`** to match upstream and avoid surprise 2x
   writes; the defcustom lets the user pick `"1h"` for sessions with
   natural pauses.  Applied uniformly (system + messages).  Tools: keep
   `"5m"` regardless (upstream choice, e5ab85a) — mixing is legal as
   long as longer TTLs precede shorter ones (tools precede system
   precede messages; tools at `"5m"` after system/messages at `"1h"`
   would violate the ordering rule and 400.  So when the user chooses
   `"1h"`, apply it to tools too; when `"5m"`, everything is `"5m"` —
   no mixed-TTL hazard.)

4. **Compaction is opt-in and non-destructive**: it edits the temp
   prompt-buffer copy only; the source gptel buffer is never touched.
   Trimming (not llm summary) is the v2 first step; llm summarization
   can follow.  `gptel-note`/`gptel-directives` are unaffected.

5. **Diagnostics**: the `Cache%` column and the `debug`-level
   per-request cache line give the user (and this plan) the
   `cache_creation_input_tokens` vs `cache_read_input_tokens` numbers
   the original analysis asked for, without new infrastructure.

## Implementation status (checked as work lands)

Branch: `feature/cache-usage` (to be created from
`feature/usage-report-grouping`).

- [ ] **A. Breakpoint placement** — second-to-last message when ≥2,
      single-message fallback; update `test/examples/anthropic-*`
      prompt expectations? (existing `.eld` files assert prompt shape —
      check if any assert `cache_control` placement; none currently do,
      so tests add coverage rather than churn).
- [ ] **B. TTL defcustom** — `gptel-anthropic-cache-ttl`, emitted on
      system + messages (uniform, per resolution 3), tools always
      `"5m"`.
- [ ] **Tests (v1)** — ert: parse-list/parse-buffer with ≥2 messages
      places breakpoint on second-to-last; single-message fallback;
      `gptel-cache` = nil/`system`/`tool` unaffected; TTL refactored
      into a small pure helper so tests can assert the emitted plist
      without hitting the network.
- [ ] **E2E (v1)** — extend `test/e2e/gptel-e2e-server.py` with a fake
      Anthropic endpoint that echoes usage `cache_creation/cache_read`
      derived from a simulated cache table; drive two turns and assert
      the second reports a cache read for the shared prefix.  Reuse the
      existing curl transport harness (run-e2e.sh).
- [ ] **D. Cache% column** — `gptel-usage.el` aggregate + table writers,
      toggle defcustom, tests in `test/gptel-usage-test.el`.
- [ ] **C. Compaction (v2)** — trim-in-copy first; optional llm
      summary; `gptel-compact.el` + prompt-transform hook + tests.
- [ ] Byte-compile all touched files clean; `make`-style test target
      (per existing ert run in PLAN.md: batch + e2e).

## Out of scope (noted, not planned)

- **Batch API** (50% off): gptel is interactive-first; non-interactive
  bulk work doesn't map cleanly onto a per-request transport.  The
  usage report's per-period tables make it possible to eyeball whether
  any single task is bulk enough to justify a batch rerun, but wiring
  batch submission is a separate feature.
- **Automatic caching (top-level `cache_control`)** as the default:
  it moves the breakpoint to the *last* block — which is the incoming
  message for gptel — and would reintroduce the exact miss pattern we
  are fixing.  Only useful combined with an explicit system/tools
  breakpoint, and the message breakpoint must stay explicit anyway.
- **Context auto-resizing / "just cache less"**: shrinking
  `gptel-context` or pruning turns as a cache strategy (as opposed to a
  cost strategy) is orthogonal; compaction (C) is the surgical version.
