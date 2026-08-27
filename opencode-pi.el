;;; opencode-pi.el --- Pi backend adapter for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Pi backend adapter.  Translates the Pi coding agent's RPC protocol
;; (`opencode-pi-rpc.el') into opencode.el's UI shapes.
;;
;; Pi's data model differs from OpenCode's:
;;
;;   Pi AgentMessage            opencode.el message
;;   ----------------           --------------------
;;   {role:"user",              {info:{id,role:"user",...},
;;    content:string|blocks}     parts:[{type:"text",text}, ...]}
;;
;;   {role:"assistant",         {info:{id,role:"assistant",modelID,
;;    content:[text|thinking|     providerID,tokens,cost,time},
;;            toolCall],          parts:[{type:"text"},
;;    usage, model, ...}                 {type:"reasoning"},
;;                                       {type:"tool",state:{...}}]}
;;
;;   {role:"toolResult",        merged into the matching assistant tool
;;    toolCallId, content,       part's :state (status/output/error)
;;    isError}
;;
;; Pi events (agent_start/agent_end/message_*/tool_execution_*) are mapped to
;; the OpenCode SSE event vocabulary the chat handlers already understand
;; (session.status / session.idle / message.updated / message.part.updated),
;; AND to the canonical `opencode-backend-event' shape.
;;
;; This file holds the PURE normalizers (no I/O).  The adapter command
;; functions and backend registration live further down / in commit 3.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'opencode-util)
(require 'opencode-backend-core)
(require 'opencode-event)
(require 'opencode-pi-rpc)
(require 'opencode-pi-widget)
(require 'opencode-prompt)

(defcustom opencode-pi-session-dir
  (expand-file-name "~/.pi/agent/sessions/")
  "Directory where Pi stores session JSONL files."
  :type 'directory
  :group 'opencode-pi)

(defcustom opencode-pi-steering-mode 'steer
  "How a prompt sent while Pi is generating is queued.
`steer' delivers it after the current turn's tools, before the next LLM
call.  `follow-up' delivers it only after the agent fully stops."
  :type '(choice (const :tag "Steer (redirect now)" steer)
                 (const :tag "Follow-up (after done)" follow-up))
  :group 'opencode-pi)

;;; --- Message-part normalization ---

(defun opencode-pi--content-blocks (content)
  "Normalize Pi message CONTENT to a list of block plists.
Pi `UserMessage.content' may be a string or an array of blocks;
assistant/tool content is always an array.  Returns a list."
  (cond
   ((stringp content)
    (list (list :type "text" :text content)))
   ((vectorp content) (append content nil))
   ((listp content) content)
   (t nil)))

(defun opencode-pi--block->part (block msg-id index)
  "Convert a Pi content BLOCK to an OpenCode-shaped part plist.
MSG-ID and INDEX seed a stable part id.  Returns nil for unknown blocks."
  (let ((type (plist-get block :type))
        (pid (format "%s/p%d" (or msg-id "msg") index)))
    (pcase type
      ("text"
       (list :id pid :type "text" :text (or (plist-get block :text) "")))
      ("thinking"
       (list :id pid :type "reasoning"
             :text (or (plist-get block :thinking) "")))
      ("toolCall"
       (list :id pid :type "tool"
             :tool (plist-get block :name)
             :callID (plist-get block :id)
             :state (list :status "running"
                          :input (plist-get block :arguments))))
      ("image"
       (list :id pid :type "file"
             :mime (plist-get block :mimeType)
             :text "[image]"))
      (_ nil))))

(defun opencode-pi--apply-tool-result (parts tool-result)
  "Fold a Pi TOOL-RESULT message into the matching tool PART in PARTS.
Returns PARTS (mutated in place).  Matches by `toolCallId' == part :callID."
  (let ((call-id (plist-get tool-result :toolCallId))
        (is-error (eq t (plist-get tool-result :isError)))
        (output (opencode-pi--tool-result-text tool-result)))
    (dolist (part parts)
      (when (and (equal (plist-get part :type) "tool")
                 (equal (plist-get part :callID) call-id))
        (let ((state (copy-sequence (or (plist-get part :state) '()))))
          (setq state (plist-put state :status (if is-error "error" "completed")))
          (setq state (plist-put state :output output))
          (when is-error (setq state (plist-put state :error output)))
          (plist-put part :state state))))
    parts))

(defun opencode-pi--tool-result-text (tool-result)
  "Extract a text string from a Pi TOOL-RESULT message's content blocks."
  (let ((blocks (opencode-pi--content-blocks (plist-get tool-result :content))))
    (mapconcat (lambda (b) (or (plist-get b :text) ""))
               (seq-filter (lambda (b) (equal (plist-get b :type) "text")) blocks)
               "")))

;;; --- Message normalization ---

(defun opencode-pi--message-id (message index)
  "Return a stable id for Pi MESSAGE at position INDEX.
Pi messages have no server id.  Prefer role and timestamp so runtime
message lifecycle events and later history fetches derive the same ID;
INDEX is the fallback for messages without timestamps."
  (if-let ((timestamp (plist-get message :timestamp)))
      (format "pimsg-%s-%s"
              (or (plist-get message :role) "x") timestamp)
    (format "pimsg-%d-%s"
            index (or (plist-get message :role) "x"))))

(defun opencode-pi--message (message index &optional correlations)
  "Convert a single Pi MESSAGE (AgentMessage) to an OpenCode-shaped message.
INDEX is the message's position in the conversation.  Returns a plist
{:info ... :parts [...]} suitable for the renderer, or nil for a
toolResult message (folded into the preceding assistant message instead).
CORRELATIONS maps stable assistant IDs to their user message IDs."
  (let* ((role (plist-get message :role))
         (msg-id (opencode-pi--message-id message index))
         (user-message-id (and correlations (gethash msg-id correlations)))
         (ts (plist-get message :timestamp)))
    (pcase role
      ("toolResult" nil)
      ("user"
       (let ((parts (cl-loop for block in (opencode-pi--content-blocks
                                           (plist-get message :content))
                             for i from 0
                             for part = (opencode-pi--block->part block msg-id i)
                             when part collect part)))
         (list :info (list :id msg-id :role "user"
                           :time (list :created ts))
               :parts (vconcat parts))))
      ("assistant"
       (let* ((usage (plist-get message :usage))
              (parts (cl-loop for block in (opencode-pi--content-blocks
                                            (plist-get message :content))
                             for i from 0
                             for part = (opencode-pi--block->part block msg-id i)
                             when part collect part)))
          (list :info (list :id msg-id :role "assistant"
                            :parentID user-message-id
                           :modelID (plist-get message :model)
                           :providerID (plist-get message :provider)
                           :tokens (opencode-pi--usage->tokens usage)
                           :cost (opencode-pi--usage-cost usage)
                           :finish (plist-get message :stopReason)
                           :error-message (plist-get message :errorMessage)
                           :time (list :created ts :completed ts))
               :parts (vconcat parts))))
      (_ nil))))

(defun opencode-pi--usage->tokens (usage)
  "Convert a Pi USAGE plist to an OpenCode-shaped tokens plist."
  (when usage
    (list :input (or (plist-get usage :input) 0)
          :output (or (plist-get usage :output) 0)
          :reasoning 0
          :total (or (plist-get usage :totalTokens)
                     (+ (or (plist-get usage :input) 0)
                        (or (plist-get usage :output) 0)))
          :cache (list :read (or (plist-get usage :cacheRead) 0)
                       :write (or (plist-get usage :cacheWrite) 0)))))

(defun opencode-pi--usage-cost (usage)
  "Return the total cost from a Pi USAGE plist, or 0."
  (or (plist-get (plist-get usage :cost) :total) 0))

(defun opencode-pi--messages (messages &optional correlations)
  "Convert a Pi MESSAGES vector/list to OpenCode-shaped messages.
ToolResult messages are folded into the preceding assistant message's
matching tool part; user/assistant messages become {:info :parts} plists.
CORRELATIONS maps stable assistant IDs to their user message IDs."
  (let* ((seq (if (vectorp messages) (append messages nil) messages))
         (out nil)
         (index 0))
    (dolist (m seq)
      (if (equal (plist-get m :role) "toolResult")
          (when out
            (let* ((last (car out))
                   (parts (append (plist-get last :parts) nil)))
              (opencode-pi--apply-tool-result parts m)
              (plist-put last :parts (vconcat parts))))
        (when-let* ((norm
                     (opencode-pi--message
                      m index correlations)))
          (push norm out)))
      (setq index (1+ index)))
    (vconcat (nreverse out))))

;;; --- Event normalization ---

(defun opencode-pi--assistant-event-part-type (ae)
  "Return the OpenCode part type implied by Pi assistant-message-event AE."
  (pcase (plist-get ae :type)
    ((or "text_start" "text_delta" "text_end") "text")
    ((or "thinking_start" "thinking_delta" "thinking_end") "reasoning")
    ((or "toolcall_start" "toolcall_delta" "toolcall_end") "tool")
    (_ "text")))

(defun opencode-pi--event (raw &optional session-id)
  "Convert Pi RPC event RAW into one canonical backend event.
SESSION-ID identifies the connection and enables turn correlation.
Return nil for modern `agent_end' events, whose authoritative terminal
boundary is the later `agent_settled' event."
  (let ((type (plist-get raw :type)))
    (pcase type
      ("agent_start"
       (opencode-backend-event
        :type "session.status" :backend 'pi :session-id session-id
        :status (list :type "busy") :raw raw))
      ("agent_end"
       (unless (plist-member raw :willRetry)
         (opencode-backend-event
          :type "session.idle" :backend 'pi :session-id session-id :raw raw)))
      ("agent_settled"
       (opencode-backend-event
        :type "session.idle" :backend 'pi :session-id session-id :raw raw))
      ("message_update"
       (let* ((assistant-event (plist-get raw :assistantMessageEvent))
              (part-type
               (opencode-pi--assistant-event-part-type assistant-event))
              (message-id
               (and session-id
                    (opencode-pi--active-assistant-message-id session-id)))
              (part-id
               (and message-id
                    (format "%s/stream-%s" message-id part-type))))
         (opencode-backend-event
          :type "message.part.updated"
          :backend 'pi
          :session-id session-id
          :message-id message-id
          :part-id part-id
          :delta (plist-get assistant-event :delta)
          :part
          (list :id part-id
                :message-id message-id
                :session-id session-id
                :type part-type
                :text (plist-get (plist-get assistant-event :partial) :text)
                :time (list :start 0))
          :raw raw)))
      ((or "message_start" "message_end")
       (let* ((completed (equal type "message_end"))
              (info (opencode-pi--message-info session-id raw completed)))
         (opencode-backend-event
          :type "message.updated"
          :backend 'pi
          :session-id session-id
          :message-id (plist-get info :id)
          :message
          (list :id (plist-get info :id)
                :session-id session-id
                :parent-id (plist-get info :parentID)
                :role (plist-get info :role)
                :created-at (plist-get (plist-get info :time) :created)
                :completed-at (plist-get (plist-get info :time) :completed)
                :raw info)
          :raw raw)))
      ((or "tool_execution_start" "tool_execution_update"
           "tool_execution_end")
       (let* ((message-id
               (and session-id
                    (opencode-pi--active-assistant-message-id session-id)))
              (part-id (plist-get raw :toolCallId))
              (status
               (pcase type
                 ((or "tool_execution_start" "tool_execution_update")
                  "running")
                 ("tool_execution_end"
                  (if (eq t (plist-get raw :isError))
                      "error"
                    "completed")))))
         (opencode-backend-event
          :type "message.part.updated"
          :backend 'pi
          :session-id session-id
          :message-id message-id
          :part-id part-id
          :status status
          :part
          (list :id part-id
                :message-id message-id
                :session-id session-id
                :type "tool"
                :tool (plist-get raw :toolName)
                :tool-call-id part-id
                :state (list :status status))
          :raw raw)))
      ("turn_end"
       (opencode-backend-event
        :type "message.updated"
        :backend 'pi
        :session-id session-id
        :message (list :session-id session-id)
        :raw raw))
      ((or "compaction_start" "compaction_end")
       (opencode-backend-event
        :type "session.compacted"
        :backend 'pi
        :session-id session-id
        :raw raw))
      ("extension_error"
       (opencode-backend-event
        :type "session.error"
        :backend 'pi
        :session-id session-id
        :error (list :message (or (plist-get raw :error) "extension error"))
        :raw raw))
      (_
       (opencode-backend-event
        :type type :backend 'pi :session-id session-id :raw raw)))))

;;; --- Connection registry ---
;;
;; Pi is one subprocess per session.  The adapter keys live connections by the
;; session id so facade ops (which receive only a session-id string) can find
;; the right conn.  `opencode-pi-bind-conn' is called by the chat layer when it
;; starts a session; `opencode-pi-conn-for' resolves it back.

(defvar opencode-pi--conns (make-hash-table :test 'equal)
  "Map of Pi session-id -> `opencode-pi-conn'.")

(defun opencode-pi--enqueue-prompt (conn message-id busy)
  "Record MESSAGE-ID as turn-scoped correlation state on CONN.
When BUSY is non-nil in steer mode, the prompt modifies the active turn and
must not steal its correlation.  Follow-up prompts queue for a later turn."
  (when message-id
    (cond
     ((and busy (eq opencode-pi-steering-mode 'steer))
      nil)
     ((and busy (eq opencode-pi-steering-mode 'follow-up))
      (setf (opencode-pi-conn-pending-prompt-message-ids conn)
            (append (opencode-pi-conn-pending-prompt-message-ids conn)
                    (list message-id))))
     (t
      (setf (opencode-pi-conn-pending-prompt-message-ids conn)
            (append (opencode-pi-conn-pending-prompt-message-ids conn)
                    (list message-id)))))))

(defun opencode-pi--activate-prompt (conn)
  "Promote CONN's next pending prompt to the active Pi turn."
  (unless (opencode-pi-conn-active-prompt-message-id conn)
    (let ((pending (opencode-pi-conn-pending-prompt-message-ids conn)))
      (when pending
        (setf (opencode-pi-conn-active-prompt-message-id conn) (car pending)
              (opencode-pi-conn-pending-prompt-message-ids conn)
              (cdr pending)))))
  (opencode-pi-conn-active-prompt-message-id conn))

(defun opencode-pi--assistant-message-id (session-id message)
  "Return a stable assistant ID for SESSION-ID and Pi MESSAGE."
  (ignore session-id)
  (opencode-pi--message-id message 0))

(defun opencode-pi--message-info (session-id raw completed)
  "Return OpenCode-shaped info for Pi message event RAW.
SESSION-ID locates turn state.  COMPLETED marks message_end events."
  (let* ((conn (opencode-pi-conn-for session-id))
         (message (or (plist-get raw :message) '()))
         (role (plist-get message :role))
         (user-message-id
          (and conn
               (equal role "assistant")
               (or (opencode-pi-conn-active-prompt-message-id conn)
                   (opencode-pi--activate-prompt conn))))
         (message-id
          (if (equal role "assistant")
              (or (and conn
                       (opencode-pi-conn-active-assistant-message-id conn))
                  (opencode-pi--assistant-message-id session-id message))
            (opencode-pi--assistant-message-id session-id message)))
         (timestamp (or (plist-get message :timestamp)
                        (floor (* (float-time) 1000)))))
    (when (and conn (equal role "assistant"))
      (setf (opencode-pi-conn-active-assistant-message-id conn) message-id)
      (when (and completed user-message-id)
        (puthash message-id user-message-id
                 (opencode-pi-conn-assistant-correlations conn))))
    (list :id message-id
          :sessionID session-id
          :role role
          :parentID user-message-id
          :time (append (list :created timestamp)
                        (when completed (list :completed timestamp))))))

(defun opencode-pi--finish-turn (session-id)
  "Clear active turn state for Pi SESSION-ID after idle."
  (when-let ((conn (opencode-pi-conn-for session-id)))
    (setf (opencode-pi-conn-active-prompt-message-id conn) nil
          (opencode-pi-conn-active-assistant-message-id conn) nil)))

(defun opencode-pi--finish-assistant-message (session-id)
  "Clear SESSION-ID's active assistant after one finalized message.
One Pi agent run can contain several assistant messages separated by tool
results.  The prompt remains active for the whole run, but each assistant
must retain its own stable ID so a final-output consumer can correlate the
last assistant rather than an earlier tool-call message."
  (when-let ((conn (opencode-pi-conn-for session-id)))
    (setf (opencode-pi-conn-active-assistant-message-id conn) nil)))

(defun opencode-pi-bind-conn (session-id conn)
  "Register CONN under SESSION-ID for later facade-op resolution."
  (puthash session-id conn opencode-pi--conns)
  (setf (opencode-pi-conn-session-id conn) session-id)
  conn)

(defun opencode-pi-unbind-conn (session-id)
  "Forget the connection bound to SESSION-ID."
  (remhash session-id opencode-pi--conns))

(defun opencode-pi-conn-for (session-id)
  "Return the live conn bound to SESSION-ID, or nil.
Dead connections are auto-unbound."
  (let ((conn (gethash session-id opencode-pi--conns)))
    (cond
     ((null conn) nil)
     ((opencode-pi-rpc-alive-p conn) conn)
     (t (opencode-pi-unbind-conn session-id) nil))))

(defun opencode-pi--require-conn (session-id)
  "Return the live conn for SESSION-ID or signal a user error."
  (or (opencode-pi-conn-for session-id)
      (user-error "No live Pi session for %s" session-id)))

;;; --- Adapter command functions ---

(defun opencode-pi--intent-images (intent)
  "Translate canonical prompt INTENT images into Pi image blocks."
  (let (images)
    (dolist (image (opencode-prompt-intent-images intent))
      (when-let* ((decoded (opencode-prompt-image-data image)))
        (push (list :type "image"
                    :data (plist-get decoded :data)
                    :mimeType (or (plist-get decoded :mime-type)
                                  (plist-get image :mime)))
              images)))
    (when images
      (vconcat (nreverse images)))))

(defun opencode-pi-send-prompt (session-id intent callback &optional busy)
  "Send prompt INTENT to the Pi session SESSION-ID.
When BUSY is non-nil the message is queued per `opencode-pi-steering-mode'
\(steer or follow_up); otherwise it is a fresh prompt.  CALLBACK receives
  the RPC response plist."
  (let* ((conn (opencode-pi--require-conn session-id))
         (message (opencode-prompt-intent-text intent))
         (images (opencode-pi--intent-images intent))
         (cmd (cond
                ((not busy)
                 (append (list :type "prompt" :message message)
                        (when images (list :images images))))
               ((eq opencode-pi-steering-mode 'follow-up)
                (append (list :type "follow_up" :message message)
                        (when images (list :images images))))
               (t
                 (append (list :type "prompt" :message message
                               :streamingBehavior "steer")
                         (when images (list :images images)))))))
    (opencode-pi--enqueue-prompt
     conn (opencode-prompt-intent-message-id intent) busy)
    (opencode-pi-rpc-send conn cmd callback)))

(defun opencode-pi-execute-command
    (session-id command arguments agent model variant callback &optional busy)
  "Execute slash COMMAND in Pi SESSION-ID as a canonical prompt.
ARGUMENTS is appended after the command name.  AGENT, MODEL, and VARIANT are
accepted for backend interface parity; Pi manages those values on its live
connection."
  (ignore agent model variant)
  (opencode-pi-send-prompt
   session-id
   (opencode-prompt-intent-create
    :text (concat "/" command
                  (if (and arguments
                           (not (string-empty-p arguments)))
                      (concat " " arguments)
                    "")))
   callback busy))

(defun opencode-pi-abort (session-id &optional callback)
  "Abort the current Pi operation for SESSION-ID."
  (when-let* ((conn (opencode-pi-conn-for session-id)))
    (opencode-pi-rpc-send conn (list :type "abort") callback)))

(defun opencode-pi-get-messages (session-id callback &optional _query-params)
  "Fetch and normalize messages for Pi SESSION-ID, then call CALLBACK."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-send
     conn (list :type "get_messages")
     (lambda (resp)
        (funcall callback
                 (opencode-pi--messages
                  (plist-get (plist-get resp :data) :messages)
                  (opencode-pi-conn-assistant-correlations conn)))))))

(defun opencode-pi-get-messages-sync (session-id &optional _query-params)
  "Return normalized messages for Pi SESSION-ID synchronously."
  (let* ((conn (opencode-pi--require-conn session-id))
         (resp (opencode-pi-rpc-request-sync conn (list :type "get_messages"))))
    (opencode-pi--messages
     (plist-get (plist-get resp :data) :messages)
     (opencode-pi-conn-assistant-correlations conn))))

(defun opencode-pi--state->session (session-id state conn)
  "Synthesize a canonical session plist for SESSION-ID from RPC STATE and CONN."
  (opencode-backend-session
   :id session-id
   :title (or (plist-get state :sessionName) session-id)
   :directory (or (opencode-pi-conn-cwd conn)
                  (plist-get state :cwd))
   :raw state))

(defun opencode-pi-get-session (session-id callback &optional _backend)
  "Fetch Pi SESSION-ID state and call CALLBACK with a canonical session."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-send
     conn (list :type "get_state")
     (lambda (resp)
       (funcall callback
                 (opencode-pi--state->session
                  session-id (plist-get resp :data) conn))))))

(defun opencode-pi-get-session-sync (session-id &optional _backend)
  "Return a canonical session for Pi SESSION-ID synchronously."
  (let* ((conn (opencode-pi--require-conn session-id))
         (resp (opencode-pi-rpc-request-sync conn (list :type "get_state"))))
    (opencode-pi--state->session session-id (plist-get resp :data) conn)))

(defun opencode-pi-rename-session (session-id title &optional _backend)
  "Set the display name of Pi SESSION-ID to TITLE."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-request-sync
     conn (list :type "set_session_name" :name title))))

(defun opencode-pi-compact-session (session-id &optional _model _provider _backend)
  "Compact the Pi SESSION-ID conversation context."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-send conn (list :type "compact"))))

(defun opencode-pi-list-models (callback &optional _backend)
  "List available Pi models for the current session via CALLBACK.
Resolves against any live conn (model lists are process-global in Pi)."
  (let ((conn (opencode-pi--any-conn)))
    (when conn
      (opencode-pi-rpc-send
       conn (list :type "get_available_models")
       (lambda (resp)
         (funcall callback (plist-get (plist-get resp :data) :models)))))))

(defun opencode-pi-set-model (session-id provider-id model-id &optional _backend)
  "Switch Pi SESSION-ID to PROVIDER-ID / MODEL-ID."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-request-sync
     conn (list :type "set_model" :provider provider-id :modelId model-id))))

(defun opencode-pi--any-conn ()
  "Return any live Pi conn, or nil."
  (catch 'found
    (maphash (lambda (_id conn)
               (when (opencode-pi-rpc-alive-p conn)
                 (throw 'found conn)))
             opencode-pi--conns)
    nil))

;;; --- Extension UI bridge ---
;;
;; Pi has no permission/question API.  Approval prompts arrive as
;; `extension_ui_request' events on the conn stdout (method confirm/select/
;; input/editor) and are answered with `extension_ui_response' on stdin.
;;
;; Inbound:  a UI request is synthesized into an OpenCode-shaped permission or
;;           question request and pushed into the existing popup pipeline.
;; Outbound: the popup reply is routed back over the originating conn via the
;;           registered `reply-permission-fn' / `reply-question-fn'.
;;
;; A pending map (ui-request-id -> conn) lets the reply find its conn, since the
;; popup layer only knows the request id.

(defvar opencode-pi--ui-requests (make-hash-table :test 'equal)
  "Map of extension-UI request id -> `opencode-pi-conn' awaiting a reply.")

(defun opencode-pi-handle-ui-request (conn session-id req)
  "Route a Pi extension UI REQ from CONN for SESSION-ID.
CONFIRM maps to the permission popup; SELECT/INPUT/EDITOR map to the
question popup (all reply via `extension_ui_response').  The fire-and-forget
methods setWidget/setStatus/setTitle/notify drive the widget surface (used
by extensions like `/btw') and send no reply.  The request id is remembered
only for the reply-bearing methods so the reply can reach CONN."
  (let ((id (plist-get req :id))
        (method (plist-get req :method)))
    (pcase method
      ("confirm"
       (puthash id conn opencode-pi--ui-requests)
       (opencode-event-dispatch
         (opencode-backend-event
          :type "permission.asked"
          :backend 'pi
          :session-id session-id
          :request-id id
          :request
          (list :id id :sessionID session-id
                :permission (or (plist-get req :title) "confirm")
                :patterns (when (plist-get req :message)
                            (vector (plist-get req :message))))
          :raw req)))
      ((or "select" "input" "editor")
       (puthash id conn opencode-pi--ui-requests)
       (opencode-event-dispatch
         (opencode-backend-event
          :type "question.asked"
          :backend 'pi
          :session-id session-id
          :request-id id
          :request
          (list :id id :sessionID session-id
                :questions
                (vector
                 (list :header (or (plist-get req :title) "Input")
                       :question (or (plist-get req :title)
                                     (plist-get req :placeholder) "")
                       :options (when (equal method "select")
                                  (plist-get req :options))
                       :custom (not (equal method "select")))))
          :raw req)))
      ;; --- Fire-and-forget widget surface (no reply) ---
      ("setWidget"
       (opencode-pi-widget-set session-id
                               (plist-get req :widgetKey)
                               (plist-get req :widgetLines)
                               (plist-get req :widgetPlacement)))
      ("setStatus"
       (opencode-pi-widget-status session-id
                                  (plist-get req :statusKey)
                                  (plist-get req :statusText)))
      ("setTitle" nil)
      ("notify"
       (message "%s" (or (plist-get req :message) "")))
      ("set_editor_text" nil)
      (_ nil))))

(defun opencode-pi-reply-permission (id choice _message &optional _backend)
  "Answer a Pi confirm UI request ID from a permission popup CHOICE.
CHOICE is the permission popup's reply (once/always/reject).  Maps to a
confirm/deny `extension_ui_response' over the originating conn."
  (when-let* ((conn (gethash id opencode-pi--ui-requests)))
    (remhash id opencode-pi--ui-requests)
    (let ((confirmed (member choice '("once" "always"))))
      (opencode-pi-rpc-ui-reply-confirm conn id (and confirmed t)))))

(defun opencode-pi-reply-question (id answers &optional _backend)
  "Answer a Pi select/input UI request ID from a question popup.
ANSWERS is the popup's answer vector; the first answer becomes the
`value' in the `extension_ui_response'."
  (when-let* ((conn (gethash id opencode-pi--ui-requests)))
    (remhash id opencode-pi--ui-requests)
    (let* ((flat (cond ((vectorp answers) (append answers nil))
                       ((listp answers) answers)
                       (t (list answers))))
           (first (car flat))
           (value (cond ((stringp first) first)
                        ((vectorp first) (and (> (length first) 0) (aref first 0)))
                        ((listp first) (car first))
                        (t (format "%s" first)))))
      (if value
          (opencode-pi-rpc-ui-reply-value conn id value)
        (opencode-pi-rpc-ui-reply-cancel conn id)))))

(defun opencode-pi-reject-question (id _message &optional _backend)
  "Cancel a Pi UI request ID (question popup rejected)."
  (when-let* ((conn (gethash id opencode-pi--ui-requests)))
    (remhash id opencode-pi--ui-requests)
    (opencode-pi-rpc-ui-reply-cancel conn id)))

;;; --- Runtime event router (Pi event -> canonical router) ---
;;
;; Runtime Pi events are adapted to canonical backend events and handed to the
;; central event router.  The router performs canonical→legacy conversion for
;; existing chat/popup/sidebar handlers.

(defun opencode-pi--active-assistant-message-id (session-id)
  "Return SESSION-ID's active assistant message id, or the bootstrap fallback."
  (or (when-let ((conn (opencode-pi-conn-for session-id)))
        (opencode-pi-conn-active-assistant-message-id conn))
      (format "%s/asst" session-id)))

(defun opencode-pi--route-event (session-id raw)
  "Route a raw Pi event RAW for SESSION-ID through canonical dispatch."
  (let ((type (plist-get raw :type)))
    (when (equal type "agent_start")
      (when-let ((conn (opencode-pi-conn-for session-id)))
        (opencode-pi--activate-prompt conn)))
    (when-let ((event (opencode-pi--event raw session-id)))
      (opencode-event-dispatch event))
    (pcase type
      ("agent_end"
       (unless (plist-member raw :willRetry)
         (opencode-pi--finish-turn session-id)))
      ("agent_settled"
       (opencode-pi--finish-turn session-id))
      ("message_end"
       (when (equal (plist-get (plist-get raw :message) :role) "assistant")
         (opencode-pi--finish-assistant-message session-id))))))

;;; --- Session lifecycle / entry point ---

(declare-function opencode-chat-open "opencode-chat"
                  (session-id &optional directory display-action backend))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

(defun opencode-pi--session-file (session-id directory)
  "Return the JSONL session file path for SESSION-ID under DIRECTORY's tree."
  (let ((dir (expand-file-name
              (file-name-as-directory
               (file-name-nondirectory (directory-file-name directory)))
              opencode-pi-session-dir)))
    (expand-file-name (concat session-id ".jsonl") dir)))

;;; --- On-disk session enumeration (sidebar / resume picker) ---

(defun opencode-pi--read-jsonl-head (file max-lines)
  "Read up to MAX-LINES parsed JSON objects from the head of FILE.
Returns a list of plists, oldest first.  Ignores unparseable lines."
  (let (objs (n 0))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file nil 0 65536)
        (goto-char (point-min))
        (while (and (< n max-lines) (not (eobp)))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p (string-trim line))
              (condition-case err
                  (push (opencode--json-parse line) objs)
                (error
                 (opencode--debug
                  "opencode-pi: skipping malformed JSONL line in %s: %s"
                  file (error-message-string err))))
              (setq n (1+ n))))
          (forward-line 1))))
    (nreverse objs)))

(defun opencode-pi--session-from-file (file)
  "Build a canonical session plist for a Pi session FILE, or nil.
Title preference: explicit session_info name > first user message text >
file base name.  Directory comes from the session header `cwd'."
  (let* ((head (opencode-pi--read-jsonl-head file 12))
         (header (seq-find (lambda (o) (equal (plist-get o :type) "session")) head))
         (info (seq-find (lambda (o) (equal (plist-get o :type) "session_info")) head))
         (first-user
          (seq-find
           (lambda (o)
             (and (equal (plist-get o :type) "message")
                  (equal (plist-get (plist-get o :message) :role) "user")))
           head))
         (id (file-name-base file))
         (title
          (or (plist-get info :name)
              (let ((c (plist-get (plist-get first-user :message) :content)))
                (when (stringp c) (opencode--truncate-string c 60)))
              id)))
    (when header
      (opencode-backend-session
       :id id
       :title title
       :directory (plist-get header :cwd)
       :updated-at (let ((attrs (file-attributes file)))
                     (and attrs (float-time (file-attribute-modification-time attrs))))
       :raw (list :file file :header header)))))

(defun opencode-pi-list-sessions (&optional _query-params)
  "Return canonical Pi sessions found on disk, newest first.
Enumerates `opencode-pi-session-dir' for *.jsonl files."
  (when (file-directory-p opencode-pi-session-dir)
    (let* ((files (directory-files-recursively opencode-pi-session-dir "\\.jsonl\\'"))
           (sessions (delq nil (mapcar #'opencode-pi--session-from-file files))))
      (vconcat
       (sort sessions
             (lambda (a b)
               (> (or (plist-get a :updated-at) 0)
                  (or (plist-get b :updated-at) 0))))))))

;;;###autoload
(defun opencode-pi (&optional directory)
  "Start or resume a Pi coding-agent session and open a chat buffer.
DIRECTORY is the project root (defaults to the current project or
`default-directory').  Offers existing on-disk sessions plus a \"New
session\" option.  Spawns `pi --mode rpc' (resuming the chosen session
file when applicable), learns the Pi session id, wires event and UI
handlers, then opens the chat buffer bound to the `pi' backend."
  (interactive)
  (let* ((directory (or directory
                         (when (fboundp 'project-current)
                           (when-let* ((proj (project-current)))
                             (project-root proj)))
                         default-directory))
         (choice (opencode-pi--read-session))
         (session (and (consp choice) (cdr choice)))
         (session-file (and session (plist-get session :file)))
         (session-directory (and session (plist-get session :directory))))
    (opencode-pi--launch (or session-directory directory) session-file)))

(defun opencode-pi--read-session ()
  "Prompt for a Pi session to resume, or `new'.
Returns `new' or a cons (TITLE . SESSION-PLIST)."
  (let* ((sessions (append (opencode-pi-list-sessions) nil))
         (alist (mapcar (lambda (s)
                          (cons (format "%s  [%s]"
                                        (plist-get s :title)
                                        (plist-get s :id))
                                s))
                        sessions))
         (new-label "★ New session")
         (keys (cons new-label (mapcar #'car alist)))
         (pick (completing-read "Pi session: " keys nil t)))
    (if (equal pick new-label)
        'new
      (let ((s (cdr (assoc pick alist))))
        (cons pick
              (list :file (plist-get (plist-get s :raw) :file)
                    :directory (plist-get s :directory)))))))

(defun opencode-pi--launch (directory &optional session-file)
  "Spawn a Pi RPC subprocess in DIRECTORY and open its chat buffer.
When SESSION-FILE is non-nil, resume that session via `--session'."
  (let* ((args (when session-file (list "--session" session-file)))
         (conn (opencode-pi-rpc-start directory :args args))
         (state (plist-get
                 (opencode-pi-rpc-request-sync conn (list :type "get_state"))
                 :data))
         (session-id (or (plist-get state :sessionId)
                         (format "pi-%d" (floor (float-time))))))
    (opencode-pi-bind-conn session-id conn)
    (setf (opencode-pi-conn-event-handler conn)
          (lambda (raw) (opencode-pi--route-event session-id raw)))
    (setf (opencode-pi-conn-ui-handler conn)
          (lambda (req) (opencode-pi-handle-ui-request conn session-id req)))
    (setf (opencode-pi-conn-exit-handler conn)
          (lambda ()
            (opencode-pi-unbind-conn session-id)
            (opencode-pi-widget-cleanup session-id)))
    (opencode-chat-open session-id (opencode-pi-conn-cwd conn) nil 'pi)
    session-id))

;;; --- Backend registration ---
;;
;; Capabilities deliberately omit diffs, todos, permissions(list),
;; questions(list), and share/revert: Pi has no equivalent.  The UI gates on
;; `opencode-backend-capable-p', and unset `*-fn' slots already no-op.

(opencode-backend-register
 (opencode-backend-create
  :name 'pi
  :capabilities '(sessions messages streaming tools models permissions questions)
  :connected-p-fn nil
  :list-sessions-fn #'opencode-pi-list-sessions
  :send-prompt-fn #'opencode-pi-send-prompt
  :execute-command-fn #'opencode-pi-execute-command
  :abort-session-fn #'opencode-pi-abort
  :get-messages-fn #'opencode-pi-get-messages
  :get-messages-sync-fn #'opencode-pi-get-messages-sync
  :get-session-fn #'opencode-pi-get-session
  :get-session-sync-fn #'opencode-pi-get-session-sync
  :rename-session-fn #'opencode-pi-rename-session
  :compact-session-fn #'opencode-pi-compact-session
  :list-models-fn #'opencode-pi-list-models
  :set-model-fn #'opencode-pi-set-model
  :reply-permission-fn #'opencode-pi-reply-permission
  :reply-question-fn #'opencode-pi-reply-question
  :reject-question-fn #'opencode-pi-reject-question
  :event-adapter #'opencode-pi--event))

(provide 'opencode-pi)
;;; opencode-pi.el ends here
