;;; gptel-backoff.el --- Retry/backoff and concurrency limiting for gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026  James Aimonetti

;; Author: James Aimonetti <james.aimonetti@gmail.com>
;; Keywords: convenience, hypermedia, llm

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Automatic retry with backoff and per-backend concurrency limiting
;; for gptel requests.
;;
;; gptel drives requests with a finite state machine (see `gptel-fsm'
;; in gptel-request.el).  This file adds two states to that machine:
;;
;; - RTRY: entered when a request fails with a retryable provider
;;   error (HTTP 429/5xx, a Retry-After header, an x-should-retry:
;;   true header, or a known retryable error type in the JSON body
;;   such as rate_limit_error or overloaded_error).  The RTRY handler
;;   schedules a `run-at-time' timer with exponential backoff plus
;;   jitter; when it fires, the FSM re-enters WAIT and the request is
;;   transparently re-issued.  Only after the attempt budget is
;;   exhausted does the request proceed to the normal error handling
;;   (ERRS), so users are never spammed with transient errors.
;;
;; - QUEUE: entered when a request cannot start because the backend's
;;   concurrency limit is reached (or a Retry-After cooldown is
;;   active).  The FSM parks in QUEUE until a slot frees up, then
;;   re-enters WAIT.
;;
;; Both states are installed into any FSM passed to `gptel-request' by
;; `gptel-backoff--install', which is idempotent and called
;; automatically unless the `retry' keyword argument of
;; `gptel-request' is nil.
;;
;; Configuration is global (see the `gptel-backoff' customize group)
;; and can be overridden per backend with
;; `gptel-backoff--backend-settings'.

;;; Code:

(require 'cl-lib)
;; NOTE: Do NOT require gptel-request from here.  gptel-request.el
;; requires this file at load time, so loading gptel-request here would
;; create a cycle.  The gptel-fsm accessors and FSM functions used below
;; are declared for the byte-compiler; they are only called at runtime,
;; by which point gptel-request is loaded.

(defvar gptel--request-alist)
(defvar gptel-mode)

(declare-function gptel-fsm-info "gptel-request")
(declare-function gptel-fsm-state "gptel-request")
(declare-function gptel-fsm-table "gptel-request")
(declare-function gptel-fsm-handlers "gptel-request")
(declare-function gptel--fsm-transition "gptel-request")
(declare-function gptel--handle-wait "gptel-request")
(declare-function gptel--error-p "gptel-request")
(declare-function gptel-backend-name "gptel-request")
(declare-function gptel--to-string "gptel-request")
(declare-function gptel--update-status "gptel")

(defgroup gptel-backoff nil
  "Retry/backoff and concurrency limiting for gptel."
  :group 'gptel)

(defcustom gptel-backoff-enabled t
  "Whether to automatically retry gptel requests on retryable errors.

When nil, retries are disabled.  Concurrency limiting, if
configured, still applies."
  :type 'boolean
  :group 'gptel-backoff)

(defcustom gptel-backoff-max-retries 5
  "Maximum number of retries after the initial failed request."
  :type 'natnum
  :group 'gptel-backoff)

(defcustom gptel-backoff-base-delay 1.0
  "Base delay in seconds for exponential backoff."
  :type 'number
  :group 'gptel-backoff)

(defcustom gptel-backoff-max-delay 60.0
  "Maximum delay in seconds between retries."
  :type 'number
  :group 'gptel-backoff)

(defcustom gptel-backoff-jitter-factor 0.2
  "Fraction of the computed delay to use as random jitter.

A value of 0 disables jitter.  A value of 0.2 means each delay is
adjusted by up to +/-20%.  Jitter avoids synchronized retry storms
when many clients retry at once."
  :type 'number
  :group 'gptel-backoff)

(defcustom gptel-backoff-retryable-status '(429 500 502 503 504 529)
  "HTTP status codes considered retryable by default."
  :type '(repeat integer)
  :group 'gptel-backoff)

(defcustom gptel-backoff-retryable-error-types
  '("rate_limit_error" "overloaded_error" "insufficient_quota"
    "server_error" "timeout" "temporarily_unavailable"
    "service_unavailable" "resource_exhausted")
  "Substrings matching retryable errors in the JSON error body.

The response error object's :type, :code and :message fields are
searched case-insensitively for these substrings."
  :type '(repeat string)
  :group 'gptel-backoff)

(defcustom gptel-backoff-default-concurrency nil
  "Default maximum number of concurrent requests per backend.

nil means no limit.  Override per backend with
`gptel-backoff--backend-settings'."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'gptel-backoff)

(defcustom gptel-backoff-cooldown 30.0
  "Cooldown in seconds applied after a 429 response without a
Retry-After header, when the concurrency limiter is enabled.

This throttles the whole backend so a rate-limited provider is
not hammered by queued or retried requests."
  :type 'number
  :group 'gptel-backoff)

(defcustom gptel-backoff--respect-retry-after t
  "Whether the concurrency limiter honors Retry-After as a cooldown."
  :type 'boolean
  :group 'gptel-backoff)

(defcustom gptel-backoff--backend-settings nil
  "Per-backend retry/backoff and concurrency settings.

An alist of (BACKEND-NAME . PLIST).  Recognized PLIST keys:

:max-retries   - override `gptel-backoff-max-retries'
:base-delay    - override `gptel-backoff-base-delay'
:max-delay     - override `gptel-backoff-max-delay'
:jitter-factor - override `gptel-backoff-jitter-factor'
:concurrency   - override `gptel-backoff-default-concurrency'"
  :type '(alist :key-type string :value-type plist)
  :group 'gptel-backoff)


;;; Settings

(defun gptel-backoff--setting (backend key &optional default)
  "Return BACKEND's setting KEY, or DEFAULT.

KEY can be given either as a keyword (`:max-retries') or as the
corresponding plain symbol (`max-retries'): both are normalized
to a keyword before lookup, since
`gptel-backoff--backend-settings' is a plist keyed by keywords.
Per-backend settings take precedence over the global defaults."
  (or (plist-get (alist-get (gptel-backend-name backend)
                            gptel-backoff--backend-settings
                            nil nil #'equal)
                 (if (keywordp key)
                     key
                   (intern (concat ":" (symbol-name key)))))
      default))

(defun gptel-backoff--status-int (status)
  "Return STATUS as an integer, for comparisons."
  (if (stringp status) (string-to-number status) status))


;;; Retryability

(cl-defgeneric gptel-backoff--retryable-p (_backend info)
  "Return non-nil if a request to BACKEND with INFO should be retried.

INFO is the request plist, containing at least :http-status,
:http-headers and :error.

The default method is conservative and header-first:

1. An explicit `x-should-retry' header wins: \"false\" means no
   retry, \"true\" means retry.
2. Otherwise, known retryable HTTP statuses (see
   `gptel-backoff-retryable-status') are retried.
3. Otherwise, a known retryable error type/code/message in the
   JSON error body (see `gptel-backoff-retryable-error-types') is
   retried.
4. Unknown errors are not retried."
  (let* ((status (gptel-backoff--status-int (plist-get info :http-status)))
         (headers (plist-get info :http-headers))
         (xsr (cdr (assoc "x-should-retry" headers))))
    (cond
     (xsr (string= (downcase (string-trim xsr)) "true"))
     ((member status gptel-backoff-retryable-status) t)
     ((gptel-backoff--error-retryable-p (plist-get info :error)) t)
     (t nil))))

(defun gptel-backoff--error-retryable-p (error-data)
  "Return non-nil if ERROR-DATA indicates a retryable error.

ERROR-DATA is the parsed error from the response body: a plist
(the provider's JSON error object) or a string (a generic gptel
error message)."
  (let ((hay (cond
              ((plistp error-data)
               (mapconcat #'gptel--to-string
                          (delq nil (list (plist-get error-data :type)
                                          (plist-get error-data :code)
                                          (plist-get error-data :message)))
                          " "))
              ((stringp error-data) error-data)
              (t ""))))
    (let ((case-fold-search t))
      (cl-some (lambda (pat)
                 (string-match-p (regexp-quote pat) hay))
               gptel-backoff-retryable-error-types))))

(defun gptel-backoff--retry-after (headers)
  "Return the number of seconds to wait per HEADERS' Retry-After.

HEADERS is an alist of lowercased (name . value) conses.  Supports
both delta-seconds and RFC 7231 IMF-fixdate (HTTP-date) forms.
Returns nil if the header is absent or unparseable.  A strict
date pattern is used so garbage that `date-to-time' would coerce
to a (possibly past) time is rejected instead of meaning an
immediate retry."
  (when-let* ((val (cdr (assoc "retry-after" headers))))
    (let ((val (string-trim val)))
      (cond
       ((string-match-p "\\`[0-9]+\\'" val) (string-to-number val))
       ((string-match-p
         (concat "\\`\\(?:Mon\\|Tue\\|Wed\\|Thu\\|Fri\\|Sat\\|Sun\\), "
                 "[0-9][0-9] "
                 "\\(?:Jan\\|Feb\\|Mar\\|Apr\\|May\\|Jun\\|Jul\\|Aug\\|Sep\\|Oct\\|Nov\\|Dec\\) "
                 "[0-9][0-9][0-9][0-9] "
                 "[0-9][0-9]:[0-9][0-9]:[0-9][0-9] GMT\\'")
         val)
        (max 0 (round (float-time (time-subtract (date-to-time val)
                                                 (current-time))))))
       (t nil)))))

(defun gptel-backoff--jitter (delay factor)
  "Return DELAY adjusted by +/-FACTOR random jitter.

FACTOR 0 (or nil) returns DELAY unchanged.

The random component is uniformly distributed in [-1, 1).  The
limit passed to `random' must be a positive integer (Emacs Lisp
Reference, \"Random Numbers\"): passing a float yields an
arbitrary fixnum, which would produce astronomically large (or
zero) delays."
  (if (or (null factor) (zerop factor))
      delay
    (max 0.0
         (* delay (1+ (* factor (- (/ (float (random 2000)) 1000.0) 1.0)))))))

(defun gptel-backoff--delay (attempt info)
  "Compute the backoff delay before retry ATTEMPT of request INFO.

Honors a Retry-After header as a floor.  Otherwise uses
exponential backoff (base * 2^(attempt-1)) capped at the
configured maximum, then applies jitter."
  (let* ((backend (plist-get info :backend))
         (base (gptel-backoff--setting backend 'base-delay gptel-backoff-base-delay))
         (maxd (gptel-backoff--setting backend 'max-delay gptel-backoff-max-delay))
         (jitter (gptel-backoff--setting backend 'jitter-factor gptel-backoff-jitter-factor))
         (delay (min maxd (* base (expt 2 (1- attempt))))))
    (when-let* ((ra (gptel-backoff--retry-after (plist-get info :http-headers))))
      (setq delay (max delay ra)))
    (gptel-backoff--jitter delay jitter)))

(defun gptel-backoff--retry-p (info)
  "Return non-nil if request INFO should be retried.

Consults `gptel-backoff-enabled', the attempt budget and the
provider's retry signals.  This predicate is side-effect-free; the
attempt counter is incremented in `gptel-backoff--handle-retry'.

A nil :backend is treated as not retryable (the retry timer and
generics need a real backend, and transport-level failures without
an HTTP response are never retried anyway)."
  (and gptel-backoff-enabled
       (let* ((backend (plist-get info :backend))
              (attempts (or (plist-get info :backoff-attempts) 0))
              (max (if backend
                       (gptel-backoff--setting backend 'max-retries
                                               gptel-backoff-max-retries)
                     gptel-backoff-max-retries)))
         (and backend
              (< attempts max)
              (gptel-backoff--retryable-p backend info)))))


;;; FSM installation

(defun gptel-backoff--install (fsm)
  "Install retry/backoff and concurrency limiting into FSM.

Adds the RTRY and QUEUE states to FSM's transition table and
handler list, and wraps the WAIT handler with the concurrency
limiter gate.  Idempotent: returns immediately if RTRY is already
present in FSM's table."
  (when (and (gptel-fsm-table fsm)
             (not (assq 'RTRY (gptel-fsm-table fsm))))
    (let* ((table (mapcar (lambda (row)
                            (cons (car row) (copy-sequence (cdr row))))
                          (gptel-fsm-table fsm)))
           ;; Shallow copy only: handlers may contain closures, which
           ;; copy-tree would try to duplicate.
           (handlers (mapcar (lambda (row)
                               (cons (car row) (copy-sequence (cdr row))))
                             (gptel-fsm-handlers fsm))))
      ;; Route retryable errors to RTRY in the TYPE and TRET rows.
      (dolist (state '(TYPE TRET))
        (when-let* ((row (assq state table)))
          (setcdr row (gptel-backoff--insert-retry-pred (cdr row)))))
      ;; RTRY and QUEUE both lead back to WAIT.
      (setq table (append table '((RTRY (t . WAIT)) (QUEUE (t . WAIT)))))
      ;; Wrap the WAIT handler with the limiter gate; add new handlers.
      (setq handlers (gptel-backoff--install-wait handlers))
      (setq handlers (append handlers '((RTRY gptel-backoff--handle-retry)
                                        (QUEUE gptel-backoff--handle-queue))))
      (with-no-warnings
        (setf (cl-struct-slot-value 'gptel-fsm 'table fsm) table)
        (setf (cl-struct-slot-value 'gptel-fsm 'handlers fsm) handlers)
        (setf (cl-struct-slot-value 'gptel-fsm 'info fsm)
              (plist-put (or (gptel-fsm-info fsm) (list))
                         :backoff-attempts 0))))))

(defun gptel-backoff--insert-retry-pred (transitions)
  "Insert the retry predicate before the first error predicate.

TRANSITIONS is the cdr of a state row: an alist of
(PREDICATE . NEXT-STATE).  The first match wins in
`gptel--fsm-next', so the retry predicate must precede the error
predicate; when it returns nil, the error predicate is tried."
  (let ((copy (copy-sequence transitions))
        (idx (cl-position-if
              (lambda (entry) (eq (car entry) #'gptel--error-p))
              transitions)))
    (if (null idx)
        (cons '(gptel-backoff--retry-p . RTRY) copy)
      (if (= idx 0)
          (cons '(gptel-backoff--retry-p . RTRY) copy)
        (setcdr (nthcdr (1- idx) copy)
                (cons '(gptel-backoff--retry-p . RTRY)
                      (nthcdr idx copy)))
        copy))))

(defun gptel-backoff--install-wait (handlers)
  "Replace `gptel--handle-wait' with the limiter gate in HANDLERS.

Other WAIT handlers (e.g. `gptel--update-wait',
`gptel--rewrite-update-wait') are captured and run by the gate
after a successful dispatch, so they do not override the
\"waiting for slot\" status when the request is queued.

HANDLERS is a shallow copy of the FSM's handler alist, so this
does not mutate the shared default handler lists."
  (when-let* ((row (assq 'WAIT handlers))
              ((memq #'gptel--handle-wait (cdr row))))
    (let ((others (remove #'gptel--handle-wait (cdr row))))
      (setf (cdr row)
            (list (lambda (fsm)
                    (gptel-backoff--handle-wait fsm others))))))
  handlers)


;;; Concurrency limiter

(defvar gptel-backoff--semaphores (make-hash-table :test #'equal)
  "Per-backend concurrency state.

Maps backend name to a list (ACTIVE QUEUE COOLDOWN TIMER), where
ACTIVE is the number of in-flight requests, QUEUE is a list of
FSMs waiting for a slot, COOLDOWN is a time value (or nil) before
which no new requests may start, and TIMER is a pending
cooldown-expiry pump timer (or nil).")

(defun gptel-backoff--semaphore (backend)
  "Return the semaphore state list for BACKEND."
  (let ((name (gptel-backend-name backend)))
    (or (gethash name gptel-backoff--semaphores)
        (puthash name (list 0 nil nil nil) gptel-backoff--semaphores))))

(defun gptel-backoff--limit (backend)
  "Return the concurrency limit for BACKEND (nil means unlimited)."
  (gptel-backoff--setting backend 'concurrency gptel-backoff-default-concurrency))

(defun gptel-backoff--handle-wait (fsm &optional others)
  "Limiter gate for FSM: acquire a slot, then dispatch the request.

OTHERS is a list of the remaining WAIT-state handlers to run
after a successful dispatch (e.g. `gptel--update-wait').

If BACKEND has no configured concurrency limit, or a slot is
available (and no cooldown is active), dispatch via
`gptel--handle-wait'.  Otherwise park the FSM in the QUEUE state."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend))
         (limit (gptel-backoff--limit backend))
         (dispatched nil))
    (if (and limit (> limit 0))
        (let ((sem (gptel-backoff--semaphore backend)))
          (if (gptel-backoff--acquire backend sem)
              (unwind-protect
                  (progn
                    (plist-put info :backoff-dispatched t)
                    (gptel--handle-wait fsm)
                    ;; Dispatch started: the transport owns the slot and
                    ;; will release it on completion.  Only a synchronous
                    ;; throw inside `gptel--handle-wait' must undo the
                    ;; acquire below.
                    (setq dispatched t)
                    (mapc (lambda (h) (funcall h fsm)) others))
                ;; A synchronous throw before dispatch starts must release.
                (unless dispatched
                  (plist-put info :backoff-dispatched nil)
                  (gptel-backoff--release-backend backend sem)))
            ;; Over limit or cooling down: park in QUEUE.
            (plist-put info :queued t)
            (push fsm (nth 1 sem))  ;must join the semaphore queue for pump to resume it
            (gptel-backoff--register-parked fsm)
            (gptel-backoff--schedule-cooldown-pump backend sem)
            (gptel--fsm-transition fsm 'QUEUE)))
      ;; No limit configured: dispatch directly, then run the other
      ;; WAIT handlers (status updates etc).
      (gptel--handle-wait fsm)
      (mapc (lambda (h) (funcall h fsm)) others))))

(defun gptel-backoff--parked-p (fsm)
  "Return non-nil if FSM is parked in RTRY or QUEUE."
  (memq (gptel-fsm-state fsm) '(RTRY QUEUE)))

(defun gptel-backoff--installed-p (fsm)
  "Return non-nil if retry/backoff is installed in FSM.

The install is idempotent and adds the RTRY row to FSM's
transition table; its presence is what makes the transport
callbacks (url-retrieve and curl) skip the response callback on a
retryable error.  When `gptel-request' is called with :retry nil,
the transport must keep the pre-feature behavior (always calling
the callback), so it keys off this test."
  (and (gptel-fsm-table fsm)
       (assq 'RTRY (gptel-fsm-table fsm))))

(defun gptel-backoff--acquire (backend sem)
  "Try to acquire a concurrency slot for BACKEND's semaphore SEM.

Returns non-nil on success.  Fails when the active count equals
the limit or a Retry-After cooldown is active."
  (let ((limit (gptel-backoff--limit backend)))
    (if (null limit)
        t
      (cl-destructuring-bind (active _queue cooldown _timer) sem
        (and (or (null cooldown) (time-less-p cooldown (current-time)))
             (< active limit)
             (progn (cl-incf (nth 0 sem)) t))))))

(defun gptel-backoff--release-backend (backend sem)
  "Decrement BACKEND's semaphore SEM active count and pump the queue."
  (setf (nth 0 sem) (max 0 (1- (nth 0 sem))))
  (gptel-backoff--pump backend sem))

(defun gptel-backoff--pump (backend sem)
  "Start the next queued request for BACKEND's semaphore SEM."
  (cl-destructuring-bind (active queue cooldown _timer) sem
    (let ((limit (gptel-backoff--limit backend)))
      (when (and limit
                 (> limit 0)
                 (< active limit)
                 (or (null cooldown) (time-less-p cooldown (current-time)))
                 queue)
        (let ((next (pop (nth 1 sem))))
          (gptel-backoff--resume next))))))

(defun gptel-backoff--resume (fsm)
  "Resume queued FSM: clear its parked bookkeeping and re-enter WAIT."
  (plist-put (gptel-fsm-info fsm) :queued nil)
  (gptel-backoff--alist-delete-fsm fsm)
  (gptel--fsm-transition fsm 'WAIT))

(defun gptel-backoff--schedule-cooldown-pump (backend sem)
  "Schedule a queue pump for SEM after its cooldown expires.

No-ops if SEM has no active cooldown or a pump timer is already
pending."
  (cl-destructuring-bind (_active _queue cooldown timer) sem
    (when (and cooldown (time-less-p (current-time) cooldown) (null timer))
      (setf (nth 3 sem)
            (run-at-time (float-time (time-subtract cooldown (current-time)))
                         nil
                         (lambda ()
                           (setf (nth 3 sem) nil)
                           (gptel-backoff--pump backend sem)))))))

(defun gptel-backoff--release (fsm)
  "Release any concurrency slot or queue position held by FSM.

Also sets a Retry-After cooldown on the backend when the finished
attempt was a retryable rate-limit response.  Idempotent: no-ops
if FSM holds neither a slot nor a queue position."
  (when-let* ((info (gptel-fsm-info fsm))
              (backend (plist-get info :backend)))
    (let ((sem (gptel-backoff--semaphore backend)))
      ;; Cooldown from a retryable rate-limit response.
      (when (and gptel-backoff--respect-retry-after
                 (plist-get info :backoff-dispatched)
                 (gptel-backoff--retryable-p backend info))
        (when-let* ((cooldown (or (gptel-backoff--retry-after (plist-get info :http-headers))
                                  (and (eq (gptel-backoff--status-int
                                            (plist-get info :http-status))
                                           429)
                                       gptel-backoff-cooldown))))
          (setf (nth 2 sem)
                (time-add (current-time)
                          (seconds-to-time (gptel-backoff--jitter cooldown gptel-backoff-jitter-factor))))
          (gptel-backoff--schedule-cooldown-pump backend sem)))
      ;; Remove from the queue if parked there.
      (when (plist-get info :queued)
        (setf (nth 1 sem) (delq fsm (nth 1 sem)))
        (plist-put info :queued nil))
      ;; Decrement if dispatched.
      (when (plist-get info :backoff-dispatched)
        (plist-put info :backoff-dispatched nil)
        (gptel-backoff--release-backend backend sem)))))


;;; Parked request bookkeeping (RTRY / QUEUE)

(defun gptel-backoff--register-parked (fsm)
  "Register parked FSM (in RTRY or QUEUE) so `gptel-abort' finds it.

Adds a (nil . (FSM ABORT-FN)) entry to `gptel--request-alist'."
  (gptel-backoff--alist-delete-fsm fsm)
  (push (cons nil (cons fsm (lambda () (gptel-backoff--cleanup-parked fsm))))
        gptel--request-alist))

(defun gptel-backoff--cleanup-parked (fsm)
  "Clean up parked FSM: cancel its timer and release its slot/queue."
  (let ((info (gptel-fsm-info fsm)))
    (plist-put info :cancelled t)
    (when-let* ((timer (plist-get info :backoff-timer)))
      (cancel-timer timer)
      (plist-put info :backoff-timer nil))
    (gptel-backoff--release fsm)
    (gptel-backoff--alist-delete-fsm fsm)))

(defun gptel-backoff--alist-delete-fsm (fsm)
  "Remove all `gptel--request-alist' entries whose FSM is FSM."
  (setq gptel--request-alist
        (cl-remove-if (lambda (entry) (eq (cadr entry) fsm))
                      gptel--request-alist)))

(defun gptel-backoff--handle-queue (fsm)
  "Update status when FSM is queued waiting for a concurrency slot."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend))
         (sem (gptel-backoff--semaphore backend))
         (n (length (nth 1 sem))))
    (gptel-backoff--status fsm (format " Waiting for slot (%d queued)" n) 'warning)))


;;; Retry handler and timer

(defun gptel-backoff--handle-retry (fsm)
  "Handle entering RTRY: truncate partial output and schedule a retry.

Increments the :backoff-attempts counter, truncates any partially
streamed output, registers the FSM for abort bookkeeping, updates
the status line, and schedules `gptel-backoff--fire' after a
backoff delay.  The FSM stays parked in RTRY until the timer
fires; it does not transition here."
  (let* ((info (gptel-fsm-info fsm))
         (backend (plist-get info :backend))
         (attempts (1+ (or (plist-get info :backoff-attempts) 0)))
         (max (gptel-backoff--setting backend 'max-retries gptel-backoff-max-retries))
         (delay (gptel-backoff--delay attempts info)))
    (plist-put info :backoff-attempts attempts)
    (gptel-backoff--truncate-stream info)
    (gptel-backoff--register-parked fsm)
    (gptel-backoff--status fsm (format " Retrying in %.0fs (%d/%d)" delay attempts max)
                           'warning)
    (plist-put info :backoff-timer
               (run-at-time delay nil #'gptel-backoff--fire fsm))))

(defun gptel-backoff--fire (fsm)
  "Timer callback: re-enter WAIT for parked FSM.

No-ops if the request was cancelled, the FSM left RTRY (a stale
timer on a reused FSM), or the request buffer is gone.  Never
strands the FSM in RTRY: on error, falls through to ERRS."
  (let ((info (gptel-fsm-info fsm)))
    (plist-put info :backoff-timer nil)
    (when (and (not (plist-get info :cancelled))
               (eq (gptel-fsm-state fsm) 'RTRY)
               (let ((buf (plist-get info :buffer)))
                 (and (bufferp buf) (buffer-live-p buf))))
      (gptel-backoff--alist-delete-fsm fsm)
      (condition-case err
          (gptel--fsm-transition fsm 'WAIT)
        (error
         ;; Don't strand the FSM in RTRY.
         (gptel--fsm-transition fsm 'ERRS)
         (message "gptel backoff retry failed: %S" err))))))

(defun gptel-backoff--truncate-stream (info)
  "Delete any partially streamed response for request INFO.

Non-streaming requests insert only on success, so there is nothing
to clean up.  Streaming requests track insertion with
:tracking-marker (reasoning text is inserted in the same region);
delete back to the request start marker so a retry does not
duplicate output."
  (when (and (plist-get info :stream)
             (markerp (plist-get info :position))
             (buffer-live-p (marker-buffer (plist-get info :position))))
    (let ((start (plist-get info :position))
          (tracking (plist-get info :tracking-marker)))
      (when (and tracking (marker-buffer tracking))
        (with-current-buffer (marker-buffer start)
          (let ((inhibit-read-only t))
            (delete-region (marker-position start) (marker-position tracking)))
          (goto-char (marker-position start))))
      ;; Reset stream state so the retried stream starts fresh.
      (dolist (key '(:tracking-marker :reasoning-marker :reasoning-block
                     :partial_text :partial_reasoning :partial_json))
        (plist-put info key nil)))))

(defun gptel-backoff--status (fsm msg &optional face)
  "Show MSG (with FACE) in the gptel buffer for FSM."
  (when-let* ((info (gptel-fsm-info fsm))
              (buf (plist-get info :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (when (and (boundp 'gptel-mode) gptel-mode)
        (gptel--update-status msg face)))))

(provide 'gptel-backoff)
;;; gptel-backoff.el ends here
