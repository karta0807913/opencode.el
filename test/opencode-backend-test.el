;;; opencode-backend-test.el --- Tests for backend abstraction -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'opencode-backend)

(ert-deftest opencode-backend-register-and-get-current ()
  "Backend registration must be independent of concrete API modules so a
future backend can register itself without changing chat rendering code."
  (let ((opencode-backend--registry (make-hash-table :test 'eq))
        (opencode-backend-current 'fake))
    (opencode-backend-register
     (opencode-backend-create :name 'fake :capabilities '(messages)))
    (should (opencode-backend-get))
    (should (opencode-backend-capable-p 'messages))))

(ert-deftest opencode-backend-opencode-session-normalizes-core-fields ()
  "OpenCode session payloads must adapt to the canonical session shape.
Without this boundary, alternate backends would have to mimic OpenCode's
`:parentID' and `:time' layout throughout the UI."
  (let* ((raw '(:id "ses_1" :title "T" :directory "/p" :parentID "ses_0"
                :time (:created 1 :updated 2) :summary (:files 1)))
         (session (opencode-backend-opencode-session raw)))
    (should (equal (plist-get session :id) "ses_1"))
    (should (equal (plist-get session :parent-id) "ses_0"))
    (should (= (plist-get session :created-at) 1))
    (should (eq (plist-get session :raw) raw))))

(ert-deftest opencode-backend-opencode-message-normalizes-parts ()
  "OpenCode message payloads must adapt to canonical messages with
canonical parts, so renderers can eventually consume opencode.el's own
shape rather than server-native payloads."
  (let* ((raw '(:info (:id "msg_1" :sessionID "ses_1" :role "assistant"
                      :agent "build" :modelID "m" :providerID "p"
                      :time (:created 10 :completed 20))
                :parts [(:id "prt_1" :messageID "msg_1" :sessionID "ses_1"
                         :type "text" :text "hi")]))
         (message (opencode-backend-opencode-message raw))
         (part (car (plist-get message :parts))))
    (should (equal (plist-get message :id) "msg_1"))
    (should (equal (plist-get message :model-id) "m"))
    (should (= (plist-get message :completed-at) 20))
    (should (equal (plist-get part :id) "prt_1"))
    (should (equal (plist-get part :text) "hi"))))

(ert-deftest opencode-backend-opencode-event-normalizes-session-id ()
  "Event normalization must extract the session id from all OpenCode SSE
locations.  This is the key dispatch field that alternate backends need
to supply in a backend-neutral way."
  (let* ((event '(:type "message.part.updated"
                  :properties (:part (:id "prt_1" :sessionID "ses_1"
                                      :messageID "msg_1" :type "text")
                               :delta "hi")))
         (normalized (opencode-backend-opencode-event event)))
    (should (equal (plist-get normalized :session-id) "ses_1"))
    (should (equal (plist-get normalized :message-id) "msg_1"))
    (should (equal (plist-get normalized :part-id) "prt_1"))
    (should (equal (plist-get normalized :delta) "hi"))))

(ert-deftest opencode-backend-normalize-event-uses-registered-adapter ()
  "Event normalization must dispatch through the active backend adapter.
This keeps message/question/permission handlers separated from SSE/API
wire formats and lets future backends adapt at one boundary."
  (let ((opencode-backend--registry (make-hash-table :test 'eq))
        (opencode-backend-current 'fake))
    (opencode-backend-register
     (opencode-backend-create
      :name 'fake
      :event-adapter (lambda (event)
                       (opencode-backend-event
                        :type "canonical"
                        :session-id (plist-get event :sid)
                        :raw event))))
    (let ((normalized (opencode-backend-normalize-event '(:sid "s1"))))
      (should (equal (plist-get normalized :type) "canonical"))
      (should (equal (plist-get normalized :session-id) "s1")))))

(ert-deftest opencode-backend-canonical-shapes-cover-pi-style-blocks ()
  "Canonical shapes must be broad enough for Pi adapters without making
Pi's TypeScript unions part of the UI contract.  Pi assistant content has
text/thinking/toolCall blocks, and tool results carry a toolCallId plus
error/details metadata; those map to generic backend parts."
  (let ((tool-call (opencode-backend-part
                    :type "tool-call"
                    :content-index 2
                    :tool "bash"
                    :tool-call-id "call_1"
                    :arguments '(:command "pwd")))
        (tool-result (opencode-backend-part
                      :type "tool-result"
                      :tool "bash"
                      :tool-call-id "call_1"
                      :text "/tmp\n"
                      :is-error nil
                      :details '(:exit-code 0)))
        (model (opencode-backend-model
                :id "claude-sonnet-4"
                :provider-id "anthropic"
                :api "anthropic-messages"
                :input '("text" "image")
                :context-window 200000)))
    (should (equal (plist-get tool-call :tool-call-id) "call_1"))
    (should (equal (plist-get tool-result :type) "tool-result"))
    (should-not (plist-get tool-result :is-error))
    (should (equal (plist-get model :api) "anthropic-messages"))
    (should (= (plist-get model :context-window) 200000))))

(provide 'opencode-backend-test)
;;; opencode-backend-test.el ends here
