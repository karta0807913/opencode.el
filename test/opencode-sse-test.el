;;; opencode-sse-test.el --- Tests for opencode-sse.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the SSE event stream consumer.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-sse)

;;; --- Line parsing: event: ---

(ert-deftest opencode-sse-parse-event-type ()
  "Verify event: line with space after colon extracts the event type.
SSE protocol compliance — wrong parsing breaks event routing."
  (let ((opencode-sse--current-event nil))
    (opencode-sse--process-line "event: server.connected")
    (should (string= (plist-get opencode-sse--current-event :event-type)
                      "server.connected"))))

(ert-deftest opencode-sse-parse-event-type-no-space ()
  "Verify event: line WITHOUT space after colon still extracts type.
SSE spec allows optional space — must handle both forms."
  (let ((opencode-sse--current-event nil))
    (opencode-sse--process-line "event:session.updated")
    (should (string= (plist-get opencode-sse--current-event :event-type)
                      "session.updated"))))

;;; --- Line parsing: data: ---

(ert-deftest opencode-sse-parse-data-line ()
  "Verify data: line stores its content in the current event.
SSE protocol — data extraction is fundamental to receiving payloads."
  (let ((opencode-sse--current-event nil))
    (opencode-sse--process-line "data: {\"type\":\"test\"}")
    (should (string= (plist-get opencode-sse--current-event :data)
                      "{\"type\":\"test\"}"))))

(ert-deftest opencode-sse-parse-multi-data-lines ()
  "Verify multiple data: lines concatenate with newlines.
SSE spec requires multi-line data support — large JSON spans multiple lines."
  (let ((opencode-sse--current-event nil))
    (opencode-sse--process-line "data: {\"line1\":")
    (opencode-sse--process-line "data: \"value\"}")
    (should (string= (plist-get opencode-sse--current-event :data)
                      "{\"line1\":\n\"value\"}"))))

;;; --- Line parsing: id: ---

(ert-deftest opencode-sse-parse-id-line ()
  "Verify id: line sets event ID and updates last-event-id.
SSE reconnect protocol — server uses Last-Event-ID header to resume."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-id nil))
    (opencode-sse--process-line "id: evt_123")
    (should (string= (plist-get opencode-sse--current-event :id) "evt_123"))
    (should (string= opencode-sse--last-event-id "evt_123"))))

;;; --- Line parsing: comments ---

(ert-deftest opencode-sse-parse-comment-ignored ()
  "Verify comment lines (starting with :) are ignored.
SSE protocol — server sends keep-alive comments that must not pollute data."
  (let ((opencode-sse--current-event nil))
    (opencode-sse--process-line ": this is a comment")
    (should (null opencode-sse--current-event))))

;;; --- Event dispatch on empty line ---

(ert-deftest opencode-sse-dispatch-on-empty-line ()
  "Verify empty line dispatches accumulated event and clears state.
SSE protocol — empty line is the event boundary that triggers dispatch."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event))
              nil t)
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: server.heartbeat")
          (opencode-sse--process-line "data: {\"type\":\"server.heartbeat\",\"properties\":{}}")
          (opencode-sse--process-line "")
          (should dispatched)
          (should (string= (plist-get dispatched :type) "server.heartbeat"))
          ;; Current event should be cleared after dispatch
          (should (null opencode-sse--current-event)))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))
                   t))))

(ert-deftest opencode-sse-sync-envelope-is-skipped ()
  "Sync-wrapped events must not dispatch — server re-publishes every
sync event as a bus event (see `packages/opencode/src/sync/README.md'),
so processing both would double every handler run."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (fire-count 0))
    (let ((listener (lambda (_event) (cl-incf fire-count))))
      (add-hook 'opencode-sse-message-updated-hook listener)
      (unwind-protect
          (progn
            ;; Flat bus event — should fire the hook
            (opencode-sse--dispatch-event
             "message"
             "{\"payload\":{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"s1\",\"info\":{\"id\":\"m1\",\"role\":\"assistant\"}}}}")
            ;; Sync-wrapped duplicate — must be skipped
            (opencode-sse--dispatch-event
             "message"
             "{\"payload\":{\"type\":\"sync\",\"syncEvent\":{\"type\":\"message.updated.1\",\"id\":\"evt_1\",\"seq\":0,\"aggregateID\":\"s1\",\"data\":{\"sessionID\":\"s1\",\"info\":{\"id\":\"m1\",\"role\":\"assistant\"}}}}}")
            (should (= fire-count 1)))
        (remove-hook 'opencode-sse-message-updated-hook listener)))))

(ert-deftest opencode-sse-no-dispatch-without-data ()
  "Verify empty line with no accumulated data does not dispatch.
No spurious events — consecutive blank lines must not fire empty dispatches."
  (let ((opencode-sse--current-event nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (_event) (setq dispatched t)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "")
          (should-not dispatched))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (_event) (setq dispatched t))))))

;;; --- Hook dispatch by type ---

(ert-deftest opencode-sse-hook-for-type-mapping ()
  "Verify hook lookup returns correct hook for all 12+ event types.
Hook routing correctness — wrong mapping sends events to wrong handlers."
  (should (eq (opencode-sse--hook-for-type "server.connected")
              'opencode-sse-server-connected-hook))
  (should (eq (opencode-sse--hook-for-type "server.heartbeat")
              'opencode-sse-server-heartbeat-hook))
  (should (eq (opencode-sse--hook-for-type "session.updated")
              'opencode-sse-session-updated-hook))
  (should (eq (opencode-sse--hook-for-type "message.updated")
              'opencode-sse-message-updated-hook))
  (should (eq (opencode-sse--hook-for-type "message.part.updated")
              'opencode-sse-message-part-updated-hook))
  (should (eq (opencode-sse--hook-for-type "message.part.removed")
              'opencode-sse-message-part-removed-hook))
  (should (eq (opencode-sse--hook-for-type "message.removed")
              'opencode-sse-message-removed-hook))
  (should (eq (opencode-sse--hook-for-type "question.asked")
              'opencode-sse-question-asked-hook))
  (should (eq (opencode-sse--hook-for-type "permission.asked")
              'opencode-sse-permission-asked-hook))
   (should (eq (opencode-sse--hook-for-type "global.disposed")
               'opencode-sse-global-disposed-hook))
   (should (eq (opencode-sse--hook-for-type "server.instance.disposed")
               'opencode-sse-server-instance-disposed-hook))
   (should (null (opencode-sse--hook-for-type "unknown.event"))))

;;; --- Type-specific hook dispatch ---

(ert-deftest opencode-sse-dispatches-to-specific-hook ()
  "Verify end-to-end: SSE text parses and dispatches to type-specific hook.
Integration — validates the full parse→dispatch→hook pipeline works."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-message-part-updated-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: message.part.updated")
          (opencode-sse--process-line
           (concat "data: {\"type\":\"message.part.updated\","
                   "\"properties\":{\"sessionID\":\"ses_abc\","
                   "\"messageID\":\"msg_1\","
                   "\"part\":{\"id\":\"p1\",\"type\":\"text\",\"text\":\"hello\"}}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "message.part.updated"))
          (let ((props (plist-get received :properties)))
            (should (string= (plist-get props :sessionID) "ses_abc"))))
      (remove-hook 'opencode-sse-message-part-updated-hook
                   (lambda (event) (setq received event))))))

;;; --- Process filter: partial data ---

(ert-deftest opencode-sse-filter-handles-complete-chunk ()
  "Verify filter processes a complete SSE event arriving in one chunk.
Normal case — full event in single TCP packet must dispatch correctly."
  (let ((opencode-sse--buffer "")
        (opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event)))
    (unwind-protect
        (progn
          (opencode-sse--filter
           nil
           "event: server.heartbeat\ndata: {\"type\":\"server.heartbeat\",\"properties\":{}}\n\n")
          (should dispatched))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))))))

(ert-deftest opencode-sse-filter-handles-partial-chunks ()
  "Verify filter buffers incomplete data across multiple calls.
CRITICAL: Chunked TCP delivery splits events mid-line — must reassemble."
  (let ((opencode-sse--buffer "")
        (opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event)))
    (unwind-protect
        (progn
          ;; First chunk: incomplete
          (opencode-sse--filter nil "event: server.hea")
          (should-not dispatched)
          ;; Second chunk: completes event line + data + dispatch
          (opencode-sse--filter
           nil
           "rtbeat\ndata: {\"type\":\"server.heartbeat\",\"properties\":{}}\n\n")
          (should dispatched))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))))))

;;; --- Reconnect logic ---

(ert-deftest opencode-sse-reconnect-delay-doubles ()
  "Verify reconnect delay doubles with each attempt.
Exponential backoff — avoids hammering a down server with rapid retries."
  (let ((opencode-sse--reconnect-delay 1)
        (opencode-sse-max-reconnect-delay 30)
        (opencode-sse--reconnect-timer nil)
        (opencode-sse--url "http://test/event")
        (opencode-sse-auto-reconnect t))
    ;; Simulate scheduling (cancel any timers immediately)
    (opencode-sse--schedule-reconnect)
    (should (= opencode-sse--reconnect-delay 2))
    (when opencode-sse--reconnect-timer
      (cancel-timer opencode-sse--reconnect-timer))
    (opencode-sse--schedule-reconnect)
    (should (= opencode-sse--reconnect-delay 4))
    (when opencode-sse--reconnect-timer
      (cancel-timer opencode-sse--reconnect-timer))
    (setq opencode-sse--reconnect-timer nil)))

(ert-deftest opencode-sse-reconnect-delay-caps ()
  "Verify reconnect delay caps at max value.
Backoff ceiling — prevents infinite delay that would block reconnection."
  (let ((opencode-sse--reconnect-delay 16)
        (opencode-sse-max-reconnect-delay 30)
        (opencode-sse--reconnect-timer nil)
        (opencode-sse--url "http://test/event")
        (opencode-sse-auto-reconnect t))
    (opencode-sse--schedule-reconnect)
    (should (= opencode-sse--reconnect-delay 30))
    (when opencode-sse--reconnect-timer
      (cancel-timer opencode-sse--reconnect-timer))
    (opencode-sse--schedule-reconnect)
    (should (= opencode-sse--reconnect-delay 30))
    (when opencode-sse--reconnect-timer
      (cancel-timer opencode-sse--reconnect-timer))
    (setq opencode-sse--reconnect-timer nil)))

(ert-deftest opencode-sse-reconnect-delay-resets-on-event ()
  "Verify reconnect delay resets to 1 after successful event.
Recovery — after reconnect succeeds, delay must reset for next failure."
  (let ((opencode-sse--reconnect-delay 16)
        (opencode-sse--last-event-time nil))
    (opencode-sse--dispatch-event
     "server.heartbeat"
     "{\"type\":\"server.heartbeat\",\"properties\":{}}")
    (should (= opencode-sse--reconnect-delay 1))))

;;; --- State management ---

;;; --- Connected predicate ---

(ert-deftest opencode-sse--connected-p-false-when-no-process ()
  "Verify connected-p returns nil when no process exists.
Connection check used throughout — wrong result breaks reconnect logic."
  (let ((opencode-sse--process nil))
    (should-not (opencode-sse--connected-p))))

;;; --- Full event parsing flow ---

(ert-deftest opencode-sse-full-event-flow ()
  "Verify full flow: 2 events parsed and dispatched in order.
Integration test — validates complete SSE pipeline with multiple events."
  (let ((opencode-sse--buffer "")
        (opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received-events nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (push event received-events)))
    (unwind-protect
        (progn
          ;; Feed a complete SSE block
          (opencode-sse--filter
           nil
           (concat
            "event: message.part.updated\n"
            "data: {\"type\":\"message.part.updated\","
            "\"properties\":{\"sessionID\":\"ses_1\","
            "\"messageID\":\"msg_2\","
            "\"part\":{\"id\":\"p3\",\"type\":\"text\",\"text\":\"Hi\"}}}\n"
            "\n"
            "event: server.heartbeat\n"
            "data: {\"type\":\"server.heartbeat\",\"properties\":{}}\n"
            "\n"))
          ;; Should have received 2 events
          (should (length= received-events 2))
          ;; First dispatched (most recent in list) is heartbeat
          (should (string= (plist-get (car received-events) :type)
                            "server.heartbeat"))
          ;; Second is message.part.updated
          (should (string= (plist-get (cadr received-events) :type)
                            "message.part.updated")))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (push event received-events))))))

;;; --- session.status and session.idle hook mapping ---

(ert-deftest opencode-sse-hook-for-session-status ()
  "Verify hook lookup returns correct hook for session.status.
Routing correctness — session.status drives busy/idle UI state."
  (should (eq (opencode-sse--hook-for-type "session.status")
              'opencode-sse-session-status-hook)))

(ert-deftest opencode-sse-hook-for-session-idle ()
  "Verify hook lookup returns correct hook for session.idle.
Routing correctness — session.idle triggers refresh and clears spinner."
  (should (eq (opencode-sse--hook-for-type "session.idle")
              'opencode-sse-session-idle-hook)))

(ert-deftest opencode-sse-dispatches-session-status ()
  "Verify session.status events dispatch with correct properties.
Busy/idle status tracking — drives UI spinner, wrong data breaks UX."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-session-status-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: session.status")
          (opencode-sse--process-line
           (concat "data: {\"type\":\"session.status\","
                   "\"properties\":{\"sessionID\":\"ses_abc\","
                   "\"status\":{\"type\":\"busy\"}}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "session.status"))
          (let ((props (plist-get received :properties)))
            (should (string= (plist-get props :sessionID) "ses_abc"))
            (let ((status (plist-get props :status)))
              (should (string= (plist-get status :type) "busy")))))
      (remove-hook 'opencode-sse-session-status-hook
                   (lambda (event) (setq received event))))))

(ert-deftest opencode-sse-dispatches-session-idle ()
  "Verify session.idle events dispatch to the session-idle hook.
Idle detection — triggers chat refresh and clears busy indicator."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-session-idle-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: session.idle")
          (opencode-sse--process-line
           (concat "data: {\"type\":\"session.idle\","
                   "\"properties\":{\"sessionID\":\"ses_xyz\"}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "session.idle"))
          (let ((props (plist-get received :properties)))
            (should (string= (plist-get props :sessionID) "ses_xyz"))))
      (remove-hook 'opencode-sse-session-idle-hook
                   (lambda (event) (setq received event))))))

;;; --- Global event format dispatch ---

(ert-deftest opencode-sse-dispatches-global-event-format ()
  "Verify global format (directory+payload wrapper) unwraps correctly.
CRITICAL: Global SSE wraps events in {directory, payload} — must unwrap."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-session-idle-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: message")
          (opencode-sse--process-line
           (concat "data: {\"directory\":\"/home/user/project\","
                   "\"payload\":{\"type\":\"session.idle\","
                   "\"properties\":{\"sessionID\":\"ses_global\"}}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "session.idle"))
          (should (string= (plist-get received :directory)
                            "/home/user/project"))
          (let ((props (plist-get received :properties)))
            (should (string= (plist-get props :sessionID) "ses_global"))))
      (remove-hook 'opencode-sse-session-idle-hook
                   (lambda (event) (setq received event))))))

;;; --- session.diff hook mapping ---

(ert-deftest opencode-sse-hook-for-session-diff ()
  "Verify hook lookup returns correct hook for session.diff.
Routing correctness — session.diff displays file changes in chat."
  (should (eq (opencode-sse--hook-for-type "session.diff")
              'opencode-sse-session-diff-hook)))

(ert-deftest opencode-sse-dispatches-session-diff ()
  "Verify session.diff events dispatch to the session-diff hook.
Diff display — file changes must reach the diff handler to show in UI."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-session-diff-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: session.diff")
          (opencode-sse--process-line
           (concat "data: {\"type\":\"session.diff\","
                   "\"properties\":{\"sessionID\":\"ses_diff\","
                   "\"diff\":[]}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "session.diff"))
          (let ((props (plist-get received :properties)))
            (should (string= (plist-get props :sessionID) "ses_diff"))))
      (remove-hook 'opencode-sse-session-diff-hook
                   (lambda (event) (setq received event))))))

;;; --- Curl transport tests ---

(ert-deftest opencode-sse-curl-path-finds-curl ()
  "Verify curl binary can be found on the system.
Transport prerequisite — no curl means SSE cannot function at all."
  (let ((opencode-sse--curl-path-cache nil))
    (let ((curl-path (opencode-sse--curl-path)))
      (should (stringp curl-path))
      (should (not (string-empty-p curl-path))))))

(ert-deftest opencode-sse-disconnect-cleans-state ()
  "Verify disconnect resets all state and kills response buffer.
Clean teardown — leaked processes/buffers waste resources and break reconnect."
  (let ((temp-buf (generate-new-buffer " *test-sse*")))
    (unwind-protect
        (let ((opencode-sse--response-buffer temp-buf)
              (opencode-sse--process nil)
              (opencode-sse--heartbeat-timer nil)
              (opencode-sse--reconnect-timer nil))
          ;; Call disconnect
          (opencode-sse--disconnect)
          ;; Assert state is cleaned
          (should (null opencode-sse--process))
          (should (null opencode-sse--response-buffer))
          ;; Buffer should be killed
          (should-not (buffer-live-p temp-buf)))
      ;; Cleanup in case test fails
      (when (buffer-live-p temp-buf)
        (kill-buffer temp-buf)))))

(ert-deftest opencode-sse-reconnect-guard-checks-server ()
  "Verify reconnect does NOT call connect when server is disconnected.
Guard — attempting SSE to a dead server wastes resources and errors."
  (let ((connect-called nil))
    (cl-letf (((symbol-function 'opencode-server--connected-p)
               (lambda () nil))
              ((symbol-function 'opencode-sse--connect)
               (lambda () (setq connect-called t))))
      (let ((opencode-sse--reconnect-timer nil))
        (opencode-sse--do-reconnect)
        (should-not connect-called)))))

;;; --- question.asked and permission.asked hook mapping ---

(ert-deftest opencode-sse-hook-for-question-asked ()
  "Verify hook lookup returns correct hook for question.asked.
Routing correctness — question.asked triggers interactive question popup."
  (should (eq (opencode-sse--hook-for-type "question.asked")
              'opencode-sse-question-asked-hook)))

(ert-deftest opencode-sse-hook-for-permission-asked ()
  "Verify hook lookup returns correct hook for permission.asked.
Routing correctness — permission.asked triggers permission grant popup."
  (should (eq (opencode-sse--hook-for-type "permission.asked")
              'opencode-sse-permission-asked-hook)))

(ert-deftest opencode-sse-hook-for-server-instance-disposed ()
  "Verify hook lookup returns correct hook for server.instance.disposed.
Routing correctness — per-project disposal event must not kill global SSE."
  (should (eq (opencode-sse--hook-for-type "server.instance.disposed")
              'opencode-sse-server-instance-disposed-hook)))

(ert-deftest opencode-sse-instance-disposed-does-not-reconnect ()
  "Verify server.instance.disposed does NOT trigger reconnect.
Per-project event — global SSE survives project disposal; reconnecting loses events."
  (require 'opencode)
  (let ((opencode-sse--reconnect-timer nil)
        (opencode-sse--reconnect-delay 1)
        (opencode-sse-auto-reconnect t)
        (opencode-sse--process nil)
        (disconnected nil))
    (cl-letf (((symbol-function 'opencode-sse-disconnect) (lambda () (setq disconnected t))))
      (opencode--on-instance-disposed
       (list :type "server.instance.disposed"
             :properties (list :directory "/home/user/project")))
      (should-not opencode-sse--reconnect-timer)
      (should-not disconnected))))

(ert-deftest opencode-sse-global-disposed-triggers-rebootstrap ()
  "Verify global.disposed schedules debounced rebootstrap, NOT reconnect.
Uses the same 0.5s idle timer as instance.disposed so rapid disposed+global
events coalesce into a single re-bootstrap.  SSE stays connected."
  (require 'opencode)
  (let ((opencode-sse--reconnect-timer nil)
        (opencode--rebootstrap-timer nil)
        (opencode-sse--process nil))
    (cl-letf (((symbol-function 'opencode--do-rebootstrap)
               (lambda () nil))
              ((symbol-function 'opencode-sse-disconnect) (lambda () nil)))
      (opencode--on-global-disposed
       (list :type "global.disposed" :properties nil))
      ;; Should schedule debounced rebootstrap timer, NOT reconnect
      (should (timerp opencode--rebootstrap-timer))
      (should-not opencode-sse--reconnect-timer)
      ;; Clean up timer
      (cancel-timer opencode--rebootstrap-timer))))

(ert-deftest opencode-sse-dispatches-instance-disposed-via-global-format ()
  "Verify server.instance.disposed via global wrapper dispatches correctly.
Global format unwrapping — disposal events wrapped in global format must still route."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (received nil))
    (add-hook 'opencode-sse-server-instance-disposed-hook
              (lambda (event) (setq received event)))
    (unwind-protect
        (progn
          (opencode-sse--process-line "event: message")
          (opencode-sse--process-line
           (concat "data: {\"directory\":\"/Users/test/project\","
                   "\"payload\":{\"type\":\"server.instance.disposed\","
                   "\"properties\":{\"directory\":\"/Users/test/project\"}}}"))
          (opencode-sse--process-line "")
          (should received)
          (should (string= (plist-get received :type) "server.instance.disposed")))
      (remove-hook 'opencode-sse-server-instance-disposed-hook
                   (car (last opencode-sse-server-instance-disposed-hook))))))

;;; --- Edge case tests ---

(ert-deftest opencode-sse-dispatch-malformed-json ()
  "Verify invalid JSON does not crash dispatch.
Resilience — malformed server data must be handled gracefully, not crash Emacs."
  (let ((opencode-sse--last-event-time nil)
        (opencode-sse--reconnect-delay 4))
    ;; Should NOT signal an error — condition-case in dispatch catches it
    (opencode-sse--dispatch-event "message" "this is not valid JSON")
    ;; last-event-time should still be set (happens before JSON parse? No,
    ;; it's set at the top of dispatch before condition-case body)
    (should (numberp opencode-sse--last-event-time))
    ;; reconnect-delay should still be reset to 1 (set before condition-case body)
    (should (= opencode-sse--reconnect-delay 1))))

(ert-deftest opencode-sse-dispatch-missing-type ()
  "Verify event with no :type in payload uses SSE event-type as fallback.
Fallback routing — events without :type must still reach correct handlers."
  (let ((opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event)))
    (unwind-protect
        (progn
          ;; JSON has no :type and no :payload — falls through to fallback branch
          (opencode-sse--dispatch-event
           "server.heartbeat"
           "{\"someKey\":\"someValue\"}")
          (should dispatched)
          ;; Fallback uses the SSE event-type field as :type
          (should (string= (plist-get dispatched :type) "server.heartbeat"))
          ;; The entire JSON becomes :properties
          (should (string= (plist-get (plist-get dispatched :properties) :someKey)
                            "someValue")))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))))))

(ert-deftest opencode-sse-dispatch-missing-properties ()
  "Verify event with :type but nil :properties is handled gracefully.
Defensive coding — sparse events must not crash on missing properties."
  (let ((opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event)))
    (unwind-protect
        (progn
          (opencode-sse--dispatch-event
           "message"
           "{\"type\":\"session.idle\"}")
          (should dispatched)
          (should (string= (plist-get dispatched :type) "session.idle"))
          ;; :properties should be nil, not cause an error
          (should (null (plist-get dispatched :properties))))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))))))

(ert-deftest opencode-sse-process-line-incomplete-event ()
  "Verify partial data lines without empty-line terminator accumulate.
SSE protocol — no premature dispatch until event boundary (empty line)."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (_event) (setq dispatched t)))
    (unwind-protect
        (progn
          ;; Feed event type and data but NO empty line
          (opencode-sse--process-line "event: session.idle")
          (opencode-sse--process-line "data: {\"type\":\"session.idle\",\"properties\":{}}")
          ;; Should NOT have dispatched yet
          (should-not dispatched)
          ;; But current-event should have accumulated data
          (should opencode-sse--current-event)
          (should (string= (plist-get opencode-sse--current-event :event-type)
                            "session.idle"))
          (should (plist-get opencode-sse--current-event :data)))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (_event) (setq dispatched t))))))

(ert-deftest opencode-sse-dispatch-default-event-type ()
  "Verify data-only event (no event: line) defaults to 'message' type.
SSE spec — default event type is 'message' when event: line is omitted."
  (let ((opencode-sse--current-event nil)
        (opencode-sse--last-event-time nil)
        (dispatched nil))
    (add-hook 'opencode-sse-event-hook
              (lambda (event) (setq dispatched event)))
    (unwind-protect
        (progn
          ;; Only data line, no event: line
          (opencode-sse--process-line
           "data: {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_1\"}}")
          (opencode-sse--process-line "")
          (should dispatched)
          ;; The inner JSON :type should be used (instance event format)
          (should (string= (plist-get dispatched :type) "session.idle")))
      (remove-hook 'opencode-sse-event-hook
                   (lambda (event) (setq dispatched event))))))

(ert-deftest opencode-sse-heartbeat-timeout-detection ()
  "Verify check-heartbeat detects stale connection and schedules reconnect.
Liveness detection — dead SSE connections must be detected and recovered."
  (let ((opencode-sse--last-event-time (- (float-time) 120)) ; 120s ago
        (opencode-sse-heartbeat-timeout 60)
        (opencode-sse-auto-reconnect t)
        (opencode-sse--reconnect-timer nil)
        (opencode-sse--reconnect-delay 1)
        (opencode-sse--heartbeat-timer nil)
        (opencode-sse--process nil)
        (disconnect-called nil))
    (cl-letf (((symbol-function 'opencode-sse-disconnect)
               (lambda () (setq disconnect-called t))))
      (opencode-sse--check-heartbeat)
      ;; Should have detected timeout and called disconnect
      (should disconnect-called)
      ;; Should have scheduled reconnect
      (should opencode-sse--reconnect-timer)
      (cancel-timer opencode-sse--reconnect-timer)
      (setq opencode-sse--reconnect-timer nil))))

;;; --- New event type dispatch tests (Tasks 4-7, 11-13) ---

(ert-deftest opencode-sse-dispatch-session-deleted ()
  "Verify session.deleted events dispatch to opencode-sse-session-deleted-hook.
If this fails, chat buffers won't be notified when their session is deleted,
leaving users typing into a dead session."
  (should (eq (opencode-sse--hook-for-type "session.deleted")
              'opencode-sse-session-deleted-hook)))

(ert-deftest opencode-sse-dispatch-session-error ()
  "Verify session.error events dispatch to opencode-sse-session-error-hook.
If this fails, server errors during generation won't be shown to users,
leaving them confused about why the assistant stopped responding."
  (should (eq (opencode-sse--hook-for-type "session.error")
              'opencode-sse-session-error-hook)))

(ert-deftest opencode-sse-dispatch-todo-updated ()
  "Verify todo.updated events dispatch to opencode-sse-todo-updated-hook.
If this fails, the todo buffer won't refresh when tasks change,
showing stale todo state to users."
  (should (eq (opencode-sse--hook-for-type "todo.updated")
              'opencode-sse-todo-updated-hook)))

(ert-deftest opencode-sse-dispatch-permission-replied ()
  "Verify permission.replied events dispatch to opencode-sse-permission-replied-hook.
If this fails, permission popups won't dismiss when answered elsewhere,
leaving stale popups blocking user input."
  (should (eq (opencode-sse--hook-for-type "permission.replied")
              'opencode-sse-permission-replied-hook)))

(ert-deftest opencode-sse-dispatch-question-replied ()
  "Verify question.replied events dispatch to opencode-sse-question-replied-hook.
If this fails, question popups won't dismiss when answered elsewhere,
leaving stale popups blocking user input."
  (should (eq (opencode-sse--hook-for-type "question.replied")
              'opencode-sse-question-replied-hook)))

(ert-deftest opencode-sse-dispatch-question-rejected ()
  "Verify question.rejected events dispatch to opencode-sse-question-rejected-hook.
If this fails, question popups won't dismiss when rejected elsewhere,
leaving stale popups blocking user input."
  (should (eq (opencode-sse--hook-for-type "question.rejected")
              'opencode-sse-question-rejected-hook)))

(ert-deftest opencode-sse-dispatch-installation-update-available ()
  "Verify installation.update-available events dispatch to correct hook.
If this fails, users won't see update notifications in the chat footer,
missing important version updates."
  (should (eq (opencode-sse--hook-for-type "installation.update-available")
              'opencode-sse-installation-update-available-hook)))

(provide 'opencode-sse-test)
;;; opencode-sse-test.el ends here
