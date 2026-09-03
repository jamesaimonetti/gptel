# Plan: Time-bucketed `gptel-usage-report`

## Context and goals

`gptel-usage-report` (and `gptel-usage-report SINCE`) renders one Org table
aggregating **all** records from `gptel-usage-log-file` into per-(backend,
model) rows, from v1/v2 records read by `gptel-usage--read-log`.

Goal: let the user choose a **date grouping** — by day, by week, by month, by
year, or all-time (no grouping) — as configurable options. Each grouping gets a
report shape that makes the time dimension visible, and the implementation
stays compatible with the existing log schema (append-only, mixed v1/v2
records). Each record's `:timestamp` string is `"%Y-%m-%dT%H:%M:%S%z"` (local
time), which is exactly what every bucketing below needs; no log-format change
required.

## Configuration

```elisp
(defcustom gptel-usage-report-grouping 'all
  ;; `all' | `day' | `week' | `month' | `year'
  )

(defcustom gptel-usage-report-max-periods 24
  ;; collapses oldest periods into a "..." summary when exceeded
  )
```

## Report shapes

- **all** — unchanged: single table, `Backend Model Reqs Input Output CacheRd
  CacheWr Cost (USD)`, sorted by cost desc then requests desc, `Total` row.
- **day** — one combined table with a leading `Period` column (`%Y-%m-%d`),
  one row per (period, backend, model), hline between periods, final `Total`.
- **week** — label `%G-W%V` (ISO week-year; verified `2026-01-01`→`2026-W01`,
  `2026-01-05`→`2026-W02`; sort-safe and never collides across a year). One
  `<<< LABEL` table per period, each with its own `Total` row, then a final
  overall `Total` table.
- **month** — label `%Y-%m`; same per-period layout.
- **year** — label `%Y`; same per-period layout.

Bucket key = `format-time-string` of the record's local timestamp. Missing or
unparseable timestamps go in a `"?"` bucket (kept as its own last group, never
counted against the cap). The `since` filter applies before bucketing.
`gptel-usage-report-max-periods` collapses the oldest periods into a `"..."`
group so the day report shows at most `max-periods` blocks.

## Implementation

1. Add the two defcustoms after `gptel-usage-log-file`.
2. Extract `gptel-usage--report-table (records &optional period-label)` (pure
   refactor of the current aggregation + table body), plus
   `gptel-usage--aggregate`, `gptel-usage--report-day-table`,
   `gptel-usage--insert-unknown-note`.
3. Add `gptel-usage--bucket-key (record grouping)` (guards against
   `date-to-time` silently accepting garbage: regex-validates the timestamp
   shape first) and `gptel-usage--group-records (records grouping)` (hash
   grouped, alist sorted by label, `?` sorts last), and
   `gptel-usage--cap-periods`.
4. Rewrite `gptel-usage-report (&optional grouping since)`:
   - Interactive: `completing-read` for the grouping, prefix arg still prompts
     for `since`.
   - Backward compatibility: a time value as the sole argument still means
     SINCE (detected via `(not (memq grouping '(nil all day week month year)))`).
   - Header note gains `-- grouped by X`, and the grouped total table is now
     labeled `<<<Total` so it is visible and addressable.
   - Empty records: single "No usage records..." message (all-time path).

## Tests

- Existing report tests unchanged (all-time path is byte-identical).
- New helpers `gptel-usage-test--report-tables` / `gptel-usage-test--report-heads`
  (scan every `^|` table via `org-table-to-lisp` + every `^<<<label$`).
- New tests: day (Period col + total), week (ISO labels W01/W02),
  month (per-period sets + total), year, defcustom default, legacy since,
  missing date → `?` group, max-periods cap → `...` + newest.
