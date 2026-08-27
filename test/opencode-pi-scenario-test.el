;;; opencode-pi-scenario-test.el --- End-to-end Pi stream -> chat buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Integration test: drive a Pi RPC event stream through the transport filter
;; and the runtime event router into a REAL chat buffer, asserting the rendered
;; result.  No `pi' binary: `make-process' is stubbed and the captured filter is
;; fed canned JSONL, exactly as a live subprocess would.
;;
;; This exercises the full Pi path: jsonl framing (opencode-pi-rpc) -> event
;; handler -> opencode-pi--route-event -> canonical event router -> chat
;; handlers (on-session-status / on-part-updated / on-session-idle) -> buffer
;; render.

;;; Code:

(require 'test-helper nil t)
(require 'cl-lib)
(require 'opencode-pi)
(require 'opencode-chat)

(defvar opencode-pi-scenario-test--filter nil)

(defun opencode-pi-scenario-test--feed (conn &rest chunks)
  "Feed CHUNKS to CONN's captured filter."
  (dolist (chunk chunks)
    (funcall opencode-pi-scenario-test--filter
             (opencode-pi-conn-process conn) chunk)))

(ert-deftest opencode-pi-scenario-streams-text-into-chat-buffer ()
  "A Pi agent_start/text_delta/agent_end stream renders text and clears busy.
This is the full Pi runtime path: framing -> router -> chat handlers ->
render.  If any link breaks, the user sees no streamed output or a buffer
stuck in the busy state."
  (let ((opencode-pi-scenario-test--filter nil)
        (opencode-pi--conns (make-hash-table :test 'equal))
        (opencode-event-routes nil)
        (chat-buf (generate-new-buffer "*test-pi-chat*")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (setq opencode-pi-scenario-test--filter (plist-get args :filter))
                     'fake-pi-process))
                  ((symbol-function 'process-live-p)
                   (lambda (p) (eq p 'fake-pi-process)))
                  ((symbol-function 'process-send-string) (lambda (&rest _) nil))
                  ;; Route canonical events straight to our chat buffer.
                  ((symbol-function 'opencode--chat-buffer-for-session)
                   (lambda (_sid) chat-buf))
                  ((symbol-function 'opencode--all-chat-buffers)
                   (lambda () (list chat-buf)))
                  ;; Avoid real refresh HTTP during the message.updated bounce.
                  ((symbol-function 'opencode-chat--schedule-refresh) #'ignore)
                  ((symbol-function 'opencode-chat--refresh) #'ignore))
          ;; Set up a real Pi-backed chat buffer.
          (opencode-event-route "session.status"
                                'opencode-sse-session-status-hook
                                #'opencode-chat--on-session-status 'chat)
          (opencode-event-route "message.updated"
                                'opencode-sse-message-updated-hook
                                #'opencode-chat--on-message-updated 'chat)
          (opencode-event-route "message.part.updated"
                                'opencode-sse-message-part-updated-hook
                                #'opencode-chat--on-part-updated 'chat)
          (opencode-event-route "session.idle"
                                'opencode-sse-session-idle-hook
                                #'opencode-chat--on-session-idle 'chat)
          (with-current-buffer chat-buf
            (opencode-chat-mode)
            (opencode-chat--set-session-id "ses_pi")
            (opencode-chat--set-backend 'pi)
            ;; Render once (empty) so messages-end + input area markers exist,
            ;; matching the state after the first refresh.  Without this the
            ;; streaming delta has no insertion marker (Case 3) and no-ops.
            (opencode-chat--render-messages '()))
          ;; Start a conn and wire the router exactly as `opencode-pi--launch'.
          (let ((conn (opencode-pi-rpc-start default-directory)))
            (opencode-pi-bind-conn "ses_pi" conn)
            (setf (opencode-pi-conn-event-handler conn)
                  (lambda (raw) (opencode-pi--route-event "ses_pi" raw)))
            ;; Drive the stream.
            (opencode-pi-scenario-test--feed
             conn
             "{\"type\":\"agent_start\"}\n")
            (with-current-buffer chat-buf
              (should (opencode-chat--busy)))
            (opencode-pi-scenario-test--feed
             conn
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"timestamp\":42}}\n"
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_start\",\"contentIndex\":0,\"partial\":{\"text\":\"\"}}}\n"
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"Hello \",\"partial\":{\"text\":\"Hello \"}}}\n"
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"world\",\"partial\":{\"text\":\"Hello world\"}}}\n"
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"timestamp\":42}}\n"
             "{\"type\":\"agent_end\",\"messages\":[]}\n")
            (with-current-buffer chat-buf
              (should-not (opencode-chat--busy))
              (should (opencode-test-buffer-contains-p "Hello world")))))
      (kill-buffer chat-buf))))

(provide 'opencode-pi-scenario-test)
;;; opencode-pi-scenario-test.el ends here
