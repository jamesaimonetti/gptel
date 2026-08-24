# Plan: Retry/Backoff + Concurrency Limiting for gptel

## Context and goals

- gptel has no automatic retry/backoff today. Provider retry signals
  (`retry-after`, `x-should-retry`, JSON `type: rate_limit_error`,
  `overloaded_error`, HTTP 429/5xx) are discarded or only logged.
- Goal 1: on retryable errors, wait with exponential backoff + jitter and
  transparently re-issue the same request, per-backend configurable.
- Goal 2: per-backend concurrency limiter (max N in-flight), queue excess,
  release when a slot frees (including when a stream ends).
- Must work for both transports (url-retrieve and curl), streaming and
  non-streaming, and for all fsms (`gptel-send`, `gptel-rewrite`,
  `gptel-transient` custom fsms) without editing each.

## Architecture (verified against source)

- Every request runs through a `gptel-fsm` (gptel-request.el:1843, slots
  `state`/`table`/`handlers`/`info`). `gptel--fsm-transition` (1869) sets
  the new state, then `mapc`s the handlers for that state; **no
  short-circuit**. `gptel--fsm-next` (1883) runs synchronous predicates,
  first match wins.
- Transitions (1801): `INIT->WAIT->TYPE`,
  `TYPE->(error-p->ERRS | tool-use-p->TOOL | t->DONE)`,
  `TOOL->TRET->(error-p->ERRS | tool-result-p->WAIT | t->DONE)`.
- `gptel--handle-wait` (1900) fires the network request and **resets**
  `info` keys `:error :http-status :tool-result :tool-use :reasoning
  :tokens`; reusing one FSM for a second network request is already a
  supported pattern (tool-call loop). So a retry = timer -> transition
  back to `WAIT`.
- Both transports plist-put `:http-status`/`:status`/`:error` then
  transition `WAIT->TYPE`:
  - url: `gptel--url-get-response` (2639) + `gptel--url-parse-response`
    (2748)
  - curl non-stream: `gptel-curl--sentinel` (3134) + `gptel-curl--parse-response` (3177)
  - curl stream: `gptel-curl--stream-filter` (3029, header detection at
    3042) + `gptel-curl--stream-cleanup` (2979)
  - Headers are currently parsed only for logging then discarded —
    this is the gap to plug.
- `gptel-request` (2042) takes `&key fsm`, default `(gptel-make-fsm)`.
  Callers pass custom `:table`/`:handlers`: `gptel-send` (gptel.el:1663,
  tables at 1226/1242), `gptel-transient` (1789), `gptel-rewrite` (808).
  **All funnel through `gptel-request` with their custom fsm**, so a
  central install inside `gptel-request` on the *resolved* fsm covers all
  of them.
- The response callback is invoked from the transport callbacks (not from
  ERRS/DONE handlers); `gptel--handle-error` (gptel.el:1415) messages the
  user, `gptel--fsm-last` (1260) stores the fsm for inspection,
  `gptel--handle-abort` (1454) handles ABRT. Custom fsms' ERRS handlers
  do terminal bookkeeping — retries must not enter ERRS.

## Chosen route (elisp-expert evaluation)

**Approach A: parking state `RTRY` + slot surgery installed centrally in
`gptel-request`.** Not Approach B (handler prepend): B enters ERRS on a
transient error, so every ERRS handler (including custom fsms' terminal
bookkeeping and the user-facing `gptel--handle-error`) would run on a
retryable error, breaking the "callback fires once with final result"
contract; mid-`mapc` handler-list swapping doesn't work because the
running `mapc` iterates over the list value it already bound.

A keeps the retry path out of terminal states entirely: a `retry-p`
predicate in the `TYPE` row (and `TRET` row) routes to `RTRY` *before*
`error-p` sees the value. ERRS/DONE handlers run only when retries are
exhausted. Zero changes needed in gptel.el's `gptel--handle-error`.

## Design

### 1. Capture headers (prerequisite, gptel-request.el)

- `gptel--url-parse-response`: parse the header region (already visited
  for logging, up to `url-http-end-of-headers`) into an alist; return it
  as a 5th element `(response http-status http-msg error headers)`.
- `gptel-curl--parse-response` and the header-detection in
  `gptel-curl--stream-filter` / `gptel-curl--stream-cleanup`: same —
  curl already delimits headers via the `-w` uuid/size trick; parse them
  into an alist.
- At all call sites, `(plist-put info :http-headers <alist>)` next to the
  existing `:http-status`/`:error` puts, **before** `gptel--fsm-transition`.
- Additive; nothing currently reads `:http-headers`, so no behavior
  change until backoff consumes it.
- Helper `gptel--parse-http-headers` (string -> alist, lowercase keys).

### 2. New file `gptel-backoff.el`

**Retryability — provider-aware, header-first:**
```elisp
(cl-defgeneric gptel-backoff--retryable-p (backend info))
```
Default method:
- `x-should-retry: false` present -> nil (hard no: malformed request,
  credit balance).
- `x-should-retry: true` -> t.
- Else HTTP status: 429, 500, 502, 503, 504, 529 -> t; 400/401/403/404
  -> nil.
- Else JSON error `:type`/`:code`/`:message` for known retryable strings
  (`rate_limit_error`, `overloaded_error`, ...); unknown -> nil
  (conservative: don't retry).
Provider overrides via `cl-defmethod` in `gptel-anthropic.el`,
`gptel-openai.el`, `gptel-gemini.el` if their semantics diverge.

**Backoff config (customs):**
```elisp
(defcustom gptel-backoff-jitter-factor 0.2 ...)  ; 0 disables jitter
(defcustom gptel-backoff-base-delay 1.0 ...)
(defcustom gptel-backoff-max-delay 60.0 ...)
(defcustom gptel-backoff-max-retries 5 ...)
```
`gptel-backoff--delay (attempt info)`:
- `retry-after` header (seconds, else RFC 7231 HTTP-date) honored as a
  floor when present.
- Else exponential: `base * 2^(attempt-1)`, capped at `max-delay`.
- Apply jitter: `delay * (1 + uniform(-jitter, +jitter))` via pure
  function, `(random)` for nondeterminism (seedable for tests).

**FSM install (central, idempotent):**
```elisp
(defun gptel-backoff--install (fsm)
  ;; 1. Insert (gptel-backoff--retry-p . RTRY) into the TYPE row (and
  ;;    TRET row if present) BEFORE the first (gptel--error-p . ...)
  ;;    entry.  First-match-wins makes this safe; retry-p returning nil
  ;;    falls through to error-p.
  ;; 2. Replace gptel--handle-wait in the WAIT handler list with
  ;;    gptel-backoff--handle-wait (limiter gate); add
  ;;    (RTRY . gptel-backoff--handle-retry) and
  ;;    (QUEUE . gptel-backoff--handle-queue) to handlers.
  ;; 3. plist-put info :backoff-attempts 0.
  ;; No-op if RTRY already present (idempotent).
  )
```
Called at the top of `gptel-request` on the **final resolved fsm**
(after `&key fsm` is resolved, default or custom) — covers gptel-send /
rewrite / transient for free since they all pass `&key fsm` to
`gptel-request`. Opt-out escape hatch: `gptel-request` gets `&key
(retry t)`; install only when non-nil and the table has a TYPE row with
an `error-p` entry.

**Retry predicate (side-effect-free):**
```elisp
(defun gptel-backoff--retry-p (info)
  ;; reads :error :http-status :http-headers :backend :backoff-attempts
  ;; returns t iff retryable AND attempts < max
  )
```

**RTRY handler (schedules, does not block):**
```elisp
(defun gptel-backoff--handle-retry (fsm)
  ;; 1. Truncate any partial streamed output back to the response-start
  ;;    marker (info :position / :tracking-marker) — streaming may have
  ;;    already inserted chunks.  Non-streaming transports insert only on
  ;;    success, so nothing to clean there.  If no marker, skip (doc).
  ;; 2. Increment info :backoff-attempts (predicates stay side-effect
  ;;    free; the NEXT TYPE evaluation of retry-p sees the incremented
  ;;    counter and gives up when exhausted).
  ;; 3. Compute delay via gptel-backoff--delay.
  ;; 4. (run-at-time delay nil #'gptel-backoff--fire fsm)
  ;;    — do NOT transition here; stay parked in RTRY.
  )
(defun gptel-backoff--fire (fsm)
  ;; Guard: (buffer-live-p ...) check; bail if fsm state is no longer
  ;; RTRY (stale timer on a reused fsm); cancel-timer on teardown.
  ;; (gptel--fsm-transition fsm 'WAIT)  ; re-issues the request
  )
```
`gptel--handle-wait` re-runs on re-entry to WAIT and resets
`:error`/`:http-status` — exactly what a retry needs. No gptel.el
changes.

### 3. Concurrency limiter (`gptel-backoff.el`)

- **Gate:** wrap the transport dispatch at the single choke point —
  the WAIT handler. Install `gptel-backoff--handle-wait` **in place of**
  `gptel--handle-wait` in the WAIT handler list (slot surgery; idempotent;
  other WAIT handlers like `gptel--update-wait` still run on entry):
  - if a slot is free (and no cooldown active): `cl-incf active`, set
    `info :backoff-dispatched`, call `gptel--handle-wait` (dispatch).
  - if over limit: `(gptel--fsm-transition fsm 'QUEUE)` (new state),
    `plist-put info :queued t`; register `(nil . (fsm cleanup-fn))` in
    `gptel--request-alist` so `gptel-abort` finds it.
  - wrap in `condition-case`/`unwind-protect` so a synchronous throw
    releases the slot (decrement + pump).
- **Release:** at `gptel--request-alist` removal — url callback (~2727),
  curl sentinel (~3174), stream cleanup (~3026), `gptel-abort` (~2400) —
  call `(gptel-backoff--release fsm)`: if `:backoff-dispatched`, decrement
  (clamp 0), clear flag, pump queue (pop fsm, remove its nil-key alist
  entry, `(gptel--fsm-transition fsm 'WAIT)` → re-dispatch and re-acquire).
  With retries, each attempt re-enters WAIT → re-dispatch → re-acquire →
  release on removal — balanced, and streams hold their slot until the
  process fully ends (removal happens in the sentinel after cleanup).
- **Keying:** hash table keyed by `(gptel-backend-name backend)`; note
  `(host . key)` as an option if two backends share a provider limit.
- **Config:** `gptel-backoff--backend-settings` (name → plist) + defcustom
  default, per resolution 3.

### 4. Streaming truncation detail

Verified: `gptel-curl--stream-insert-response` (gptel.el:1841) inserts
chunks as they arrive and tracks `info :tracking-marker` (and
`:reasoning-marker` for reasoning blocks). On a mid-stream error the
`RTRY` handler must, before re-entering WAIT, delete
`(tracking-marker .. position-marker)` (and reasoning region) or the
retry will duplicate output. Non-streaming paths (`gptel--insert-response`
1765) insert only on success, so no cleanup needed there. Guard with
`buffer-live-p`; skip truncation for custom fsms without a marker
(document).

### 5. Files and edits summary

| File | Change |
|---|---|
| `gptel-backoff.el` (new) | retryability generic + defaults, backoff delay + jitter, RTRY install/predicate/handler, fire timer, concurrency limiter (acquire/release/queue) |
| `gptel-request.el` | parse+keep `:http-headers` in url+curl paths (4 call sites); `gptel-request` `&key (retry t)` + `gptel-backoff--install` call on resolved fsm; `gptel-backoff--release` at the 4 alist-removal points; require/declare gptel-backoff |
| `gptel.el` | `(require 'gptel-backoff)`; optionally wire concurrency config defcustom |
| `gptel-anthropic.el`, `gptel-openai.el`, `gptel-gemini.el` | `cl-defmethod gptel-backoff--retryable-p` overrides if provider semantics differ (optional) |
| constructors `gptel-make-*` (openai/anthropic/gemini/ollama/kagi/bedrock/gh) | plumb `:concurrency` / `:retry` `&key` into backend struct (or use global alist) |

### 6. Pitfalls / testing

- Timers do not bind `current-buffer` — capture fsm/buffer in the
  closure, `with-current-buffer` explicitly, guard `buffer-live-p`.
- Stale timers on a reused fsm: capture attempt id at schedule time; bail
  in the timer body if `(gptel-fsm-state fsm)` is no longer RTRY or the
  id != `:backoff-attempts`; `cancel-timer` on abort (`gptel-abort`
  path, ABRT handler).
- Timers only run while Emacs waits; the parked RTRY state is fine for
  this. `inhibit-quit` is t in timers — keep the timer body short.
- ert: in batch mode timers don't fire unless the test pumps
  `(accept-process-output 0.1)` in a bounded loop; bind delay to 0 in
  tests; clean up timers in `unwind-protect`; seed `random` for
  deterministic jitter (structure backoff as a pure injectable function).
- Never retry 401/403/400/context-length errors; unknown error ->
  terminal, don't retry.

## Open questions — resolutions

1. **`gptel--handle-wait` idempotency: safe.** It (gptel-request.el:1900)
   only resets info keys and dispatches; marker creation lives only in the
   insert callbacks. BUT the RTRY handler must additionally clear stream
   state after truncating partial output: `:tracking-marker`,
   `:reasoning-marker`, `:reasoning-block`, `:partial_text`,
   `:partial_reasoning`, `:partial_json` (none are in handle-wait's reset
   list), else the retried stream appends to the stale marker.
2. **Count WAIT only.** TRET is not a network phase
   (`gptel--handle-tool-result` ~2020 only injects tool results and
   transitions). Each network attempt is exactly one `WAIT→TYPE`, so that
   is the release point.
3. **Global alist, not struct slots (v1).** `gptel-backend-name` is unique
   (`gptel--known-backends` keyed by name). A struct slot would require
   adding a new `&key` to 13+ `gptel-make-*` constructors plus the
   `gptel-backend` customize `:get`/`:set` round-trip. Use
   `gptel-backoff--backend-settings` (name → plist) with accessor
   `gptel-backoff--settings` = entry → struct slot (future) → default.
   Revisit struct slot if upstream wants it.
4. **Yes, honor `retry-after` as a limiter cooldown.** Set a per-backend
   `until = now + retry-after + jitter`; `acquire` refuses while
   `(time-less-p (current-time) until)`. Active only when the limiter is
   enabled; gate with `gptel-backoff--respect-retry-after` (default t).
   Directly serves the "avoid synchronized retry storms" goal.
5. **Don't prompt; auto-retry silently, bounded by max-retries and
   `x-should-retry: false`; keep abort available.** Status via existing
   `gptel--update-status` (" Retrying in Ns (M/K)"). On exhaustion, ERRS
   handlers run normally. While in RTRY/QUEUE, register
   `(nil . (fsm cleanup-fn))` in `gptel--request-alist` so the existing
   `gptel-abort` finds the request with **zero changes** to it (cleanup-fn
   cancels timer / removes from queue; must not `delete-process` on nil).
   Optional `gptel-backoff-confirm` (default nil) for interactive
   first-retry confirmation.

### Mechanical consequences (from resolutions)

- **Release point = `gptel--request-alist` removal**, not a transition
  advise. The advise fires at `WAIT→TYPE`, which for streaming is stream
  *start* — too early (would over-admit). The universal "attempt done"
  point is alist-entry removal, in 4 places: url callback (~2727), curl
  sentinel (~3174), stream cleanup (~3026), `gptel-abort` (~2400). Wrap
  each in `(gptel-backoff--release fsm)`, decrementing only when the fsm's
  `:backoff-dispatched` flag is set (then clear it) — no-ops for
  never-dispatched queued entries.
- **Limiter uses a `QUEUE` state**, not a WAIT self-transition. Over
  limit: wrapper transitions `WAIT→QUEUE`; resume is `QUEUE→WAIT`,
  re-running WAIT handlers → wrapper re-acquires. Clean diagnostic state,
  no self-transition ambiguity, abort/status key on it.

## Implementation status

Branch: `feature/backoff-retry-limiter` (created).

- [x] `PLAN.md` — design + resolutions finalized.
- [x] **Branch created** `feature/backoff-retry-limiter`.
- [x] **`gptel-backoff.el` (new file)** written (retryability generic,
      backoff delay + jitter, RTRY/QUEUE install, limiter semaphore,
      parked-request bookkeeping, retry timer, stream truncation).
- [x] **`gptel-request.el`** fully wired (see bugfixes below):
  - [x] require + declare gptel-backoff
  - [x] `gptel-request` `&key (retry t)` + `gptel-backoff--install` call
  - [x] `gptel--parse-http-headers` helper + `gptel--url-parse-response`
        returns 5th element headers
  - [x] url callback: plist-put `:http-headers` + `gptel-backoff--release`
  - [x] `gptel-curl--parse-response` returns 5th element headers
  - [x] curl sentinel destructure 5-tuple + `:http-headers` + release
  - [x] curl stream-cleanup destructure 5-tuple + `:http-headers` + release
- [x] `gptel.el`: `(require 'gptel-backoff)`
- [ ] constructors: plumb `:concurrency` etc via
      `gptel-backoff--backend-settings` (no struct-slot churn, per res. 3)
- [x] byte-compile check + fix warnings (all three files compile clean;
      only pre-existing warning at gptel-request.el:1061 remains)
- [ ] smoke test (fake 429 backend, retry, jitter, limiter, abort) —
      FSM-level simulations pass; end-to-end curl/url-retrieve smoke test
      still TODO

### Bugfix round 1 (elisp-expert review + batch simulation, applied Aug 24)

The initial implementation had three real FSM-ordering bugs, all found by
simulating the transport callback flow against the installed table:

1. **Dead `parked-p` branch (was: callback fired on every transient error).**
   Transport callbacks checked `(gptel-backoff--parked-p fsm)` immediately
   after `WAIT→TYPE`, but at that instant the state is always `TYPE` — RTRY
   is only *reached* on the *next* transition (`TYPE→next`). So the branch
   never ran and `(funcall callback nil info)` was delivered on every
   retryable 429/5xx. For custom fsms (gptel-rewrite) a nil callback is
   terminal, so a transient failure would cancel the rewrite.
   **Fix:** the url + curl-sentinel callbacks now branch on
   `(and (gptel-backoff--installed-p fsm) (gptel-backoff--retry-p info))`
   *before* the callback; in the retry case they explicitly transition
   `TYPE→RTRY` and skip the callback entirely. The parked state is thus
   entered deliberately, not via a dead check.

2. **curl sentinel trailing transition re-issued the request instantly
   (backoff bypass).** After `TYPE→next` parked the FSM in RTRY, the
   sentinel's unconditional trailing `(gptel--fsm-transition fsm)` followed
   the `(RTRY (t . WAIT))` row and immediately re-entered WAIT, re-firing
   the network request before the timer could fire; the timer later bailed
   (state ≠ RTRY), leaving a stale `(nil . (fsm cleanup-fn))` entry in
   `gptel--request-alist`.
   **Fix:** sentinel no longer has a trailing transition. Each branch
   advances the FSM exactly once past the TYPE dispatch point. The shared
   epilogue only cleans the alist entry and releases the slot.

3. **stream-cleanup announced success on retryable mid-stream errors.**
   It always ran `(funcall callback t info)` for HTTP 200 before the
   `TYPE→next` transition could route to RTRY, so an Anthropic
   `overloaded_error` mid-stream produced a phantom success.
   **Fix:** the success callback is now gated on
   `(not (and installed-p retry-p))`; the transition to RTRY/ERRS happens
   first, and the terminal nil callback is delivered only for non-parked
   failures. The function also tolerates the filter never having done
   `WAIT→TYPE` (empty/connection-failed response).

Also fixed in this round:

- **`gptel-abort` now finds parked (nil-keyed) requests.** The original
  `when-let*` required a non-nil `proc`, so a request parked in RTRY/QUEUE
  (alist key `nil`) was not abortable. `proc` is now obtained inside the
  body after the lookup.
- **Limiter gate `unwind-protect` corrected.** `:backoff-dispatched` is set
  before dispatch (so a synchronous throw inside `gptel--handle-wait`
  actually releases the slot) and cleared in the cleanup branch.
- **`gptel-backoff--installed-p` added** so the transport callbacks can
  distinguish "backoff installed" (skip callback on retryable error) from
  "`:retry nil`, pre-feature behavior" (always call the callback).

The design decision to keep the user callback *before* `TYPE→next` in the
success path is deliberately retained: the elisp-expert review confirmed
`:tool-use` is a parse product (so dispatch is safe either way), but
TOOL/DONE handlers assume the response is already in the buffer (marker /
overlay layout), so the callback must run before those handlers.

### Remaining work

- [ ] End-to-end smoke test with a fake 429 backend (url-retrieve and curl
      transports, streaming + non-streaming): verify a retry is issued
      after the backoff delay, output isn't duplicated, the limiter queues
      and releases, and abort works from RTRY/QUEUE.
- [ ] ert tests (timer pumping, seeded jitter, semaphore accounting,
      stream truncation).
- [ ] Provider overrides for `gptel-backoff--retryable-p` where semantics
      differ (openai/anthropic/gemini) — optional, defaults are
      conservative.
- [ ] Decide whether `:concurrency` should also be plumbed through the
      `gptel-make-*` constructors (currently via
      `gptel-backoff--backend-settings` only).
- [ ] Verify tool-call flow end-to-end with the reordered sentinel (no
      trailing transition) — the non-retry path is unchanged, but needs a
      live tool-use test.

