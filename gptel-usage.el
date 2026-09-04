;;; gptel-usage.el --- Track token usage and cost per backend/model -*- lexical-binding: t; -*-

;; Records :tokens-full from each gptel request's FSM info plist -- the
;; same (:input :output :cached :cache) data that drives gptel's own
;; header-line stats display, so there's no need to re-parse raw
;; response JSON here at all.  :tokens-full is the cumulative usage for
;; the whole request, which for tool-call (multi-turn) requests is the
;; figure the provider actually bills; :tokens only covers the final
;; turn.  :tokens-full is preferred, falling back to :tokens for FSMs
;; that never accumulated one (single-turn requests carry the same
;; numbers in both keys, so this is just the all-time simple path).
;;
;; Note: `gptel-post-response-functions' is called with the response
;; buffer positions (BEG END), NOT the FSM, so this package instead
;; advises the FSM handlers `gptel--handle-post-insert' and
;; `gptel--handle-error', which do receive the FSM as their sole
;; argument.
;;
;; COVERAGE.  Which requests get tracked depends on the handler table of
;; the FSM driving them, since only some tables run the advised handlers:
;;
;;   `gptel-send' and the transient menu   tracked
;;       Both use `gptel-send--handlers', whose DONE/ERRS entries are
;;       `gptel--handle-post-insert' / `gptel--handle-error'.
;;
;;   plain `gptel-request' callers         NOT tracked
;;       `gptel-request--handlers' uses `gptel--handle-post' for
;;       DONE/ERRS/ABRT instead.
;;
;;   `gptel-rewrite'                       NOT tracked
;;       `gptel--rewrite-handlers' has no DONE or ERRS entry at all.
;;
;; Extending coverage to those would mean also advising
;; `gptel--handle-post' (for `gptel-request') and finding another hook
;; point for `gptel-rewrite'; deliberately not done here.
;;
;; Records are appended, one per line, to `gptel-usage-log-file' as
;; plain printed plists -- durable across restarts, and readable back
;; with plain `read', no external format/dependency needed.
;;
;; REQUIRED SETUP:
;;   (require 'gptel-usage)
;;   (gptel-usage-mode 1)

(require 'cl-lib)

(declare-function gptel-fsm-info "gptel-request")
(declare-function gptel-backend-name "gptel")
(declare-function gptel--to-string "gptel")
(declare-function gptel--update-token-usage "gptel")
(declare-function org-table-align "org-table")

(defvar gptel--token-usage-strings)

(defgroup gptel-usage nil
  "Token usage and cost tracking for gptel."
  :group 'gptel)

(defcustom gptel-usage-log-file (expand-file-name "gptel-usage.log" user-emacs-directory)
  "File where usage records are appended, one plist per line."
  :type 'file :group 'gptel-usage)

(defcustom gptel-usage-report-grouping 'all
  "How `gptel-usage-report' groups records in time.

A value of nil (or the symbol `all') treats every record as one
period, exactly like the pre-grouping report.  Otherwise records are
bucketed into periods and reported with one Org table per period
(day: one combined table with a Period column), plus an overall
total table.  Labels are local-time day (`2026-01-31'), ISO week
(`2026-W05'), month (`2026-01') or year (`2026').

Used when `gptel-usage-report' is called without an explicit
grouping argument."
  :type '(choice (const :tag "All time (no grouping)" all)
                 (const :tag "By day" day)
                 (const :tag "By week (ISO)" week)
                 (const :tag "By month" month)
                 (const :tag "By year" year))
  :group 'gptel-usage)

(defcustom gptel-usage-report-max-periods 24
  "Maximum number of periods shown in a grouped `gptel-usage-report'.

When a grouping such as `day' would produce more periods than this,
the oldest periods are collapsed into a summary row/table labeled
\"...\" and only the newest `gptel-usage-report-max-periods'
periods are shown in detail.  The overall total table always
covers everything."
  :type 'integer
  :group 'gptel-usage)

(defcustom gptel-usage-annotate-cache-ratio t
  "Whether `gptel-usage-report' shows a Cache% column.

When non-nil (the default), the report tables gain a Cache% column:
CacheRd / (Input + CacheRd + CacheWr), i.e. the fraction of input
tokens served from the prompt cache.  A low number next to healthy
cache write counts is the first sign that breakpoints are missing or
the cache keeps expiring (Anthropic's 5-minute default TTL), which is
exactly the failure mode this column exists to surface.

Set to nil to revert to the pre-annotation column set (Backend, Model,
Reqs, Input, Output, CacheRd, CacheWr, Cost)."
  :type 'boolean
  :group 'gptel-usage)

(defun gptel-usage--cache-ratio (input cached cache)
  "Return the prompt-cache hit ratio for INPUT, CACHED and CACHE tokens.

CACHE (cache writes/creation) is folded into the total alongside
INPUT because Anthropic bills it as input; the ratio is CACHED /
\(INPUT + CACHED + CACHE).  Returns a formatted percentage string
with one decimal place, or \"0.0\" when there are no input tokens of
any kind."
  (let ((total (+ input cached cache)))
    (if (zerop total)
        "0.0"
      (format "%.1f" (* 100.0 (/ (float cached) total))))))

(defconst gptel-usage-record-version 2
  "Schema version stamped on new usage records, under the :v key.

Version history:

  (absent)  Original format.  Keys :timestamp :backend :model :input
            :output :cached :cost.  Cache writes were not recorded, and
            on backends that report them (Anthropic, Bedrock) those
            tokens are included in :input and were billed at the input
            rate.  Such records cannot be corrected after the fact.

  2         Adds :cache, the number of cache write (creation) tokens,
            and prices cache reads and writes separately.  See
            `gptel-usage-pricing'.

Records are only ever appended, so a log can hold a mix of versions.
Readers should treat a missing :v as version 1.")

(defcustom gptel-usage-pricing
  '(;; Prices are USD per MILLION tokens. Verify against your
    ;; provider's current pricing page before trusting cost totals --
    ;; these are a starting point, not guaranteed current.
    ("claude-opus-5"   . (:input 5.0  :output 25.0 :cache-read 0.5))
    ;; Fill in as you confirm current pricing -- left nil deliberately
    ;; rather than guessed:
    ("claude-sonnet-5" . nil)
    ("claude-haiku-4-5-20251001" . nil)
    ;; Opaque proxy/aggregator pricing -- fill in from AirRouter's own
    ;; dashboard/docs if it exposes per-model rates.
    ("DeepSeek-V4-Flash" . nil))
  "Alist of (MODEL-NAME . PLIST) giving per-million-token USD pricing.

All rates are in USD per MILLION tokens.  Recognized PLIST keys:

  :input        fresh (uncached) input tokens
  :output       generated tokens
  :cache-read   tokens read from a prompt cache, usually much cheaper
                than fresh input
  :cache-write  tokens written to a prompt cache (\"cache creation\"),
                usually more expensive than fresh input

  :cached       deprecated alias for :cache-read, still honored

Only providers with explicit prompt caching (Anthropic, Bedrock)
report cache writes; for others the write count is zero and
:cache-write is irrelevant.

A nil PLIST means \"unknown, don't compute a cost for this model\"
rather than guessing zero.  The same applies per-rate: if a model
used tokens of some kind but the matching rate is not configured,
the cost is reported as unknown instead of silently billing those
tokens at zero.  So a model that uses cache writes needs a
:cache-write rate before its cost is counted."
  :type '(alist :key-type string
                :value-type
                (choice (const :tag "Unknown (don't compute cost)" nil)
                        (plist :key-type
                               (choice (const :input) (const :output)
                                       (const :cache-read) (const :cache-write)
                                       (const :cached))
                               :value-type number)))
  :group 'gptel-usage)

;;;###autoload
(define-minor-mode gptel-usage-mode
  "Track token usage and cost for gptel requests.

When enabled, records usage from each completed gptel request to
`gptel-usage-log-file' by advising the FSM handlers
`gptel--handle-post-insert' and `gptel--handle-error', which run
with the request FSM as their sole argument.  See
`gptel-usage-report'."
  :global t
  :group 'gptel-usage
  (if gptel-usage-mode
      (progn
        (advice-add 'gptel--handle-post-insert :after #'gptel-usage--record)
        (advice-add 'gptel--handle-error :after #'gptel-usage--record))
    (advice-remove 'gptel--handle-post-insert #'gptel-usage--record)
    (advice-remove 'gptel--handle-error #'gptel-usage--record)))

(defun gptel-usage--cost (model tokens)
  "Return the USD cost of TOKENS under MODEL's pricing, or nil if unknown.

TOKENS is a token plist as produced by gptel's backends, with keys
:input, :output, :cached (cache reads) and :cache (cache writes, also
called cache creation).  See `gptel-usage-pricing' for the rates.

Returns nil when MODEL has no pricing configured at all, and also when
MODEL used a nonzero number of tokens of some kind whose rate is
missing: billing those at zero would silently understate the cost, so
they are reported as unknown instead.

Note on cache writes: backends that report them (Anthropic, Bedrock)
fold the write count into :input, i.e. :input already includes :cache.
This function therefore charges (:input - :cache) at the input rate and
:cache at the write rate, so writes are not billed twice.  Backends
without prompt caching report no :cache and are unaffected."
  (when-let* ((pricing (alist-get model gptel-usage-pricing nil nil #'equal)))
    (let* ((output (or (plist-get tokens :output) 0))
           (cache-write (or (plist-get tokens :cache) 0))
           (cache-read (or (plist-get tokens :cached) 0))
           ;; :input includes cache writes on backends that report them.
           ;; `max' guards against a future upstream change to that invariant
           ;; producing a negative (cost-reducing) term.
           (input (max 0 (- (or (plist-get tokens :input) 0) cache-write)))
           (input-rate (plist-get pricing :input))
           (output-rate (plist-get pricing :output))
           ;; :cached is the historical name for the cache read rate.
           (read-rate (or (plist-get pricing :cache-read)
                          (plist-get pricing :cached)))
           (write-rate (plist-get pricing :cache-write)))
      ;; Unknown rather than zero: only demand a rate for token kinds
      ;; actually used, so a model that never touches the cache does not
      ;; need cache rates configured.
      (unless (or (and (> input 0) (null input-rate))
                  (and (> output 0) (null output-rate))
                  (and (> cache-read 0) (null read-rate))
                  (and (> cache-write 0) (null write-rate)))
        (/ (+ (* input (or input-rate 0))
              (* output (or output-rate 0))
              (* cache-read (or read-rate 0))
              (* cache-write (or write-rate 0)))
           1000000.0)))))

(defun gptel-usage--record (fsm)
  "Record token usage for the just-completed request driving FSM.

Meant as :after advice for `gptel--handle-post-insert' (and
`gptel--handle-error'), which receive the FSM as their sole argument.
Silently does nothing if the FSM has no token data (e.g. the
provider didn't report usage, or the request failed before any usage
was returned).  Errors are caught so tracking can never break gptel
request handling.

Records :tokens-full, the cumulative usage for the whole request --
the figure gptel's own header line shows and the one the provider
bills.  For single-turn requests :tokens-full carries the same
numbers as :tokens; for multi-turn (tool call) requests it sums every
round trip, whereas :tokens only holds the final turn.  :tokens is
used as a fallback for FSMs that never accumulated a :tokens-full
(e.g. synthetic or pre-v1.0 FSMs).

Recording is idempotent per turn: the token plist recorded last is
remembered on the FSM info (under :gptel-usage-last-tokens) and
compared with `eq', so a request that reaches more than one advised
handler is logged only once.  Each turn of a multi-turn (tool call)
request gets a fresh :tokens-full object from the backend parser, so
retries and subsequent turns are still recorded when they occur."
  (condition-case-unless-debug err
      (let* ((info (gptel-fsm-info fsm))
             ;; :tokens-full is the whole-request total (what the provider
             ;; bills); :tokens is only the final turn, which badly
             ;; understates agentic/tool-call requests.  Prefer the former,
             ;; fall back to the latter for FSMs without cumulative data.
             (tokens (or (plist-get info :tokens-full)
                         (plist-get info :tokens)))
             (backend (plist-get info :backend))
             (model (gptel--to-string (plist-get info :model))))
        (when (and tokens
                   ;; Skip if this exact usage was already recorded, e.g. when
                   ;; both an error and a completion handler run for one turn.
                   (not (eq tokens (plist-get info :gptel-usage-last-tokens))))
          (let* ((cost (gptel-usage--cost model tokens))
                 (coding-system-for-write 'utf-8-unix)
                 (record (list :v gptel-usage-record-version
                               :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                               :backend (and backend (gptel-backend-name backend))
                               :model model
                               :input (or (plist-get tokens :input) 0)
                               :output (or (plist-get tokens :output) 0)
                               :cached (or (plist-get tokens :cached) 0)
                               ;; Cache writes (creation).  Only some backends
                               ;; report these; zero elsewhere.
                               :cache (or (plist-get tokens :cache) 0)
                               :cost cost))) ; nil if pricing unknown for this model
            (with-temp-buffer
              (insert (prin1-to-string record) "\n")
              (write-region (point-min) (point-max) gptel-usage-log-file 'append 'silent))
            ;; Feed the per-buffer header line totals.  Done after the write
            ;; so a display problem cannot cost us the record itself.
            (gptel-usage--accumulate (plist-get info :buffer) cost)
            ;; NOTE: mutate the plist in place (plist-put appends at the tail)
            ;; so the FSM's own info reference sees the marker.
            (plist-put info :gptel-usage-last-tokens tokens))))
    (error (message "gptel-usage: failed to record usage: %S" err))))

;;;; Per-buffer cost, shown in the header line

;; These mirror the scopes of gptel's own token indicator: the usage for
;; the last request, and the running total for this buffer.  Costs across
;; all buffers and sessions live in the log; see `gptel-usage-report'.

(defvar-local gptel-usage--last-cost nil
  "USD cost of the last recorded request in this buffer, or nil if unknown.")

(defvar-local gptel-usage--buffer-cost nil
  "Running USD cost of priced requests recorded in this buffer.

Nil until the first priced request is recorded, so that a buffer with
no usage yet can be told apart from one whose usage genuinely cost
nothing.  Displaying the former as \"$0.00\" would claim the session
was free.")

(defvar-local gptel-usage--buffer-cost-partial nil
  "Non-nil if some request in this buffer had no pricing configured.
The buffer total then understates the true cost, and is displayed with
a trailing \"+\".")

(defun gptel-usage--accumulate (buffer cost)
  "Fold COST into the per-buffer running totals of BUFFER.

COST is nil when the model has no pricing configured; that request is
excluded from the total and flagged, rather than counted as free."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq gptel-usage--last-cost cost)
      (if cost
          (setq gptel-usage--buffer-cost (+ (or gptel-usage--buffer-cost 0.0) cost))
        (setq gptel-usage--buffer-cost-partial t))
      (force-mode-line-update))))

(defun gptel-usage--format-cost (cost &optional partial)
  "Format COST as a compact USD string for the header line.

Returns nil when COST is nil, i.e. unknown or nothing recorded yet, so
that the indicator stays absent rather than claiming a request or
session was free.

With PARTIAL, append \"+\" to mark a total that omits requests with no
pricing configured."
  (when cost
    (concat
     (cond
      ;; Genuinely zero: a priced model can legitimately cost nothing.
      ((zerop cost) "$0.00")
      ;; Too small to show at 4dp.  "$0.0000" would read as free, so
      ;; report it as a bound instead.
      ((< cost 0.00005) "<$0.0001")
      ;; Sub-dollar costs are the common case per request; keep enough
      ;; precision to distinguish them.
      ((< cost 1.0) (format "$%.4f" cost))
      (t (format "$%.2f" cost)))
     (and partial "+"))))

(defun gptel-usage--annotate-header (&rest _)
  "Append per-buffer costs to gptel's token usage indicator.

Meant as :after advice on `gptel--update-token-usage', which rebuilds
the display strings from scratch on every update, so the costs must be
re-appended each time.

`gptel--token-usage-strings' is a list (IDX REQUEST BUFFER); the two
cost scopes are matched to the two token scopes."
  (condition-case-unless-debug err
      (when (consp gptel--token-usage-strings)
        (when-let* ((s (nth 1 gptel--token-usage-strings))
                    (c (gptel-usage--format-cost gptel-usage--last-cost)))
          (setf (nth 1 gptel--token-usage-strings) (concat s " " c)))
        (when-let* ((s (nth 2 gptel--token-usage-strings))
                    (c (gptel-usage--format-cost gptel-usage--buffer-cost
                                                 gptel-usage--buffer-cost-partial)))
          (setf (nth 2 gptel--token-usage-strings) (concat s " " c))))
    (error (message "gptel-usage: failed to annotate header line: %S" err))))

;;;###autoload
(define-minor-mode gptel-usage-header-line-mode
  "Show per-buffer request costs in gptel's header line.

Extends gptel's token usage indicator with the USD cost of the last
request and the running cost of the current buffer, matching the two
scopes that indicator already toggles between.  Click it to switch
scope, as before.

A total ending in \"+\" means some request in the buffer used a model
with no pricing configured (see `gptel-usage-pricing'), so the true
cost is higher.

This only displays costs; recording them requires `gptel-usage-mode'.
For usage across all buffers and sessions, see `gptel-usage-report'."
  :global t
  :group 'gptel-usage
  (if gptel-usage-header-line-mode
      (advice-add 'gptel--update-token-usage :after #'gptel-usage--annotate-header)
    (advice-remove 'gptel--update-token-usage #'gptel-usage--annotate-header)))

(defun gptel-usage--org-escape (s)
  "Return S as a string safe to place inside an Org table cell.

A literal \"|\" would end the cell and corrupt the table, so it is
escaped the way Org expects; newlines and tabs are folded to spaces for
the same reason.  Nil becomes \"?\", matching how unknown backends and
models are displayed."
  (if (null s)
      "?"
    (replace-regexp-in-string
     "|" "\\\\vert{}"
     (replace-regexp-in-string "[\n\r\t]+" " " (gptel--to-string s)))))

(defun gptel-usage--read-log ()
  "Return all records from `gptel-usage-log-file' as a list of plists."
  (if (not (file-exists-p gptel-usage-log-file))
      nil
    (with-temp-buffer
      (insert-file-contents gptel-usage-log-file)
      (goto-char (point-min))
      (let (records)
        (while (not (eobp))
          (condition-case nil
              (push (read (current-buffer)) records)
            (error nil))
          (forward-line 1))
        (nreverse records)))))

;;;###autoload
(defun gptel-usage-report (&optional grouping since)
  "Show recorded token usage and cost, optionally grouped by time.

With GROUPING \(one of `day', `week', `month', `year', `all', or nil
for all-time\), records from `gptel-usage-log-file' are bucketed
into periods and reported as one Org table per period (plus an
overall total table), instead of the single all-time table.  `day'
uses one combined table with a Period column; `week' (ISO),
`month' and `year' render a labeled table per period.  When GROUPING
is nil, `gptel-usage-report-grouping' is consulted.

With SINCE \(a time value), only records from that point on are
included; the filter is applied before grouping/bucketing.

Interactively, the grouping is read from the minibuffer; a prefix
argument additionally prompts for the starting date.
Backward compatibility: calling with a time value as the sole
argument still means SINCE, as in the pre-grouping API.

The report is one or more Org tables in an `org-mode' buffer, so it
can be sorted, exported or extended with table formulas.  Costs are
plain numbers rather than currency strings to keep that column
numeric.  The buffer is left writable for that reason; it is
regenerated from `gptel-usage-log-file' on every call, so edits are
never persisted.

See also `gptel-usage-report-grouping' and
`gptel-usage-report-max-periods'."
  (interactive
   (list (intern (completing-read
                  "Group by: " '("all" "day" "week" "month" "year")
                  nil t nil nil "all"))
         (when current-prefix-arg
           (let ((str (read-string "Include records since (e.g. 2024-01-01): ")))
             (unless (string-blank-p str)
               (or (ignore-errors (date-to-time str))
                   (user-error "Cannot parse time: %s" str)))))))
  ;; Legacy callers may pass the since time as the first argument.  A time
  ;; value is a cons or number, never one of the grouping keywords.
  (when (and (null since)
             (not (memq grouping '(nil all day week month year))))
    (setq since grouping grouping nil))
  (require 'org)
  (let* ((records (gptel-usage--read-log))
         (records (if since
                      (cl-remove-if
                       (lambda (r) (time-less-p (date-to-time (plist-get r :timestamp)) since))
                       records)
                    records))
         (grouping (or grouping gptel-usage-report-grouping))
         (grouping (if (memq grouping '(all day week month year)) grouping 'all))
         (periods (gptel-usage--cap-periods
                   (gptel-usage--group-records records grouping)
                   gptel-usage-report-max-periods)))
    (with-current-buffer (get-buffer-create "*gptel-usage*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "#+TITLE: gptel token usage\n")
        (insert (format "# Generated %s%s%s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M")
                        (pcase grouping
                          ('all "")
                          (g (format " -- grouped by %s" g)))
                        (if since
                            (concat ", covering records since "
                                    (format-time-string "%Y-%m-%d %H:%M" since))
                          "")))
        (cond
         ;; All-time: a single table, byte-for-byte the pre-grouping output.
         ((eq grouping 'all)
          (gptel-usage--report-table records nil))
         ;; Day: one combined table with a Period column.
         ((eq grouping 'day)
          (gptel-usage--report-day-table periods))
         ;; Week/month/year: one labeled table per period, then an overall
         ;; total table.
         (t
          (pcase-dolist (`(,label . ,recs) periods)
            (gptel-usage--report-table recs label))
          (insert "\n")
          (gptel-usage--report-table records "Total")))
        (when (null records)
          (insert "No usage records"
                  (if since " in the selected period" "")
                  ".  Usage is tracked while ~gptel-usage-mode~ is enabled.\n"))
        ;; Org mode last: it resets buffer-local state, and the table needs to
        ;; exist before it can be aligned.
        (org-mode)
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (while (re-search-forward "^|" nil t)
            (org-table-align)))
        (goto-char (point-min))
        (set-buffer-modified-p nil))
      (display-buffer (current-buffer)))))

(defun gptel-usage--aggregate (records)
  "Aggregate RECORDS (usage plists) into per-(backend, model) rows.

Returns an alist of \(KEY . SUMMARY), where KEY is (BACKEND . MODEL)
and SUMMARY is a plist with :input :output :cached :cache :cost :n
and :cost-known.  Sorted most expensive first, then most requests.

Pre-v2 records have no :cache key; treat it as zero.  :input is
fresh input, i.e. with cache writes taken out, since backends that
report writes fold them into :input (see `gptel-usage--cost').  This
keeps the columns disjoint, so Input + CacheRd + CacheWr is the true
token total."
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (r records)
      (let* ((key (cons (plist-get r :backend) (plist-get r :model)))
             (cur (or (gethash key groups)
                      (list :input 0 :output 0 :cached 0 :cache 0
                            :cost 0.0 :n 0 :cost-known t))))
        (setf (gethash key groups)
              (list :input (+ (plist-get cur :input)
                              (max 0 (- (or (plist-get r :input) 0)
                                        (or (plist-get r :cache) 0))))
                    :output (+ (plist-get cur :output) (or (plist-get r :output) 0))
                    :cached (+ (plist-get cur :cached) (or (plist-get r :cached) 0))
                    :cache (+ (plist-get cur :cache) (or (plist-get r :cache) 0))
                    :cost (+ (plist-get cur :cost) (or (plist-get r :cost) 0.0))
                    :n (1+ (plist-get cur :n))
                    :cost-known (and (plist-get cur :cost-known) (plist-get r :cost))))))
    ;; `maphash' order is unspecified, so collect and sort for a stable
    ;; report: most expensive first, then most requests.
    (let (rows)
      (maphash (lambda (key v) (push (cons key v) rows)) groups)
      (sort rows
            (lambda (a b)
              (let ((ca (and (plist-get (cdr a) :cost-known)
                             (plist-get (cdr a) :cost)))
                    (cb (and (plist-get (cdr b) :cost-known)
                             (plist-get (cdr b) :cost))))
                (cond ((and ca cb (/= ca cb)) (> ca cb))
                      ((and ca (not cb)) t)
                      ((and cb (not ca)) nil)
                      (t (> (plist-get (cdr a) :n)
                            (plist-get (cdr b) :n))))))))))

(defun gptel-usage--insert-unknown-note (any-unknown)
  "Insert the /unknown/ pricing note when ANY-UNKNOWN is non-nil."
  (when any-unknown
    (insert "Total covers priced models only; rows reading /unknown/ are\n"
            "excluded because some models have no pricing configured --\n"
            "see ~gptel-usage-pricing~.\n")))

(defun gptel-usage--report-table (records &optional period-label)
  "Render one all-time-style Org table for RECORDS in the current buffer.

RECORDS is a list of usage plists as read by `gptel-usage--read-log'.
PERIOD-LABEL, when non-nil, is shown on a \"<<< LABEL\" line above
the table; grouped reports pass the period label, while the
all-time report and the final overall-total table pass nil.

The table has one row per (backend, model), columns Backend, Model,
Reqs, Input, Output, CacheRd, CacheWr and Cost (USD), plus a Cache%
column when `gptel-usage-annotate-cache-ratio' is non-nil, and ends
with a Total row.  Input is fresh input with cache writes taken out,
so the columns do not overlap; Cache% = CacheRd / (Input + CacheRd +
CacheWr).  Costs are bare numbers (no currency symbol) so Org treats
the column as numeric and table formulas work.

Appends the /unknown/ pricing note when some row has no pricing
configured (see `gptel-usage-pricing').  Returns non-nil when
RECORDS is non-empty; callers print their own empty-state message
otherwise."
  (when period-label
    (insert (format "<<<%s\n\n" period-label)))
  (let ((rows (gptel-usage--aggregate records)))
    (when rows
      (let ((total-cost 0.0)
            (any-unknown nil)
            (show-cache-ratio gptel-usage-annotate-cache-ratio)
            (tot-n 0) (tot-in 0) (tot-out 0) (tot-rd 0) (tot-wr 0))
        (insert (format "| Backend | Model | Reqs | Input | Output | CacheRd | CacheWr |%s Cost (USD) |\n"
                        (if show-cache-ratio " Cache% |" "")))
        (insert "|-\n")
        (pcase-dolist (`(,key . ,v) rows)
          (insert (format "| %s | %s | %d | %d | %d | %d | %d |%s %s |\n"
                          (gptel-usage--org-escape (car key))
                          (gptel-usage--org-escape (cdr key))
                          (plist-get v :n) (plist-get v :input)
                          (plist-get v :output) (plist-get v :cached)
                          (plist-get v :cache)
                          (if show-cache-ratio
                              (concat " "
                                      (gptel-usage--cache-ratio
                                       (plist-get v :input)
                                       (plist-get v :cached)
                                       (plist-get v :cache))
                                      " |")
                            "")
                          (if (plist-get v :cost-known)
                              (format "%.4f" (plist-get v :cost))
                            "unknown")))
          (cl-incf tot-n (plist-get v :n))
          (cl-incf tot-in (plist-get v :input))
          (cl-incf tot-out (plist-get v :output))
          (cl-incf tot-rd (plist-get v :cached))
          (cl-incf tot-wr (plist-get v :cache))
          (if (plist-get v :cost-known)
              (cl-incf total-cost (plist-get v :cost))
            (setq any-unknown t)))
        (insert "|-\n")
        (insert (format "| Total | | %d | %d | %d | %d | %d |%s %.4f |\n"
                        tot-n tot-in tot-out tot-rd tot-wr
                        (if show-cache-ratio
                            (concat " " (gptel-usage--cache-ratio
                                         tot-in tot-rd tot-wr) " |")
                          "")
                        total-cost))
        (insert "\n")
        (gptel-usage--insert-unknown-note any-unknown)
        t))))

(defun gptel-usage--report-day-table (periods)
  "Render one Org table for PERIODS with a Period column.

PERIODS is the alist from `gptel-usage--group-records': (PERIOD-LABEL
. PERIOD-RECORDS), ordered by label.  Every period contributes one
hrule-separated block of (backend, model) rows prefixed by the
period label; a final Total row sums the whole table.  Gains a
Cache% column when `gptel-usage-annotate-cache-ratio' is non-nil.
Appends the /unknown/ pricing note if any row lacks pricing.  Returns
non-nil when PERIODS is non-empty."
  (when periods
    (let ((first t)
          (show-cache-ratio gptel-usage-annotate-cache-ratio)
          (total-cost 0.0)
          (any-unknown nil)
          (tot-n 0) (tot-in 0) (tot-out 0) (tot-rd 0) (tot-wr 0))
      (insert (format "| Period | Backend | Model | Reqs | Input | Output | CacheRd | CacheWr |%s Cost (USD) |\n"
                      (if show-cache-ratio " Cache% |" "")))
      (pcase-dolist (`(,label . ,recs) periods)
        (unless first (insert "|-\n"))
        (setq first nil)
        (pcase-dolist (`(,key . ,v) (gptel-usage--aggregate recs))
          (insert (format "| %s | %s | %s | %d | %d | %d | %d | %d |%s %s |\n"
                          (gptel-usage--org-escape label)
                          (gptel-usage--org-escape (car key))
                          (gptel-usage--org-escape (cdr key))
                          (plist-get v :n) (plist-get v :input)
                          (plist-get v :output) (plist-get v :cached)
                          (plist-get v :cache)
                          (if show-cache-ratio
                              (concat " "
                                      (gptel-usage--cache-ratio
                                       (plist-get v :input)
                                       (plist-get v :cached)
                                       (plist-get v :cache))
                                      " |")
                            "")
                          (if (plist-get v :cost-known)
                              (format "%.4f" (plist-get v :cost))
                            "unknown")))
          (cl-incf tot-n (plist-get v :n))
          (cl-incf tot-in (plist-get v :input))
          (cl-incf tot-out (plist-get v :output))
          (cl-incf tot-rd (plist-get v :cached))
          (cl-incf tot-wr (plist-get v :cache))
          (if (plist-get v :cost-known)
              (cl-incf total-cost (plist-get v :cost))
            (setq any-unknown t))))
      (insert "|-\n")
      (insert (format "| Total | | | %d | %d | %d | %d | %d |%s %.4f |\n"
                      tot-n tot-in tot-out tot-rd tot-wr
                      (if show-cache-ratio
                          (concat " " (gptel-usage--cache-ratio
                                       tot-in tot-rd tot-wr) " |")
                        "")
                      total-cost))
      (insert "\n")
      (gptel-usage--insert-unknown-note any-unknown)
      t)))

(defun gptel-usage--cap-periods (periods max-periods)
  "Cap PERIODS to at most MAX-PERIODS displayed period blocks.

PERIODS is the alist from `gptel-usage--group-records', ordered by
label.  When its length exceeds MAX-PERIODS, the oldest periods are
merged into a single leading group labeled \"...\" so the report
shows exactly MAX-PERIODS blocks: the collapsed summary plus the
newest MAX-PERIODS - 1 periods in detail.  The \"?\" group (records
with unknown dates) never counts toward the cap and always remains
its own last group.

Returns a new alist; PERIODS is not modified."
  (if (or (null max-periods) (<= (length periods) max-periods))
      periods
    (let* ((unknown (and (equal (caar (last periods)) "?")
                         (car (last periods))))
           (rest (if unknown (butlast periods) periods))
           (n-drop (- (length rest) (1- max-periods)))
           (dropped (and (> n-drop 0) (cl-subseq rest 0 n-drop)))
           (kept (and (> n-drop 0) (cl-subseq rest n-drop))))
      (cond
       ((null dropped)
        (if unknown (append rest (list unknown)) periods))
       (t
        (append (list (cons "..." (apply #'append (mapcar #'cdr dropped))))
                kept
                (and unknown (list unknown))))))))

(defun gptel-usage--group-records (records grouping)
  "Group RECORDS (list of usage plists) under GROUPING.

GROUPING is one of `day', `week', `month', `year', or `all'/nil \(in
which case the single entry (nil . RECORDS) is returned).  Otherwise
returns an alist of (PERIOD-LABEL . PERIOD-RECORDS), ordered by
label \(which for the chosen labels is also chronological), with an
entry labeled \"?\" appended last for records whose :timestamp is
missing or unparseable.

See `gptel-usage--bucket-key' for the label format."
  (if (memq grouping '(all nil))
      (and records (list (cons nil records)))
    (let ((table (make-hash-table :test #'equal)))
      (dolist (r records)
        (let ((label (gptel-usage--bucket-key r grouping)))
          (puthash label (cons r (gethash label table)) table)))
      (let (groups)
        (maphash (lambda (label recs)
                   (push (cons label (nreverse recs)) groups))
                 table)
        ;; "?" sorts last, even after "..." (0x3F > 0x2E and > all digits).
        (sort groups (lambda (a b) (string< (car a) (car b))))))))

(defun gptel-usage--bucket-key (record grouping)
  "Return the period label for RECORD under GROUPING.

GROUPING is one of `day', `week', `month' or `year'.  The label is
the local-time formatted period: `%Y-%m-%d' for `day', ISO week
`%G-W%V' for `week' (the ISO week-year, so weeks straddling a year
sort correctly), `%Y-%m' for `month' and `%Y' for `year'.  A record
with a missing or unparseable :timestamp returns \"?\"."
  (let ((ts (plist-get record :timestamp)))
    ;; `date-to-time' silently maps garbage input to a fixed date instead of
    ;; signaling, so validate the shape our records are written in rather
    ;; than relying on an error.
    (if (and (stringp ts)
             (string-match-p
              "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}"
              ts))
        (format-time-string
         (pcase grouping
           ('day "%Y-%m-%d")
           ('week "%G-W%V")
           ('month "%Y-%m")
           ('year "%Y"))
         (date-to-time ts))
      "?")))

(provide 'gptel-usage)
;;; gptel-usage.el ends here
