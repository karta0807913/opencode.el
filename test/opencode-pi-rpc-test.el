;;; opencode-pi-rpc-test.el --- Tests for opencode-pi-rpc.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the Pi RPC stdio transport.  No real `pi' binary is needed:
;; `make-process' is stubbed to capture the process filter and record stdin
;; writes, then the filter is driven directly with canned JSONL bytes.

;;; Code:

(require 'test-helper nil t)
(require 'cl-lib)
(require 'opencode-pi-rpc)

;;; --- Fake process harness ---

(defvar opencode-pi-rpc-test--sent nil
  "List of strings written to the fake subprocess stdin, oldest first.")

(defvar opencode-pi-rpc-test--filter nil
  "Captured process filter for the fake subprocess.")

(defvar opencode-pi-rpc-test--sentinel nil
  "Captured process sentinel for the fake subprocess.")

(defmacro opencode-pi-rpc-test--with-conn (conn-var &rest body)
  "Start a Pi RPC connection bound to CONN-VAR with a fake subprocess.
`make-process' is stubbed so no real `pi' is launched.  Stdin writes are
captured in `opencode-pi-rpc-test--sent'; the filter/sentinel are captured
so tests can feed bytes and simulate exit.  Cleans up CONN-VAR after BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((opencode-pi-rpc-test--sent nil)
         (opencode-pi-rpc-test--filter nil)
         (opencode-pi-rpc-test--sentinel nil))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest args)
                  (setq opencode-pi-rpc-test--filter (plist-get args :filter))
                  (setq opencode-pi-rpc-test--sentinel (plist-get args :sentinel))
                  ;; Return a marker object; the transport only calls
                  ;; `process-live-p' and `process-send-string' on it, both
                  ;; stubbed below.
                  'fake-pi-process))
               ((symbol-function 'process-live-p)
                (lambda (proc) (eq proc 'fake-pi-process)))
               ((symbol-function 'process-send-string)
                (lambda (_proc str) (push str opencode-pi-rpc-test--sent)))
               ((symbol-function 'delete-process) (lambda (&rest _) nil)))
       (let ((,conn-var (opencode-pi-rpc-start default-directory)))
         (unwind-protect
             (progn ,@body)
           (when (opencode-pi-conn-work-buffer ,conn-var)
             (when (buffer-live-p (opencode-pi-conn-work-buffer ,conn-var))
               (kill-buffer (opencode-pi-conn-work-buffer ,conn-var)))))))))

(defun opencode-pi-rpc-test--feed (conn &rest chunks)
  "Feed CHUNKS (raw strings) to CONN's captured filter in order."
  (dolist (chunk chunks)
    (funcall opencode-pi-rpc-test--filter (opencode-pi-conn-process conn) chunk)))

(defun opencode-pi-rpc-test--last-sent ()
  "Return the most recent stdin write as a parsed plist (sans trailing LF)."
  (opencode--json-parse (string-trim (car opencode-pi-rpc-test--sent))))

;;; --- Framing ---

(ert-deftest opencode-pi-rpc-frames-complete-line ()
  "A complete JSONL event line dispatches one parsed event.
Baseline framing: without it, no Pi event ever reaches the chat buffer."
  (opencode-pi-rpc-test--with-conn conn
    (let (events)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev) (push ev events)))
      (opencode-pi-rpc-test--feed conn "{\"type\":\"agent_start\"}\n")
      (should (= 1 (length events)))
      (should (equal "agent_start" (plist-get (car events) :type))))))

(ert-deftest opencode-pi-rpc-frames-partial-chunks ()
  "A JSON record split across filter calls is reassembled.
CRITICAL: pipe delivery splits records mid-line; the buffer must rejoin."
  (opencode-pi-rpc-test--with-conn conn
    (let (events)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev) (push ev events)))
      (opencode-pi-rpc-test--feed conn "{\"type\":\"age")
      (should (null events))
      (opencode-pi-rpc-test--feed conn "nt_end\",\"messages\":[]}\n")
      (should (= 1 (length events)))
      (should (equal "agent_end" (plist-get (car events) :type))))))

(ert-deftest opencode-pi-rpc-frames-multiple-records-one-chunk ()
  "Two records in a single chunk dispatch in order.
Guards against only handling the first line of a batched write."
  (opencode-pi-rpc-test--with-conn conn
    (let (events)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev) (push (plist-get ev :type) events)))
      (opencode-pi-rpc-test--feed
       conn "{\"type\":\"agent_start\"}\n{\"type\":\"turn_start\"}\n")
      (should (equal '("agent_start" "turn_start") (nreverse events))))))

(ert-deftest opencode-pi-rpc-frames-strips-cr ()
  "A trailing CR before LF is stripped (CRLF tolerance).
Pi's framing spec strips \\r; otherwise JSON.parse sees a stray byte."
  (opencode-pi-rpc-test--with-conn conn
    (let (events)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev) (push ev events)))
      (opencode-pi-rpc-test--feed conn "{\"type\":\"agent_start\"}\r\n")
      (should (= 1 (length events)))
      (should (equal "agent_start" (plist-get (car events) :type))))))

;;; --- Request / response correlation ---

(ert-deftest opencode-pi-rpc-send-attaches-id ()
  "`opencode-pi-rpc-send' attaches an `id' to the outgoing command.
Pi correlates responses by `id'; a missing id breaks sync requests."
  (opencode-pi-rpc-test--with-conn conn
    (let ((id (opencode-pi-rpc-send conn (list :type "get_state"))))
      (should (stringp id))
      (let ((sent (opencode-pi-rpc-test--last-sent)))
        (should (equal "get_state" (plist-get sent :type)))
        (should (equal id (plist-get sent :id)))))))

(ert-deftest opencode-pi-rpc-response-resolves-callback ()
  "A response with a matching `id' resolves the pending callback exactly once.
Without id correlation, command results never reach their caller."
  (opencode-pi-rpc-test--with-conn conn
    (let (result (calls 0))
      (let ((id (opencode-pi-rpc-send
                 conn (list :type "get_state")
                 (lambda (resp) (cl-incf calls) (setq result resp)))))
        (opencode-pi-rpc-test--feed
         conn (format "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"id\":\"%s\",\"data\":{\"sessionId\":\"abc\"}}\n" id))
        (should (= 1 calls))
        (should (eq t (plist-get result :success)))
        (should (equal "abc" (plist-get (plist-get result :data) :sessionId)))
        ;; A duplicate response with the same id must not fire again.
        (opencode-pi-rpc-test--feed
         conn (format "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"id\":\"%s\"}\n" id))
        (should (= 1 calls))))))

(ert-deftest opencode-pi-rpc-event-not-treated-as-response ()
  "Events (no `id') go to the event handler, never the response path.
Misrouting events as responses would silently drop streaming output."
  (opencode-pi-rpc-test--with-conn conn
    (let (events responses)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev) (push ev events)))
      (opencode-pi-rpc-send conn (list :type "get_state")
                            (lambda (resp) (push resp responses)))
      (opencode-pi-rpc-test--feed conn "{\"type\":\"message_start\",\"message\":{}}\n")
      (should (= 1 (length events)))
      (should (null responses)))))

;;; --- Extension UI routing ---

(ert-deftest opencode-pi-rpc-routes-ui-request ()
  "`extension_ui_request' lines go to the UI handler, not the event handler.
This is the bridge that surfaces Pi permission/question popups."
  (opencode-pi-rpc-test--with-conn conn
    (let (ui events)
      (setf (opencode-pi-conn-ui-handler conn) (lambda (req) (push req ui)))
      (setf (opencode-pi-conn-event-handler conn) (lambda (ev) (push ev events)))
      (opencode-pi-rpc-test--feed
       conn "{\"type\":\"extension_ui_request\",\"id\":\"u1\",\"method\":\"confirm\",\"title\":\"OK?\",\"message\":\"do it\"}\n")
      (should (= 1 (length ui)))
      (should (null events))
      (should (equal "confirm" (plist-get (car ui) :method))))))

(ert-deftest opencode-pi-rpc-ui-reply-confirm-shape ()
  "`opencode-pi-rpc-ui-reply-confirm' writes a confirmed extension_ui_response.
Pi expects {type:extension_ui_response,id,confirmed}; wrong shape = stuck UI."
  (opencode-pi-rpc-test--with-conn conn
    (opencode-pi-rpc-ui-reply-confirm conn "u1" t)
    (let ((sent (opencode-pi-rpc-test--last-sent)))
      (should (equal "extension_ui_response" (plist-get sent :type)))
      (should (equal "u1" (plist-get sent :id)))
      (should (eq t (plist-get sent :confirmed))))))

(ert-deftest opencode-pi-rpc-ui-reply-cancel-shape ()
  "`opencode-pi-rpc-ui-reply-cancel' writes a cancelled extension_ui_response.
Killing a popup must dismiss the agent-side dialog, not leave it hanging."
  (opencode-pi-rpc-test--with-conn conn
    (opencode-pi-rpc-ui-reply-cancel conn "u9")
    (let ((sent (opencode-pi-rpc-test--last-sent)))
      (should (equal "extension_ui_response" (plist-get sent :type)))
      (should (equal "u9" (plist-get sent :id)))
      (should (eq t (plist-get sent :cancelled))))))

;;; --- Reentrancy ---

(ert-deftest opencode-pi-rpc-survives-stop-during-dispatch ()
  "A handler may stop the connection mid-dispatch without an out-of-range error.
Popup answers can abort the process from inside an event handler; holding
work-buffer positions across dispatch would signal `Args out of range'
\(the bug fixed in `opencode-sse--filter')."
  (opencode-pi-rpc-test--with-conn conn
    (let (seen)
      (setf (opencode-pi-conn-event-handler conn)
            (lambda (ev)
              (push (plist-get ev :type) seen)
              ;; Reset the connection from inside the handler.
              (opencode-pi-rpc--cleanup conn)))
      ;; Two records in one chunk: the first handler kills the work buffer,
      ;; the second must still dispatch without error.
      (opencode-pi-rpc-test--feed
       conn "{\"type\":\"agent_start\"}\n{\"type\":\"agent_end\",\"messages\":[]}\n")
      (should (member "agent_start" seen))
      (should (member "agent_end" seen)))))

;;; --- Sentinel ---

(ert-deftest opencode-pi-rpc-sentinel-fails-pending ()
  "Process exit fails all pending requests and runs the exit handler.
A dropped subprocess must unblock waiting callers, not hang sync requests."
  (opencode-pi-rpc-test--with-conn conn
    (let (resp (exited nil))
      (setf (opencode-pi-conn-exit-handler conn) (lambda () (setq exited t)))
      (opencode-pi-rpc-send conn (list :type "get_state")
                            (lambda (r) (setq resp r)))
      ;; Simulate process death.
      (funcall opencode-pi-rpc-test--sentinel (opencode-pi-conn-process conn) "killed\n")
      (should exited)
      (should resp)
      (should (eq :false (plist-get resp :success)))
      (should-not (opencode-pi-rpc-alive-p conn)))))

(ert-deftest opencode-pi-rpc-send-after-stop-errors ()
  "Sending on a dead connection signals a user-visible error.
Prevents silent no-ops that look like a hung agent."
  (opencode-pi-rpc-test--with-conn conn
    (opencode-pi-rpc--cleanup conn)
    (should-error (opencode-pi-rpc-send conn (list :type "get_state")))))

;;; --- Sync request ---

(ert-deftest opencode-pi-rpc-request-sync-returns-response ()
  "`opencode-pi-rpc-request-sync' blocks until the matching response arrives.
Used by sync facade slots (get_state, get_messages); must return real data."
  (opencode-pi-rpc-test--with-conn conn
    ;; Arrange: when a command is sent, immediately feed its response.  The
    ;; blocking loop calls `accept-process-output' on the fake process symbol,
    ;; which would error; stub it to a no-op so the loop just re-checks `done'.
    (cl-letf* ((orig (symbol-function 'process-send-string))
               ((symbol-function 'accept-process-output)
                (lambda (&rest _) nil))
               ((symbol-function 'process-send-string)
                (lambda (proc str)
                  (funcall orig proc str)
                  (let ((id (plist-get (opencode--json-parse (string-trim str)) :id)))
                    (opencode-pi-rpc-test--feed
                     conn (format "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"id\":\"%s\",\"data\":{\"ok\":true}}\n" id))))))
      (let ((resp (opencode-pi-rpc-request-sync conn (list :type "get_state") 2)))
        (should (eq t (plist-get resp :success)))
        (should (eq t (plist-get (plist-get resp :data) :ok)))))))

(provide 'opencode-pi-rpc-test)
;;; opencode-pi-rpc-test.el ends here
