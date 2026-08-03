;;; opencode-backend.el --- Backend abstraction for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Backend abstraction boundary.  This module defines opencode.el's own
;; normalized shapes and backend registry, independent of any concrete
;; agent protocol.  OpenCode HTTP/SSE remains the only runtime backend for
;; now; future backends adapt into the shapes below instead of leaking
;; their native API objects into the UI.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'opencode-api)
(require 'opencode-api-cache)

(defgroup opencode-backend nil
  "Backend abstraction for opencode.el."
  :group 'opencode
  :prefix "opencode-backend-")

(defcustom opencode-backend-current 'opencode
  "Backend selected for opencode.el.
Only `opencode' is implemented today; other values must be registered
with `opencode-backend-register' before use."
  :type 'symbol
  :group 'opencode-backend)

(cl-defstruct (opencode-backend
               (:constructor opencode-backend-create)
               (:copier nil))
  name
  capabilities
  start-fn
  stop-fn
  connected-p-fn
  list-projects-fn
  list-sessions-fn
  get-session-fn
  get-session-sync-fn
  create-session-fn
  rename-session-fn
  delete-session-fn
  fork-session-fn
  compact-session-fn
  share-session-fn
  unshare-session-fn
  revert-session-fn
  unrevert-session-fn
  session-status-all-fn
  abort-session-fn
  get-messages-fn
  get-messages-sync-fn
  get-child-sessions-fn
  get-todos-fn
  get-diff-fn
  get-diff-sync-fn
  send-prompt-fn
  list-questions-fn
  list-permissions-fn
  reply-question-fn
  reject-question-fn
  reply-permission-fn
  event-adapter
  list-models-fn
  set-model-fn)

(defvar opencode-backend--registry (make-hash-table :test 'eq)
  "Registered backend objects keyed by backend name symbol.")

(defconst opencode-backend-required-ops
  '(list-sessions get-session-sync get-messages-sync send-prompt abort-session)
  "Operations a backend must implement to be usable at all.

Deliberately the floor for working with an *existing* session, not the
full surface.  `create-session' is not on it because the `pi' backend
does not implement it: making it required would stop that backend
loading over one gap, when everything else about it works.  Starting a
new session is exactly the kind of optional operation callers should
probe for and hide when absent.

Everything else is optional and should be probed with
`opencode-backend-supports-p' rather than assumed.  Dispatch resolves a
function slot at call time and errors when it is nil, so an unimplemented
operation used to surface as a runtime error at the moment a user reached
that feature -- with no way to ask beforehand whether it was there.  This
list is the floor; the check runs at registration so a backend missing
one fails loudly at load rather than mid-session.")

(defun opencode-backend-supports-p (operation &optional backend)
  "Return non-nil if BACKEND implements OPERATION.

OPERATION is the bare name, e.g. `get-todos'.  Answers from the function
slot itself, so it cannot disagree with what the backend actually does --
unlike the `capabilities' list, which is declared separately and can
drift from the implementation.  Callers offering an optional feature
should probe this and hide the feature when it is absent, instead of
calling and letting the error reach the user."
  (when-let* ((b (opencode-backend--resolve backend))
              (accessor (intern-soft
                         (format "opencode-backend-%s-fn" operation))))
    (and (fboundp accessor) (funcall accessor b) t)))

(defun opencode-backend-register (backend)
  "Register BACKEND and return it.
BACKEND must be an `opencode-backend' struct with a non-nil `name' slot
and must implement every operation in `opencode-backend-required-ops'."
  (unless (opencode-backend-p backend)
    (error "Not an opencode-backend: %S" backend))
  (let ((name (opencode-backend-name backend)))
    (unless (symbolp name)
      (error "Backend name must be a symbol: %S" name))
    (when-let* ((missing (seq-remove
                          (lambda (op) (opencode-backend-supports-p op backend))
                          opencode-backend-required-ops)))
      (error "Backend %S is missing required operations: %s"
             name (mapconcat #'symbol-name missing ", ")))
    (puthash name backend opencode-backend--registry)
    backend))

(defun opencode-backend-get (&optional name)
  "Return backend registered under NAME, or current backend when NAME is nil."
  (gethash (or name opencode-backend-current) opencode-backend--registry))

(defun opencode-backend-capable-p (capability &optional backend)
  "Return non-nil if BACKEND advertises CAPABILITY."
  (memq capability (opencode-backend-capabilities
                    (or (opencode-backend--resolve backend)
                        (opencode-backend-get)))))

(defun opencode-backend--resolve (&optional backend)
  "Resolve BACKEND symbol/struct/nil to an `opencode-backend' struct."
  (cond
   ((null backend) (opencode-backend-get))
   ((opencode-backend-p backend) backend)
   ((symbolp backend) (opencode-backend-get backend))
   (t (error "Invalid backend: %S" backend))))

(defun opencode-backend--missing (backend operation)
  "Signal that BACKEND does not implement OPERATION.
Reaching here means a caller invoked an optional operation without
probing `opencode-backend-supports-p' first."
  (error "Backend %S does not implement %S (probe `opencode-backend-supports-p')"
         (and backend (opencode-backend-name backend)) operation))

(defun opencode-backend--call (backend operation accessor &rest args)
  "Call BACKEND OPERATION function from ACCESSOR with ARGS."
  (let* ((backend (opencode-backend--resolve backend))
         (fn (and backend (funcall accessor backend))))
    (unless fn
      (opencode-backend--missing backend operation))
    (apply fn args)))

(defun opencode-backend-list-sessions (&optional query-params backend)
  "Return sessions from BACKEND matching QUERY-PARAMS."
  (opencode-backend--call backend 'list-sessions
                           #'opencode-backend-list-sessions-fn query-params))

(defun opencode-backend-list-projects (&optional backend)
  "Return canonical projects from BACKEND.
This is an optional operation; callers should probe `list-projects'
with `opencode-backend-supports-p' before invoking it."
  (opencode-backend--call backend 'list-projects
                           #'opencode-backend-list-projects-fn))

(defun opencode-backend-get-session (session-id callback &optional backend)
  "Fetch SESSION-ID from BACKEND asynchronously and call CALLBACK."
  (opencode-backend--call backend 'get-session
                          #'opencode-backend-get-session-fn session-id callback))

(defun opencode-backend-get-session-sync (session-id &optional backend)
  "Return SESSION-ID from BACKEND synchronously."
  (opencode-backend--call backend 'get-session-sync
                          #'opencode-backend-get-session-sync-fn session-id))

(cl-defun opencode-backend-create-session (&key title parent-id backend)
  "Create a session in BACKEND with optional TITLE and PARENT-ID."
  (opencode-backend--call backend 'create-session
                          #'opencode-backend-create-session-fn title parent-id))

(defun opencode-backend-rename-session (session-id title &optional backend)
  "Rename SESSION-ID to TITLE in BACKEND."
  (opencode-backend--call backend 'rename-session
                          #'opencode-backend-rename-session-fn session-id title))

(defun opencode-backend-delete-session (session-id &optional backend)
  "Delete SESSION-ID in BACKEND."
  (opencode-backend--call backend 'delete-session
                          #'opencode-backend-delete-session-fn session-id))

(defun opencode-backend-fork-session (session-id &optional message-id backend)
  "Fork SESSION-ID at optional MESSAGE-ID in BACKEND."
  (opencode-backend--call backend 'fork-session
                          #'opencode-backend-fork-session-fn session-id message-id))

(defun opencode-backend-compact-session (session-id model-id provider-id &optional backend)
  "Compact SESSION-ID using MODEL-ID and PROVIDER-ID in BACKEND."
  (opencode-backend--call backend 'compact-session
                          #'opencode-backend-compact-session-fn
                          session-id model-id provider-id))

(defun opencode-backend-share-session (session-id &optional backend)
  "Create a share link for SESSION-ID in BACKEND."
  (opencode-backend--call backend 'share-session
                          #'opencode-backend-share-session-fn session-id))

(defun opencode-backend-unshare-session (session-id &optional backend)
  "Remove the share link for SESSION-ID in BACKEND."
  (opencode-backend--call backend 'unshare-session
                          #'opencode-backend-unshare-session-fn session-id))

(defun opencode-backend-revert-session (session-id message-id &optional backend)
  "Revert SESSION-ID to before MESSAGE-ID in BACKEND."
  (opencode-backend--call backend 'revert-session
                          #'opencode-backend-revert-session-fn session-id message-id))

(defun opencode-backend-unrevert-session (session-id &optional backend)
  "Undo the latest revert for SESSION-ID in BACKEND."
  (opencode-backend--call backend 'unrevert-session
                          #'opencode-backend-unrevert-session-fn session-id))

(defun opencode-backend-session-status-all (&optional backend)
  "Return status of all active sessions from BACKEND."
  (opencode-backend--call backend 'session-status-all
                          #'opencode-backend-session-status-all-fn))

(defun opencode-backend-abort-session (session-id &optional backend)
  "Abort active work in SESSION-ID for BACKEND."
  (opencode-backend--call backend 'abort-session
                          #'opencode-backend-abort-session-fn session-id))

(defun opencode-backend-get-messages (session-id callback &optional query-params backend)
  "Fetch messages for SESSION-ID from BACKEND and call CALLBACK."
  (opencode-backend--call backend 'get-messages
                          #'opencode-backend-get-messages-fn
                          session-id callback query-params))

(defun opencode-backend-get-messages-sync (session-id &optional query-params backend)
  "Return messages for SESSION-ID from BACKEND synchronously."
  (opencode-backend--call backend 'get-messages-sync
                          #'opencode-backend-get-messages-sync-fn
                          session-id query-params))

(defun opencode-backend-get-child-sessions (session-id &optional backend)
  "Return child sessions for SESSION-ID from BACKEND."
  (opencode-backend--call backend 'get-child-sessions
                          #'opencode-backend-get-child-sessions-fn session-id))

(defun opencode-backend-get-todos (session-id callback &optional backend)
  "Fetch todos for SESSION-ID from BACKEND and call CALLBACK."
  (opencode-backend--call backend 'get-todos
                          #'opencode-backend-get-todos-fn session-id callback))

(defun opencode-backend-get-diff (session-id callback &optional message-id backend)
  "Fetch diff for SESSION-ID from BACKEND and call CALLBACK."
  (opencode-backend--call backend 'get-diff
                          #'opencode-backend-get-diff-fn session-id callback message-id))

(defun opencode-backend-get-diff-sync (session-id &optional message-id backend)
  "Return diff for SESSION-ID from BACKEND synchronously."
  (opencode-backend--call backend 'get-diff-sync
                          #'opencode-backend-get-diff-sync-fn session-id message-id))

(defun opencode-backend-send-prompt (session-id body callback &optional backend busy)
  "Send prompt BODY to SESSION-ID in BACKEND and call CALLBACK.
BUSY indicates the session is already generating; backends that support
mid-stream queueing (e.g. Pi steer/follow_up) use it.  Backends that do
not simply ignore it."
  (opencode-backend--call backend 'send-prompt
                          #'opencode-backend-send-prompt-fn
                          session-id body callback busy))

(defun opencode-backend-list-questions (callback &optional backend)
  "Fetch pending questions from BACKEND and call CALLBACK."
  (let* ((backend (opencode-backend--resolve backend))
         (fn (and backend (opencode-backend-list-questions-fn backend))))
    (when fn
      (funcall fn callback))))

(defun opencode-backend-list-permissions (callback &optional backend)
  "Fetch pending permissions from BACKEND and call CALLBACK."
  (let* ((backend (opencode-backend--resolve backend))
         (fn (and backend (opencode-backend-list-permissions-fn backend))))
    (when fn
      (funcall fn callback))))

(defun opencode-backend-reply-question (id answers &optional backend)
  "Reply to question ID with ANSWERS via BACKEND."
  (opencode-backend--call backend 'reply-question
                          #'opencode-backend-reply-question-fn id answers))

(defun opencode-backend-reject-question (id message &optional backend)
  "Reject question ID with optional MESSAGE via BACKEND."
  (opencode-backend--call backend 'reject-question
                          #'opencode-backend-reject-question-fn id message))

(defun opencode-backend-reply-permission (id choice message &optional backend)
  "Reply to permission ID with CHOICE and optional MESSAGE via BACKEND."
  (opencode-backend--call backend 'reply-permission
                          #'opencode-backend-reply-permission-fn id choice message))

(defun opencode-backend-list-models (callback &optional backend)
  "Fetch available models from BACKEND and call CALLBACK.
No-op when BACKEND does not implement model listing."
  (let* ((backend (opencode-backend--resolve backend))
         (fn (and backend (opencode-backend-list-models-fn backend))))
    (when fn
      (funcall fn callback))))

(defun opencode-backend-set-model (session-id provider-id model-id &optional backend)
  "Switch SESSION-ID to PROVIDER-ID / MODEL-ID via BACKEND.
No-op when BACKEND does not implement model switching."
  (let* ((backend (opencode-backend--resolve backend))
         (fn (and backend (opencode-backend-set-model-fn backend))))
    (when fn
      (funcall fn session-id provider-id model-id))))

(defun opencode-backend-normalize-event (event &optional backend)
  "Return canonical backend event for native EVENT.
BACKEND defaults to `opencode-backend-current'.  When BACKEND has no
adapter, wrap EVENT as `:raw' so downstream code still has a backend
event object."
  (let* ((backend (or backend (opencode-backend-get)))
         (adapter (and backend (opencode-backend-event-adapter backend))))
    (if adapter
        (funcall adapter event)
      (opencode-backend-event :type (plist-get event :type) :raw event))))

;;; --- Canonical opencode.el shapes ---

(defun opencode-backend-project (&rest plist)
  "Return a canonical project PLIST.
Known keys: :id, :directory, :name, :raw."
  plist)

(defun opencode-backend-session (&rest plist)
  "Return a canonical session PLIST.
Known keys: :id, :title, :directory, :parent-id, :created-at,
:updated-at, :summary, :raw."
  plist)

(defun opencode-backend-message (&rest plist)
  "Return a canonical message PLIST.
Known keys: :id, :session-id, :parent-id, :role, :agent, :model-id,
:provider-id, :api, :created-at, :completed-at, :usage, :tokens, :cost,
:finish, :stop-reason, :error-message, :parts, :raw."
  plist)

(defun opencode-backend-part (&rest plist)
  "Return a canonical message part PLIST.
Known keys: :id, :message-id, :session-id, :content-index, :type,
:text, :thinking, :tool, :tool-call-id, :arguments, :state, :time,
:mime-type, :data, :is-error, :details, :raw."
  plist)

(defun opencode-backend-model (&rest plist)
  "Return a canonical model PLIST.
Known keys: :id, :name, :provider-id, :api, :base-url, :reasoning,
:input, :context-window, :max-tokens, :cost, :raw."
  plist)

(defun opencode-backend-event (&rest plist)
  "Return a canonical backend event PLIST.
Known keys: :type, :session-id, :message-id, :part-id, :delta,
:message, :part, :session, :status, :error, :raw."
  plist)

(defun opencode-backend--plist (value)
  "Return VALUE when it is a plist, otherwise nil."
  (and (listp value) value))

;;; --- OpenCode shape adapter ---

(defun opencode-backend-opencode-list-projects ()
  "Return OpenCode projects normalized to canonical project shapes."
  (let ((projects (opencode-api-get-sync "/project")))
    (mapcar #'opencode-backend-opencode-project
            (seq-into (or projects []) 'list))))

(defun opencode-backend-opencode-list-sessions (&optional query-params)
  "OpenCode implementation of `opencode-backend-list-sessions'."
  (opencode-api-get-sync "/session" query-params))

(defun opencode-backend-opencode-get-session (session-id callback)
  "OpenCode async session fetch for SESSION-ID."
  (opencode-api-cache-get-session session-id callback))

(defun opencode-backend-opencode-get-session-sync (session-id)
  "OpenCode sync session fetch for SESSION-ID."
  (opencode-api-get-sync (format "/session/%s" session-id)))

(defun opencode-backend-opencode-create-session (&optional title parent-id)
  "OpenCode session creation with optional TITLE and PARENT-ID."
  (let ((body '()))
    (when title (setq body (plist-put body :title title)))
    (when parent-id (setq body (plist-put body :parentID parent-id)))
    (opencode-api-post-sync "/session" body)))

(defun opencode-backend-opencode-rename-session (session-id title)
  "OpenCode rename SESSION-ID to TITLE."
  (plist-get
   (opencode-api--request "PATCH" (format "/session/%s" session-id)
                          (list :title title))
   :body))

(defun opencode-backend-opencode-delete-session (session-id)
  "OpenCode delete SESSION-ID."
  (plist-get
   (opencode-api--request "DELETE" (format "/session/%s" session-id))
   :body))

(defun opencode-backend-opencode-fork-session (session-id &optional message-id)
  "OpenCode fork SESSION-ID at optional MESSAGE-ID."
  (opencode-api-post-sync (format "/session/%s/fork" session-id)
                           (when message-id (list :messageID message-id))))

(defun opencode-backend-opencode-compact-session (session-id model-id provider-id)
  "OpenCode compact SESSION-ID using MODEL-ID and PROVIDER-ID."
  (opencode-api-post-sync (format "/session/%s/summarize" session-id)
                          (list :modelID model-id :providerID provider-id)))

(defun opencode-backend-opencode-share-session (session-id)
  "OpenCode share SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/share" session-id)))

(defun opencode-backend-opencode-unshare-session (session-id)
  "OpenCode unshare SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/unshare" session-id)))

(defun opencode-backend-opencode-revert-session (session-id message-id)
  "OpenCode revert SESSION-ID to before MESSAGE-ID."
  (opencode-api-post-sync (format "/session/%s/revert" session-id)
                          (list :messageID message-id)))

(defun opencode-backend-opencode-unrevert-session (session-id)
  "OpenCode unrevert SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/unrevert" session-id)))

(defun opencode-backend-opencode-session-status-all ()
  "OpenCode status fetch for all active sessions."
  (opencode-api-get-sync "/session/status"))

(defun opencode-backend-opencode-abort-session (session-id)
  "OpenCode abort SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/abort" session-id)))

(defun opencode-backend-opencode-get-messages (session-id callback &optional query-params)
  "OpenCode async messages fetch for SESSION-ID."
  (opencode-api-get (format "/session/%s/message" session-id) callback query-params))

(defun opencode-backend-opencode-get-messages-sync (session-id &optional query-params)
  "OpenCode sync messages fetch for SESSION-ID."
  (opencode-api-get-sync (format "/session/%s/message" session-id) query-params))

(defun opencode-backend-opencode-get-child-sessions (session-id)
  "OpenCode child-session fetch for SESSION-ID."
  (let ((result (opencode-api-get-sync (format "/session/%s/children" session-id))))
    (if (vectorp result) (append result nil) result)))

(defun opencode-backend-opencode-get-todos (session-id callback)
  "OpenCode async todos fetch for SESSION-ID."
  (opencode-api-get (format "/session/%s/todo" session-id) callback))

(defun opencode-backend-opencode-get-diff (session-id callback &optional message-id)
  "OpenCode async diff fetch for SESSION-ID."
  (opencode-api-get (format "/session/%s/diff" session-id)
                    callback
                    (when message-id `(("messageID" . ,message-id)))))

(defun opencode-backend-opencode-get-diff-sync (session-id &optional message-id)
  "OpenCode sync diff fetch for SESSION-ID."
  (opencode-api-get-sync (format "/session/%s/diff" session-id)
                         (when message-id `(("messageID" . ,message-id)))))

(defun opencode-backend-opencode-send-prompt (session-id body callback &optional _busy)
  "OpenCode prompt_async for SESSION-ID with BODY.
The BUSY flag is ignored: OpenCode queues server-side."
  (opencode-api-post (format "/session/%s/prompt_async" session-id) body callback))

(defun opencode-backend-opencode-list-questions (callback)
  "OpenCode pending questions fetch."
  (opencode-api-get "/question" callback))

(defun opencode-backend-opencode-list-permissions (callback)
  "OpenCode pending permissions fetch."
  (opencode-api-get "/permission" callback))

(defun opencode-backend-opencode-reply-question (id answers)
  "OpenCode reply to question ID with ANSWERS."
  (opencode-api-post-sync (format "/question/%s/reply" id)
                          (list :answers answers)))

(defun opencode-backend-opencode-reject-question (id message)
  "OpenCode reject question ID with optional MESSAGE."
  (if message
      (opencode-api-post-sync (format "/question/%s/reject" id)
                              (list :message message))
    (opencode-api-post-sync (format "/question/%s/reject" id))))

(defun opencode-backend-opencode-reply-permission (id choice message)
  "OpenCode reply to permission ID with CHOICE and optional MESSAGE."
  (opencode-api--request
   "POST"
   (format "/permission/%s/reply" id)
   (if message
       (list :reply choice :message message)
     (list :reply choice))))

(defun opencode-backend-opencode-session (session)
  "Convert OpenCode SESSION plist to the canonical session shape."
  (opencode-backend-session
   :id (plist-get session :id)
   :title (plist-get session :title)
   :directory (plist-get session :directory)
   :parent-id (plist-get session :parentID)
   :created-at (plist-get (opencode-backend--plist (plist-get session :time)) :created)
   :updated-at (plist-get (opencode-backend--plist (plist-get session :time)) :updated)
   :summary (plist-get session :summary)
   :raw session))

(defun opencode-backend-opencode-project (project)
  "Convert OpenCode PROJECT plist to the canonical project shape."
  (let* ((directory (or (plist-get project :worktree)
                        (plist-get project :directory)))
         (directory (and directory
                         (directory-file-name
                          (expand-file-name directory)))))
    (opencode-backend-project
     :id (plist-get project :id)
     :directory directory
     :name (or (plist-get project :name)
               (and directory
                    (file-name-nondirectory directory)))
     :raw project)))

(defun opencode-backend-opencode-part (part)
  "Convert OpenCode PART plist to the canonical part shape."
  (opencode-backend-part
   :id (plist-get part :id)
   :message-id (plist-get part :messageID)
   :session-id (plist-get part :sessionID)
   :type (plist-get part :type)
   :text (plist-get part :text)
   :tool (plist-get part :tool)
   :state (plist-get part :state)
   :time (plist-get part :time)
   :raw part))

(defun opencode-backend-opencode-message (message)
  "Convert OpenCode MESSAGE plist to the canonical message shape."
  (let* ((info (plist-get message :info))
         (time (opencode-backend--plist (plist-get info :time))))
    (opencode-backend-message
     :id (plist-get info :id)
     :session-id (plist-get info :sessionID)
     :parent-id (plist-get info :parentID)
     :role (plist-get info :role)
     :agent (plist-get info :agent)
     :model-id (plist-get info :modelID)
     :provider-id (plist-get info :providerID)
     :api nil
     :created-at (plist-get time :created)
     :completed-at (plist-get time :completed)
     :usage (plist-get info :tokens)
     :tokens (plist-get info :tokens)
     :cost (plist-get info :cost)
     :finish (plist-get info :finish)
     :stop-reason (plist-get info :finish)
     :error-message nil
     :parts (mapcar #'opencode-backend-opencode-part
                    (append (or (plist-get message :parts) []) nil))
     :raw message)))

(defun opencode-backend-opencode-event (event)
  "Convert OpenCode SSE EVENT plist to the canonical event shape."
  (let* ((type (plist-get event :type))
         (props (plist-get event :properties))
         (info (plist-get props :info))
         (part (plist-get props :part)))
    (opencode-backend-event
     :type type
     :session-id (or (plist-get props :sessionID)
                     (plist-get info :sessionID)
                     (plist-get info :id)
                     (plist-get part :sessionID))
     :message-id (or (plist-get info :id)
                     (plist-get part :messageID)
                     (plist-get props :messageID))
     :part-id (or (plist-get part :id)
                  (plist-get props :partID))
     :delta (plist-get props :delta)
     :session (when (and info (string-prefix-p "session." type))
                (opencode-backend-opencode-session info))
     :message (when (and info (string-prefix-p "message." type))
                (opencode-backend-message :raw info
                                          :id (plist-get info :id)
                                          :session-id (plist-get info :sessionID)
                                          :role (plist-get info :role)))
     :part (when part (opencode-backend-opencode-part part))
     :status (plist-get props :status)
     :error (plist-get props :error)
     :raw event)))

(opencode-backend-register
 (opencode-backend-create
  :name 'opencode
  :capabilities '(sessions messages streaming tools models permissions questions todos diffs)
  :start-fn nil
  :stop-fn nil
  :connected-p-fn nil
  :list-projects-fn #'opencode-backend-opencode-list-projects
  :list-sessions-fn #'opencode-backend-opencode-list-sessions
  :get-session-fn #'opencode-backend-opencode-get-session
  :get-session-sync-fn #'opencode-backend-opencode-get-session-sync
  :create-session-fn #'opencode-backend-opencode-create-session
  :rename-session-fn #'opencode-backend-opencode-rename-session
  :delete-session-fn #'opencode-backend-opencode-delete-session
  :fork-session-fn #'opencode-backend-opencode-fork-session
  :compact-session-fn #'opencode-backend-opencode-compact-session
  :share-session-fn #'opencode-backend-opencode-share-session
  :unshare-session-fn #'opencode-backend-opencode-unshare-session
  :revert-session-fn #'opencode-backend-opencode-revert-session
  :unrevert-session-fn #'opencode-backend-opencode-unrevert-session
  :session-status-all-fn #'opencode-backend-opencode-session-status-all
  :abort-session-fn #'opencode-backend-opencode-abort-session
  :get-messages-fn #'opencode-backend-opencode-get-messages
  :get-messages-sync-fn #'opencode-backend-opencode-get-messages-sync
  :get-child-sessions-fn #'opencode-backend-opencode-get-child-sessions
  :get-todos-fn #'opencode-backend-opencode-get-todos
  :get-diff-fn #'opencode-backend-opencode-get-diff
  :get-diff-sync-fn #'opencode-backend-opencode-get-diff-sync
  :send-prompt-fn #'opencode-backend-opencode-send-prompt
  :list-questions-fn #'opencode-backend-opencode-list-questions
  :list-permissions-fn #'opencode-backend-opencode-list-permissions
  :reply-question-fn #'opencode-backend-opencode-reply-question
  :reject-question-fn #'opencode-backend-opencode-reject-question
  :reply-permission-fn #'opencode-backend-opencode-reply-permission
  :event-adapter #'opencode-backend-opencode-event
  :list-models-fn nil
  :set-model-fn nil))

(provide 'opencode-backend)
;;; opencode-backend.el ends here
