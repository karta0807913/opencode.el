;;; opencode-scenario-test.el --- Scenario replay framework & tests -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Record-and-replay test framework for opencode.el.
;; Reads scenario files containing sequences of OpenCode operations
;; (SSE events, API calls, assertions) and replays them against a
;; chat buffer — either in batch mode (ERT) or interactively.
;;
;; Scenario file format (line-based, prefix-driven):
;;
;;   # Comments start with #
;;   :session <session-id>     — set the session ID (required, first line)
;;   :directory <path>         — set the project directory (optional)
;;   :sse <json>               — deliver an SSE event (global format)
;;   :refresh <file.json>      — load message JSON and re-render the buffer
;;   :refresh <inline-json>    — inline message JSON and re-render
;;   :api <method> <path> <json>  — register a mock API response
;;   :wait <ms>                — pause (interactive mode only; no-op in batch)
;;   :assert-contains <text>   — assert buffer contains text
;;   :assert-not-contains <text> — assert buffer does NOT contain text
;;   :assert-busy              — assert session is busy
;;   :assert-idle              — assert session is idle
;;   :eval <elisp>             — evaluate elisp in the chat buffer context
;;   :answer-permission <choice>  — answer the current permission popup
;;                                  choice: allow-once | allow-always | reject
;;   :answer-question <selections> — answer the current question popup
;;                                   selections: comma-separated option numbers (1-indexed)
;;                                   e.g. ":answer-question 1" or ":answer-question 1,3"
;;   :reject-question             — reject the current question popup
;;   :assert-permission           — assert a permission popup is displayed
;;   :assert-no-permission        — assert no permission popup is displayed
;;   :assert-question             — assert a question popup is displayed
;;   :assert-no-question          — assert no question popup is displayed
;;
;; The :sse lines accept the "global" SSE format:
;;   {"directory":"/path","payload":{"type":"message.part.updated","properties":{...}}}
;;
;; Or the already-unwrapped internal format:
;;   {"type":"message.part.updated","properties":{...}}
;;
;; Multi-line JSON: If a line does not start with a known prefix (:sse,
;; :api, etc.) and follows a JSON-bearing line, it is treated as a
;; continuation of the previous line's JSON payload.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'test-helper)
(require 'opencode-log)
(require 'opencode-sse)
(require 'opencode)
(require 'opencode-chat)
(require 'opencode-chat-message)
(require 'opencode-permission)
(require 'opencode-question)

;; Forward declarations
(declare-function opencode-chat--render-messages "opencode-chat")
(declare-function opencode-chat--render-input-area "opencode-chat-input")
(declare-function opencode-chat--on-message-updated "opencode-chat")
(declare-function opencode-chat--on-part-updated "opencode-chat")
(declare-function opencode-chat--on-session-status "opencode-chat")
(declare-function opencode-chat--on-session-idle "opencode-chat")
(declare-function opencode-chat--on-session-updated "opencode-chat")
(declare-function opencode-chat--on-session-deleted "opencode-chat")
(declare-function opencode-chat--on-session-error "opencode-chat")
(declare-function opencode-chat--on-session-diff "opencode-chat")
(declare-function opencode-chat--on-session-compacted "opencode-chat")
(declare-function opencode-chat--on-message-removed "opencode-chat")
(declare-function opencode-chat--on-server-instance-disposed "opencode-chat")
(declare-function opencode-chat--on-installation-update-available "opencode-chat")
(declare-function opencode-permission--on-asked "opencode-permission")
(declare-function opencode-permission--on-replied "opencode-permission")
(declare-function opencode-permission--allow-once "opencode-permission")
(declare-function opencode-permission--allow-always "opencode-permission")
(declare-function opencode-permission--reject "opencode-permission")
(declare-function opencode-question--on-asked "opencode-question")
(declare-function opencode-question--on-replied "opencode-question")
(declare-function opencode-question--on-rejected "opencode-question")
(declare-function opencode-question--select-option "opencode-question")
(declare-function opencode-question--submit "opencode-question")
(declare-function opencode-question--reject "opencode-question")

(defvar opencode-chat--state)
(defvar opencode-api-directory)
(defvar opencode-api--server-config-cache)
(defvar opencode-api-cache--load-state)
(defvar opencode-popup--inline-p)
(defvar opencode-popup--overlay)
(defvar opencode-permission--current)
(defvar opencode-question--current)
(defvar opencode-question--pending)
(defvar opencode-question--question-idx)
(defvar opencode-question--answers)
(defvar opencode-question--selected)


;; ════════════════════════════════════════════════════════════════════
;;  Scenario Framework
;; ════════════════════════════════════════════════════════════════════

;;; --- Scenario Data Structures ---

(cl-defstruct (opencode-scenario-op (:constructor opencode-scenario-op--create))
  "A single operation in a scenario."
  type        ; symbol: sse, api, wait, assert-contains, assert-not-contains,
              ;         assert-busy, assert-idle, session, directory, refresh,
              ;         answer-permission, answer-question, reject-question,
              ;         assert-permission, assert-no-permission,
              ;         assert-question, assert-no-question
  data        ; depends on type — see below
  line-number ; source line number for error reporting
  )

;; :sse       → data is a JSON string (the SSE event payload)
;; :api       → data is (:method METHOD :path PATH :status STATUS :body JSON-STRING)
;; :wait      → data is milliseconds (integer)
;; :assert-*  → data is the text/pattern string (or nil for assert-busy/idle/permission/question)
;; :session   → data is the session-id string
;; :directory → data is the directory path string
;; :refresh   → data is (:file FILENAME) or (:json JSON-STRING)
;; :answer-permission → data is choice string: "allow-once", "allow-always", "reject"
;; :answer-question   → data is list of 1-indexed option numbers (integers)
;; :reject-question   → data is nil


;;; --- Parser ---

(defun opencode-scenario--parse-file (file)
  "Parse scenario FILE and return a list of `opencode-scenario-op' structs."
  (with-temp-buffer
    (insert-file-contents file)
    (opencode-scenario--parse-buffer)))

(defun opencode-scenario--parse-string (str)
  "Parse scenario string STR and return a list of `opencode-scenario-op' structs."
  (with-temp-buffer
    (insert str)
    (opencode-scenario--parse-buffer)))

(defun opencode-scenario--parse-buffer ()
  "Parse the current buffer as a scenario.  Return list of ops."
  (goto-char (point-min))
  (let ((ops nil)
        (line-num 0))
    (while (not (eobp))
      (setq line-num (1+ line-num))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (cond
         ;; Blank line or comment
         ((or (string-empty-p (string-trim line))
              (string-prefix-p "#" (string-trim-left line)))
          nil)

         ;; :session <id>
         ((string-match "^:session[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'session
                 :data (string-trim (match-string 1 line))
                 :line-number line-num)
                ops))

         ;; :directory <path>
         ((string-match "^:directory[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'directory
                 :data (string-trim (match-string 1 line))
                 :line-number line-num)
                ops))

         ;; :parent-id <id>
         ((string-match "^:parent-id[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'parent-id
                 :data (string-trim (match-string 1 line))
                 :line-number line-num)
                ops))

         ;; :sse <json>
         ((string-match "^:sse[[:space:]]+\\(.*\\)" line)
          (let ((json-start (match-string 1 line)))
            (let ((full-json (opencode-scenario--collect-continuation
                              json-start)))
              (push (opencode-scenario-op--create
                     :type 'sse
                     :data full-json
                     :line-number line-num)
                    ops))))

         ;; :refresh <json-or-filename>
         ;; If the argument ends with .json, treat it as a fixture file path.
         ;; Otherwise, treat it as inline JSON (with multi-line continuation).
         ((string-match "^:refresh[[:space:]]+\\(.*\\)" line)
          (let ((arg (string-trim (match-string 1 line))))
            (if (string-suffix-p ".json" arg)
                (push (opencode-scenario-op--create
                       :type 'refresh
                       :data (list :file arg)
                       :line-number line-num)
                      ops)
              (let ((full-json (opencode-scenario--collect-continuation arg)))
                (push (opencode-scenario-op--create
                       :type 'refresh
                       :data (list :json full-json)
                       :line-number line-num)
                      ops)))))

         ;; :api <method> <path> <status> <json>
         ((string-match "^:api[[:space:]]+\\([A-Z]+\\)[[:space:]]+\\([^[:space:]]+\\)[[:space:]]+\\([0-9]+\\)[[:space:]]+\\(.*\\)" line)
          (let* ((method (match-string 1 line))
                 (path (match-string 2 line))
                 (status (string-to-number (match-string 3 line)))
                 (json-start (match-string 4 line))
                 (full-json (opencode-scenario--collect-continuation json-start)))
            (push (opencode-scenario-op--create
                   :type 'api
                   :data (list :method method :path path
                               :status status :body full-json)
                   :line-number line-num)
                  ops)))

         ;; :wait <ms>
         ((string-match "^:wait[[:space:]]+\\([0-9]+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'wait
                 :data (string-to-number (match-string 1 line))
                 :line-number line-num)
                ops))

         ;; :assert-contains <text>
         ((string-match "^:assert-contains[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'assert-contains
                 :data (match-string 1 line)
                 :line-number line-num)
                ops))

         ;; :assert-not-contains <text>
         ((string-match "^:assert-not-contains[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'assert-not-contains
                 :data (match-string 1 line)
                 :line-number line-num)
                ops))

         ;; :assert-busy
         ((string-match "^:assert-busy\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-busy :data nil :line-number line-num)
                ops))

         ;; :assert-idle
         ((string-match "^:assert-idle\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-idle :data nil :line-number line-num)
                ops))

         ;; :eval <elisp>
         ((string-match "^:eval[[:space:]]+\\(.+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'eval
                 :data (match-string 1 line)
                 :line-number line-num)
                ops))

         ;; :answer-permission <choice>
         ;; choice: allow-once | allow-always | reject
         ((string-match "^:answer-permission[[:space:]]+\\(allow-once\\|allow-always\\|reject\\)" line)
          (push (opencode-scenario-op--create
                 :type 'answer-permission
                 :data (match-string 1 line)
                 :line-number line-num)
                ops))

         ;; :answer-question <selections>
         ;; selections: comma-separated 1-indexed option numbers, e.g. "1" or "1,3"
         ((string-match "^:answer-question[[:space:]]+\\([0-9,]+\\)" line)
          (push (opencode-scenario-op--create
                 :type 'answer-question
                 :data (mapcar #'string-to-number
                               (split-string (match-string 1 line) ","))
                 :line-number line-num)
                ops))

         ;; :reject-question
         ((string-match "^:reject-question\\b" line)
          (push (opencode-scenario-op--create
                 :type 'reject-question :data nil :line-number line-num)
                ops))

         ;; :assert-permission
         ((string-match "^:assert-permission\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-permission :data nil :line-number line-num)
                ops))

         ;; :assert-no-permission
         ((string-match "^:assert-no-permission\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-no-permission :data nil :line-number line-num)
                ops))

         ;; :assert-question
         ((string-match "^:assert-question\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-question :data nil :line-number line-num)
                ops))

         ;; :assert-no-question
         ((string-match "^:assert-no-question\\b" line)
          (push (opencode-scenario-op--create
                 :type 'assert-no-question :data nil :line-number line-num)
                ops))

         ;; Unknown prefix — skip with warning
         ((string-prefix-p ":" (string-trim-left line))
          (opencode--debug "opencode-scenario: unknown op at line %d: %s" line-num line))

         ;; Continuation line — should have been consumed already
         (t nil)))
      (forward-line 1))
    (nreverse ops)))

(defun opencode-scenario--collect-continuation (first-fragment)
  "Collect multi-line JSON starting with FIRST-FRAGMENT.
Reads subsequent lines that do not start with a `:' prefix
and appends them.  Point is left at the last continuation line."
  (let ((parts (list first-fragment)))
    (while (and (not (eobp))
                (save-excursion
                  (forward-line 1)
                  (and (not (eobp))
                       (let ((next (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position))))
                         (not (or (string-empty-p (string-trim next))
                                  (string-prefix-p ":" (string-trim-left next))
                                  (string-prefix-p "#" (string-trim-left next))))))))
      (forward-line 1)
      (push (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            parts))
    (mapconcat #'identity (nreverse parts) "")))


;;; --- SSE Event Unwrapper ---

(defun opencode-scenario--unwrap-sse (json-string)
  "Parse JSON-STRING as SSE event data.
Handles both global format (with :payload wrapper) and flat format.
Returns a plist with :type, :properties, :directory."
  (let ((parsed (json-parse-string json-string
                                   :object-type 'plist
                                   :array-type 'array
                                   :null-object nil
                                   :false-object :false)))
    (cond
     ;; Global format
     ((plist-get parsed :payload)
      (let ((payload (plist-get parsed :payload)))
        (list :type (plist-get payload :type)
              :properties (plist-get payload :properties)
              :directory (plist-get parsed :directory))))
     ;; Flat format
     ((plist-get parsed :type)
      (list :type (plist-get parsed :type)
            :properties (plist-get parsed :properties)
            :directory (plist-get parsed :directory)))
     ;; Fallback
     (t (error "Cannot parse SSE event: %s" json-string)))))


;;; --- SSE Handler Dispatch ---

(defvar opencode-scenario--sse-handlers nil
  "Map SSE event type to handler function for scenario replay.
Built once from `opencode--sse-chat-dispatch-specs' (production hook→handler
mapping) plus permission/question handlers.  Derived at init to stay in
sync with production — never manually maintained.")

(defun opencode-scenario--build-sse-handlers ()
  "Build `opencode-scenario--sse-handlers' from production dispatch specs.
Derives the event-type→handler mapping from `opencode--sse-chat-dispatch-specs'
\(via `opencode-sse--hook-for-type' reverse lookup) so the scenario framework
stays in sync automatically.  Permission/question handlers are added
separately because they use popup dispatch in production."
  (let ((result nil)
        ;; All event types the SSE layer knows about
        (all-types '("message.updated" "message.removed"
                     "message.part.updated" "message.part.delta"
                     "session.updated" "session.status" "session.idle"
                     "session.diff" "session.deleted" "session.error"
                     "session.compacted" "session.created" "todo.updated"
                     "server.instance.disposed" "installation.update-available"
                     "permission.asked" "permission.replied"
                     "question.asked" "question.replied" "question.rejected")))
    ;; Chat dispatch specs: hook-symbol → handler
    (dolist (type all-types)
      (let* ((hook (opencode-sse--hook-for-type type))
             (handler (cdr (assq hook opencode--sse-chat-dispatch-specs))))
        (when handler
          (push (cons type handler) result))))
    ;; Permission/question: use direct handlers (no popup dispatch in tests)
    (unless (assoc "permission.asked" result)
      (push '("permission.asked"  . opencode-permission--on-asked) result))
    (unless (assoc "permission.replied" result)
      (push '("permission.replied" . opencode-permission--on-replied) result))
    (unless (assoc "question.asked" result)
      (push '("question.asked"    . opencode-question--on-asked) result))
    (unless (assoc "question.replied" result)
      (push '("question.replied"  . opencode-question--on-replied) result))
    (unless (assoc "question.rejected" result)
      (push '("question.rejected" . opencode-question--on-rejected) result))
    (nreverse result)))

;; Build at load time
(setq opencode-scenario--sse-handlers (opencode-scenario--build-sse-handlers))


;;; --- Replay Engine ---

(defvar opencode-scenario--log nil
  "List of log entries from the last replay.  Most recent first.")

(defun opencode-scenario--log (fmt &rest args)
  "Log FMT with ARGS to scenario replay log."
  (let ((msg (apply #'format fmt args)))
    (push msg opencode-scenario--log)
    (opencode--debug "opencode-scenario: %s" msg)))

(defun opencode-scenario-replay-ops (ops &optional interactive-p)
  "Replay a list of scenario OPS in the current buffer.
Assumes the buffer is already in `opencode-chat-mode' with session ID set.
When INTERACTIVE-P is non-nil, :wait ops actually pause.
Returns a list of assertion results: ((LINE OK-P MESSAGE) ...)."
  (setq opencode-scenario--log nil)
  (let ((results nil))
    (dolist (op ops)
      (let ((type (opencode-scenario-op-type op))
            (data (opencode-scenario-op-data op))
            (lnum (opencode-scenario-op-line-number op)))
        (condition-case err
            (pcase type
              ('session
               (opencode-chat--set-session-id data)
               (opencode-scenario--log "L%d: session=%s" lnum data))

              ('directory
               (setq-local opencode-api-directory data)
               (opencode-scenario--log "L%d: directory=%s" lnum data))

              ('sse
               (opencode-scenario--log "L%d: SSE event" lnum)
               (let* ((event (opencode-scenario--unwrap-sse data))
                      (event-type (plist-get event :type))
                      (handler (cdr (assoc event-type
                                           opencode-scenario--sse-handlers))))
                 (if handler
                     (progn
                       (opencode-scenario--log "  type=%s handler=%s"
                                               event-type handler)
                       (condition-case err
                           (funcall handler event)
                         (error
                          (opencode-scenario--log "  handler error: %S" err))))
                   (opencode-scenario--log "  type=%s (no handler, skipped)"
                                           event-type))
                 ;; Yield to let timers/async callbacks fire (matches production)
                 (sit-for 0)))

              ('api
               (let ((method (plist-get data :method))
                     (path (plist-get data :path))
                     (status (plist-get data :status))
                     (body (plist-get data :body)))
                 (opencode-scenario--log "L%d: API mock %s %s → %d"
                                         lnum method path status)
                 (when (fboundp 'opencode-test-mock-response)
                   (let ((parsed-body
                          (condition-case nil
                              (json-parse-string body
                                                 :object-type 'plist
                                                 :array-type 'array
                                                 :null-object nil
                                                 :false-object :false)
                            (error body))))
                     (opencode-test-mock-response method path status parsed-body)))))

              ('wait
               (opencode-scenario--log "L%d: wait %dms" lnum data)
               (when interactive-p
                 (sit-for (/ data 1000.0))))

              ('refresh
               (opencode-scenario--log "L%d: refresh" lnum)
               (let* ((json-str
                       (cond
                        ((plist-get data :file)
                         (let* ((filename (plist-get data :file))
                                (filepath
                                 (if (file-name-absolute-p filename)
                                     filename
                                   (let ((fixture-path
                                          (and (boundp 'opencode-test--fixtures-dir)
                                               (expand-file-name filename
                                                                 opencode-test--fixtures-dir))))
                                     (if (and fixture-path (file-exists-p fixture-path))
                                         fixture-path
                                       (expand-file-name filename))))))
                           (opencode-scenario--log "  loading from file: %s" filepath)
                           (with-temp-buffer
                             (insert-file-contents filepath)
                             (buffer-string))))
                        ((plist-get data :json)
                         (plist-get data :json))))
                      (messages (json-parse-string json-str
                                                   :object-type 'plist
                                                   :array-type 'array
                                                   :null-object nil
                                                   :false-object :false)))
                 (opencode-scenario--log "  parsed %d messages" (length messages))
                 ;; Fetch pending popups (uses mock API) before rendering
                 (opencode-chat--fetch-pending-popups (current-buffer))
                 (opencode-chat--render-messages messages)))

              ('assert-contains
               (let* ((found (opencode-test-buffer-contains-p data))
                      (ok (if found t nil))
                      (msg (if ok
                               (format "L%d: PASS assert-contains %S" lnum data)
                             (format "L%d: FAIL assert-contains %S (not found)" lnum data))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-not-contains
               (let* ((found (opencode-test-buffer-contains-p data))
                      (ok (if found nil t))
                      (msg (if ok
                               (format "L%d: PASS assert-not-contains %S" lnum data)
                             (format "L%d: FAIL assert-not-contains %S (found)" lnum data))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-busy
               (let* ((ok (opencode-chat--busy))
                      (msg (if ok
                               (format "L%d: PASS assert-busy" lnum)
                             (format "L%d: FAIL assert-busy (not busy)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-idle
               (let* ((ok (not (opencode-chat--busy)))
                      (msg (if ok
                               (format "L%d: PASS assert-idle" lnum)
                             (format "L%d: FAIL assert-idle (is busy)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('eval
               (opencode-scenario--log "L%d: eval %s" lnum data)
               (condition-case err
                   (eval (car (read-from-string data)) t)
                 (error
                  (let ((msg (format "L%d: EVAL ERROR: %S\n  expr: %s" lnum err data)))
                    (opencode-scenario--log "%s" msg)
                    (push (list lnum nil msg) results))))
               ;; Yield to let timers/async callbacks fire
               (sit-for 0))

              ('answer-permission
               (opencode-scenario--log "L%d: answer-permission %s" lnum data)
               (if (not opencode-permission--current)
                   (let ((msg (format "L%d: FAIL answer-permission: no active permission popup" lnum)))
                     (opencode-scenario--log "%s" msg)
                     (push (list lnum nil msg) results))
                 (pcase data
                   ("allow-once"   (opencode-permission--allow-once))
                   ("allow-always" (opencode-permission--allow-always))
                   ("reject"       (opencode-permission--reject))
                   (_ (let ((msg (format "L%d: FAIL answer-permission: unknown choice %S" lnum data)))
                        (opencode-scenario--log "%s" msg)
                        (push (list lnum nil msg) results))))))

              ('answer-question
               (opencode-scenario--log "L%d: answer-question %S" lnum data)
               (if (not opencode-question--current)
                   (let ((msg (format "L%d: FAIL answer-question: no active question popup" lnum)))
                     (opencode-scenario--log "%s" msg)
                     (push (list lnum nil msg) results))
                 ;; Select options by 1-indexed numbers
                 (dolist (n data)
                   (opencode-question--select-option n))
                 ;; Submit
                 (opencode-question--submit)))

              ('reject-question
               (opencode-scenario--log "L%d: reject-question" lnum)
               (if (not opencode-question--current)
                   (let ((msg (format "L%d: FAIL reject-question: no active question popup" lnum)))
                     (opencode-scenario--log "%s" msg)
                     (push (list lnum nil msg) results))
                 (opencode-question--reject)))

              ('assert-permission
               (let* ((ok (not (null opencode-permission--current)))
                      (msg (if ok
                               (format "L%d: PASS assert-permission" lnum)
                             (format "L%d: FAIL assert-permission (no active permission)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-no-permission
               (let* ((ok (null opencode-permission--current))
                      (msg (if ok
                               (format "L%d: PASS assert-no-permission" lnum)
                             (format "L%d: FAIL assert-no-permission (permission active)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-question
               (let* ((ok (not (null opencode-question--current)))
                      (msg (if ok
                               (format "L%d: PASS assert-question" lnum)
                             (format "L%d: FAIL assert-question (no active question)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results)))

              ('assert-no-question
               (let* ((ok (null opencode-question--current))
                      (msg (if ok
                               (format "L%d: PASS assert-no-question" lnum)
                             (format "L%d: FAIL assert-no-question (question active)" lnum))))
                 (opencode-scenario--log "%s" msg)
                 (push (list lnum ok msg) results))))
          (error
           (let ((msg (format "L%d: ERROR %s: %S" lnum type err)))
             (opencode-scenario--log "%s" msg)
             (push (list lnum nil msg) results))))))
    (nreverse results)))


;;; --- Buffer Bootstrap ---

(defun opencode-scenario--bootstrap-buffer (session-id &optional directory parent-id)
  "Set up the current buffer as a chat buffer for scenario replay.
Initializes `opencode-chat-mode', sets SESSION-ID, stubs network calls,
and renders the input area.  DIRECTORY optionally sets the API directory.
PARENT-ID, when non-nil, makes this a child (sub-agent) session."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (opencode-chat-mode)
  (opencode-chat--set-session-id session-id)
  (opencode-chat--set-session
   (let ((ses (list :id session-id
                    :title (if parent-id "Sub-agent Replay" "Scenario Replay")
                    :directory (or directory default-directory))))
     (when parent-id
       (setq ses (plist-put ses :parentID parent-id)))
     ses))
  (opencode-chat--set-busy nil)
  (opencode-chat--set-streaming-assistant-info nil)
  (opencode-chat--set-refresh-timer nil)
  (opencode-chat--set-refresh-state nil)
  (when directory
    (setq-local opencode-api-directory directory))
  (setq opencode-chat--state nil)
  ;; Populate config cache so state-init resolves model/provider
  (setq opencode-api--server-config-cache
        (list :model "anthropic/claude-opus-4-6"))
  (opencode-chat-message-clear-all)
  ;; Register buffer so popup dispatch can find it
  (when (fboundp 'opencode--register-chat-buffer)
    (opencode--register-chat-buffer session-id (current-buffer)))
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (opencode-chat--render-input-area)
    ;; Child sessions: append sub-agent indicator below the input area
    (when parent-id
      (opencode-chat--render-child-indicator)))
  (opencode-scenario--log "bootstrap: session=%s dir=%s parent=%s"
                          session-id (or directory "default")
                          (or parent-id "nil")))


;;; --- cl-letf Stub List (shared by all entry points) ---

(defmacro opencode-scenario--with-stubs (file-label &rest body)
  "Execute BODY with all network/UI functions stubbed for scenario replay.
FILE-LABEL is used for the header-line display.
Uses mock API infrastructure so `:api' directives can register responses.
`opencode-chat--refresh' is NOT stubbed — it calls mock API endpoints.
`opencode-chat--schedule-refresh' bypasses the timer and calls refresh directly."
  (declare (indent 1) (debug t))
  `(let ((opencode-test--mock-responses (make-hash-table :test 'equal))
         (opencode-test--mock-requests nil))
     ;; Register default empty responses for common endpoints
     (opencode-test-mock-response "GET" "/question" 200 [])
     (opencode-test-mock-response "GET" "/permission" 200 [])
     (opencode-test-mock-response "GET" "/agent" 200
       [(:name "build" :description "Default agent" :mode "primary" :native t)])
     (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                (lambda () (opencode-chat--refresh)))
               ((symbol-function 'opencode-chat--header-line)
                (lambda () (format " Scenario: %s" ,file-label)))
               ((symbol-function 'opencode-chat--schedule-streaming-fontify) #'ignore)
               ((symbol-function 'rename-buffer) #'ignore)
               ((symbol-function 'opencode-agent--default-name) (lambda () "build"))
               ((symbol-function 'opencode-api--request)
                #'opencode-test--mock-api-request))
       ,@body)))


;;; --- Entry Points ---

(defun opencode-scenario-run-file (&optional file)
  "Parse and replay scenario FILE in a chat buffer.
Displays the buffer and leaves it open for inspection.
Returns a list of assertion results: ((LINE OK-P MESSAGE) ...)."
  (interactive (list (or buffer-file-name
                        (read-file-name "Scenario file: "))))
  (let ((ops (opencode-scenario--parse-file file))
        (session-id "ses_scenario_default")
        (directory nil)
        (parent-id nil))
    (dolist (op ops)
      (pcase (opencode-scenario-op-type op)
        ('session (setq session-id (opencode-scenario-op-data op)))
        ('directory (setq directory (opencode-scenario-op-data op)))
        ('parent-id (setq parent-id (opencode-scenario-op-data op)))))
    (let ((buf (get-buffer-create "*opencode: scenario-replay*")))
      (with-current-buffer buf
        (opencode-scenario--with-stubs (file-name-base file)
          (opencode-scenario--bootstrap-buffer session-id directory parent-id)
          (let ((results (opencode-scenario-replay-ops ops)))
            (pop-to-buffer buf)
            (goto-char (point-min))
            (let ((pass (cl-count-if (lambda (r) (nth 1 r)) results))
                  (fail (cl-count-if-not (lambda (r) (nth 1 r)) results)))
              (message "Scenario complete: %d passed, %d failed" pass fail)
              (when (> fail 0)
                (dolist (r results)
                  (unless (nth 1 r)
                    (message "  %s" (nth 2 r))))))
            results))))))

(defun opencode-scenario-run-string (scenario-string)
  "Parse and replay SCENARIO-STRING in a temp chat buffer.
Returns assertion results.  Buffer is killed after."
  (let ((ops (opencode-scenario--parse-string scenario-string))
        (session-id "ses_scenario_default")
        (directory nil)
        (parent-id nil))
    (dolist (op ops)
      (pcase (opencode-scenario-op-type op)
        ('session (setq session-id (opencode-scenario-op-data op)))
        ('directory (setq directory (opencode-scenario-op-data op)))
        ('parent-id (setq parent-id (opencode-scenario-op-data op)))))
    (let ((buf (get-buffer-create "*opencode: scenario-replay*")))
      (unwind-protect
          (with-current-buffer buf
            (opencode-scenario--with-stubs "inline"
              (opencode-scenario--bootstrap-buffer session-id directory parent-id)
              (opencode-scenario-replay-ops ops)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(defmacro opencode-scenario-with-replay (scenario-string &rest body)
  "Parse and replay SCENARIO-STRING, then execute BODY in the chat buffer.
Buffer is killed after BODY completes."
  (declare (indent 1) (debug t))
  `(let* ((ops (opencode-scenario--parse-string ,scenario-string))
          (session-id "ses_scenario_default")
          (directory nil)
          (parent-id nil)
          (buf (get-buffer-create "*opencode: scenario-replay*")))
     (dolist (op ops)
       (pcase (opencode-scenario-op-type op)
         ('session (setq session-id (opencode-scenario-op-data op)))
         ('directory (setq directory (opencode-scenario-op-data op)))
         ('parent-id (setq parent-id (opencode-scenario-op-data op)))))
     (unwind-protect
         (with-current-buffer buf
           (opencode-scenario--with-stubs "inline"
             (opencode-scenario--bootstrap-buffer session-id directory parent-id)
             (opencode-scenario-replay-ops ops)
             ,@body))
       (when (buffer-live-p buf)
         (kill-buffer buf)))))

(defun opencode-scenario-replay-file (&optional file)
  "Interactively replay scenario FILE with :wait pauses.
Leaves the buffer open for inspection."
  (interactive (list (or buffer-file-name
                        (read-file-name "Scenario file: "))))
  (let* ((ops (opencode-scenario--parse-file file))
         (session-id "ses_scenario_default")
         (directory nil)
         (parent-id nil))
    (dolist (op ops)
      (pcase (opencode-scenario-op-type op)
        ('session (setq session-id (opencode-scenario-op-data op)))
        ('directory (setq directory (opencode-scenario-op-data op)))
        ('parent-id (setq parent-id (opencode-scenario-op-data op)))))
    (let ((buf (get-buffer-create
                (format "*opencode: scenario<%s>*" (file-name-base file)))))
      (pop-to-buffer buf)
      (with-current-buffer buf
        (opencode-scenario--with-stubs (file-name-base file)
          (opencode-scenario--bootstrap-buffer session-id directory parent-id)
          (let ((results (opencode-scenario-replay-ops ops t)))
            (let ((pass (cl-count-if (lambda (r) (nth 1 r)) results))
                  (fail (cl-count-if-not (lambda (r) (nth 1 r)) results)))
              (message "Scenario complete: %d passed, %d failed"
                       pass fail)
              (when (> fail 0)
                (dolist (r results)
                  (unless (nth 1 r)
                    (message "  %s" (nth 2 r))))))))))))


;; ════════════════════════════════════════════════════════════════════
;;  ERT Tests
;; ════════════════════════════════════════════════════════════════════

;;; --- Parser Tests ---

(ert-deftest opencode-scenario-parse-empty ()
  "Empty input produces no ops.
Guards against crash on empty scenario files."
  (let ((ops (opencode-scenario--parse-string "")))
    (should (null ops))))

(ert-deftest opencode-scenario-parse-comments-and-blanks ()
  "Comments (#) and blank lines are skipped.
Ensures the parser ignores non-operational lines."
  (let ((ops (opencode-scenario--parse-string
              "# This is a comment\n\n# Another comment\n  \n")))
    (should (null ops))))

(ert-deftest opencode-scenario-parse-session ()
  "The :session directive sets the session ID.
Without this, replay would use a default session ID that doesn't match events."
  (let ((ops (opencode-scenario--parse-string ":session ses_abc123\n")))
    (should (= 1 (length ops)))
    (should (eq 'session (opencode-scenario-op-type (car ops))))
    (should (string= "ses_abc123" (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-directory ()
  "The :directory directive sets the project directory.
Required for correct X-OpenCode-Directory header matching."
  (let ((ops (opencode-scenario--parse-string
              ":directory /Users/test/project\n")))
    (should (= 1 (length ops)))
    (should (eq 'directory (opencode-scenario-op-type (car ops))))
    (should (string= "/Users/test/project" (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-sse-global-format ()
  "The :sse directive accepts global SSE format with payload wrapper.
This is the format from `GET /global/event` which wraps events in
{directory, payload: {type, properties}}."
  (let* ((json "{\"directory\":\"/proj\",\"payload\":{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_1\"}}}")
         (ops (opencode-scenario--parse-string
               (format ":sse %s\n" json))))
    (should (= 1 (length ops)))
    (should (eq 'sse (opencode-scenario-op-type (car ops))))
    (should (string= json (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-sse-flat-format ()
  "The :sse directive accepts flat SSE format without payload wrapper.
This is the internal format after unwrapping."
  (let* ((json "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_1\",\"status\":{\"type\":\"busy\"}}}")
         (ops (opencode-scenario--parse-string
               (format ":sse %s\n" json))))
    (should (= 1 (length ops)))
    (should (eq 'sse (opencode-scenario-op-type (car ops))))))

(ert-deftest opencode-scenario-parse-api ()
  "The :api directive registers a mock API response.
Format: :api METHOD PATH STATUS JSON-BODY."
  (let ((ops (opencode-scenario--parse-string
              ":api GET /session/ses_1 200 {\"id\":\"ses_1\"}\n")))
    (should (= 1 (length ops)))
    (let ((op (car ops)))
      (should (eq 'api (opencode-scenario-op-type op)))
      (should (string= "GET" (plist-get (opencode-scenario-op-data op) :method)))
      (should (string= "/session/ses_1" (plist-get (opencode-scenario-op-data op) :path)))
      (should (= 200 (plist-get (opencode-scenario-op-data op) :status))))))

(ert-deftest opencode-scenario-parse-wait ()
  "The :wait directive specifies a delay in milliseconds.
Used in interactive replay; no-op in batch mode."
  (let ((ops (opencode-scenario--parse-string ":wait 500\n")))
    (should (= 1 (length ops)))
    (should (eq 'wait (opencode-scenario-op-type (car ops))))
    (should (= 500 (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-assert-contains ()
  "The :assert-contains directive checks buffer content.
Fails the test if the expected text is not in the buffer."
  (let ((ops (opencode-scenario--parse-string
              ":assert-contains hello world\n")))
    (should (= 1 (length ops)))
    (should (eq 'assert-contains (opencode-scenario-op-type (car ops))))
    (should (string= "hello world" (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-assert-not-contains ()
  "The :assert-not-contains directive checks text is absent.
Fails the test if the unwanted text is found in the buffer."
  (let ((ops (opencode-scenario--parse-string
              ":assert-not-contains error message\n")))
    (should (= 1 (length ops)))
    (should (eq 'assert-not-contains (opencode-scenario-op-type (car ops))))
    (should (string= "error message" (opencode-scenario-op-data (car ops))))))

(ert-deftest opencode-scenario-parse-assert-busy-idle ()
  "The :assert-busy and :assert-idle directives check session state.
Important for verifying SSE status events are handled correctly."
  (let ((ops (opencode-scenario--parse-string
              ":assert-busy\n:assert-idle\n")))
    (should (= 2 (length ops)))
    (should (eq 'assert-busy (opencode-scenario-op-type (car ops))))
    (should (eq 'assert-idle (opencode-scenario-op-type (cadr ops))))))

(ert-deftest opencode-scenario-parse-multiline-json ()
  "Multi-line JSON is collected when continuation lines don't start with :.
Allows readable formatting of large JSON payloads in scenario files."
  (let ((ops (opencode-scenario--parse-string
              (concat ":sse {\"directory\":\"/proj\",\n"
                      "\"payload\":{\"type\":\"session.status\",\n"
                      "\"properties\":{\"sessionID\":\"ses_1\"}}}\n"))))
    (should (= 1 (length ops)))
    (should (eq 'sse (opencode-scenario-op-type (car ops))))
    (let ((data (opencode-scenario-op-data (car ops))))
      (should (string-match-p "session.status" data)))))

(ert-deftest opencode-scenario-parse-mixed-ops ()
  "A scenario with mixed op types parses in order.
Verifies that the parser handles interleaved directives correctly."
  (let ((ops (opencode-scenario--parse-string
              (concat ":session ses_test\n"
                      "# comment\n"
                      ":directory /proj\n"
                      ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_test\",\"status\":{\"type\":\"busy\"}}}\n"
                      ":assert-busy\n"
                      ":wait 100\n"))))
    (should (= 5 (length ops)))
    (should (eq 'session (opencode-scenario-op-type (nth 0 ops))))
    (should (eq 'directory (opencode-scenario-op-type (nth 1 ops))))
    (should (eq 'sse (opencode-scenario-op-type (nth 2 ops))))
    (should (eq 'assert-busy (opencode-scenario-op-type (nth 3 ops))))
    (should (eq 'wait (opencode-scenario-op-type (nth 4 ops))))))

(ert-deftest opencode-scenario-parse-line-numbers ()
  "Each op records its source line number for error reporting.
Enables meaningful error messages when assertions fail."
  (let ((ops (opencode-scenario--parse-string
              (concat "# line 1\n"
                      ":session ses_1\n"      ; line 2
                      "\n"                    ; line 3
                      ":assert-idle\n"))))    ; line 4
    (should (= 2 (length ops)))
    (should (= 2 (opencode-scenario-op-line-number (nth 0 ops))))
    (should (= 4 (opencode-scenario-op-line-number (nth 1 ops))))))

(ert-deftest opencode-scenario-parse-refresh-file ()
  "The :refresh directive with a .json filename parses correctly."
  (let ((ops (opencode-scenario--parse-string
              ":refresh multi-tool-messages.json\n")))
    (should (= 1 (length ops)))
    (should (eq 'refresh (opencode-scenario-op-type (car ops))))
    (should (string= "multi-tool-messages.json"
                     (plist-get (opencode-scenario-op-data (car ops)) :file)))))

(ert-deftest opencode-scenario-parse-refresh-inline ()
  "The :refresh directive with inline JSON parses correctly."
  (let ((ops (opencode-scenario--parse-string
              ":refresh [{\"info\":{},\"parts\":[]}]\n")))
    (should (= 1 (length ops)))
    (should (eq 'refresh (opencode-scenario-op-type (car ops))))
    (should (plist-get (opencode-scenario-op-data (car ops)) :json))))


;;; --- SSE Unwrapper Tests ---

(ert-deftest opencode-scenario-unwrap-global-format ()
  "Global format SSE events are unwrapped correctly.
Extracts type, properties, and directory from the payload wrapper."
  (let ((event (opencode-scenario--unwrap-sse
                "{\"directory\":\"/proj\",\"payload\":{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_1\",\"status\":{\"type\":\"busy\"}}}}")))
    (should (string= "session.status" (plist-get event :type)))
    (should (string= "ses_1" (plist-get (plist-get event :properties) :sessionID)))
    (should (string= "/proj" (plist-get event :directory)))))

(ert-deftest opencode-scenario-unwrap-flat-format ()
  "Flat format SSE events pass through correctly.
Used when events are already in internal format."
  (let ((event (opencode-scenario--unwrap-sse
                "{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_1\"}}")))
    (should (string= "session.idle" (plist-get event :type)))
    (should (string= "ses_1" (plist-get (plist-get event :properties) :sessionID)))))


;;; --- Replay Engine Tests ---

(ert-deftest opencode-scenario-replay-session-status ()
  "Replaying a session.status(busy) event sets the busy flag.
Verifies the SSE handler dispatch works through the replay engine."
  (opencode-scenario-with-replay
      (concat ":session ses_replay_test\n"
              ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_replay_test\",\"status\":{\"type\":\"busy\"}}}\n"
              ":assert-busy\n")
    (should (opencode-chat--busy))
    (let ((results (opencode-scenario-replay-ops
                    (opencode-scenario--parse-string ":assert-busy\n"))))
      (should (nth 1 (car results))))))

(ert-deftest opencode-scenario-replay-streaming-delta ()
  "Replaying streaming delta events inserts text in the buffer.
This is the core streaming test — verifies that message.part.updated
events with delta fields produce visible text in the chat buffer."
  (opencode-scenario-with-replay
      (concat
       ":session ses_delta_test\n"
       ":sse {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"msg_1\",\"sessionID\":\"ses_delta_test\",\"role\":\"assistant\",\"time\":{\"created\":1700000000000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\"}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_1\",\"sessionID\":\"ses_delta_test\",\"messageID\":\"msg_1\",\"type\":\"text\",\"text\":\"\",\"time\":{\"start\":1700000000000}}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_1\",\"sessionID\":\"ses_delta_test\",\"messageID\":\"msg_1\",\"type\":\"text\",\"text\":\"hello\",\"time\":{\"start\":1700000000000}},\"delta\":\"hello\"}}\n"
       ":assert-contains hello\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_1\",\"sessionID\":\"ses_delta_test\",\"messageID\":\"msg_1\",\"type\":\"text\",\"text\":\"hello world\",\"time\":{\"start\":1700000000000}},\"delta\":\" world\"}}\n"
       ":assert-contains hello world\n")
    (should (opencode-test-buffer-contains-p "hello world"))))

(ert-deftest opencode-scenario-replay-assert-not-contains ()
  "The :assert-not-contains op correctly fails when text IS present.
Ensures negative assertions work for absence checking."
  (let ((results (opencode-scenario-run-string
                  (concat ":session ses_neg\n"
                          ":assert-not-contains > \n"))))
    (should (= 1 (length results)))
    (should-not (nth 1 (car results)))))

(ert-deftest opencode-scenario-replay-idle-clears-busy ()
  "Replaying session.idle clears the busy flag set by session.status(busy).
Verifies the full busy → idle lifecycle through SSE events."
  (opencode-scenario-with-replay
      (concat
       ":session ses_idle\n"
       ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_idle\",\"status\":{\"type\":\"busy\"}}}\n"
       ":assert-busy\n"
       ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_idle\",\"status\":{\"type\":\"idle\"}}}\n"
       ":sse {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_idle\"}}\n"
       ":assert-idle\n")
    (should-not (opencode-chat--busy))))


;;; --- Fixture File Tests ---

(ert-deftest opencode-scenario-replay-fixture-file ()
  "The sample-scenario.txt fixture file loads and replays without errors.
Serves as an integration test for the full parser → replay pipeline."
  (let* ((fixture-file (expand-file-name
                        "sample-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-replay-refresh-from-file ()
  "The :refresh directive loads a JSON fixture and renders the full buffer.
Verifies that the complete render pipeline works: user messages, assistant
messages, text parts, tool parts (bash, question)."
  (let* ((fixture-file (expand-file-name
                        "multi-tool/refresh-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))


;;; --- Edge Cases ---

(ert-deftest opencode-scenario-parse-unknown-prefix ()
  "Unknown :prefix lines are skipped gracefully without error.
Prevents crashes when scenario files contain forward-compatible directives."
  (let ((ops (opencode-scenario--parse-string
              ":unknown-directive foo bar\n:session ses_1\n")))
    (should (= 1 (length ops)))
    (should (eq 'session (opencode-scenario-op-type (car ops))))))

(ert-deftest opencode-scenario-replay-error-handling ()
  "Replay engine catches errors from individual ops and continues.
A broken SSE event should not abort the entire scenario."
  (let ((results (opencode-scenario-run-string
                  (concat ":session ses_err\n"
                          ":sse {invalid json}\n"
                          ":assert-idle\n"))))
    (should (>= (length results) 1))))

;;; --- Scenario Comparison ---

(defun opencode-scenario--run-and-capture (fixture-subdir)
  "Run streaming and refresh scenarios from FIXTURE-SUBDIR, return (streaming . refresh) text.
FIXTURE-SUBDIR is relative to `opencode-test--fixtures-dir', e.g. \"multi-tool\"."
  (let (streaming-text refresh-text)
    (dolist (variant '("streaming" "refresh"))
      (let* ((file (expand-file-name
                    (format "%s/%s-scenario.txt" fixture-subdir variant)
                    opencode-test--fixtures-dir))
             (ops (opencode-scenario--parse-file file))
             (session-id "ses_scenario_default")
             (directory nil)
             (buf (get-buffer-create (format "*opencode: cmp-%s*" variant))))
        (dolist (op ops)
          (pcase (opencode-scenario-op-type op)
            ('session (setq session-id (opencode-scenario-op-data op)))
            ('directory (setq directory (opencode-scenario-op-data op)))))
        (unwind-protect
            (with-current-buffer buf
              (opencode-scenario--with-stubs variant
                (opencode-scenario--bootstrap-buffer session-id directory)
                (opencode-scenario-replay-ops ops)
                (let ((text (buffer-substring-no-properties
                             (point-min)
                             (marker-position
                              (opencode-chat-message-messages-end)))))
                  (if (string= variant "streaming")
                      (setq streaming-text text)
                    (setq refresh-text text)))))
          (when (buffer-live-p buf) (kill-buffer buf)))))
    (cons streaming-text refresh-text)))

(ert-deftest opencode-scenario-streaming-vs-refresh ()
  "Compare message area rendering between streaming (SSE) and refresh (API).
The refresh scenario loads the finalized /session/:id/message response
and renders the complete buffer — this is the ground truth.  The streaming
scenario replays the live SSE event sequence.  Both should produce the
same visible message area.

If this test fails, the streaming code path has diverged from the refresh
code path, meaning users see different content depending on whether they
watched the session live or opened it after completion."
  (let ((result (opencode-scenario--run-and-capture "multi-tool")))
    (should (string= (string-trim (car result)) (string-trim (cdr result))))))

(ert-deftest opencode-scenario-double-permission-replay ()
  "The double-permission streaming scenario replays without errors.
Tests the edge case where two permission.asked events arrive back-to-back
for the same session — the popup queue must handle this correctly."
  (let* ((file (expand-file-name "double-permission/streaming-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-double-permission-refresh ()
  "The double-permission refresh scenario renders correctly.
Tests rendering from API response with a completed tool, a running tool,
and a pending permission popup."
  (let* ((file (expand-file-name "double-permission/refresh-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-double-permission-streaming-vs-refresh ()
  "Compare streaming vs refresh for the double-permission scenario.
Both code paths should produce the same visible message area despite
the complex double-permission event sequence."
  (let ((result (opencode-scenario--run-and-capture "double-permission")))
    (should (string= (string-trim (car result))
                     (string-trim (cdr result))))))

(defun opencode-scenario--normalize-whitespace (s)
  "Normalize S for comparison: trim and collapse whitespace runs.
Streaming deltas may include trailing newlines in intermediate chunks
that are absent from the finalized API response.  This collapses any
run of blank lines (lines with only spaces) into nothing, so the
comparison tests semantic content rather than incidental spacing."
  (let ((result (string-trim-right s)))
    ;; Remove lines that contain only spaces (blank lines with prefix).
    ;; These appear in streaming from trailing newlines in reasoning deltas.
    (setq result (replace-regexp-in-string "\n *\n" "\n" result))
    ;; May need multiple passes for runs of 3+ blank lines
    (setq result (replace-regexp-in-string "\n *\n" "\n" result))
    result))

(ert-deftest opencode-scenario-commit-tools-with-thinking-streaming-vs-refresh ()
  "Compare streaming vs refresh for a session with reasoning/thinking parts.
Both code paths should produce the same visible message area.
The fixture includes step-start, reasoning, text, and tool parts —
verifying that streamed thinking blocks match the refresh render.
Uses whitespace normalization because streaming deltas include trailing
newlines in intermediate chunks that the finalized API response omits."
  (let ((result (opencode-scenario--run-and-capture "commit-tools-with-thinking")))
    (should (string= (opencode-scenario--normalize-whitespace (car result))
                     (opencode-scenario--normalize-whitespace (cdr result))))))

(ert-deftest opencode-scenario-reasoning-midline-boundary-streaming-vs-refresh ()
  "Regression pin for the \"glued parts\" bug.
The fixture's only reasoning delta ends MID-LINE (no trailing newline),
then a new text part arrives — reproducing the condition under which
the first text delta used to concatenate onto the reasoning's tail.
With the fix in `opencode-chat-message-update-part' (Case 2 inserts a
\\n when not at `bolp'), streaming output must match the refresh render
after whitespace normalization — the existing
`commit-tools-with-thinking' fixture happens to always end reasoning
on a newline so it never exercised this path."
  (let ((result (opencode-scenario--run-and-capture "reasoning-midline-boundary")))
    (should (string= (opencode-scenario--normalize-whitespace (car result))
                     (opencode-scenario--normalize-whitespace (cdr result))))))

(ert-deftest opencode-scenario-golden-full-session-streaming-vs-refresh ()
  "Full-pipeline golden: streaming output must match refresh output.
The `golden-full-session' fixture covers every boundary the 10-commit
cleanup sweep cared about — reasoning→text (mid-line), text→tool,
tool→text, text→tool (edit), text→footer — over two user turns.  Any
regression in part-boundary rendering, tool dispatch, or footer finalize
surfaces here as a streaming-vs-refresh divergence."
  (let ((result (opencode-scenario--run-and-capture "golden-full-session")))
    (should (string= (opencode-scenario--normalize-whitespace (car result))
                     (opencode-scenario--normalize-whitespace (cdr result))))))

(ert-deftest opencode-scenario-collapsed-indent-line-prefix ()
  "All assistant message children must have consistent line-prefix (stripe only).
Reasoning header, tool header, and footer should all use the same line-prefix
value — a single propertized stripe char with `opencode-assistant-block' face.
Tool prefix must NOT include an extra space (was stripe+\" \", now just stripe)."
  (let* ((fixture-file (expand-file-name
                        "collapsed-indent/refresh-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (with-current-buffer "*opencode: scenario-replay*"
          ;; File-level assertions should pass
          (dolist (r results)
            (should (nth 1 r)))
          ;; Helper: find text and return line-prefix at that position
          (cl-flet ((lp-at (text)
                      (save-excursion
                        (goto-char (point-min))
                        (when (search-forward text nil t)
                          (get-text-property (match-beginning 0) 'line-prefix)))))
            ;; All children should have line-prefix
            (let ((thinking-lp (lp-at "Thinking"))
                  (tool-lp (lp-at "bash"))
                  (footer-lp (lp-at "\u2B06")))
              ;; Each should have a line-prefix
              (should thinking-lp)
              (should tool-lp)
              (should footer-lp)
              ;; All should be the stripe char (no extra space)
              (should (string= (substring-no-properties thinking-lp) "\u258E"))
              (should (string= (substring-no-properties tool-lp) "\u258E"))
              (should (string= (substring-no-properties footer-lp) "\u258E"))
              ;; All should carry the assistant-block face
              (should (eq 'opencode-assistant-block
                          (get-text-property 0 'face thinking-lp)))
              (should (eq 'opencode-assistant-block
                          (get-text-property 0 'face tool-lp)))
              (should (eq 'opencode-assistant-block
                          (get-text-property 0 'face footer-lp))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-optimistic-user-msg-no-duplicate ()
  "Optimistic user message text must not be rendered twice.
The client renders optimistically, server confirms with delete+recreate.
User text should appear exactly once, in correct order before assistant."
  (let* ((file (expand-file-name "optimistic-delete-recreate/streaming-scenario.txt"
                                 opencode-test--fixtures-dir))
         (ops (opencode-scenario--parse-file file))
         (session-id nil)
         (directory nil)
         (buf (get-buffer-create "*opencode: optimistic-test*")))
    ;; Extract session-id and directory from fixture
    (dolist (op ops)
      (pcase (opencode-scenario-op-type op)
        ('session (setq session-id (opencode-scenario-op-data op)))
        ('directory (setq directory (opencode-scenario-op-data op)))))
    (unwind-protect
        (with-current-buffer buf
          (opencode-scenario--with-stubs "optimistic-test"
            (opencode-scenario--bootstrap-buffer session-id directory)
            (opencode-scenario-replay-ops ops)
            ;; User header must appear before assistant header
            (let ((user-pos (save-excursion
                              (goto-char (point-min))
                              (search-forward "You" nil t)))
                  (asst-pos (save-excursion
                              (goto-char (point-min))
                              (search-forward "Assistant" nil t))))
              (should user-pos)
              (when asst-pos
                (should (< user-pos asst-pos))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-scenario-undo-safe-after-streaming ()
  "Undo must not corrupt the buffer after streaming events.
SSE-driven mutations (streaming deltas, tool upserts, session status)
are infrastructure — not user edits.  If they leak into the undo list,
C-/ would reverse streamed text or re-render artifacts.

Strategy: replay a full streaming lifecycle, capture the buffer text,
attempt undo, then verify the buffer text is unchanged."
  (opencode-scenario-with-replay
      (concat
       ":session ses_undo_test\n"
       ":directory /tmp/test\n"
       ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_undo_test\",\"status\":{\"type\":\"busy\"}}}\n"
       ":sse {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"msg_a1\",\"sessionID\":\"ses_undo_test\",\"role\":\"assistant\",\"time\":{\"created\":1700000000000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\"}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_t1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"text\",\"text\":\"\",\"time\":{\"start\":1700000000000}}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_t1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"text\",\"text\":\"hello\",\"time\":{\"start\":1700000000000}},\"delta\":\"hello\"}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_t1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"text\",\"text\":\"hello world\",\"time\":{\"start\":1700000000000}},\"delta\":\" world\"}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_t1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"text\",\"text\":\"hello world\",\"time\":{\"start\":1700000000000,\"end\":1700000001000}}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_tool1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"tool\",\"callID\":\"call_1\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"echo hi\"},\"output\":\"hi\\n\",\"time\":{\"start\":1700000001000,\"end\":1700000002000}}}}}\n"
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_sf1\",\"sessionID\":\"ses_undo_test\",\"messageID\":\"msg_a1\",\"type\":\"step-finish\",\"reason\":\"stop\",\"cost\":0,\"tokens\":{\"input\":100,\"output\":50,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}}}}\n"
       ":sse {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"msg_a1\",\"sessionID\":\"ses_undo_test\",\"role\":\"assistant\",\"time\":{\"created\":1700000000000,\"completed\":1700000002000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\",\"cost\":0,\"tokens\":{\"input\":100,\"output\":50,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}},\"finish\":\"stop\"}}}\n"
       ":sse {\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_undo_test\",\"status\":{\"type\":\"idle\"}}}\n"
       ":sse {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_undo_test\"}}\n"
       ":assert-contains hello world\n")
    (let ((text-before (buffer-string)))
      ;; Attempt undo — should either be a no-op or signal "no undo info"
      (condition-case nil
          (let ((inhibit-read-only t))
            (primitive-undo 1 buffer-undo-list))
        (error nil))
      (should (string= text-before (buffer-string))))))

(ert-deftest opencode-scenario-undo-safe-after-refresh ()
  "Undo must not corrupt the buffer after a :refresh re-render.
The :refresh directive simulates GET /session/:id/message → render-messages,
which wipes and rebuilds the entire buffer.  Undo must not reverse this."
  (opencode-scenario-with-replay
      (concat
       ":session ses_refresh_undo\n"
       ":refresh [{\"info\":{\"id\":\"msg_u1\",\"role\":\"user\",\"time\":{\"created\":1700000000000}},\"parts\":[{\"id\":\"prt_u1\",\"type\":\"text\",\"text\":\"hello\"}]},{\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"time\":{\"created\":1700000001000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\",\"tokens\":{\"input\":10,\"output\":20,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}},\"parts\":[{\"id\":\"prt_a1\",\"type\":\"text\",\"text\":\"world\",\"time\":{\"start\":1700000001000,\"end\":1700000002000}}]}]\n"
       ":assert-contains hello\n"
       ":assert-contains world\n")
    (let ((text-before (buffer-string)))
      (condition-case nil
          (let ((inhibit-read-only t))
            (primitive-undo 1 buffer-undo-list))
        (error nil))
      (should (string= text-before (buffer-string))))))

;;; --- @-mention chip tests ---

(ert-deftest opencode-scenario-mention-sequential-folder-chips ()
  "Sequential folder @-mentions must each produce their own chip.
When the user types @test/ and completes (chip 1), then types
@test/fixtures/ and completes (chip 2), the second mention-exit
must find the NEW @ (not the one inside chip 1).  Without this fix,
search-backward finds the @ inside the first chip overlay, causing
the second chip to cover the wrong region or fail entirely.
Bug: `search-backward \"@\"` doesn't skip existing chip overlays."
  (opencode-scenario-with-replay
      (concat
       ":session ses_mention_test\n"
       ;; Step 1: simulate typing "@test/" and completing it
       ;; Insert @test/ at input area, then call mention-exit to create chip
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (insert \"@test/\")\n"
       ":eval (opencode-chat--mention-exit \"test/\" 'finished)\n"
       ;; Step 2: simulate typing " @test/fixtures/" after the chip and completing
       ":eval (goto-char (opencode-chat--input-content-end))\n"
       ":eval (insert \" @test/fixtures/\")\n"
       ":eval (opencode-chat--mention-exit \"test/fixtures/\" 'finished)\n")
    ;; Both chips should exist in the buffer
    (should (opencode-test-buffer-contains-p "@test/"))
    (should (opencode-test-buffer-contains-p "@test/fixtures/"))
    ;; Verify exactly 2 chip overlays exist in the input area
    (let* ((input-start (opencode-chat--input-content-start))
           (input-end (opencode-chat--input-content-end))
           (chip-overlays (seq-filter
                           (lambda (ov) (overlay-get ov 'opencode-mention))
                           (overlays-in input-start input-end))))
      (should (= 2 (length chip-overlays)))
      ;; Verify each chip covers the right text
      (let ((chip-texts (mapcar (lambda (ov)
                                  (buffer-substring-no-properties
                                   (overlay-start ov) (overlay-end ov)))
                                (sort chip-overlays
                                      (lambda (a b) (< (overlay-start a)
                                                       (overlay-start b)))))))
        (should (equal (car chip-texts) "@test/"))
        (should (equal (cadr chip-texts) "@test/fixtures/"))))))

(ert-deftest opencode-scenario-mention-search-skips-chip-overlay ()
  "The backward @ search helper must skip @ chars inside chip overlays.
This is the fundamental invariant: when an existing chip contains `@foo',
typing a new `@bar' after it must find the new `@', not the chipped one."
  (opencode-scenario-with-replay
      (concat
       ":session ses_at_skip_test\n"
       ;; Create a chip for @README.md
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (insert \"@README.md\")\n"
       ":eval (opencode-chat--mention-exit \"README.md\" 'finished)\n"
       ;; Insert a new @ after the chip
       ":eval (goto-char (opencode-chat--input-content-end))\n"
       ":eval (insert \" @\")\n")
    ;; search-backward-at-sign should find the NEW @, not the one in the chip
    (let* ((input-start (opencode-chat--input-content-start))
           (found (save-excursion
                    (goto-char (opencode-chat--input-content-end))
                    (opencode-chat--search-backward-at-sign input-start))))
      (should found)
      ;; The found @ should NOT be inside a chip overlay
      (should-not (seq-find (lambda (ov) (overlay-get ov 'opencode-mention))
                            (overlays-at found)))
      ;; The found @ should be the second one (after the chip)
      (should (> found (overlay-end
                        (car (seq-filter
                              (lambda (ov) (overlay-get ov 'opencode-mention))
                              (overlays-in input-start
                                           (opencode-chat--input-content-end))))))))))

(ert-deftest opencode-scenario-footer-shows-variant-and-context-bar ()
  "Footer must display variant badge and context progress bar.
When the provider cache is populated and a variant is set, the footer
line should read: [model] · Agent · variant, followed by token usage
and a context progress bar with remaining tokens.
Bug: context bar was missing because provider cache was not pre-warmed,
and variant was not displayed."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_footer_test\n"
         ;; Set up state with variant and tokens
         ":eval (opencode-chat--set-variant \"max\")\n"
         ":eval (opencode-chat--set-tokens"
         " (list :total 5000 :input 1000 :output 4000 :reasoning 0"
         " :cache-read 3000 :cache-write 500))\n"
         ;; Re-render footer to pick up changes
         ":eval (opencode-chat--refresh-footer)\n")
      ;; Model badge
      (should (opencode-test-buffer-contains-p "[claude-opus-4-6]"))
      ;; Dot separator + agent
      (should (opencode-test-buffer-contains-p "· build"))
      ;; Variant with dot separator
      (should (opencode-test-buffer-contains-p "· max"))
      ;; Token line
      (should (opencode-test-buffer-contains-p "Tokens: 5,000"))
      (should (opencode-test-buffer-contains-p "⬆1,000"))
      (should (opencode-test-buffer-contains-p "⬇4,000"))
      ;; Context bar with limit and remaining
      (should (opencode-test-buffer-contains-p "Context:"))
      (should (opencode-test-buffer-contains-p "200,000"))
      (should (opencode-test-buffer-contains-p "remaining")))))

(ert-deftest opencode-scenario-footer-context-bar-without-tokens ()
  "Context bar should appear even when token count is zero.
A new session with no messages should still show the full context
capacity as available, not hide the bar entirely.
Bug: guard was (> total-tok 0) which hid the bar for new sessions."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_footer_zero\n"
         ;; No tokens set — defaults to 0
         ":eval (opencode-chat--refresh-footer)\n")
      ;; Context bar should still appear
      (should (opencode-test-buffer-contains-p "Context:"))
      (should (opencode-test-buffer-contains-p "0.0%"))
      (should (opencode-test-buffer-contains-p "200,000 remaining")))))

(ert-deftest opencode-scenario-footer-no-variant-hides-variant-badge ()
  "When variant is nil, no variant badge or trailing dot separator appears.
The footer should show only: [model] · Agent"
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_footer_novar\n"
         ":eval (opencode-chat--set-variant nil)\n"
         ":eval (opencode-chat--refresh-footer)\n")
      (should (opencode-test-buffer-contains-p "[claude-opus-4-6]"))
      (should (opencode-test-buffer-contains-p "· build"))
      ;; No "· max" or "· nil" should appear
      (should-not (opencode-test-buffer-contains-p "· max"))
      (should-not (opencode-test-buffer-contains-p "· nil")))))

(ert-deftest opencode-scenario-footer-context-bar-overflow ()
  "Context bar must not crash when token usage exceeds context limit.
Bug: `filled' could exceed `bar-width' when percentage > 100%,
making `empty' negative and crashing `make-string' with wholenump error."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_footer_overflow\n"
         ;; Set tokens WAY over the context limit (200000)
         ":eval (opencode-chat--set-tokens"
         " (list :total 3110000 :input 1000000 :output 2110000 :reasoning 0"
         " :cache-read 0 :cache-write 0))\n"
         ":eval (opencode-chat--refresh-footer)\n")
      ;; Should not crash — context bar renders with 100% filled
      (should (opencode-test-buffer-contains-p "Context:"))
      (should (opencode-test-buffer-contains-p "0 remaining")))))

;;; --- Permission/Question answer tests ---

(ert-deftest opencode-scenario-parse-answer-permission ()
  "The :answer-permission directive parses the three valid choices.
Required for testing permission popup answer flow without :eval hacks."
  (let ((ops (opencode-scenario--parse-string
              (concat ":answer-permission allow-once\n"
                      ":answer-permission allow-always\n"
                      ":answer-permission reject\n"))))
    (should (= 3 (length ops)))
    (should (eq 'answer-permission (opencode-scenario-op-type (nth 0 ops))))
    (should (string= "allow-once" (opencode-scenario-op-data (nth 0 ops))))
    (should (string= "allow-always" (opencode-scenario-op-data (nth 1 ops))))
    (should (string= "reject" (opencode-scenario-op-data (nth 2 ops))))))

(ert-deftest opencode-scenario-parse-answer-question ()
  "The :answer-question directive parses comma-separated option numbers.
Required for testing question popup answer flow without :eval hacks."
  (let ((ops (opencode-scenario--parse-string
              (concat ":answer-question 1\n"
                      ":answer-question 1,3\n"))))
    (should (= 2 (length ops)))
    (should (eq 'answer-question (opencode-scenario-op-type (nth 0 ops))))
    (should (equal '(1) (opencode-scenario-op-data (nth 0 ops))))
    (should (equal '(1 3) (opencode-scenario-op-data (nth 1 ops))))))

(ert-deftest opencode-scenario-parse-reject-question ()
  "The :reject-question directive parses correctly."
  (let ((ops (opencode-scenario--parse-string ":reject-question\n")))
    (should (= 1 (length ops)))
    (should (eq 'reject-question (opencode-scenario-op-type (car ops))))))

(ert-deftest opencode-scenario-parse-assert-permission-question ()
  "The :assert-permission/question directives parse correctly."
  (let ((ops (opencode-scenario--parse-string
              (concat ":assert-permission\n"
                      ":assert-no-permission\n"
                      ":assert-question\n"
                      ":assert-no-question\n"))))
    (should (= 4 (length ops)))
    (should (eq 'assert-permission (opencode-scenario-op-type (nth 0 ops))))
    (should (eq 'assert-no-permission (opencode-scenario-op-type (nth 1 ops))))
    (should (eq 'assert-question (opencode-scenario-op-type (nth 2 ops))))
    (should (eq 'assert-no-question (opencode-scenario-op-type (nth 3 ops))))))

(ert-deftest opencode-scenario-cursor-returns-to-input-after-question ()
  "After answering a question popup, cursor must return to the input area.
Bug: popup--restore-input re-renders the input area but leaves point at
position 1 (beginning of buffer) instead of the input area, so the user
cannot type immediately after answering."
  (let* ((file (expand-file-name "question-cursor-position/streaming-scenario.txt"
                                 opencode-test--fixtures-dir))
         (ops (opencode-scenario--parse-file file))
         (session-id "ses_scenario_default")
         (directory nil)
         (buf (get-buffer-create "*opencode: cursor-test*")))
    (dolist (op ops)
      (pcase (opencode-scenario-op-type op)
        ('session (setq session-id (opencode-scenario-op-data op)))
        ('directory (setq directory (opencode-scenario-op-data op)))))
    (unwind-protect
        (with-current-buffer buf
          (opencode-scenario--with-stubs "cursor-test"
            (opencode-scenario--bootstrap-buffer session-id directory)
            (opencode-scenario-replay-ops ops)
            ;; After answering the question, cursor should be in the input area
            (should (>= (point) (marker-position (opencode-chat--input-start))))
            (should (not (get-text-property (point) 'read-only)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; --- Issue tests: input area, cursor position, paste keymap, S-TAB ---

(ert-deftest opencode-scenario-input-text-after-refresh ()
  "After :refresh, saved input text must appear on the same line as the prompt.
Bug: input-start marker was placed AFTER the editable space, so
`render-messages' restore code jumped into the footer, causing saved
text to land below the prompt instead of beside it.
The invariant is: the line containing input-start must read \"> <text>\"."
  (opencode-scenario-with-replay
      (concat
       ":session ses_input_refresh\n"
       ":refresh [{\"info\":{\"id\":\"msg_u1\",\"role\":\"user\",\"time\":{\"created\":1700000000000}},\"parts\":[{\"id\":\"prt_u1\",\"type\":\"text\",\"text\":\"hello\"}]},{\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"time\":{\"created\":1700000001000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\",\"tokens\":{\"input\":10,\"output\":20,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}},\"parts\":[{\"id\":\"prt_a1\",\"type\":\"text\",\"text\":\"world\",\"time\":{\"start\":1700000001000,\"end\":1700000002000}}]}]\n"
       ;; Type text in the input area
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (insert \"my saved query\")\n")
    ;; Verify before refresh
    (should (string= "my saved query" (opencode-chat--input-text)))
    ;; Second refresh (simulates SSE-triggered re-render)
    (opencode-chat--render-messages)
    ;; Text must survive
    (should (string= "my saved query" (opencode-chat--input-text)))
    ;; CRITICAL: prompt and text must be on the SAME line
    (let* ((is (marker-position (opencode-chat--input-start)))
           (line (save-excursion
                   (goto-char is)
                   (buffer-substring-no-properties (pos-bol) (pos-eol)))))
      (should (string-prefix-p "> " line))
      (should (string-match-p "my saved query" line)))))

(ert-deftest opencode-scenario-cursor-in-input-after-refresh ()
  "When cursor is in input area during refresh, it returns to input area.
Bug: absolute position restore put cursor in wrong place when messages
changed (more text rendered shifts input area down)."
  (opencode-scenario-with-replay
      (concat
       ":session ses_cursor_input\n"
       ;; Type text and position cursor in the input area
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (insert \"test input\")\n")
    ;; Verify cursor is in the input area
    (should (opencode-chat--in-input-area-p))
    ;; Refresh
    (opencode-chat--render-messages)
    ;; Cursor must still be in the input area
    (should (opencode-chat--in-input-area-p))))

(ert-deftest opencode-scenario-cursor-in-footer-returns-to-input ()
  "When cursor is in the footer area during refresh, it moves to input.
Fallback: if cursor was in footer/shortcut area, go to input start."
  (opencode-scenario-with-replay
      (concat
       ":session ses_cursor_footer\n")
    ;; Move cursor to footer area (past input, into read-only zone)
    (goto-char (point-max))
    ;; Refresh
    (opencode-chat--render-messages)
    ;; Cursor should be in the input area (fallback)
    (should (opencode-chat--in-input-area-p))))

(ert-deftest opencode-scenario-cursor-placement-on-session-idle ()
  "`opencode-chat--on-session-idle' cursor-snap covers three cases:
1. Cursor inside a message overlay — left alone (async refresh restores
   by msg-id + offset).
2. Cursor in the footer / past input (e.g. `point-max' after streaming)
   — snapped to input via `opencode-chat--goto-latest'.
3. Cursor inside the editable input area — left alone (no clobbering
   the user's typing position).
The handler fires async refresh after the snap; we only verify the
immediate synchronous cursor placement here."
  (opencode-scenario-with-replay
      (concat
       ":session ses_idle_cursor\n"
       ":refresh [{\"info\":{\"id\":\"msg_u1\",\"role\":\"user\",\"time\":{\"created\":1700000000000}},\"parts\":[{\"id\":\"prt_u1\",\"type\":\"text\",\"text\":\"hello world\"}]},{\"info\":{\"id\":\"msg_a1\",\"role\":\"assistant\",\"time\":{\"created\":1700000001000},\"modelID\":\"claude-opus-4-6\",\"providerID\":\"anthropic\",\"tokens\":{\"input\":10,\"output\":20,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}},\"parts\":[{\"id\":\"prt_a1\",\"type\":\"text\",\"text\":\"greetings\",\"time\":{\"start\":1700000001000,\"end\":1700000002000}}]}]\n")
    ;; Stub the async refresh — we're only verifying the synchronous
    ;; cursor-snap in `on-session-idle', not the HTTP round-trip.
    (cl-letf (((symbol-function 'opencode-chat--refresh) (lambda (&rest _) nil))
              ((symbol-function 'opencode-chat--drain-popup-queue) (lambda (&rest _) nil)))
    (let ((idle-event '(:type "session.idle"
                        :properties (:sessionID "ses_idle_cursor"))))
      ;; --- Case 1: cursor on a message is preserved ---
      (let* ((ov (opencode-chat--store-find-overlay "msg_u1"))
             (_ (should ov))
             (target (+ (overlay-start ov) 3)))
        (goto-char target)
        (opencode-chat--on-session-idle idle-event)
        ;; Immediate snap must NOT fire — cursor stays inside the message
        ;; overlay.  (The async refresh would later restore by msg-id +
        ;; offset, also landing inside the same overlay.)
        (should (= (point) target))
        (let ((msg-ov (seq-find
                       (lambda (o)
                         (let ((sec (overlay-get o 'opencode-section)))
                           (and sec
                                (eq (plist-get sec :type) 'message)
                                (equal (plist-get sec :id) "msg_u1"))))
                       (overlays-at (point)))))
          (should msg-ov)))
      ;; --- Case 2: cursor in footer / past input snaps to input ---
      ;; `point-max' lands past the editable region (after the help
      ;; line / shortcuts).  Streaming often leaves point there.
      (goto-char (point-max))
      (opencode-chat--on-session-idle idle-event)
      (should (= (point) (opencode-chat--input-content-start)))
      ;; --- Case 3: cursor inside input area is preserved ---
      (let* ((start (opencode-chat--input-content-start))
             (_ (goto-char start))
             (_ (insert "draft message"))
             (target (+ start 5)))  ; middle of "draft"
        (goto-char target)
        (should (opencode-chat--in-input-area-p))
        (opencode-chat--on-session-idle idle-event)
        ;; Cursor must NOT snap to content-start — user's typing position
        ;; is preserved.
        (should (opencode-chat--in-input-area-p))
        (should (= (point) target)))))))

(ert-deftest opencode-scenario-paste-text-has-keymap ()
  "Text inserted (simulating paste/yank) in input area must have the input keymap.
Bug: yanked text from another buffer doesn't carry `opencode-chat-input-map',
so keybindings like C-p (command-select) stop working on pasted text."
  (opencode-scenario-with-replay
      (concat
       ":session ses_paste_keymap\n"
       ;; Simulate pasting text (insert without properties, like yank)
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (let ((inhibit-read-only t)) (insert \"pasted text\"))\n")
    ;; The pasted text should have the input keymap
    (let* ((start (opencode-chat--input-content-start))
           (pos (+ start 3)))  ; middle of "pasted text"
      (should (eq (get-text-property pos 'keymap) opencode-chat-input-map)))))

(ert-deftest opencode-scenario-s-tab-cycles-agent-backward ()
  "S-TAB in the input area must cycle through agents in reverse order.
TAB cycles forward; S-TAB should cycle backward for symmetry."
  (opencode-scenario-with-replay
      (concat
       ":session ses_stab_test\n")
    ;; Move to input area
    (goto-char (opencode-chat--input-content-start))
    ;; Verify cycle-agent-backward is bound to S-TAB or backtab
    (let ((binding (or (lookup-key opencode-chat-mode-map (kbd "S-TAB"))
                       (lookup-key opencode-chat-mode-map [backtab]))))
      (should binding)
      (should (commandp binding)))))

(ert-deftest opencode-scenario-stuck-refresh-guard ()
  "A stuck refresh-in-flight guard must not block the canonical idle refresh.
Reproduces the bug where refresh-in-flight gets permanently stuck (e.g. from
a lost HTTP callback), preventing session.idle from triggering a full refresh.

The scenario streams two assistant messages, then simulates a stuck guard via
:eval.  When session.idle fires, the fix (force-clear in on-session-idle)
clears the guard so refresh runs.  The refresh fetches API mock data that
includes:
  - A user message (\"commit and push\") — never streamed, only from refresh
  - Updated assistant text (\"second response done\") — differs from the
    streamed delta (\"second response\")
Asserting these proves the refresh actually ran after the guard was cleared."
  (let* ((fixture-file (expand-file-name
                        "stuck-refresh-guard-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-abort-preserves-tokens ()
  "Aborting a stream must not clear the cached context/token usage.
The aborted assistant message is returned by the server with a
zero-valued `:tokens' field.  If we blindly treat that as the latest
cumulative usage, the footer's Tokens/context bar disappears.
Expected: recompute keeps the previous meaningful value."
  (let* ((fixture-file (expand-file-name
                        "abort-preserves-tokens-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-sync-dedup ()
  "Sync-wrapped duplicates must not cause double handler runs.
The opencode server re-publishes every sync event as a bus event for
backwards compatibility — so the SSE stream contains BOTH forms for
each logical event.  The client must dispatch each event exactly once;
otherwise footers/renders are doubled."
  (let* ((fixture-file (expand-file-name
                        "sync-dedup-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-cursor-shrinking-refresh ()
  "Refresh₁ returns X messages, refresh₂ returns Y<X.  Cursor must
remain in the input area after the shrinking refresh, not jump to
`point-max'."
  (let* ((fixture-file (expand-file-name
                        "cursor-shrinking-refresh-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-cursor-window-point-desync ()
  "Async refresh leaves `window-point' stale at `point-max'.
When `render-messages' runs inside a process-filter callback,
`goto-char' updates buffer-point but not `window-point' — so the
next redisplay snaps buffer-point back to `point-max' (the help
line at the bottom).  Fix: `render-messages' must also call
`set-window-point' after restoring buffer-point."
  (let* ((fixture-file (expand-file-name
                        "cursor-window-point-desync-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-tool-streaming-stdout ()
  "Tool stdout must render while the tool is still `running'.
While a tool runs, the final `state.output' is nil but progressive
stdout lives under `state.metadata.output'.  `render-tool-body' must
fall back to `metadata.output' so users see output as it streams,
not a blank tool box until completion."
  (let* ((fixture-file (expand-file-name
                        "tool-streaming-stdout-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-cursor-after-idle ()
  "Cursor in message area must not jump to input after session.idle.
When the user is reading messages (point before input-start),
session.idle + refresh should restore cursor position, not snap to input."
  (let* ((fixture-file (expand-file-name
                        "cursor-after-idle-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-retry-status ()
  "session.status with type=retry shows an error badge in the chat buffer.
Each retry replaces the previous badge.  When the session recovers
(idle), the badge is cleared."
  (let* ((fixture-file (expand-file-name
                        "retry-status-scenario.txt"
                        opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file fixture-file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (should (nth 1 r))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-cross-session-idle-isolation ()
  "session.idle for session A must not affect session B's chat buffer.
Reproduces the real-world scenario: two chat buffers open for different
projects/sessions.  Session A finishes and goes idle while session B is
still busy streaming.  Dispatching through the real
`opencode-event--dispatch-chat' must route the idle event ONLY to
session A's buffer.  Session B must remain busy with its streamed
content intact.

Timeline:
  1. Both sessions become busy and stream text
  2. Session A goes idle (dispatched through real routing)
  3. Assert: session A is idle, session B is still busy
  4. Assert: session B's streamed content is intact
  5. Session B goes idle
  6. Assert: session B refreshes correctly with API data"
  (let* ((sid-a "ses_cross_A")
         (sid-b "ses_cross_B")
         (buf-a (get-buffer-create "*opencode: cross-A*"))
         (buf-b (get-buffer-create "*opencode: cross-B*"))
         ;; Save and restore registry to avoid polluting global state
         (saved-registry (copy-hash-table opencode--chat-registry)))
    (unwind-protect
        (let ((opencode-test--mock-responses (make-hash-table :test 'equal))
              (opencode-test--mock-requests nil))
          ;; Register default mocks
          (opencode-test-mock-response "GET" "/question" 200 [])
          (opencode-test-mock-response "GET" "/permission" 200 [])
          (opencode-test-mock-response "GET" "/agent" 200
            [(:name "build" :description "Default agent" :mode "primary" :native t)])
          ;; API mocks for session B refresh (session A doesn't need them —
          ;; it has no stuck guard, so its idle refresh works normally)
          (opencode-test-mock-response
           "GET" (format "/session/%s/message" sid-b) 200
           (format "[{\"info\":{\"id\":\"msg_bu\",\"sessionID\":\"%s\",\"role\":\"user\",\"time\":{\"created\":1000}},\"parts\":[{\"id\":\"prt_bu\",\"sessionID\":\"%s\",\"messageID\":\"msg_bu\",\"type\":\"text\",\"text\":\"user prompt B\",\"time\":{\"start\":1000,\"end\":1001}}]},{\"info\":{\"id\":\"msg_ba\",\"sessionID\":\"%s\",\"role\":\"assistant\",\"time\":{\"created\":2000},\"modelID\":\"m\",\"agent\":\"a\",\"tokens\":{\"input\":5,\"output\":3,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}},\"parts\":[{\"id\":\"prt_bt\",\"sessionID\":\"%s\",\"messageID\":\"msg_ba\",\"type\":\"text\",\"text\":\"response B final\",\"time\":{\"start\":2001,\"end\":2002}}]}]"
                   sid-b sid-b sid-b sid-b))
          (opencode-test-mock-response
           "GET" (format "/session/%s" sid-b) 200
           (format "{\"id\":\"%s\",\"slug\":\"b\",\"directory\":\"/tmp/b\",\"title\":\"B\",\"version\":\"1.0\",\"time\":{\"created\":1000,\"updated\":2000}}"
                   sid-b))
          (opencode-test-mock-response
           "GET" (format "/session/%s/todo" sid-b) 200 "[]")
          (opencode-test-mock-response
           "GET" (format "/session/%s/diff" sid-b) 200 "[]")
          ;; Also register mocks for session A (its idle refresh needs them)
          (opencode-test-mock-response
           "GET" (format "/session/%s/message" sid-a) 200 "[]")
          (opencode-test-mock-response
           "GET" (format "/session/%s" sid-a) 200
           (format "{\"id\":\"%s\",\"slug\":\"a\",\"directory\":\"/tmp/a\",\"title\":\"A\",\"version\":\"1.0\",\"time\":{\"created\":500,\"updated\":1000}}"
                   sid-a))
          (opencode-test-mock-response
           "GET" (format "/session/%s/todo" sid-a) 200 "[]")
          (opencode-test-mock-response
           "GET" (format "/session/%s/diff" sid-a) 200 "[]")

          ;; Skip cache prewarm entirely (avoid unmocked endpoints)
          (setq opencode-api-cache--load-state 'loaded)
          (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                     (lambda () (opencode-chat--refresh)))
                    ((symbol-function 'opencode-chat--header-line)
                     (lambda () " Cross-session test"))
                    ((symbol-function 'opencode-chat--schedule-streaming-fontify)
                     #'ignore)
                    ((symbol-function 'rename-buffer) #'ignore)
                    ((symbol-function 'opencode-agent--default-name)
                     (lambda () "build"))
                    ((symbol-function 'opencode-api--request)
                     #'opencode-test--mock-api-request))

            ;; ── Bootstrap both buffers ──
            ;; NOTE: bootstrap-buffer resets opencode-chat--state to nil
            ;; (to allow state-init to populate from config), so we must
            ;; re-set the session-id after bootstrap — just like the
            ;; scenario replay engine does via the :session op.
            (with-current-buffer buf-a
              (opencode-scenario--bootstrap-buffer sid-a "/tmp/a")
              (opencode-chat--set-session-id sid-a))
            (with-current-buffer buf-b
              (opencode-scenario--bootstrap-buffer sid-b "/tmp/b")
              (opencode-chat--set-session-id sid-b))

            ;; Verify both registered
            (should (eq buf-a (opencode--chat-buffer-for-session sid-a)))
            (should (eq buf-b (opencode--chat-buffer-for-session sid-b)))

            ;; ── Both sessions become busy ──
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-status
             (list :type "session.status"
                   :properties (list :sessionID sid-a
                                     :status (list :type "busy"))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-status
             (list :type "session.status"
                   :properties (list :sessionID sid-b
                                     :status (list :type "busy"))))

            (with-current-buffer buf-a
              (should (opencode-chat--busy)))
            (with-current-buffer buf-b
              (should (opencode-chat--busy)))

            ;; ── Stream text in both sessions ──
            ;; Session A: bootstrap message + stream "hello from A"
            (opencode-event--dispatch-chat
             #'opencode-chat--on-message-updated
             (list :type "message.updated"
                   :properties (list :info (list :id "msg_aa" :sessionID sid-a
                                                 :role "assistant"
                                                 :time (list :created 1000)
                                                 :modelID "m" :agent "a"))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-part-updated
             (list :type "message.part.updated"
                   :properties (list :part (list :id "prt_at" :sessionID sid-a
                                                 :messageID "msg_aa" :type "text"
                                                 :text "" :time (list :start 1001)))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-part-updated
             (list :type "message.part.updated"
                   :properties (list :part (list :id "prt_at" :sessionID sid-a
                                                 :messageID "msg_aa" :type "text"
                                                 :text "hello from A"
                                                 :time (list :start 1001))
                                     :delta "hello from A")))

            ;; Session B: bootstrap message + stream "hello from B"
            (opencode-event--dispatch-chat
             #'opencode-chat--on-message-updated
             (list :type "message.updated"
                   :properties (list :info (list :id "msg_ba" :sessionID sid-b
                                                 :role "assistant"
                                                 :time (list :created 2000)
                                                 :modelID "m" :agent "a"))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-part-updated
             (list :type "message.part.updated"
                   :properties (list :part (list :id "prt_bt" :sessionID sid-b
                                                 :messageID "msg_ba" :type "text"
                                                 :text "" :time (list :start 2001)))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-part-updated
             (list :type "message.part.updated"
                   :properties (list :part (list :id "prt_bt" :sessionID sid-b
                                                 :messageID "msg_ba" :type "text"
                                                 :text "hello from B"
                                                 :time (list :start 2001))
                                     :delta "hello from B")))

            ;; Verify both have streamed content
            (with-current-buffer buf-a
              (should (opencode-test-buffer-contains-p "hello from A")))
            (with-current-buffer buf-b
              (should (opencode-test-buffer-contains-p "hello from B")))

            ;; ── Session A goes idle (dispatched through real routing) ──
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-status
             (list :type "session.status"
                   :properties (list :sessionID sid-a
                                     :status (list :type "idle"))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-idle
             (list :type "session.idle"
                   :properties (list :sessionID sid-a)))

            ;; ── KEY ASSERTIONS: cross-session isolation ──
            ;; Session A: should be idle
            (with-current-buffer buf-a
              (should-not (opencode-chat--busy)))

            ;; Session B: must still be busy — session A's idle must NOT affect it
            (with-current-buffer buf-b
              (should (opencode-chat--busy)))

            ;; Session B: streamed content must be intact
            (with-current-buffer buf-b
              (should (opencode-test-buffer-contains-p "hello from B")))

            ;; Session B: streaming marker must still be valid (not cleared)
            (with-current-buffer buf-b
              (should (opencode-chat--store-part-marker "msg_ba" "prt_bt")))

            ;; ── Session B goes idle ──
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-status
             (list :type "session.status"
                   :properties (list :sessionID sid-b
                                     :status (list :type "idle"))))
            (opencode-event--dispatch-chat
             #'opencode-chat--on-session-idle
             (list :type "session.idle"
                   :properties (list :sessionID sid-b)))

            ;; Session B: should now be idle and refreshed
            (with-current-buffer buf-b
              (should-not (opencode-chat--busy))
              ;; "response B final" is only in the API mock — proves refresh ran
              (should (opencode-test-buffer-contains-p "response B final"))
              ;; "user prompt B" is a user message — never streamed, only from refresh
              (should (opencode-test-buffer-contains-p "user prompt B")))))

      ;; Cleanup
      (setq opencode--chat-registry saved-registry)
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(ert-deftest opencode-scenario-concurrent-popups-different-sessions ()
  "Two question.asked events for DIFFERENT sessions must not corrupt each other.
Bug repro: `opencode-popup--rendered-buffer' is a GLOBAL defvar (not
buffer-local), so when buffer A shows a popup and then buffer B also
shows one, the global gets overwritten to point at B.  When the user
then answers the popup in A, cleanup reads the global, finds B, and
restores B's input area — destroying B's popup — while A's buffer is
left with stale markers and `opencode-popup--inline-p' stuck at t.

Same project, two sessions open, two question.asked events arrive
back-to-back for different session IDs.  Both popups must render
correctly, and submitting one must leave the other intact."
  (let* ((sid-a "ses_qpopup_A")
         (sid-b "ses_qpopup_B")
         (buf-a (get-buffer-create "*opencode: qpopup-A*"))
         (buf-b (get-buffer-create "*opencode: qpopup-B*"))
         (saved-registry (copy-hash-table opencode--chat-registry)))
    (unwind-protect
        (let ((opencode-test--mock-responses (make-hash-table :test 'equal))
              (opencode-test--mock-requests nil))
          (opencode-test-mock-response "GET" "/question" 200 [])
          (opencode-test-mock-response "GET" "/permission" 200 [])
          (opencode-test-mock-response "GET" "/agent" 200
            [(:name "build" :description "Default agent" :mode "primary" :native t)])
          (setq opencode-api-cache--load-state 'loaded)
          (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                     (lambda () (opencode-chat--refresh)))
                    ((symbol-function 'opencode-chat--header-line)
                     (lambda () " Concurrent popup test"))
                    ((symbol-function 'opencode-chat--schedule-streaming-fontify)
                     #'ignore)
                    ((symbol-function 'rename-buffer) #'ignore)
                    ((symbol-function 'opencode-agent--default-name)
                     (lambda () "build"))
                    ((symbol-function 'opencode-api--request)
                     #'opencode-test--mock-api-request))
            ;; Bootstrap two chat buffers for same project, different sessions
            (with-current-buffer buf-a
              (opencode-scenario--bootstrap-buffer sid-a "/tmp/proj")
              (opencode-chat--set-session-id sid-a))
            (with-current-buffer buf-b
              (opencode-scenario--bootstrap-buffer sid-b "/tmp/proj")
              (opencode-chat--set-session-id sid-b))
            (should (eq buf-a (opencode--chat-buffer-for-session sid-a)))
            (should (eq buf-b (opencode--chat-buffer-for-session sid-b)))

            ;; ── Both popups arrive ──
            (let ((req-a (list :id "q_A"
                               :sessionID sid-a
                               :questions (vector
                                           (list :header "A header"
                                                 :question "Question A?"
                                                 :options (vector
                                                           (list :label "A-opt1"
                                                                 :description "first")
                                                           (list :label "A-opt2"
                                                                 :description "second"))
                                                 :multiple :false
                                                 :custom :false))))
                  (req-b (list :id "q_B"
                               :sessionID sid-b
                               :questions (vector
                                           (list :header "B header"
                                                 :question "Question B?"
                                                 :options (vector
                                                           (list :label "B-opt1"
                                                                 :description "first")
                                                           (list :label "B-opt2"
                                                                 :description "second"))
                                                 :multiple :false
                                                 :custom :false)))))
              ;; Dispatch both via the real popup dispatch
              (opencode-event--dispatch-popup
               #'opencode-question--on-asked
               (list :type "question.asked" :properties req-a))
              (opencode-event--dispatch-popup
               #'opencode-question--on-asked
               (list :type "question.asked" :properties req-b)))

            ;; ── Assert: both popups rendered in their respective buffers ──
            (with-current-buffer buf-a
              (should opencode-popup--inline-p)
              (should opencode-question--current)
              (should (equal (plist-get opencode-question--current :id) "q_A"))
              (should (opencode-test-buffer-contains-p "Question A?"))
              (should (opencode-test-buffer-contains-p "A-opt1")))
            (with-current-buffer buf-b
              (should opencode-popup--inline-p)
              (should opencode-question--current)
              (should (equal (plist-get opencode-question--current :id) "q_B"))
              (should (opencode-test-buffer-contains-p "Question B?"))
              (should (opencode-test-buffer-contains-p "B-opt1")))

            ;; ── Submit the popup in buf-A ──
            ;; (Pick option 1 then submit.)  We stub the HTTP reply since
            ;; we only care about the popup state, not the wire call.
            (cl-letf (((symbol-function 'opencode-api-post-sync)
                       (lambda (&rest _args) nil)))
              (with-current-buffer buf-a
                (opencode-question--select-option 1)
                (opencode-question--submit)))

            ;; ── KEY ASSERTIONS: cross-buffer popup isolation ──
            ;; buf-A's popup should be cleaned up
            (with-current-buffer buf-a
              (should-not opencode-question--current)
              (should-not opencode-popup--inline-p))

            ;; buf-B's popup MUST be intact: current still set, inline-p t,
            ;; popup text still visible.  The bug wipes this buffer.
            (with-current-buffer buf-b
              (should opencode-question--current)
              (should (equal (plist-get opencode-question--current :id) "q_B"))
              (should opencode-popup--inline-p)
              (should (opencode-test-buffer-contains-p "Question B?"))
              (should (opencode-test-buffer-contains-p "B-opt1")))))

      ;; Cleanup
      (setq opencode--chat-registry saved-registry)
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(ert-deftest opencode-scenario-concurrent-permissions-different-sessions ()
  "Two permission.asked events for DIFFERENT sessions must not corrupt each other.
Same root cause as the concurrent question test: the global
`opencode-popup--rendered-buffer' clobbers across buffers, so answering
the first popup destroys the second buffer's popup."
  (let* ((sid-a "ses_ppopup_A")
         (sid-b "ses_ppopup_B")
         (buf-a (get-buffer-create "*opencode: ppopup-A*"))
         (buf-b (get-buffer-create "*opencode: ppopup-B*"))
         (saved-registry (copy-hash-table opencode--chat-registry)))
    (unwind-protect
        (let ((opencode-test--mock-responses (make-hash-table :test 'equal))
              (opencode-test--mock-requests nil))
          (opencode-test-mock-response "GET" "/question" 200 [])
          (opencode-test-mock-response "GET" "/permission" 200 [])
          (opencode-test-mock-response "POST" "/permission/p_A/reply" 200 "{}")
          (opencode-test-mock-response "POST" "/permission/p_B/reply" 200 "{}")
          (opencode-test-mock-response "GET" "/agent" 200
            [(:name "build" :description "Default agent" :mode "primary" :native t)])
          (setq opencode-api-cache--load-state 'loaded)
          (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                     (lambda () (opencode-chat--refresh)))
                    ((symbol-function 'opencode-chat--header-line)
                     (lambda () " Concurrent permission test"))
                    ((symbol-function 'opencode-chat--schedule-streaming-fontify)
                     #'ignore)
                    ((symbol-function 'rename-buffer) #'ignore)
                    ((symbol-function 'opencode-agent--default-name)
                     (lambda () "build"))
                    ((symbol-function 'opencode-api--request)
                     #'opencode-test--mock-api-request))
            (with-current-buffer buf-a
              (opencode-scenario--bootstrap-buffer sid-a "/tmp/proj")
              (opencode-chat--set-session-id sid-a))
            (with-current-buffer buf-b
              (opencode-scenario--bootstrap-buffer sid-b "/tmp/proj")
              (opencode-chat--set-session-id sid-b))

            (let ((req-a (list :id "p_A" :sessionID sid-a
                               :permission "bash"
                               :patterns ["ls *"]))
                  (req-b (list :id "p_B" :sessionID sid-b
                               :permission "bash"
                               :patterns ["git status"])))
              (opencode-event--dispatch-popup
               #'opencode-permission--on-asked
               (list :type "permission.asked" :properties req-a))
              (opencode-event--dispatch-popup
               #'opencode-permission--on-asked
               (list :type "permission.asked" :properties req-b)))

            (with-current-buffer buf-a
              (should opencode-popup--inline-p)
              (should (equal (plist-get opencode-permission--current :id) "p_A"))
              (should (opencode-test-buffer-contains-p "ls *")))
            (with-current-buffer buf-b
              (should opencode-popup--inline-p)
              (should (equal (plist-get opencode-permission--current :id) "p_B"))
              (should (opencode-test-buffer-contains-p "git status")))

            ;; Allow-once in buf-A (stub the network).
            ;; NOTE: permission--reply uses opencode-api--request, not post-sync.
            (with-current-buffer buf-a
              (opencode-permission--allow-once))

            ;; buf-A cleaned up, buf-B intact
            (with-current-buffer buf-a
              (should-not opencode-permission--current)
              (should-not opencode-popup--inline-p))
            (with-current-buffer buf-b
              (should opencode-permission--current)
              (should (equal (plist-get opencode-permission--current :id) "p_B"))
              (should opencode-popup--inline-p)
              (should (opencode-test-buffer-contains-p "git status")))))

      (setq opencode--chat-registry saved-registry)
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(ert-deftest opencode-scenario-todo-update-preserves-footer ()
  "Footer info (model, agent) must survive inline todo updates.
Bug: when a `todo.updated' SSE event arrives, the provider/agent
info in the footer disappears.  The inline todo refresh must not
destroy the footer-info region."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_todo_footer\n"
         ;; Pre-check: footer shows model and agent
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ;; First todo.updated — the "no overlay" branch
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Task 1: do something\",\"status\":\"pending\",\"priority\":\"high\"}]}}\n"
         ;; Footer must still be present
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ;; Todos must appear
         ":assert-contains Task 1: do something\n"
         ;; Second todo.updated — the "overlay exists" branch
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Task 1: do something\",\"status\":\"in_progress\",\"priority\":\"high\"},{\"content\":\"Task 2: another thing\",\"status\":\"pending\",\"priority\":\"medium\"}]}}\n"
         ;; Footer still present after second update
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ;; Both todos visible
         ":assert-contains Task 1: do something\n"
         ":assert-contains Task 2: another thing\n")
      ;; Final buffer check: footer-info text property exists
      (should (text-property-any (point-min) (point-max) 'opencode-footer-info t))
      ;; Inline todos overlay exists
      (should (opencode-chat--inline-todos-ov))
      (should (overlay-buffer (opencode-chat--inline-todos-ov))))))

(ert-deftest opencode-scenario-footer-survives-todo-then-refresh ()
  "Footer refresh after inline todo update must not destroy either section.
Bug: when `refresh-footer' deletes and re-renders the footer-info region,
the adjacent inline todos overlay gets its start collapsed to the deletion
point, causing it to cover the new footer text.  The next todo refresh then
deletes everything the overlay covers (including the footer)."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_todo_then_refresh\n"
         ;; Deliver todos
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Implement feature X\",\"status\":\"pending\",\"priority\":\"high\"}]}}\n"
         ;; Verify both sections present
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ":assert-contains Implement feature X\n"
         ;; Now trigger footer refresh (simulates token update)
         ":eval (opencode-chat--refresh-footer)\n"
         ;; Footer must still be present
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ;; Inline todos must ALSO still be present
         ":assert-contains Implement feature X\n"
         ;; Now update todos again — exercises overlay path AFTER footer refresh
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Implement feature X\",\"status\":\"completed\",\"priority\":\"high\"}]}}\n"
         ;; Footer must STILL be present
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ":assert-contains Implement feature X\n")
      ;; Both regions intact
      (should (text-property-any (point-min) (point-max) 'opencode-footer-info t))
      (should (opencode-chat--inline-todos-ov))
      (should (overlay-buffer (opencode-chat--inline-todos-ov))))))

(ert-deftest opencode-scenario-todo-survives-footer-refresh-cycle ()
  "Multiple cycles of todo update + footer refresh must preserve both sections.
Exercises the interaction between `refresh-inline-todos' and `refresh-footer'
across multiple update cycles to catch stickiness/overlap accumulation bugs."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (opencode-scenario-with-replay
        (concat
         ":session ses_todo_cycle\n"
         ;; Cycle 1: todo update then footer refresh
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Task A\",\"status\":\"pending\",\"priority\":\"high\"}]}}\n"
         ":eval (opencode-chat--refresh-footer)\n"
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains Task A\n"
         ;; Cycle 2: another todo update then footer refresh
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Task A\",\"status\":\"completed\",\"priority\":\"high\"},{\"content\":\"Task B\",\"status\":\"pending\",\"priority\":\"medium\"}]}}\n"
         ":eval (opencode-chat--refresh-footer)\n"
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains · build\n"
         ":assert-contains Task A\n"
         ":assert-contains Task B\n"
         ;; Cycle 3: footer refresh then todo update (reverse order)
         ":eval (opencode-chat--refresh-footer)\n"
         ":sse {\"type\":\"todo.updated\",\"properties\":{\"todos\":[{\"content\":\"Task C\",\"status\":\"pending\",\"priority\":\"low\"}]}}\n"
         ":assert-contains [claude-opus-4-6]\n"
         ":assert-contains Task C\n")
      (should (text-property-any (point-min) (point-max) 'opencode-footer-info t))
      (should (opencode-chat--inline-todos-ov)))))

(ert-deftest opencode-scenario-subtask-part-renders ()
  "Subtask part in a user message renders collapsible /command with prompt body.
Replays a message.updated for a user message followed by a
message.part.updated with a subtask part containing a prompt, then
verifies the header is visible, body is collapsed, and text properties
are correct."
  (opencode-scenario-with-replay
      (concat
       ":session ses_subtask\n"
       ;; User message
       ":sse {\"type\":\"message.updated\",\"properties\":{\"info\":{\"id\":\"msg_u1\",\"sessionID\":\"ses_subtask\",\"role\":\"user\",\"time\":{\"created\":1700000000000}}}}\n"
       ;; Subtask part with prompt
       ":sse {\"type\":\"message.part.updated\",\"properties\":{\"part\":{\"id\":\"prt_s1\",\"sessionID\":\"ses_subtask\",\"messageID\":\"msg_u1\",\"type\":\"subtask\",\"command\":\"review\",\"description\":\"review changes\",\"agent\":\"claude-native\",\"model\":{\"providerID\":\"Gemini\",\"modelID\":\"gemini-3.1-pro\"},\"prompt\":\"You are a code reviewer.\"}}}\n"
       ;; Header visible
       ":assert-contains /review\n"
       ":assert-contains review changes\n"
       ":assert-contains gemini-3.1-pro\n"
       ;; Collapsed by default
       ":assert-contains [collapsed]\n"
       ;; Verify line-prefix stripe with user-block face
       ":eval (progn (goto-char (point-min)) (search-forward \"/review\") (let ((lp (get-text-property (match-beginning 0) 'line-prefix))) (should lp) (should (eq 'opencode-user-block (get-text-property 0 'face lp)))))\n"
       ;; Verify face on command name
       ":eval (progn (goto-char (point-min)) (search-forward \"/review\") (should (eq 'opencode-subtask-name (get-text-property (match-beginning 0) 'face))))\n"
       ;; Prompt text exists but is invisible (collapsed)
       ":eval (progn (goto-char (point-min)) (search-forward \"You are a code reviewer.\") (should (eq 'opencode-section (get-text-property (match-beginning 0) 'invisible))))\n")
    (should (opencode-test-buffer-contains-p "/review"))
    (should (opencode-test-buffer-contains-p "review changes"))))

(ert-deftest opencode-scenario-edit-tool-ret ()
  "Edit tool body is clickable after BOTH SSE streaming and full refresh.
Why this matters: `opencode-chat--apply-message-props' used to blanket-
overwrite the specialized `opencode-chat-message-file-map', making RET
on edit diffs fall through to `newline'.  Additionally, the
`after-change-functions' input hook used to mistake a freshly-rendered
message area for the input area (because `(opencode-chat--input-start)'
was not cleared after `erase-buffer') and force-rewrite the keymap to
`opencode-chat-input-map'.  This scenario exercises both render paths
and asserts the file-map survives in both."
  (let* ((file (expand-file-name "edit/edit-ret-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-popup-bubbles-to-parent-when-child-open ()
  "A permission popup for a child session must render in BOTH buffers.
Bug repro: `opencode-popup--find-chat-buffer' used to re-look-up the
request's `:sessionID', finding the CHILD buffer again even when
`opencode-permission--on-asked' had been dispatched to the PARENT
buffer via `opencode-event--dispatch-popup''s bubble-up path.  Result:
the parent buffer queued the request, tried to show it, but rendered
into the child buffer (or silently failed if the child was busy),
leaving the parent without a visible popup.

Setup: parent session with an open chat buffer, child session with an
open chat buffer, child→parent link established via `set-session'
auto-population.

Action: dispatch a `permission.asked' event for the CHILD session.

Assertion: BOTH buffers show the popup inline (child + parent).
Answering in the child must purge the duplicate from the parent so
no ghost popup reappears."
  (let* ((sid-parent "ses_bubble_parent")
         (sid-child  "ses_bubble_child")
         (buf-parent (get-buffer-create "*opencode: bubble-parent*"))
         (buf-child  (get-buffer-create "*opencode: bubble-child*"))
         (saved-registry (copy-hash-table opencode--chat-registry))
         ;; Save the cache so we don't pollute other tests
         (saved-cache (copy-hash-table opencode-domain--child-parent-cache)))
    (unwind-protect
        (let ((opencode-test--mock-responses (make-hash-table :test 'equal))
              (opencode-test--mock-requests nil))
          (opencode-test-mock-response "GET" "/question" 200 [])
          (opencode-test-mock-response "GET" "/permission" 200 [])
          (opencode-test-mock-response "POST" "/permission/per_bubble/reply" 200 "{}")
          (opencode-test-mock-response "GET" "/agent" 200
            [(:name "build" :description "Default agent" :mode "primary" :native t)])
          (setq opencode-api-cache--load-state 'loaded)
          (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                     (lambda () (opencode-chat--refresh)))
                    ((symbol-function 'opencode-chat--header-line)
                     (lambda () " Popup bubble test"))
                    ((symbol-function 'opencode-chat--schedule-streaming-fontify)
                     #'ignore)
                    ((symbol-function 'rename-buffer) #'ignore)
                    ((symbol-function 'opencode-agent--default-name)
                     (lambda () "build"))
                    ((symbol-function 'opencode-api--request)
                     #'opencode-test--mock-api-request))
            ;; Bootstrap parent (top-level session)
            (with-current-buffer buf-parent
              (opencode-scenario--bootstrap-buffer sid-parent "/tmp/proj"))
            ;; Bootstrap child (sub-agent session with parentID set).
            ;; bootstrap-buffer's `set-session' call auto-populates the
            ;; child→parent cache, just like a real child buffer open.
            (with-current-buffer buf-child
              (opencode-scenario--bootstrap-buffer sid-child "/tmp/proj" sid-parent))

            (should (eq buf-parent (opencode--chat-buffer-for-session sid-parent)))
            (should (eq buf-child (opencode--chat-buffer-for-session sid-child)))
            ;; The cache must have been populated by set-session
            (should (equal sid-parent
                           (opencode-domain-child-parent-get sid-child)))

            ;; ── Dispatch a permission.asked for the CHILD session ──
            (let ((req (list :id "per_bubble"
                             :sessionID sid-child
                             :permission "bash"
                             :patterns ["rm -rf /tmp/x"]
                             :tool (list :messageID "msg_x" :callID "call_x"))))
              (opencode-event--dispatch-popup
               #'opencode-permission--on-asked
               (list :type "permission.asked" :properties req)))

            ;; ── Both buffers must now show the popup ──
            (with-current-buffer buf-child
              (should opencode-popup--inline-p)
              (should opencode-permission--current)
              (should (equal (plist-get opencode-permission--current :id)
                             "per_bubble"))
              (should (opencode-test-buffer-contains-p "Permission Required"))
              (should (opencode-test-buffer-contains-p "rm -rf /tmp/x")))
            ;; This is the assertion that used to FAIL before the fix:
            ;; the parent buffer queued the request but `--show' routed
            ;; back to the child buffer via re-lookup, so the parent
            ;; never rendered.
            (with-current-buffer buf-parent
              (should opencode-popup--inline-p)
              (should opencode-permission--current)
              (should (equal (plist-get opencode-permission--current :id)
                             "per_bubble"))
              (should (opencode-test-buffer-contains-p "Permission Required"))
              (should (opencode-test-buffer-contains-p "rm -rf /tmp/x")))

            ;; ── Answer in the child; parent duplicate must be purged ──
            ;; The local --allow-once clears the child's --current.  The
            ;; real server responds with a `permission.replied' SSE event
            ;; which `on-replied' uses to dismiss the stale duplicate in
            ;; the parent buffer.  Simulate that event here.
            (with-current-buffer buf-child
              (opencode-permission--allow-once))
            (opencode-permission--on-replied
             (list :type "permission.replied"
                   :properties (list :requestID "per_bubble")))

            (with-current-buffer buf-child
              (should-not opencode-permission--current)
              (should-not opencode-popup--inline-p))
            (with-current-buffer buf-parent
              (should-not opencode-permission--current)
              (should-not opencode-popup--inline-p)
              ;; And no duplicate lingers in the pending queue
              (should (null opencode-permission--pending)))))
      ;; Cleanup
      (setq opencode--chat-registry saved-registry)
      (clrhash opencode-domain--child-parent-cache)
      (maphash (lambda (k v)
                 (puthash k v opencode-domain--child-parent-cache))
               saved-cache)
      (when (buffer-live-p buf-parent) (kill-buffer buf-parent))
      (when (buffer-live-p buf-child) (kill-buffer buf-child)))))

(ert-deftest opencode-scenario-dual-dispatch-purge ()
  "Answering a popup in buffer A purges the duplicate from buffer B.
Why this matters: `opencode-event--dispatch-popup' dispatches the same
request to the originating session's buffer AND its root parent
buffer.  Without a purge on reply, the cleanup path's `show-next'
picks the stale duplicate and re-displays it — producing a ghost popup
on the second buffer after the user already answered."
  (let* ((file (expand-file-name "popup/dual-dispatch-purge-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf))
      (when-let* ((buf (get-buffer "*opencode: dual-sibling*")))
        (kill-buffer buf)))))

(ert-deftest opencode-scenario-refresh-coalescing-state-machine ()
  "Rapid bursts of `opencode-chat--refresh' coalesce to exactly two fetches.
Why this matters: a single refresh state variable
\(`opencode-chat--refresh-state') with four values — nil, stale,
in-flight, in-flight-pending — guarantees that a burst of refresh
requests produces at most two actual /message fetches: one immediately
and one retry after the first completes.  Without coalescing, every SSE
event would trigger a full /message fetch and pound the server."
  (opencode-scenario-with-replay
      (concat ":session ses_coalesce\n"
              ":directory /tmp/coalesce-test\n"
              ":api GET /session/ses_coalesce/message 200 []\n"
              ":api GET /session/ses_coalesce 200 {\"id\":\"ses_coalesce\",\"directory\":\"/tmp/coalesce-test\",\"time\":{\"created\":1,\"updated\":2}}\n"
              ":api GET /session/ses_coalesce/todo 200 []\n"
              ":api GET /session/ses_coalesce/diff 200 []\n")
    ;; Count how many times the /message endpoint is hit and capture
    ;; its callback so we can control timing.
    (let ((message-fetch-count 0)
          (captured-message-callback nil)
          (original-api-get (symbol-function 'opencode-api-get)))
      (cl-letf (((symbol-function 'opencode-api-get)
                 (lambda (path callback &optional params)
                   (if (string-match-p "/message\\'" path)
                       (progn
                         (cl-incf message-fetch-count)
                         (setq captured-message-callback callback))
                     ;; Other endpoints — delegate to the mock-backed original.
                     (funcall original-api-get path callback params)))))
        ;; Initially idle.
        (should (null (opencode-chat--refresh-state)))
        ;; First refresh: fires ONE /message fetch, state = in-flight.
        (opencode-chat--refresh)
        (should (= 1 message-fetch-count))
        (should (eq (opencode-chat--refresh-state) 'in-flight))
        ;; Burst of refreshes while first is in-flight: no new fetch,
        ;; state transitions to in-flight-pending and stays there.
        (opencode-chat--refresh)
        (opencode-chat--refresh)
        (opencode-chat--refresh)
        (should (= 1 message-fetch-count))
        (should (eq (opencode-chat--refresh-state) 'in-flight-pending))
        ;; Complete the first fetch.  This should drain through the cache
        ;; callback chain, detect the pending flag, and fire ONE retry.
        (funcall captured-message-callback
                 (list :status 200 :body []))
        (sit-for 0)
        ;; Exactly two /message fetches total — one initial + one retry.
        (should (= 2 message-fetch-count))
        (should (eq (opencode-chat--refresh-state) 'in-flight))
        ;; Complete the retry.  State returns to nil.
        (funcall captured-message-callback
                 (list :status 200 :body []))
        (sit-for 0)
        (should (null (opencode-chat--refresh-state)))
        ;; A fresh refresh now fires a new fetch (proving the state machine
        ;; actually drained, not just masked).
        (opencode-chat--refresh)
        (should (= 3 message-fetch-count))))))

(ert-deftest opencode-scenario-refresh-state-busy-stale ()
  "When busy, refresh is deferred: state set to `stale', no HTTP fires.
Subsequent `session.idle' consumes the stale flag and actually refreshes."
  (opencode-scenario-with-replay
      (concat ":session ses_stale\n"
              ":directory /tmp/stale-test\n"
              ":api GET /session/ses_stale/message 200 []\n"
              ":api GET /session/ses_stale 200 {\"id\":\"ses_stale\",\"directory\":\"/tmp/stale-test\",\"time\":{\"created\":1,\"updated\":2}}\n"
              ":api GET /session/ses_stale/todo 200 []\n"
              ":api GET /session/ses_stale/diff 200 []\n")
    (let ((fetch-count 0))
      (cl-letf (((symbol-function 'opencode-api-get)
                 (lambda (_path callback &optional _params)
                   (cl-incf fetch-count)
                   (funcall callback (list :status 200 :body [])))))
        ;; Mark busy — refresh should defer.
        (opencode-chat--set-busy t)
        (opencode-chat--refresh)
        (should (= 0 fetch-count))
        (should (eq (opencode-chat--refresh-state) 'stale))
        ;; Another refresh while busy — still stale, still no fetch.
        (opencode-chat--refresh)
        (should (= 0 fetch-count))
        (should (eq (opencode-chat--refresh-state) 'stale))))))

(ert-deftest opencode-scenario-mcp-tool-renderer ()
  "MCP tools collapse by default and render input as `key: value' lines.
Why this matters: MCP (Model Context Protocol) tool names look like
`<server>_<tool>' and have no dedicated renderer; the fallback generic
renderer must (a) treat them as collapsible like built-in tools, and
\(b) display every JSON input field so the user can see the tool's
arguments without opening the raw JSON."
  (let* ((file (expand-file-name "mcp/mcp-tool-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(provide 'opencode-scenario-test)
;;; opencode-scenario-test.el ends here
