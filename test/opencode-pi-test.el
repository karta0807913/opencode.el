;;; opencode-pi-test.el --- Tests for opencode-pi.el normalizers -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the Pi backend adapter's pure normalizers: Pi AgentMessage and
;; AgentSessionEvent objects -> opencode.el's OpenCode-shaped messages/parts and
;; canonical backend events.  No subprocess, no I/O.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-pi)
(require 'opencode-lifecycle)
(require 'opencode-prompt)

;;; --- Content blocks ---

(ert-deftest opencode-pi-content-blocks-string ()
  "A Pi user message with a plain-string content yields one text block.
Pi `UserMessage.content' is string|blocks; the string form must not crash."
  (let ((blocks (opencode-pi--content-blocks "hello")))
    (should (= 1 (length blocks)))
    (should (equal "text" (plist-get (car blocks) :type)))
    (should (equal "hello" (plist-get (car blocks) :text)))))

(ert-deftest opencode-pi-content-blocks-vector ()
  "A vector of blocks is returned as a list unchanged.
Pi delivers content arrays as JSON arrays (vectors after parse)."
  (let ((blocks (opencode-pi--content-blocks
                 (vector (list :type "text" :text "a")
                         (list :type "text" :text "b")))))
    (should (= 2 (length blocks)))))

;;; --- Message normalization ---

(ert-deftest opencode-pi-message-user-text ()
  "A Pi user message becomes an OpenCode-shaped message with a text part.
Without this, user prompts would not render in the chat buffer."
  (let* ((msg (opencode-pi--message
               (list :role "user" :content "hi there" :timestamp 1700000000000)
               0))
         (info (plist-get msg :info))
         (parts (append (plist-get msg :parts) nil)))
    (should (equal "user" (plist-get info :role)))
    (should (= 1 (length parts)))
    (should (equal "text" (plist-get (car parts) :type)))
    (should (equal "hi there" (plist-get (car parts) :text)))))

(ert-deftest opencode-pi-message-assistant-blocks ()
  "An assistant message maps text/thinking/toolCall to text/reasoning/tool parts.
This is the core content mapping the renderer depends on."
  (let* ((msg (opencode-pi--message
               (list :role "assistant"
                     :model "claude" :provider "anthropic"
                     :stopReason "stop"
                     :usage (list :input 10 :output 5 :totalTokens 15
                                  :cost (list :total 0.01))
                     :content (vector
                               (list :type "thinking" :thinking "hmm")
                               (list :type "text" :text "Hello")
                               (list :type "toolCall" :id "call_1"
                                     :name "bash"
                                     :arguments (list :command "ls"))))
               1))
         (info (plist-get msg :info))
         (parts (append (plist-get msg :parts) nil)))
    (should (equal "assistant" (plist-get info :role)))
    (should (equal "claude" (plist-get info :modelID)))
    (should (equal 15 (plist-get (plist-get info :tokens) :total)))
    (should (equal '("reasoning" "text" "tool")
                   (mapcar (lambda (p) (plist-get p :type)) parts)))
    (let ((tool (nth 2 parts)))
      (should (equal "bash" (plist-get tool :tool)))
      (should (equal "call_1" (plist-get tool :callID)))
      (should (equal "running"
                     (plist-get (plist-get tool :state) :status))))))

(ert-deftest opencode-pi-tool-result-folds-into-tool-part ()
  "A toolResult message merges into the preceding assistant tool part's state.
Pi reports tool output as a separate message; the UI shows it inline."
  (let* ((messages (vector
                    (list :role "assistant" :model "m"
                          :content (vector (list :type "toolCall" :id "c1"
                                                 :name "bash"
                                                 :arguments (list :command "ls"))))
                    (list :role "toolResult" :toolCallId "c1"
                          :isError :false
                          :content (vector (list :type "text" :text "file1\n")))))
         (out (append (opencode-pi--messages messages) nil))
         (asst (car out))
         (tool (aref (plist-get asst :parts) 0))
         (state (plist-get tool :state)))
    (should (= 1 (length out)))
    (should (equal "completed" (plist-get state :status)))
    (should (equal "file1\n" (plist-get state :output)))))

(ert-deftest opencode-pi-tool-result-error-status ()
  "An errored toolResult sets the tool part status to error.
Surfaces failed tool calls distinctly in the UI."
  (let* ((messages (vector
                    (list :role "assistant" :model "m"
                          :content (vector (list :type "toolCall" :id "c2"
                                                 :name "bash" :arguments nil)))
                    (list :role "toolResult" :toolCallId "c2"
                          :isError t
                          :content (vector (list :type "text" :text "boom")))))
         (out (append (opencode-pi--messages messages) nil))
         (state (plist-get (aref (plist-get (car out) :parts) 0) :state)))
    (should (equal "error" (plist-get state :status)))
    (should (equal "boom" (plist-get state :error)))))

;;; --- Event normalization ---

(ert-deftest opencode-pi-event-agent-start-is-busy ()
  "`agent_start' maps to a busy session.status event.
Drives the chat buffer into the streaming/busy state."
  (let ((ev (opencode-pi--event (list :type "agent_start"))))
    (should (equal "session.status" (plist-get ev :type)))
    (should (equal "busy" (plist-get (plist-get ev :status) :type)))))

(ert-deftest opencode-pi-event-agent-end-is-idle ()
  "`agent_end' maps to session.idle so the buffer leaves busy state.
Without this, the chat buffer would appear stuck generating forever."
  (let ((ev (opencode-pi--event
             (list :type "agent_end" :messages []) "ses_pi")))
    (should (equal "session.idle" (plist-get ev :type)))
    (should (equal "ses_pi" (plist-get ev :session-id)))))

(ert-deftest opencode-pi-event-agent-settled-is-idle ()
  "`agent_settled' is the authoritative fully-settled lifecycle boundary."
  (let ((ev (opencode-pi--event
             (list :type "agent_settled") "ses_pi")))
    (should (equal "session.idle" (plist-get ev :type)))
    (should (equal "ses_pi" (plist-get ev :session-id)))))

(ert-deftest opencode-pi-messages-use-turn-scoped-correlations ()
  "Each Pi assistant keeps the user correlation recorded for its own turn."
  (let* ((messages
          (vector
           (list :role "assistant" :timestamp 1
                 :content (vector (list :type "text" :text "first")))
           (list :role "assistant" :timestamp 2
                 :content (vector (list :type "text" :text "second")))))
         (correlations (make-hash-table :test 'equal)))
    (puthash "pimsg-assistant-1" "msg_first" correlations)
    (puthash "pimsg-assistant-2" "msg_second" correlations)
    (let ((normalized
           (append (opencode-pi--messages messages correlations) nil)))
      (should (equal "msg_first"
                     (plist-get (plist-get (car normalized) :info)
                                :parentID)))
      (should (equal "msg_second"
                     (plist-get (plist-get (cadr normalized) :info)
                                :parentID))))))

(ert-deftest opencode-pi-event-text-delta-streams ()
  "A text_delta message_update maps to message.part.updated with a delta.
This is the streaming path; a wrong mapping breaks live token output."
  (let* ((ev (opencode-pi--event
              (list :type "message_update"
                    :assistantMessageEvent
                    (list :type "text_delta" :delta "Hello"
                          :partial (list :text "Hello")))))
         (part (plist-get ev :part)))
    (should (equal "message.part.updated" (plist-get ev :type)))
    (should (equal "Hello" (plist-get ev :delta)))
    (should (equal "text" (plist-get part :type)))))

(ert-deftest opencode-pi-event-thinking-delta-is-reasoning ()
  "A thinking_delta maps to a reasoning part update.
Keeps thinking output visually distinct from assistant text."
  (let* ((ev (opencode-pi--event
              (list :type "message_update"
                    :assistantMessageEvent
                    (list :type "thinking_delta" :delta "ponder"
                          :partial (list :text "ponder")))))
         (part (plist-get ev :part)))
    (should (equal "reasoning" (plist-get part :type)))
    (should (equal "ponder" (plist-get ev :delta)))))

(ert-deftest opencode-pi-event-tool-execution-end-completed ()
  "`tool_execution_end' (not error) maps to a completed tool part update.
Correlated by toolCallId so the right tool row flips to done."
  (let ((ev (opencode-pi--event
             (list :type "tool_execution_end"
                   :toolCallId "c9" :toolName "bash"
                   :isError :false :result nil))))
    (should (equal "message.part.updated" (plist-get ev :type)))
    (should (equal "c9" (plist-get ev :part-id)))
    (should (equal "completed" (plist-get ev :status)))))

(ert-deftest opencode-pi-event-tool-execution-error ()
  "An errored tool_execution_end maps to an error status.
Distinguishes failed tools in the UI."
  (let ((ev (opencode-pi--event
             (list :type "tool_execution_end"
                   :toolCallId "c9" :toolName "bash" :isError t))))
    (should (equal "error" (plist-get ev :status)))))

(ert-deftest opencode-pi-event-compaction-maps-to-compacted ()
  "Compaction events map to session.compacted (history rewrite).
Triggers a full refresh, matching OpenCode's compaction handling."
  (should (equal "session.compacted"
                 (plist-get (opencode-pi--event
                             (list :type "compaction_end" :reason "manual"))
                            :type))))

(ert-deftest opencode-pi-event-unknown-passes-through ()
  "An unmapped event keeps its type in a canonical wrapper.
No-effect events still produce a backend event object (never nil crash)."
  (let ((ev (opencode-pi--event (list :type "queue_update" :steering []))))
    (should (equal "queue_update" (plist-get ev :type)))
    (should (equal (list :type "queue_update" :steering [])
                   (plist-get ev :raw)))))

;;; --- Backend registration & capabilities ---

(ert-deftest opencode-pi-backend-registered ()
  "The `pi' backend is registered and resolvable.
Without registration, `opencode-chat-open … 'pi' has no backend to call."
  (should (opencode-backend-get 'pi)))

(ert-deftest opencode-pi-capabilities ()
  "Pi advertises streaming/tools/models/permissions/questions but NOT diffs/todos.
Permissions/questions are push-driven via the extension-UI bridge (no list
pull).  Diffs and todos have no Pi equivalent and must stay off."
  (should (opencode-backend-capable-p 'streaming 'pi))
  (should (opencode-backend-capable-p 'messages 'pi))
  (should (opencode-backend-capable-p 'models 'pi))
  (should (opencode-backend-capable-p 'permissions 'pi))
  (should (opencode-backend-capable-p 'questions 'pi))
  (should-not (opencode-backend-capable-p 'diffs 'pi))
  (should-not (opencode-backend-capable-p 'todos 'pi)))

;;; --- Prompt intent translation ---

(ert-deftest opencode-pi-intent-to-message-extracts-text ()
  "A prompt intent reduces directly to its text for Pi.
Pi's prompt command wants a plain message string, not OpenCode parts."
  (let ((intent (opencode-prompt-intent-create :text "hello world")))
    (should (equal "hello world"
                   (opencode-prompt-intent-text intent)))))

(ert-deftest opencode-pi-intent-to-images ()
  "Image attachments in a prompt intent convert to Pi image blocks.
Pi expects {type:image,data,mimeType}; wrong shape drops attachments."
  (let* ((intent (opencode-prompt-intent-create
                  :text "look"
                  :images (list (list :data-url "data:image/png;base64,BASE64"
                                      :mime "image/png"
                                      :filename "test.png"))))
         (images (append (opencode-pi--intent-images intent) nil)))
    (should (= 1 (length images)))
    (should (equal "image" (plist-get (car images) :type)))
    (should (equal "BASE64" (plist-get (car images) :data)))
    (should (equal "image/png" (plist-get (car images) :mimeType)))))

;;; --- Conn registry ---

(ert-deftest opencode-pi-conn-registry-binds-and-resolves ()
  "A bound live conn is resolvable by session id; a dead one is auto-unbound.
Facade ops only get a session id, so this lookup is the routing key."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (alive t))
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p)
               (lambda (_c) alive)))
      (let ((conn (opencode-pi-conn--create)))
        (opencode-pi-bind-conn "ses_pi" conn)
        (should (eq conn (opencode-pi-conn-for "ses_pi")))
        (should (equal "ses_pi" (opencode-pi-conn-session-id conn)))
        ;; Simulate death: lookup returns nil and unbinds.
        (setq alive nil)
        (should-not (opencode-pi-conn-for "ses_pi"))
        (should-not (gethash "ses_pi" opencode-pi--conns))))))

(ert-deftest opencode-pi-send-prompt-idle-is-prompt ()
  "An idle send maps to a plain `prompt' command with the message text.
Guards the default send path (no streamingBehavior when not busy)."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        sent)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (_conn cmd &optional _cb) (setq sent cmd) "id")))
      (opencode-pi-bind-conn "ses_pi" (opencode-pi-conn--create))
      (opencode-pi-send-prompt
       "ses_pi"
        (opencode-prompt-intent-create :text "do it")
        nil nil)
      (should (equal "prompt" (plist-get sent :type)))
      (should (equal "do it" (plist-get sent :message)))
      (should-not (plist-member sent :streamingBehavior)))))

(ert-deftest opencode-pi-execute-command-forwards-slash-text ()
  "Pi slash commands use its normal prompt/steering transport."
  (let (sent)
    (cl-letf (((symbol-function 'opencode-pi-send-prompt)
               (lambda (session-id intent callback &optional busy)
                 (setq sent (list session-id intent callback busy)))))
      (opencode-pi-execute-command
       "ses_pi" "btw" "check this" nil nil nil #'ignore t)
      (should (equal "ses_pi" (nth 0 sent)))
      (should (equal "/btw check this"
                     (opencode-prompt-intent-text (nth 1 sent))))
      (should (eq #'ignore (nth 2 sent)))
      (should (eq t (nth 3 sent))))))

(ert-deftest opencode-pi-send-prompt-busy-steers ()
  "A busy send maps to a `prompt' with streamingBehavior steer (default mode).
This is the redirect-now behavior confirmed for Pi buffers."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (opencode-pi-steering-mode 'steer)
        sent)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (_conn cmd &optional _cb) (setq sent cmd) "id")))
      (opencode-pi-bind-conn "ses_pi" (opencode-pi-conn--create))
      (opencode-pi-send-prompt
       "ses_pi"
        (opencode-prompt-intent-create :text "wait, do this")
        nil t)
      (should (equal "prompt" (plist-get sent :type)))
      (should (equal "steer" (plist-get sent :streamingBehavior))))))

(ert-deftest opencode-pi-busy-steer-does-not-steal-active-correlation ()
  "A steer modifies the active turn without replacing its user message ID."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (opencode-pi-steering-mode 'steer))
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (&rest _) "id"))
              ((symbol-function 'opencode-event-dispatch) #'ignore))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi-send-prompt
         "ses_pi"
          (opencode-prompt-intent-create :text "steer"
                                         :message-id "msg_manual")
          nil t)
        (should
         (equal "msg_pipeline"
                (opencode-pi-conn-active-prompt-message-id conn)))
        (should-not
         (opencode-pi-conn-pending-prompt-message-ids conn))))))

(ert-deftest opencode-pi-send-prompt-busy-follow-up ()
  "With follow-up mode, a busy send maps to a `follow_up' command.
Verifies the configurable alternative to steering."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (opencode-pi-steering-mode 'follow-up)
        sent)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (_conn cmd &optional _cb) (setq sent cmd) "id")))
      (opencode-pi-bind-conn "ses_pi" (opencode-pi-conn--create))
      (opencode-pi-send-prompt
       "ses_pi"
        (opencode-prompt-intent-create :text "later")
        nil t)
      (should (equal "follow_up" (plist-get sent :type))))))

(ert-deftest opencode-pi-busy-follow-up-keeps-separate-turns ()
  "A follow-up queues behind, rather than replacing, the active turn."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (opencode-pi-steering-mode 'follow-up))
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (&rest _) "id"))
              ((symbol-function 'opencode-event-dispatch) #'ignore))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_first")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi-send-prompt
         "ses_pi"
          (opencode-prompt-intent-create :text "later"
                                         :message-id "msg_follow")
          nil t)
        (should
         (equal '("msg_follow")
                (opencode-pi-conn-pending-prompt-message-ids conn)))
        (opencode-pi--route-event "ses_pi" '(:type "agent_end"))
        (opencode-pi--route-event "ses_pi" '(:type "agent_start"))
        (should
         (equal "msg_follow"
                (opencode-pi-conn-active-prompt-message-id conn)))))))

(ert-deftest opencode-pi-get-messages-normalizes ()
  "`opencode-pi-get-messages' normalizes the RPC get_messages response.
The callback must receive OpenCode-shaped messages, not raw Pi messages."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        result)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-send)
               (lambda (_conn _cmd &optional cb)
                 (funcall cb
                          (list :type "response" :success t
                                :data (list :messages
                                            (vector (list :role "user"
                                                          :content "hi"
                                                          :timestamp 1)))))
                 "id")))
      (opencode-pi-bind-conn "ses_pi" (opencode-pi-conn--create))
      (opencode-pi-get-messages "ses_pi" (lambda (msgs) (setq result msgs)))
      (let ((msgs (append result nil)))
         (should (= 1 (length msgs)))
         (should (equal "user" (plist-get (plist-get (car msgs) :info) :role)))))))

(ert-deftest opencode-pi-session-directory-comes-from-connection ()
  "Pi session metadata uses the subprocess cwd, not ambient buffer state."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        (default-directory "/ambient/"))
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-pi-rpc-request-sync)
               (lambda (&rest _)
                 '(:data (:sessionName "Pi Session"
                          :cwd "/untrusted-state-cwd/")))))
      (let ((conn (opencode-pi-conn--create :cwd "/project-b/")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (should
         (equal "/project-b/"
                 (plist-get (opencode-pi-get-session-sync "ses_pi")
                            :directory)))))))

(ert-deftest opencode-pi-resume-uses-selected-session-directory ()
  "Resuming a Pi session launches in its recorded project directory."
  (let (launched-directory launched-file)
    (cl-letf (((symbol-function 'opencode-pi--read-session)
               (lambda ()
                 '("Session"
                   :file "/sessions/abc.jsonl"
                   :directory "/recorded/project/")))
              ((symbol-function 'opencode-pi--launch)
               (lambda (directory session-file)
                 (setq launched-directory directory
                       launched-file session-file))))
      (opencode-pi "/ambient/project/")
      (should (equal "/recorded/project/" launched-directory))
      (should (equal "/sessions/abc.jsonl" launched-file)))))

;;; --- Facade busy plumbing ---

(ert-deftest opencode-pi-facade-send-prompt-passes-busy ()
  "`opencode-backend-send-prompt' forwards the BUSY flag to the backend fn.
This is the seam that lets a Pi buffer steer/follow_up while generating;
without it, a mid-stream send would error or be dropped."
  (let (got-busy)
    (cl-letf (((symbol-function 'opencode-pi-send-prompt)
               (lambda (_sid _intent _cb &optional busy) (setq got-busy busy))))
      (opencode-backend-send-prompt
       "ses_pi" (opencode-prompt-intent-create :text "hi") #'ignore 'pi t)
      (should (eq got-busy t))
      (opencode-backend-send-prompt
       "ses_pi" (opencode-prompt-intent-create :text "hi") #'ignore 'pi nil)
      (should (eq got-busy nil)))))

(ert-deftest opencode-pi-facade-send-prompt-opencode-ignores-busy ()
  "OpenCode's send fn accepts and ignores the BUSY flag (no arity error).
Adding mid-stream queueing for Pi must not break the OpenCode send path."
  (let (posted)
    (require 'opencode-backend-opencode)
    (cl-letf (((symbol-function 'opencode-api-post)
               (lambda (path body _cb) (setq posted (cons path body)))))
      (opencode-backend-send-prompt
       "ses_oc" (opencode-prompt-intent-create :text "hi") #'ignore 'opencode t)
      (should (string-match-p "prompt_async" (car posted))))))

;;; --- Extension UI bridge ---

(ert-deftest opencode-pi-ui-confirm-dispatches-permission ()
  "A Pi confirm UI request dispatches into the permission popup.
This is how Pi surfaces approval prompts (it has no permission API)."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        dispatched)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (setq dispatched (list backend-event legacy-event)))))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "u1" :method "confirm"
             :title "Allow bash?" :message "ls -la"))
      (let* ((backend-event (car dispatched))
             (request (plist-get backend-event :request)))
        (should (equal "permission.asked" (plist-get backend-event :type)))
        (should (equal "ses_pi" (plist-get backend-event :session-id)))
        (should (equal "u1" (plist-get backend-event :request-id)))
        (should (equal "u1" (plist-get request :id)))
        (should (equal "Allow bash?" (plist-get request :permission))))
      ;; The request id is remembered for the reply.
      (should (eq 'fake-conn (gethash "u1" opencode-pi--ui-requests))))))

(ert-deftest opencode-pi-ui-select-dispatches-question ()
  "A Pi select UI request dispatches into the question popup with options.
Select/input/editor map to the question popup, not the permission one."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        dispatched)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (setq dispatched (list backend-event legacy-event)))))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "u2" :method "select"
              :title "Pick one" :options (vector "A" "B")))
      (should (equal "question.asked" (plist-get (car dispatched) :type)))
      (let* ((request (plist-get (car dispatched) :request))
             (q (aref (plist-get request :questions) 0)))
        (should (equal "u2" (plist-get (car dispatched) :request-id)))
        (should (equal "Pick one" (plist-get q :header)))
        (should (equal (vector "A" "B") (plist-get q :options)))))))

(ert-deftest opencode-pi-ui-notify-is-ignored ()
  "Fire-and-forget UI methods (notify) do not dispatch a popup.
They carry no reply; surfacing them as popups would deadlock the queue."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        (called nil))
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (&rest _) (setq called t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "u3" :method "notify"
             :message "hi"))
      (should-not called)
      (should-not (gethash "u3" opencode-pi--ui-requests)))))

(ert-deftest opencode-pi-ui-setwidget-routes-to-widget ()
  "A setWidget UI request drives the widget surface, not the popup pipeline.
This is how /btw's streamed answer reaches the child frame.  It is
fire-and-forget: no reply is registered."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        widget-call popup-called)
    (cl-letf (((symbol-function 'opencode-pi-widget-set)
               (lambda (sid key lines &optional placement)
                 (setq widget-call (list sid key lines placement))))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (&rest _) (setq popup-called t))))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "w1" :method "setWidget"
             :widgetKey "btw-1" :widgetLines (vector "answer")
             :widgetPlacement "aboveEditor"))
      (should (equal '("ses_pi" "btw-1" ["answer"] "aboveEditor") widget-call))
      (should-not popup-called)
      ;; No reply expected for fire-and-forget.
      (should-not (gethash "w1" opencode-pi--ui-requests)))))

(ert-deftest opencode-pi-ui-setstatus-routes-to-widget ()
  "A setStatus UI request drives the widget status line.
Used by /btw:summarize; fire-and-forget, no reply."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        status-call)
    (cl-letf (((symbol-function 'opencode-pi-widget-status)
               (lambda (sid key text) (setq status-call (list sid key text)))))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "s1" :method "setStatus"
             :statusKey "btw" :statusText "summarizing..."))
      (should (equal '("ses_pi" "btw" "summarizing...") status-call))
      (should-not (gethash "s1" opencode-pi--ui-requests)))))

(ert-deftest opencode-pi-ui-setwidget-clear-passes-nil ()
  "setWidget with undefined widgetLines clears the key (nil lines).
Pi clears a widget by omitting widgetLines; we must forward nil, not []."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        widget-call)
    (cl-letf (((symbol-function 'opencode-pi-widget-set)
               (lambda (sid key lines &optional placement)
                 (setq widget-call (list sid key lines placement)))))
      (opencode-pi-handle-ui-request
       'fake-conn "ses_pi"
       (list :type "extension_ui_request" :id "w2" :method "setWidget"
             :widgetKey "btw-1"))
      (should (equal '("ses_pi" "btw-1" nil nil) widget-call)))))

(ert-deftest opencode-pi-reply-permission-confirms ()
  "Allowing a Pi permission sends confirmed=t over the originating conn.
This is the outbound half of the bridge; wrong mapping leaves Pi blocked."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        sent)
    (puthash "u1" 'fake-conn opencode-pi--ui-requests)
    (cl-letf (((symbol-function 'opencode-pi-rpc-ui-reply-confirm)
               (lambda (conn id confirmed) (setq sent (list conn id confirmed)))))
      (opencode-pi-reply-permission "u1" "once" nil)
      (should (equal '(fake-conn "u1" t) sent))
      ;; Pending entry consumed.
      (should-not (gethash "u1" opencode-pi--ui-requests)))))

(ert-deftest opencode-pi-reply-permission-rejects ()
  "Rejecting a Pi permission sends confirmed=nil.
Maps the permission popup's reject choice to a denied confirm response."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        sent)
    (puthash "u1" 'fake-conn opencode-pi--ui-requests)
    (cl-letf (((symbol-function 'opencode-pi-rpc-ui-reply-confirm)
               (lambda (_conn _id confirmed) (setq sent confirmed))))
      (opencode-pi-reply-permission "u1" "reject" nil)
      (should (null sent)))))

(ert-deftest opencode-pi-reply-question-sends-value ()
  "Answering a Pi question sends the selected value over the conn.
The question popup yields nested answer vectors; the first is the value."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        sent)
    (puthash "u2" 'fake-conn opencode-pi--ui-requests)
    (cl-letf (((symbol-function 'opencode-pi-rpc-ui-reply-value)
               (lambda (conn id value) (setq sent (list conn id value)))))
      (opencode-pi-reply-question "u2" (vector (vector "B")))
      (should (equal '(fake-conn "u2" "B") sent)))))

(ert-deftest opencode-pi-reject-question-cancels ()
  "Rejecting a Pi question cancels the UI request over the conn.
Dismissing the popup must dismiss Pi's dialog, not leave it hanging."
  (let ((opencode-pi--ui-requests (make-hash-table :test 'equal))
        cancelled)
    (puthash "u2" 'fake-conn opencode-pi--ui-requests)
    (cl-letf (((symbol-function 'opencode-pi-rpc-ui-reply-cancel)
               (lambda (conn id) (setq cancelled (list conn id)))))
      (opencode-pi-reject-question "u2" nil)
      (should (equal '(fake-conn "u2") cancelled)))))

;;; --- Runtime event router ---

(ert-deftest opencode-pi-route-agent-start-emits-busy-status ()
  "A Pi agent_start routes to the chat session.status handler as busy.
This drives the chat buffer into its busy streaming phase.  Message
ownership is established by message_start, or lazily by the first delta."
  (let (emits)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional _legacy-event)
                 (push backend-event emits))))
      (opencode-pi--route-event "ses_pi" (list :type "agent_start"))
      (setq emits (nreverse emits))
      (let ((status-emit (seq-find
                          (lambda (e) (equal (plist-get e :type) "session.status"))
                          emits)))
         (should status-emit)
         (should (equal "ses_pi" (plist-get status-emit :session-id)))
         (should (equal "busy"
                        (plist-get (plist-get status-emit :status) :type))))
      (should-not (seq-find
                   (lambda (e) (equal (plist-get e :type) "message.updated"))
                   emits)))))

(ert-deftest opencode-pi-route-agent-end-emits-idle ()
  "A Pi agent_end routes to the chat session.idle handler.
Without this, the chat buffer never leaves the busy state."
  (let (emitted)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional _legacy-event)
                 (setq emitted backend-event))))
      (opencode-pi--route-event "ses_pi" (list :type "agent_end" :messages []))
      (should (equal "session.idle" (plist-get emitted :type)))
      (should (equal "ses_pi" (plist-get emitted :session-id))))))

(ert-deftest opencode-pi-route-agent-end-emits-lifecycle ()
  "A retrying Pi agent_end does not prematurely advance lifecycle consumers."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (setq lifecycle event))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi" (list :type "agent_end" :messages [] :willRetry t))
        (should-not lifecycle)
        (should
         (equal "msg_pipeline"
                (opencode-pi-conn-active-prompt-message-id conn)))))))

(ert-deftest opencode-pi-route-legacy-agent-end-emits-lifecycle ()
  "A legacy Pi agent_end without settling metadata remains terminal."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (setq lifecycle event))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi" (list :type "agent_end" :messages []))
        (should (equal "session.idle" (plist-get lifecycle :type)))
        (should (equal "ses_pi" (plist-get lifecycle :session-id)))
        (should-not
         (opencode-pi-conn-active-prompt-message-id conn))))))

(ert-deftest opencode-pi-route-nonretry-agent-end-preserves-correlation ()
  "Modern Pi agent_end preserves correlation until agent_settled."
  (let ((opencode-pi--conns (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch) #'ignore))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi" '(:type "agent_end" :messages [] :willRetry :false))
        (should
         (equal "msg_pipeline"
                (opencode-pi-conn-active-prompt-message-id conn)))
        (opencode-pi--route-event "ses_pi" '(:type "agent_settled"))
        (should-not
         (opencode-pi-conn-active-prompt-message-id conn))))))

(ert-deftest opencode-pi-route-agent-settled-emits-lifecycle ()
  "Pi agent_settled reaches backend-neutral lifecycle consumers."
  (let (lifecycle)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (setq lifecycle event))))
      (opencode-pi--route-event "ses_pi" (list :type "agent_settled"))
      (should (eq 'pi (plist-get lifecycle :backend)))
      (should (equal "session.idle" (plist-get lifecycle :type)))
      (should (equal "ses_pi" (plist-get lifecycle :session-id))))))

(ert-deftest opencode-pi-route-message-end-emits-correlated-lifecycle ()
  "Pi message_end emits assistant ID, parent correlation, and completion."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (setq lifecycle event))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_user")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 42)))
        (should (equal "message.updated" (plist-get lifecycle :type)))
        (should (equal "msg_user" (plist-get lifecycle :parent-id)))
        (should (equal "assistant" (plist-get lifecycle :role)))
        (should (plist-get lifecycle :message-id))
        (should (eq t (plist-get lifecycle :completed)))))))

(ert-deftest opencode-pi-route-multiple-assistants-get-distinct-ids ()
  "Tool-loop assistants retain distinct IDs under one prompt correlation."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle-events)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (push event lifecycle-events))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_user")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 41)))
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 42)))
        (setq lifecycle-events (nreverse lifecycle-events))
        (should (= 2 (length lifecycle-events)))
        (should-not
         (equal (plist-get (car lifecycle-events) :message-id)
                (plist-get (cadr lifecycle-events) :message-id)))
        (should
         (equal '("msg_user" "msg_user")
                 (mapcar (lambda (event) (plist-get event :parent-id))
                         lifecycle-events)))))))

(ert-deftest opencode-pi-route-retry-preserves-final-assistant-correlation ()
  "A retried assistant remains correlated until authoritative settlement."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle-events)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (push event lifecycle-events))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 1)))
        (opencode-pi--route-event
         "ses_pi" '(:type "agent_end" :messages [] :willRetry t))
        (opencode-pi--route-event "ses_pi" '(:type "agent_start"))
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 2)))
        (setq lifecycle-events
              (seq-filter
               (lambda (event)
                 (and (equal "message.updated" (plist-get event :type))
                      (equal "assistant" (plist-get event :role))
                      (plist-get event :completed)))
               (nreverse lifecycle-events)))
        (should (= 2 (length lifecycle-events)))
        (should
         (equal '("msg_pipeline" "msg_pipeline")
                (mapcar (lambda (event) (plist-get event :parent-id))
                        lifecycle-events)))
        (should-not
         (equal (plist-get (car lifecycle-events) :message-id)
                (plist-get (cadr lifecycle-events) :message-id)))
        (should
         (equal "msg_pipeline"
                (gethash
                 (plist-get (cadr lifecycle-events) :message-id)
                 (opencode-pi-conn-assistant-correlations conn))))
        (opencode-pi--route-event "ses_pi" '(:type "agent_settled"))
        (should-not
         (opencode-pi-conn-active-prompt-message-id conn))))))

(ert-deftest opencode-pi-route-auto-compaction-preserves-correlation ()
  "Auto-compaction continuation keeps one prompt until agent_settled.
Covers agent_end willRetry=false followed by compaction willRetry=true."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        lifecycle-events)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional legacy-event)
                 (opencode-lifecycle--on-backend-event
                  backend-event legacy-event)))
              ((symbol-function 'opencode-lifecycle-emit)
               (lambda (event) (push event lifecycle-events))))
      (let ((conn
             (opencode-pi-conn--create
              :active-prompt-message-id "msg_pipeline")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 1)))
        (opencode-pi--route-event
         "ses_pi" '(:type "agent_end" :messages [] :willRetry :false))
        (should
         (equal "msg_pipeline"
                (opencode-pi-conn-active-prompt-message-id conn)))
        (opencode-pi--route-event "ses_pi" '(:type "compaction_start"))
        (opencode-pi--route-event
         "ses_pi" '(:type "compaction_end" :willRetry t))
        (opencode-pi--route-event "ses_pi" '(:type "agent_start"))
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_end"
           :message (:role "assistant" :timestamp 2)))
        (setq lifecycle-events
              (seq-filter
               (lambda (event)
                 (and (equal "message.updated" (plist-get event :type))
                      (equal "assistant" (plist-get event :role))
                      (plist-get event :completed)))
               (nreverse lifecycle-events)))
        (should (= 2 (length lifecycle-events)))
        (should
         (equal '("msg_pipeline" "msg_pipeline")
                (mapcar (lambda (event) (plist-get event :parent-id))
                        lifecycle-events)))
        (should-not
         (equal (plist-get (car lifecycle-events) :message-id)
                (plist-get (cadr lifecycle-events) :message-id)))
        (opencode-pi--route-event "ses_pi" '(:type "agent_settled"))
        (should-not
         (opencode-pi-conn-active-prompt-message-id conn))))))

(ert-deftest opencode-pi-route-text-delta-emits-part-update ()
  "A text_delta routes to on-part-updated with a delta and a text part.
This is the runtime streaming path into the chat renderer."
  (let (emitted)
    (cl-letf (((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional _legacy-event)
                 (setq emitted backend-event))))
      (opencode-pi--route-event
       "ses_pi"
       (list :type "message_update"
             :assistantMessageEvent
             (list :type "text_delta" :delta "Hi" :partial (list :text "Hi"))))
      (should (equal "message.part.updated" (plist-get emitted :type)))
      (should (equal "Hi" (plist-get emitted :delta)))
      (should (equal "text" (plist-get (plist-get emitted :part) :type))))))

(ert-deftest opencode-pi-route-message-start-delta-end-uses-active-owner ()
  "After message_start, deltas target the active assistant message ID."
  (let ((opencode-pi--conns (make-hash-table :test 'equal))
        events)
    (cl-letf (((symbol-function 'opencode-pi-rpc-alive-p) (lambda (_c) t))
              ((symbol-function 'opencode-event-dispatch)
               (lambda (backend-event &optional _legacy-event)
                 (push backend-event events))))
      (let ((conn (opencode-pi-conn--create
                   :active-prompt-message-id "msg_user")))
        (opencode-pi-bind-conn "ses_pi" conn)
        (opencode-pi--route-event
         "ses_pi"
         '(:type "message_start"
           :message (:role "assistant" :timestamp 42)))
        (let ((active (opencode-pi-conn-active-assistant-message-id conn)))
          (opencode-pi--route-event
           "ses_pi"
           '(:type "message_update"
             :assistantMessageEvent
             (:type "text_delta" :delta "Hi" :partial (:text "Hi"))))
          (opencode-pi--route-event
           "ses_pi"
           '(:type "message_end"
             :message (:role "assistant" :timestamp 42)))
          (setq events (nreverse events))
          (let ((delta (seq-find
                        (lambda (event)
                          (equal "message.part.updated"
                                 (plist-get event :type)))
                        events)))
            (should active)
            (should (equal active (plist-get delta :message-id)))
            (should (string-match-p
                     (regexp-quote active)
                     (plist-get delta :part-id)))))))))

(ert-deftest opencode-pi-session-file-path ()
  "The session file path is <session-dir>/<project>/<id>.jsonl.
Matches Pi's per-working-directory JSONL layout so resume works."
  (let ((opencode-pi-session-dir "/tmp/pisess/"))
    (should (equal "/tmp/pisess/myproj/abc123.jsonl"
                   (opencode-pi--session-file "abc123" "/home/me/myproj/")))))

;;; --- On-disk session enumeration ---

(defmacro opencode-pi-test--with-session-dir (dir-var &rest body)
  "Bind DIR-VAR to a fresh temp Pi session dir and clean up after BODY."
  (declare (indent 1))
  `(let ((,dir-var (make-temp-file "opencode-pi-test" t)))
     (unwind-protect
         (let ((opencode-pi-session-dir (file-name-as-directory ,dir-var)))
           ,@body)
       (delete-directory ,dir-var t))))

(defun opencode-pi-test--write-session (dir name lines)
  "Write a Pi session file NAME under DIR with LINES (list of plists)."
  (let ((file (expand-file-name name dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (dolist (l lines)
        (insert (opencode-util--json-serialize l) "\n")))
    file))

(ert-deftest opencode-pi-session-from-file-prefers-name ()
  "An explicit session_info name wins over the first user message as title.
Lets users see their chosen session names in the picker/sidebar."
  (opencode-pi-test--with-session-dir dir
    (let ((file (opencode-pi-test--write-session
                 dir "proj/s1.jsonl"
                 (list (list :type "session" :version 3 :id "s1"
                             :cwd "/home/me/proj")
                       (list :type "session_info" :name "My Feature")
                       (list :type "message"
                             :message (list :role "user" :content "do stuff"))))))
      (let ((sess (opencode-pi--session-from-file file)))
        (should (equal "My Feature" (plist-get sess :title)))
        (should (equal "/home/me/proj" (plist-get sess :directory)))
        (should (equal "s1" (plist-get sess :id)))))))

(ert-deftest opencode-pi-session-from-file-falls-back-to-first-user ()
  "Without a name, the first user message text becomes the title.
Gives unnamed sessions a recognizable label."
  (opencode-pi-test--with-session-dir dir
    (let ((file (opencode-pi-test--write-session
                 dir "proj/s2.jsonl"
                 (list (list :type "session" :version 3 :id "s2"
                             :cwd "/home/me/proj")
                       (list :type "message"
                             :message (list :role "user"
                                            :content "fix the parser bug"))))))
      (should (equal "fix the parser bug"
                     (plist-get (opencode-pi--session-from-file file) :title))))))

(ert-deftest opencode-pi-list-sessions-enumerates-dir ()
  "`opencode-pi-list-sessions' returns canonical sessions for all jsonl files.
This backs the resume picker and any Pi session listing."
  (opencode-pi-test--with-session-dir dir
    (opencode-pi-test--write-session
     dir "proj/a.jsonl"
     (list (list :type "session" :version 3 :id "a" :cwd "/p")
           (list :type "session_info" :name "Alpha")))
    (opencode-pi-test--write-session
     dir "proj/b.jsonl"
     (list (list :type "session" :version 3 :id "b" :cwd "/p")
           (list :type "session_info" :name "Beta")))
    (let* ((sessions (append (opencode-pi-list-sessions) nil))
           (titles (mapcar (lambda (s) (plist-get s :title)) sessions)))
      (should (= 2 (length sessions)))
      (should (member "Alpha" titles))
      (should (member "Beta" titles)))))

(ert-deftest opencode-pi-list-sessions-empty-when-no-dir ()
  "Listing returns nil when the session dir does not exist.
Guards the picker against a missing ~/.pi tree on first use."
  (let ((opencode-pi-session-dir "/nonexistent/opencode-pi-xyz/"))
    (should (null (opencode-pi-list-sessions)))))

(provide 'opencode-pi-test)
;;; opencode-pi-test.el ends here
