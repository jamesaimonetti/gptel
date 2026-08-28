;;; gptel-usage.el --- Track token usage and cost per backend/model -*- lexical-binding: t; -*-

;; Records :tokens from each gptel request's FSM info plist -- the same
;; per-request (:input :output :cached :cache) data that drives gptel's
;; own header-line stats display, so there's no need to re-parse raw
;; response JSON here at all.
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
Silently does nothing if the FSM has no :tokens data (e.g. the
provider didn't report usage, or the request failed before any usage
was returned).  Errors are caught so tracking can never break gptel
request handling.

Recording is idempotent per turn: the :tokens plist recorded last is
remembered on the FSM info (under :gptel-usage-last-tokens) and
compared with `eq', so a request that reaches more than one advised
handler is logged only once.  Each turn of a multi-turn (tool call)
request gets a fresh :tokens object from the backend parser, so
retries and subsequent turns are still recorded when they occur.

Note: this records :tokens, the usage for this turn, not :tokens-full,
the cumulative usage for the whole request.  For a request that makes
tool calls and thus several round trips, only the turn that reached
the advised handler is logged."
  (condition-case-unless-debug err
      (let* ((info (gptel-fsm-info fsm))
             (tokens (plist-get info :tokens))
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
(defun gptel-usage-report (&optional since)
  "Show a summary of recorded token usage and cost, grouped by
backend and model. With SINCE (a time value), only include records
from that point on.

Interactively, a prefix argument prompts for the starting date.

The report is an Org table in an `org-mode' buffer, so it can be
sorted, exported or extended with table formulas.  Costs are plain
numbers rather than currency strings to keep that column numeric.
The buffer is left writable for that reason; it is regenerated from
`gptel-usage-log-file' on every call, so edits are never persisted."
  (interactive
   (list (when current-prefix-arg
           (let ((str (read-string "Include records since (e.g. 2024-01-01): ")))
             (unless (string-blank-p str)
               (or (ignore-errors (date-to-time str))
                   (user-error "Cannot parse time: %s" str)))))))
  (require 'org)
  (let* ((records (gptel-usage--read-log))
         (records (if since
                      (cl-remove-if
                       (lambda (r) (time-less-p (date-to-time (plist-get r :timestamp)) since))
                       records)
                    records))
         (groups (make-hash-table :test #'equal)))
    (dolist (r records)
      (let* ((key (cons (plist-get r :backend) (plist-get r :model)))
             (cur (or (gethash key groups)
                      (list :input 0 :output 0 :cached 0 :cache 0
                            :cost 0.0 :n 0 :cost-known t))))
        (setf (gethash key groups)
              ;; Pre-v2 records have no :cache key; treat it as zero.
              ;; Report fresh input, i.e. with cache writes taken out, since
              ;; backends that report writes fold them into :input (see
              ;; `gptel-usage--cost').  This keeps the columns disjoint, so
              ;; Input + CacheRd + CacheWr is the true token total.
              (list :input (+ (plist-get cur :input)
                              (max 0 (- (or (plist-get r :input) 0)
                                        (or (plist-get r :cache) 0))))
                    :output (+ (plist-get cur :output) (or (plist-get r :output) 0))
                    :cached (+ (plist-get cur :cached) (or (plist-get r :cached) 0))
                    :cache (+ (plist-get cur :cache) (or (plist-get r :cache) 0))
                    :cost (+ (plist-get cur :cost) (or (plist-get r :cost) 0.0))
                    :n (1+ (plist-get cur :n))
                    :cost-known (and (plist-get cur :cost-known) (plist-get r :cost))))))
    (with-current-buffer (get-buffer-create "*gptel-usage*")
      (let* ((inhibit-read-only t)
             ;; `maphash' order is unspecified, so collect and sort for a
             ;; stable report: most expensive first, then most requests.
             (rows nil)
             (total-cost 0.0)
             (any-unknown nil)
             (tot-n 0) (tot-in 0) (tot-out 0) (tot-rd 0) (tot-wr 0))
        (erase-buffer)
        (maphash (lambda (key v) (push (cons key v) rows)) groups)
        (setq rows
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
                                    (plist-get (cdr b) :n))))))))
        (insert "#+TITLE: gptel token usage\n")
        (insert (format "# Generated %s%s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M")
                        (if since
                            (concat ", covering records since "
                                    (format-time-string "%Y-%m-%d %H:%M" since))
                          "")))
        ;; Input is fresh input only; cache reads and writes are broken out,
        ;; so the three token columns do not overlap.  Costs are bare numbers
        ;; (no currency symbol) so Org treats the column as numeric, which
        ;; keeps it right-aligned and usable with table formulas.
        (insert "| Backend | Model | Reqs | Input | Output | CacheRd | CacheWr | Cost (USD) |\n")
        (insert "|-\n")
        (pcase-dolist (`(,key . ,v) rows)
          (insert (format "| %s | %s | %d | %d | %d | %d | %d | %s |\n"
                          (gptel-usage--org-escape (car key))
                          (gptel-usage--org-escape (cdr key))
                          (plist-get v :n) (plist-get v :input)
                          (plist-get v :output) (plist-get v :cached)
                          (plist-get v :cache)
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
        (insert (format "| Total | | %d | %d | %d | %d | %d | %.4f |\n"
                        tot-n tot-in tot-out tot-rd tot-wr total-cost))
        (insert "\n")
        (when any-unknown
          (insert "Total covers priced models only; rows reading /unknown/ are\n"
                  "excluded because some models have no pricing configured --\n"
                  "see ~gptel-usage-pricing~.\n"))
        (unless rows
          (insert "No usage records"
                  (if since " in the selected period" "")
                  ".  Usage is tracked while ~gptel-usage-mode~ is enabled.\n"))
        ;; Org mode last: it resets buffer-local state, and the table needs to
        ;; exist before it can be aligned.
        (org-mode)
        (goto-char (point-min))
        (when (re-search-forward "^|" nil t)
          ;; Expand the "|-" shorthand rules and pad every cell to width.
          (org-table-align))
        (goto-char (point-min))
        (set-buffer-modified-p nil))
      (display-buffer (current-buffer)))))

(provide 'gptel-usage)
;;; gptel-usage.el ends here
