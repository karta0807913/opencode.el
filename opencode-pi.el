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
(require 'subr-x)
(require 'opencode-util)
(require 'opencode-backend)
(require 'opencode-pi-rpc)
(require 'opencode-pi-widget)

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
Pi messages have no server id; synthesize a deterministic one from role,
timestamp, and INDEX so re-renders are stable."
  (format "pimsg-%d-%s-%s"
          index
          (or (plist-get message :role) "x")
          (or (plist-get message :timestamp) 0)))

(defun opencode-pi--message (message index)
  "Convert a single Pi MESSAGE (AgentMessage) to an OpenCode-shaped message.
INDEX is the message's position in the conversation.  Returns a plist
{:info ... :parts [...]} suitable for the renderer, or nil for a
toolResult message (folded into the preceding assistant message instead)."
  (let* ((role (plist-get message :role))
         (msg-id (opencode-pi--message-id message index))
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

(defun opencode-pi--messages (messages)
  "Convert a Pi MESSAGES vector/list to OpenCode-shaped messages.
ToolResult messages are folded into the preceding assistant message's
matching tool part; user/assistant messages become {:info :parts} plists."
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
        (when-let* ((norm (opencode-pi--message m index)))
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

(defun opencode-pi--event (raw)
  "Convert a Pi RPC event RAW (plist) into a canonical `opencode-backend-event'.
Maps Pi's agent/message/tool lifecycle to OpenCode-equivalent `:type'
strings so the existing chat handlers can consume the canonical event.

Returns nil for events that have no UI effect."
  (let ((type (plist-get raw :type)))
    (pcase type
      ("agent_start"
       (opencode-backend-event :type "session.status"
                               :status (list :type "busy")
                               :raw raw))
      ("agent_end"
       (opencode-backend-event :type "session.idle" :raw raw))
      ("message_update"
       (let* ((ae (plist-get raw :assistantMessageEvent))
              (delta (plist-get ae :delta)))
         (opencode-backend-event
          :type "message.part.updated"
          :delta delta
          :part (list :type (opencode-pi--assistant-event-part-type ae)
                      :text (plist-get (plist-get ae :partial) :text))
          :raw raw)))
      ("message_start"
       (opencode-backend-event :type "message.updated"
                               :message (plist-get raw :message)
                               :raw raw))
      ("message_end"
       (opencode-backend-event :type "message.updated"
                               :message (plist-get raw :message)
                               :raw raw))
      ((or "tool_execution_start" "tool_execution_update" "tool_execution_end")
       (opencode-backend-event
        :type "message.part.updated"
        :part-id (plist-get raw :toolCallId)
        :part (list :type "tool"
                    :tool (plist-get raw :toolName)
                    :callID (plist-get raw :toolCallId))
        :status (pcase type
                  ("tool_execution_start" "running")
                  ("tool_execution_update" "running")
                  ("tool_execution_end"
                   (if (eq t (plist-get raw :isError)) "error" "completed")))
        :raw raw))
      ((or "compaction_start" "compaction_end")
       (opencode-backend-event :type "session.compacted" :raw raw))
      ("extension_error"
       (opencode-backend-event :type "session.error"
                               :error (plist-get raw :error)
                               :raw raw))
      (_ (opencode-backend-event :type type :raw raw)))))

;;; --- Connection registry ---
;;
;; Pi is one subprocess per session.  The adapter keys live connections by the
;; session id so facade ops (which receive only a session-id string) can find
;; the right conn.  `opencode-pi-bind-conn' is called by the chat layer when it
;; starts a session; `opencode-pi-conn-for' resolves it back.

(defvar opencode-pi--conns (make-hash-table :test 'equal)
  "Map of Pi session-id -> `opencode-pi-conn'.")

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

;;; --- Prompt body translation ---

(defun opencode-pi--body->message (body)
  "Extract the prompt text from an OpenCode-shaped prompt BODY plist.
BODY has :parts, a vector of {:type \"text\" :text ...}.  Returns the
concatenated text of the text parts."
  (let ((parts (append (plist-get body :parts) nil)))
    (mapconcat (lambda (p) (or (plist-get p :text) ""))
               (seq-filter (lambda (p) (equal (plist-get p :type) "text")) parts)
               "")))

(defun opencode-pi--body->images (body)
  "Extract Pi image blocks from an OpenCode-shaped prompt BODY, or nil.
OpenCode image parts carry :source {:data ...}; Pi wants
{type:image,data,mimeType}."
  (let ((parts (append (plist-get body :parts) nil))
        images)
    (dolist (p parts)
      (when (equal (plist-get p :type) "image")
        (let ((src (plist-get p :source)))
          (push (list :type "image"
                      :data (plist-get src :data)
                      :mimeType (or (plist-get src :mediaType)
                                    (plist-get p :mime)))
                images))))
    (when images (vconcat (nreverse images)))))

;;; --- Adapter command functions ---

(defun opencode-pi-send-prompt (session-id body callback &optional busy)
  "Send prompt BODY to the Pi session SESSION-ID.
When BUSY is non-nil the message is queued per `opencode-pi-steering-mode'
\(steer or follow_up); otherwise it is a fresh prompt.  CALLBACK receives
the RPC response plist."
  (let* ((conn (opencode-pi--require-conn session-id))
         (message (opencode-pi--body->message body))
         (images (opencode-pi--body->images body))
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
    (opencode-pi-rpc-send conn cmd callback)))

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
                 (plist-get (plist-get resp :data) :messages)))))))

(defun opencode-pi-get-messages-sync (session-id &optional _query-params)
  "Return normalized messages for Pi SESSION-ID synchronously."
  (let* ((conn (opencode-pi--require-conn session-id))
         (resp (opencode-pi-rpc-request-sync conn (list :type "get_messages"))))
    (opencode-pi--messages (plist-get (plist-get resp :data) :messages))))

(defun opencode-pi--state->session (session-id state)
  "Synthesize a canonical session plist for SESSION-ID from RPC STATE."
  (opencode-backend-session
   :id session-id
   :title (or (plist-get state :sessionName) session-id)
   :directory default-directory
   :raw state))

(defun opencode-pi-get-session (session-id callback &optional _backend)
  "Fetch Pi SESSION-ID state and call CALLBACK with a canonical session."
  (let ((conn (opencode-pi--require-conn session-id)))
    (opencode-pi-rpc-send
     conn (list :type "get_state")
     (lambda (resp)
       (funcall callback
                (opencode-pi--state->session
                 session-id (plist-get resp :data)))))))

(defun opencode-pi-get-session-sync (session-id &optional _backend)
  "Return a canonical session for Pi SESSION-ID synchronously."
  (let* ((conn (opencode-pi--require-conn session-id))
         (resp (opencode-pi-rpc-request-sync conn (list :type "get_state"))))
    (opencode-pi--state->session session-id (plist-get resp :data))))

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

(declare-function opencode-permission--on-asked "opencode-permission" (event))
(declare-function opencode-question--on-asked "opencode-question" (event))
(declare-function opencode--dispatch-to-chat-buffer "opencode" (session-id handler event))

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
       (opencode-pi--dispatch-popup
        session-id #'opencode-permission--on-asked
        (list :id id :sessionID session-id
              :permission (or (plist-get req :title) "confirm")
              :patterns (when (plist-get req :message)
                          (vector (plist-get req :message))))))
      ((or "select" "input" "editor")
       (puthash id conn opencode-pi--ui-requests)
       (opencode-pi--dispatch-popup
        session-id #'opencode-question--on-asked
        (list :id id :sessionID session-id
              :questions
              (vector
               (list :header (or (plist-get req :title) "Input")
                     :question (or (plist-get req :title)
                                   (plist-get req :placeholder) "")
                     :options (when (equal method "select")
                                (plist-get req :options))
                     :custom (not (equal method "select")))))))
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

(defun opencode-pi--dispatch-popup (session-id handler event)
  "Dispatch EVENT to HANDLER in the chat buffer for SESSION-ID.
Wraps the synthesized request as {:properties EVENT} like the SSE path."
  (let ((wrapped (list :type "popup" :properties event)))
    (if (fboundp 'opencode--dispatch-to-chat-buffer)
        (opencode--dispatch-to-chat-buffer session-id handler wrapped)
      (funcall handler wrapped))))

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

;;; --- Runtime event router (Pi event -> chat SSE handlers) ---
;;
;; The chat buffer handlers consume OpenCode-shaped SSE events
;; ({:type ... :properties {:sessionID ... :status/:part/:info ...}}).  This
;; router converts each raw Pi event into that shape and dispatches it to the
;; owning chat buffer's per-type handler by session id.  (`opencode-pi--event'
;; remains the pure CANONICAL adapter used by the backend `event-adapter'
;; slot; this router is the runtime UI glue.)

(declare-function opencode-chat--on-session-status "opencode-chat" (event))
(declare-function opencode-chat--on-session-idle "opencode-chat" (event))
(declare-function opencode-chat--on-message-updated "opencode-chat" (event))
(declare-function opencode-chat--on-part-updated "opencode-chat" (event))
(declare-function opencode-chat--on-session-compacted "opencode-chat" (event))
(declare-function opencode-chat--on-session-error "opencode-chat" (event))

(defun opencode-pi--route-event (session-id raw)
  "Route a raw Pi event RAW for SESSION-ID into the chat buffer handlers.
Builds OpenCode-shaped SSE events and dispatches them by session id."
  (let ((type (plist-get raw :type)))
    (pcase type
      ("agent_start"
       (opencode-pi--emit session-id #'opencode-chat--on-session-status
                          (list :sessionID session-id
                                :status (list :type "busy")))
       ;; Bootstrap an assistant message so streaming parts have an owner.
       (opencode-pi--emit session-id #'opencode-chat--on-message-updated
                          (list :info (list :id (format "%s/asst" session-id)
                                            :sessionID session-id
                                            :role "assistant"
                                            :time (list :created
                                                        (floor (* (float-time) 1000)))))))
      ("agent_end"
       (opencode-pi--emit session-id #'opencode-chat--on-session-idle
                          (list :sessionID session-id)))
      ("message_update"
       (let* ((ae (plist-get raw :assistantMessageEvent))
              (delta (plist-get ae :delta))
              (ptype (opencode-pi--assistant-event-part-type ae))
              (partial (plist-get ae :partial))
              (msg-id (format "%s/asst" session-id)))
         (opencode-pi--emit
          session-id #'opencode-chat--on-part-updated
          (append
           (list :part (list :sessionID session-id
                             :messageID msg-id
                             :id (format "%s/stream-%s" session-id ptype)
                             :type ptype
                             :text (plist-get partial :text)
                             :time (list :start 0)))
           (when delta (list :delta delta))))))
      ((or "message_start" "message_end" "turn_end")
       ;; Full-message events: trigger a refresh via a synthetic status idle
       ;; bounce is wrong; instead schedule a refresh through message.updated.
       (opencode-pi--emit session-id #'opencode-chat--on-message-updated
                          (list :info (list :sessionID session-id))))
      ((or "compaction_start" "compaction_end")
       (opencode-pi--emit session-id #'opencode-chat--on-session-compacted
                          (list :sessionID session-id)))
      ("extension_error"
       (opencode-pi--emit session-id #'opencode-chat--on-session-error
                          (list :sessionID session-id
                                :error (list :message
                                             (or (plist-get raw :error)
                                                 "extension error")))))
      (_ nil))))

(defun opencode-pi--emit (session-id handler props)
  "Dispatch a synthetic SSE event with PROPS to HANDLER for SESSION-ID."
  (let ((event (list :type "pi" :properties props)))
    (if (fboundp 'opencode--dispatch-to-chat-buffer)
        (opencode--dispatch-to-chat-buffer session-id handler event)
      (funcall handler event))))

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
              (condition-case nil
                  (push (opencode--json-parse line) objs)
                (error nil))
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
         (session-file (and (consp choice) (plist-get (cdr choice) :file))))
    (opencode-pi--launch directory session-file)))

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
        (cons pick (list :file (plist-get (plist-get s :raw) :file)))))))

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
    (opencode-chat-open session-id directory nil 'pi)
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