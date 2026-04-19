;;; opencode-sidebar.el --- Treemacs sidebar for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Global treemacs-based sidebar with grouped session display.
;; Groups: "Opened Session" (cross-project, status icons) + per-project groups.
;; Uses `treemacs-treelib' extension API with four-level hierarchy:
;;   root → group → session → child (file diffs, sub-agents, message turns).

;;; Code:

(require 'seq)
(require 'cl-lib)
(require 'treemacs)
(require 'treemacs-treelib)
(require 'treemacs-mouse-interface)
(require 'opencode-log)
(require 'opencode-diff)
(require 'opencode-util)
(require 'opencode-faces)
(require 'opencode-session)
(require 'opencode-api-cache)
(require 'opencode-chat-state)

(declare-function opencode--register-sidebar-buffer "opencode" (&rest args))
(declare-function opencode--deregister-sidebar-buffer "opencode" (&rest args))
(declare-function opencode--chat-buffer-for-session "opencode" (session-id))
(declare-function opencode--all-chat-buffers "opencode" ())
(declare-function opencode--ensure-ready "opencode" ())
(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))

(defvar opencode-default-directory)

;;; --- Customization ---

(defgroup opencode-sidebar nil
  "OpenCode sidebar panel."
  :group 'opencode
  :prefix "opencode-sidebar-")

(defcustom opencode-sidebar-refresh-delay 0.5
  "Idle-time debounce delay in seconds for sidebar rerender.
The sidebar rerenders this many seconds after Emacs becomes idle,
preventing rerender storms during rapid SSE events."
  :type 'number
  :group 'opencode-sidebar)

(defcustom opencode-sidebar-session-limit 100
  "Maximum number of sessions to fetch per project."
  :type 'integer
  :group 'opencode)


(defmacro opencode-sidebar--log (fmt &rest args)
  "Log FMT with ARGS to debug buffer via `opencode--debug'."
  `(opencode--debug ,(concat "opencode-sidebar: " fmt) ,@args))

;;; --- Buffer naming ---

(defconst opencode-sidebar--buffer-name " *opencode: sidebar*"
  "Buffer name for the single global sidebar.
The leading space makes this an internal buffer that Emacs's
`next-buffer'/`previous-buffer' commands automatically skip — same
trick treemacs uses (`treemacs--buffer-name-prefix' is \" *Treemacs-\").")

;;; --- Buffer-local variables ---

(defvar-local opencode-sidebar--primary-project-dir nil
  "Primary project directory (the project from which sidebar was opened).
This project group defaults to expanded.")

(defvar-local opencode-sidebar--status-store (make-hash-table :test 'equal)
  "Hash: session-id (string) → status symbol.
Single source of truth for session status icons.
Updated exclusively from SSE events.
Values: busy, idle, retry, question, permission.")

(defvar-local opencode-sidebar--known-project-dirs nil
  "List of known project directories.
Includes primary + discovered from chat registry + SSE events.")

(defvar-local opencode-sidebar--refresh-timer nil
  "Pending debounce timer for SSE-triggered rerender.")

(defvar-local opencode-sidebar-on-session-event-hook nil
  "Buffer-local hook run after a session SSE event is handled.
Each function receives the SSE event plist.")

;;; --- Status store ---

(defun opencode-sidebar--session-status (session-id)
  "Return status symbol for SESSION-ID from the status store.
Returns `idle' if not found."
  (gethash session-id opencode-sidebar--status-store 'idle))

;;; --- Opened session helpers ---

(defconst opencode-sidebar--max-ancestor-depth 8
  "Maximum number of parent hops `ancestor-opened-p' will walk.
Prevents infinite loops from cyclic parentID chains in the session
cache (e.g. A→B→A).  Matches the depth cap used by
`opencode-event--popup-max-walk'.")

(defun opencode-sidebar--ancestor-opened-p (session)
  "Return non-nil if any ancestor of SESSION has an open chat buffer.
Walks the parent chain via the project session cache, bounded by
`opencode-sidebar--max-ancestor-depth' to guard against cycles."
  (let ((parent-id (and session (plist-get session :parentID)))
        (dir (and session (plist-get session :directory)))
        (depth 0))
    (catch 'found
      (while (and parent-id (< depth opencode-sidebar--max-ancestor-depth))
        (when (opencode--chat-buffer-for-session parent-id)
          (throw 'found t))
        (let* ((all (and dir (opencode-api-cache-project-sessions dir :cache t)))
               (parent (and all
                            (seq-find (lambda (s)
                                        (equal (plist-get s :id) parent-id))
                                      (seq-into all 'list)))))
          (setq parent-id (and parent (plist-get parent :parentID)))
          (cl-incf depth)))
      nil)))

(defun opencode-sidebar--opened-session-ids ()
  "Return a hash-set of opened session IDs shown in the Opened Session group.
Excludes child sessions whose any ancestor is also opened."
  (let ((ids (make-hash-table :test 'equal)))
    (when (boundp 'opencode--chat-registry)
      (maphash (lambda (sid buf)
                 (when (buffer-live-p buf)
                   (let* ((session (with-current-buffer buf
                                     (opencode-chat--session))))
                     (unless (opencode-sidebar--ancestor-opened-p session)
                       (puthash sid t ids)))))
               opencode--chat-registry))
    ids))

(defun opencode-sidebar--opened-session-items ()
  "Build session item plists for all opened sessions (cross-project).
Reads session data from each chat buffer's cached session plist.
Excludes child sessions whose parent is also opened."
  (let ((items '()))
    (when (boundp 'opencode--chat-registry)
      (maphash
       (lambda (sid buf)
         (when (buffer-live-p buf)
           (let* ((session (with-current-buffer buf (opencode-chat--session))))
             ;; Skip child sessions if any ancestor is also opened
             (unless (opencode-sidebar--ancestor-opened-p session)
               (push (list :key (concat "session/" sid)
                           :session-id sid
                           :title (or (and session (plist-get session :title))
                                      "(untitled)")
                           :time (and session (plist-get session :time))
                           :summary (and session (plist-get session :summary))
                           :opened t)
                     items)))))
       opencode--chat-registry))
    (nreverse items)))

(defun opencode-sidebar--discover-project-dirs ()
  "Discover project directories from the chat registry.
Adds any new directories to `opencode-sidebar--known-project-dirs'."
  (when (boundp 'opencode--chat-registry)
    (maphash
     (lambda (_sid buf)
       (when (buffer-live-p buf)
         (let* ((session (with-current-buffer buf (opencode-chat--session)))
                (dir (and session (plist-get session :directory))))
           (when (and dir (not (member dir opencode-sidebar--known-project-dirs)))
             (push dir opencode-sidebar--known-project-dirs)))))
     opencode--chat-registry)))

;;; --- Rendering helpers ---

(defun opencode-sidebar--session-label (item)
  "Build a display label for session ITEM plist.
Format: \"{title}  +{add} -{del} {files}f  {time-ago}\".
Opened sessions get a [project] prefix."
  (let* ((raw-title (or (plist-get item :title) "(untitled)"))
         (title (replace-regexp-in-string "[\n\r\t]+" " " raw-title))
         (title (if (length> title 35)
                    (concat (substring title 0 35) "…")
                  title))
         (summary (plist-get item :summary))
         (time-info (plist-get item :time))
         (updated (and time-info (plist-get time-info :updated)))
         (time-str (opencode--time-ago updated t))
         ;; Add [project] prefix for opened sessions
         (project-prefix
          (when (plist-get item :opened)
            (let* ((dir (opencode-sidebar--session-project-dir item))
                   (proj (and dir (file-name-nondirectory
                                  (directory-file-name dir)))))
              (when proj
                (propertize (format "[%s] " proj)
                            'face 'treemacs-git-ignored-face)))))
         (title-str (concat (or project-prefix "")
                            (propertize title 'face 'treemacs-directory-face))))
    (if summary
        (let ((add (or (plist-get summary :additions) 0))
              (del (or (plist-get summary :deletions) 0))
              (files (or (plist-get summary :files) 0)))
          (concat title-str
                  (propertize (format "  +%d -%d %df" add del files)
                              'face 'treemacs-git-ignored-face)
                  (propertize (format "  %s" time-str)
                              'face 'treemacs-git-ignored-face)))
      (concat title-str
              (when (and time-str (not (string-empty-p time-str)))
                (propertize (format "  %s" time-str)
                            'face 'treemacs-git-ignored-face))))))

(defun opencode-sidebar--file-label (item)
  "Build a display label for file change ITEM plist.
Format: \"{status-char} {filename}  +{add} -{del}\"."
  (let* ((status (or (plist-get item :status) "unknown"))
         (file-path (or (plist-get item :file-path) "?"))
         (basename (file-name-nondirectory file-path))
         (additions (or (plist-get item :additions) 0))
         (deletions (or (plist-get item :deletions) 0))
         (status-char (opencode--file-status-char status))
         (status-face (pcase status
                        ("added"    'treemacs-git-added-face)
                        ("deleted"  'treemacs-git-conflict-face)
                        ("modified" 'treemacs-git-modified-face)
                        ("renamed"  'treemacs-git-renamed-face)
                        (_          'default))))
    (concat (propertize status-char 'face status-face)
            " "
            (propertize basename 'face 'treemacs-file-face)
            (propertize (concat "  " (opencode--format-diff-stats additions deletions))
                        'face 'treemacs-git-ignored-face))))

(defun opencode-sidebar--child-session-label (item)
  "Build a display label for a sub-agent child session ITEM plist.
Format: \"{title}  {time-ago}\"."
  (let* ((raw-title (or (plist-get item :title) "(sub-agent)"))
         (title (replace-regexp-in-string "[\n\r\t]+" " " raw-title))
         (title (if (length> title 30)
                    (concat (substring title 0 30) "…")
                  title))
         (time-info (plist-get item :time))
         (updated (and time-info (plist-get time-info :updated)))
         (time-str (opencode--time-ago updated t)))
    (concat (propertize title 'face 'treemacs-directory-face)
            (when (and time-str (not (string-empty-p time-str)))
              (propertize (format "  %s" time-str)
                          'face 'treemacs-git-ignored-face)))))


(defun opencode-sidebar--session-icon (item expanded?)
  "Return session icon string.
ITEM is the session plist.  EXPANDED? determines the triangle direction.
For opened sessions, shows status-based icons."
  (if (plist-get item :opened)
      (let ((status (opencode-sidebar--session-status
                     (plist-get item :session-id))))
        (pcase status
          ('busy       (propertize "⬤ " 'face 'opencode-session-active))
          ('retry      (propertize "⬤ " 'face 'opencode-session-active))
          ('question   (propertize "? " 'face 'warning))
          ('permission (propertize "! " 'face 'warning))
          (_           (propertize "○ " 'face 'opencode-session-idle))))
    (if expanded? "▾ " "▸ ")))

(defun opencode-sidebar--child-session-icon (item)
  "Return status-aware icon for a sub-agent child session ITEM."
  (let ((status (opencode-sidebar--session-status
                 (plist-get item :session-id))))
    (pcase status
      ('busy       (concat "  " (propertize "⬤ " 'face 'opencode-session-active)))
      ('retry      (concat "  " (propertize "⬤ " 'face 'opencode-session-active)))
      ('question   (concat "  " (propertize "? " 'face 'warning)))
      ('permission (concat "  " (propertize "! " 'face 'warning)))
      (_           (concat "  " (propertize "○ " 'face 'opencode-session-idle))))))

(defun opencode-sidebar--group-label (item)
  "Build a display label for group ITEM.
Shows \"(refreshing)\" indicator when a fetch is in-flight."
  (let ((name (plist-get item :group-name))
        (dir (plist-get item :project-dir)))
    (if (and dir (opencode-api-cache-project-sessions-refreshing-p dir))
        (propertize (concat name " (refreshing)") 'face 'treemacs-directory-face)
      (propertize name 'face 'treemacs-directory-face))))

;;; --- Actions ---

(defun opencode-sidebar--node-at-point ()
  "Return the treemacs node at point, or nil."
  (treemacs-node-at-point))

(defun opencode-sidebar--find-main-window ()
  "Return a non-sidebar window for content display.
Explicitly skips sidebar buffer windows and minibuffer.
If no suitable window exists, split the frame to create one."
  (let ((sidebar-buf (current-buffer)))
    (let ((win (seq-find
                (lambda (w)
                  (and (not (eq (window-buffer w) sidebar-buf))
                       (not (window-minibuffer-p w))))
                (window-list))))
      (or win (split-window (frame-root-window) nil 'right)))))

(defun opencode-sidebar--display-buffer-other-window (buffer)
  "Display BUFFER in a non-sidebar window and select it."
  (when-let* ((win (display-buffer buffer
                             '((display-buffer-use-some-window
                                display-buffer-pop-up-window)
                               (inhibit-same-window . t)))))
    (select-window win)))

(defun opencode-sidebar--session-project-dir (item)
  "Return the project directory for session ITEM.
For opened sessions, reads from the chat buffer.
For project group sessions, uses the parent group's project-dir."
  (or (plist-get item :project-dir)
      (when (plist-get item :opened)
        (let* ((sid (plist-get item :session-id))
               (buf (opencode--chat-buffer-for-session sid)))
          (when (and buf (buffer-live-p buf))
            (with-current-buffer buf
              (let ((session (opencode-chat--session)))
                (and session (plist-get session :directory)))))))
      opencode-sidebar--primary-project-dir))

(defun opencode-sidebar--ret-action (&rest _)
  "Handle RET on the current node.
File nodes show a diff buffer; session/message-turn nodes open the chat."
  (when-let ((node (opencode-sidebar--node-at-point)))
    (let ((item (button-get node :item)))
      (when item
        (let ((target-win (opencode-sidebar--find-main-window)))
          (cond
           ;; File node — has :file-path
           ((plist-get item :file-path)
            (let* ((file-path (plist-get item :file-path))
                   (session-id (plist-get item :session-id))
                   (diffs (let ((opencode-default-directory
                                  (or (opencode-sidebar--session-project-dir item)
                                      opencode-default-directory)))
                            (condition-case err
                                (opencode-diff--fetch session-id)
                              (error
                               (user-error "Failed to load diff: %s"
                                           (error-message-string err)))))))
              (select-window target-win)
              (let* ((entry (and diffs
                                 (seq-find
                                  (lambda (d)
                                    (string= (or (plist-get d :file) (plist-get d :path))
                                             file-path))
                                  diffs)))
                     (before (and entry (plist-get entry :before)))
                     (after (and entry (plist-get entry :after)))
                     (diff-text (and entry
                                     (opencode-diff--generate-unified before after file-path))))
                (if (and diff-text (not (string-empty-p diff-text)))
                    (let ((buf (get-buffer-create
                                (format "*opencode: diff %s*"
                                        (file-name-nondirectory file-path)))))
                      (with-current-buffer buf
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (insert diff-text))
                        (diff-mode)
                        (setq-local diff-refine nil)
                        (setq-local face-remapping-alist
                                    opencode-diff--face-remapping-alist)
                        (setq buffer-read-only t)
                        (goto-char (point-min)))
                      (switch-to-buffer buf))
                  (user-error "No changes for %s" file-path)))))
           ;; Session node — has :session-id
           ((plist-get item :session-id)
            (opencode-sidebar--open-session-in-window item target-win))))))))

(defun opencode-sidebar--open-session-in-window (item target-win)
  "Open the session described by ITEM in TARGET-WIN."
  (let ((session-id (plist-get item :session-id))
        (project-dir (opencode-sidebar--session-project-dir item))
        (display-buffer-overriding-action
         `((display-buffer-reuse-window
            display-buffer-same-window)
           (reusable-frames . visible)
           (inhibit-same-window . nil))))
    (select-window target-win)
    (opencode-chat-open session-id project-dir)))

;;; --- Toggle node ---

(defun opencode-sidebar--toggle-node ()
  "Toggle expand/collapse of the current node.
Skips the invisible root node to prevent collapsing all sessions."
  (interactive)
  (when-let ((node (opencode-sidebar--node-at-point)))
    (let ((key (button-get node :key)))
      (opencode-sidebar--log "TOGGLE key=%S" key)
      (unless (eq key 'opencode-sidebar-root)
        (treemacs-toggle-node)))))

;;; --- Rename session ---

(defun opencode-sidebar--rename-session ()
  "Rename the session at point.
Prompts for a new title and updates via PATCH /session/:id."
  (interactive)
  (condition-case err
      (when-let ((node (opencode-sidebar--node-at-point)))
        (let ((item (button-get node :item)))
          (when item
            (let ((session-id (plist-get item :session-id)))
              (if (not session-id)
                  (user-error "Not a session node")
                (let* ((current-title (or (plist-get item :title) "(untitled)"))
                       (new-title (read-string "New title: " current-title)))
                  (if (string-empty-p new-title)
                      (message "Rename cancelled")
                    (progn
                      (opencode-sidebar--log "RENAME >>> sid=%s new-title=%S"
                                             session-id new-title)
                      (let ((opencode-default-directory
                             (or (opencode-sidebar--session-project-dir item)
                                 opencode-default-directory)))
                        (opencode-session-rename session-id new-title))
                      (opencode-sidebar--rerender)
                      (message "Renamed session: %s" new-title)))))))))
    (error
     (user-error "Failed to rename session: %s" (error-message-string err)))))

;;; --- Delete / Close ---

(defun opencode-sidebar--delete-or-close ()
  "Close or delete the session at point.
In the Opened Session group: kill the chat buffer (close).
In project groups: delete the session (with confirmation)."
  (interactive)
  (when-let ((node (opencode-sidebar--node-at-point)))
    (let ((item (button-get node :item)))
      (when (and item (plist-get item :session-id))
        (if (plist-get item :opened)
            ;; Close: kill the chat buffer
            (let* ((sid (plist-get item :session-id))
                   (buf (opencode--chat-buffer-for-session sid)))
              (when (and buf (buffer-live-p buf))
                (kill-buffer buf))
              (opencode-sidebar--rerender))
          ;; Delete: confirm then delete
          (opencode-sidebar--delete-session-impl item))))))

(defun opencode-sidebar--delete-session-impl (item)
  "Delete the session described by ITEM after confirmation."
  (let ((session-id (plist-get item :session-id))
        (title (or (plist-get item :title) "(untitled)")))
    (when (yes-or-no-p (format "Delete session \"%s\"? " title))
      (opencode-sidebar--log "DELETE >>> sid=%s title=%S" session-id title)
      (let ((opencode-default-directory
             (or (opencode-sidebar--session-project-dir item)
                 opencode-default-directory)))
        (opencode-session-delete session-id))
      (opencode-sidebar--rerender)
      (message "Deleted session: %s" title))))

;;; --- Create session ---

(defun opencode-sidebar--new-session ()
  "Create a new session and open the chat buffer.
Prompts for an optional title.
The session is created in the project directory of the node at point."
  (interactive)
  (let* ((node (opencode-sidebar--node-at-point))
         (item (and node (button-get node :item)))
         (project-dir (or (plist-get item :project-dir)
                          opencode-sidebar--primary-project-dir))
         (opencode-default-directory
          (or project-dir opencode-default-directory))
         (sidebar-buf (current-buffer)))
    (condition-case err
        (let* ((title (read-string "Session title (optional): "))
               (_ (opencode--ensure-ready))
               (session (opencode-session-create
                         (if (string-empty-p title) nil title))))
          (when session
            (let ((target-win (opencode-sidebar--find-main-window)))
              (select-window target-win))
            (opencode-chat-open (plist-get session :id)
                                (or (plist-get session :directory)
                                    opencode-default-directory)))
          (when (buffer-live-p sidebar-buf)
            (with-current-buffer sidebar-buf
              (opencode-sidebar--rerender))))
      (error
       (user-error "Failed to create session: %s" (error-message-string err))))))

;;; --- Session expansion helpers ---

(defun opencode-sidebar--build-file-children (session-id entries)
  "Build file child items from diff ENTRIES for SESSION-ID."
  (mapcar
   (lambda (entry)
     (let* ((fpath (or (plist-get entry :file)
                       (plist-get entry :path)
                       "?"))
            (before (plist-get entry :before))
            (after (plist-get entry :after))
            (adds (or (plist-get entry :additions) 0))
            (dels (or (plist-get entry :deletions) 0))
            (status (or (plist-get entry :status)
                        (cond
                         ((and (or (null before)
                                   (string-empty-p (or before "")))
                               after
                               (not (string-empty-p after)))
                          "added")
                         ((and before
                               (not (string-empty-p before))
                               (or (null after)
                                   (string-empty-p (or after ""))))
                          "deleted")
                         ((and (> adds 0) (= dels 0)) "added")
                         ((and (= adds 0) (> dels 0)) "deleted")
                         (t "modified")))))
       (list :key (concat session-id "/" fpath)
             :file-path fpath
             :session-id session-id
             :status status
             :additions adds
             :deletions dels)))
   entries))

(defun opencode-sidebar--build-subagent-children (session-id project-dir)
  "Build sub-agent child session items for SESSION-ID.
Reads from the project session cache for PROJECT-DIR."
  (let* ((all-sessions (opencode-api-cache-project-sessions
                        (or project-dir opencode-sidebar--primary-project-dir)
                        :cache t))
         (all-list (and all-sessions (seq-into all-sessions 'list))))
    (mapcar
     (lambda (s)
       (let ((sid (plist-get s :id)))
         (list :key (concat "session/" sid)
               :session-id sid
               :title (plist-get s :title)
               :time (plist-get s :time)
               :summary (plist-get s :summary)
               :project-dir project-dir)))
     (seq-filter (lambda (s) (equal (plist-get s :parentID) session-id))
                 (or all-list nil)))))


;;; --- Treemacs node types ---

;; Expandable child node: file diffs are leaf-like (empty children),
;; sub-agent sessions recurse into their own descendants.
;; NOTE: `:async? t' is required even though children are computed
;; synchronously.  `treemacs-update-async-node' (called during re-entry
;; when a parent async node is updated) invokes the children function of
;; ALL expanded descendants with 3 args (btn item callback), regardless
;; of their own `:async?' flag.  Without `:async? t' here, the children
;; lambda only accepts 2 args → wrong-number-of-arguments error →
;; silent rerender failure → sidebar stops updating.
(treemacs-define-expandable-node-type opencode-sidebar-child
  :closed-icon (if (plist-get item :file-path)
                   "  "
                 (opencode-sidebar--child-session-icon item))
  :open-icon (if (plist-get item :file-path)
                 "  "
               (opencode-sidebar--child-session-icon item))
  :label (if (plist-get item :file-path)
             (opencode-sidebar--file-label item)
           (opencode-sidebar--child-session-label item))
  :key (plist-get item :key)
  :children
  (let ((session-id (plist-get item :session-id))
        (project-dir (plist-get item :project-dir)))
    (if (plist-get item :file-path)
        (funcall callback nil)
      (funcall callback
               (opencode-sidebar--build-subagent-children session-id project-dir))))
  :child-type 'opencode-sidebar-child
  :async? t
  :ret-action #'opencode-sidebar--ret-action)

;; Expandable: session node (async children via diff + message APIs)
(treemacs-define-expandable-node-type opencode-session
  :closed-icon (opencode-sidebar--session-icon item nil)
  :open-icon (opencode-sidebar--session-icon item t)
  :label (opencode-sidebar--session-label item)
  :key (plist-get item :key)
  :children
  (let ((session-id (plist-get item :session-id))
        (project-dir (or (plist-get item :project-dir)
                         opencode-sidebar--primary-project-dir))
        (buf (current-buffer)))
    (opencode-sidebar--log "EXPAND >>> sid=%s" session-id)
    (let ((opencode-default-directory (or project-dir opencode-default-directory)))
      (opencode-api-get
       (format "/session/%s/diff" session-id)
       (lambda (response)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (condition-case err
                 (let* ((diff-body (plist-get response :body))
                        (diff-entries (and diff-body (seq-into diff-body 'list)))
                        (files (opencode-sidebar--build-file-children
                                session-id diff-entries))
                        (subagents (opencode-sidebar--build-subagent-children
                                    session-id project-dir))
                        (children (append subagents files)))
                   (opencode-sidebar--log "EXPAND <<< sid=%s children=%d"
                                           session-id (length children))
                   (let ((inhibit-read-only t))
                     (funcall callback children)))
               (error
                (opencode-sidebar--log "EXPAND error: %s"
                                        (error-message-string err))))))))))
  :child-type 'opencode-sidebar-child
  :async? t
  :ret-action #'opencode-sidebar--ret-action)


;; Expandable: group node (Opened Session or project group)
(treemacs-define-expandable-node-type opencode-sidebar-group
  :closed-icon "▸ "
  :open-icon "▾ "
  :label (opencode-sidebar--group-label item)
  :key (plist-get item :key)
  :children
  (let ((group-type (plist-get item :group-type))
        (project-dir (plist-get item :project-dir))
        (buf (current-buffer)))
    (pcase group-type
      ('opened
       ;; Synchronous: read from chat registry
       (let ((items (opencode-sidebar--opened-session-items)))
         (funcall callback items)))
      ('project
       ;; Read from cache or fetch async
       (let* ((opened-ids (opencode-sidebar--opened-session-ids))
              (cached (opencode-api-cache-project-sessions project-dir :cache t)))
         (if cached
             (let* ((all (seq-into cached 'list))
                    (top-level (seq-filter
                                (lambda (s) (null (plist-get s :parentID)))
                                all))
                    (filtered (seq-remove
                               (lambda (s)
                                 (gethash (plist-get s :id) opened-ids))
                               top-level))
                    (items (mapcar
                            (lambda (s)
                              (let ((sid (plist-get s :id)))
                                (list :key (concat "session/" sid)
                                      :session-id sid
                                      :title (plist-get s :title)
                                      :time (plist-get s :time)
                                      :summary (plist-get s :summary)
                                      :project-dir project-dir)))
                            filtered)))
               (funcall callback items))
           ;; Not cached: fetch async
           (opencode-api-cache-project-sessions
            project-dir
            :callback
            (lambda (sessions)
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (let* ((all (and sessions (seq-into sessions 'list)))
                         (top-level (seq-filter
                                     (lambda (s) (null (plist-get s :parentID)))
                                     (or all nil)))
                         (filtered (seq-remove
                                    (lambda (s)
                                      (gethash (plist-get s :id) opened-ids))
                                    top-level))
                         (items (mapcar
                                 (lambda (s)
                                   (let ((sid (plist-get s :id)))
                                     (list :key (concat "session/" sid)
                                           :session-id sid
                                           :title (plist-get s :title)
                                           :time (plist-get s :time)
                                           :summary (plist-get s :summary)
                                           :project-dir project-dir)))
                                 filtered)))
                    (let ((inhibit-read-only t))
                      (funcall callback items))))))))))))
  :child-type 'opencode-session
  :async? t)

;; Variadic root: invisible container for all groups
(treemacs-define-variadic-entry-node-type opencode-sidebar-root
  :key 'opencode-sidebar-root
  :children
  (progn
    ;; Discover project dirs from chat registry
    (opencode-sidebar--discover-project-dirs)
    (let* ((opened-group (list :key "group/opened"
                               :group-name "Opened Session"
                               :group-type 'opened))
           (primary-dir opencode-sidebar--primary-project-dir)
           (primary-name (and primary-dir
                              (file-name-nondirectory
                               (directory-file-name primary-dir))))
           (primary-group (when primary-dir
                            (list :key (concat "group/project/" primary-dir)
                                  :group-name primary-name
                                  :group-type 'project
                                  :project-dir primary-dir)))
           (other-dirs (seq-remove
                        (lambda (d) (and primary-dir (string= d primary-dir)))
                        (or opencode-sidebar--known-project-dirs nil)))
           (other-groups (mapcar
                          (lambda (dir)
                            (list :key (concat "group/project/" dir)
                                  :group-name (file-name-nondirectory
                                               (directory-file-name dir))
                                  :group-type 'project
                                  :project-dir dir))
                          other-dirs))
           (groups (list opened-group)))
      (when primary-group
        (setq groups (append groups (list primary-group))))
      (append groups other-groups)))
  :child-type 'opencode-sidebar-group)

;;; --- Extra keybindings ---

(defun opencode-sidebar--open-in-split (direction)
  "Open the session at point in a split of the main window.
DIRECTION is `right' for a vertical split or `below' for a horizontal split."
  (when-let ((node (opencode-sidebar--node-at-point)))
    (let ((item (button-get node :item)))
      (when (and item (plist-get item :session-id))
        (let* ((main (opencode-sidebar--find-main-window))
               (new (with-selected-window main
                      (if (eq direction 'right)
                          (split-window-right)
                        (split-window-below)))))
          (opencode-sidebar--open-session-in-window item new))))))

(defun opencode-sidebar-open-vsplit ()
  "Open session at point in a vertical split of the main window."
  (interactive)
  (opencode-sidebar--open-in-split 'right))

(defun opencode-sidebar-open-hsplit ()
  "Open session at point in a horizontal split of the main window."
  (interactive)
  (opencode-sidebar--open-in-split 'below))

(defvar-keymap opencode-sidebar--extra-map
  :doc "Extra keymap layered on top of treemacs keymap in the sidebar."
  "RET" #'opencode-sidebar--ret-wrapper
  "o s" #'opencode-sidebar-open-hsplit
  "o v" #'opencode-sidebar-open-vsplit
  "TAB" #'opencode-sidebar--toggle-node
  "<tab>" #'opencode-sidebar--toggle-node
  "S-TAB" #'opencode-sidebar--toggle-node
  "<backtab>" #'opencode-sidebar--toggle-node
  "g" #'opencode-sidebar--refresh-at-point
  "r" #'opencode-sidebar--refresh-at-point
  "w" #'opencode-sidebar--set-width
  "d" #'opencode-sidebar--delete-or-close
  "R" #'opencode-sidebar--rename-session
  "c" #'opencode-sidebar--new-session)

(defun opencode-sidebar--ret-wrapper (&optional arg)
  "Wrapper for RET that logs diagnostics then delegates to treemacs.
ARG is the prefix argument."
  (interactive "P")
  (opencode-sidebar--log "RET-WRAP >>> point=%d" (point))
  (treemacs-RET-action arg))

;;; --- Refresh ---

(defun opencode-sidebar--refresh-at-point ()
  "Refresh the project group at point, or rerender the whole sidebar."
  (interactive)
  (if-let* ((node (opencode-sidebar--node-at-point))
            (item (button-get node :item))
            (dir (plist-get item :project-dir)))
      ;; On a project group or session within a project: refresh that project
      (opencode-sidebar--refresh-project dir)
    ;; Fallback: rerender everything
    (opencode-sidebar--rerender)))

(defun opencode-sidebar--refresh-project (project-dir)
  "Fetch fresh session data for PROJECT-DIR and rerender."
  (opencode-sidebar--log "REFRESH-PROJECT >>> dir=%s" project-dir)
  (let ((buf (current-buffer))
        (opencode-default-directory (or project-dir opencode-default-directory)))
    ;; Invalidate cache and fetch fresh
    (opencode-api-cache-invalidate-project-sessions project-dir)
    (opencode-sidebar--rerender) ; show refreshing indicator
    (opencode-api-cache-project-sessions
     project-dir
     :callback
     (lambda (_sessions)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (opencode-sidebar--rerender)))))))

;;; --- Rerender ---

(defun opencode-sidebar--rerender ()
  "Incrementally re-render the sidebar tree and update header."
  (opencode-sidebar--log "RERENDER >>>")
  (condition-case err
      (let ((inhibit-read-only t))
        (treemacs-update-node '(opencode-sidebar-root) t))
    (error (opencode--debug "opencode-sidebar: rerender tree update error: %S" err)))
  (setq header-line-format " OpenCode Sessions")
  (opencode-sidebar--log "RERENDER <<<"))

;;; --- Width ---

(defun opencode-sidebar--set-width ()
  "Interactively set the sidebar window width."
  (interactive)
  (let* ((current (window-width))
         (new-width (read-number "Sidebar width: " current)))
    (when (>= new-width 10)
      (window-resize nil (- new-width current) t))))

;;; --- Tree initialization ---

(defun opencode-sidebar--init-tree ()
  "Initialize the treemacs tree in the current buffer.
Saves and restores buffer-local variables across `treemacs-initialize'."
  (opencode-sidebar--log "INIT-TREE >>>")
  (let ((saved-primary-dir opencode-sidebar--primary-project-dir)
        (saved-status-store opencode-sidebar--status-store)
        (saved-known-dirs opencode-sidebar--known-project-dirs))
    (treemacs-initialize opencode-sidebar-root
      :and-do
      (progn
        (setq-local opencode-sidebar--primary-project-dir saved-primary-dir)
        (setq-local opencode-sidebar--status-store saved-status-store)
        (setq-local opencode-sidebar--known-project-dirs saved-known-dirs)
        (setq-local face-remapping-alist '((button . default)))
        (setq-local window-size-fixed nil)
        (setq-local treemacs--width-is-locked nil)
        (setq-local treemacs-space-between-root-nodes nil)
        (setq-local truncate-lines t)
        (use-local-map
         (make-composed-keymap opencode-sidebar--extra-map
                               (current-local-map)))
        ;; Prevent point from landing on the invisible root node
        (add-hook 'post-command-hook
                  #'opencode-sidebar--evade-root nil t))))
  ;; Move point past invisible root node
  (goto-char (point-min))
  (while (and (not (eobp))
              (invisible-p (point)))
    (forward-line 1))
  (opencode-sidebar--log "INIT-TREE <<<"))

(defun opencode-sidebar--evade-root ()
  "Move point past the invisible root node if it landed there."
  (when-let ((btn (treemacs-current-button)))
    (when (treemacs-button-get btn 'invisible)
      (forward-line 1))))

;;; --- ensure-buffer ---

(defun opencode-sidebar--ensure-buffer (project-dir)
  "Create or return the existing global sidebar buffer.
PROJECT-DIR is used as the primary project on first creation.
If the buffer already exists, returns it without re-fetching."
  (let ((existing (get-buffer opencode-sidebar--buffer-name)))
    ;; Retry cache load if it failed during startup
    (opencode-api-cache-ensure-loaded)
    (if existing
        existing
      ;; Full initialization
      (let ((buf (get-buffer-create opencode-sidebar--buffer-name)))
        (with-current-buffer buf
          (setq opencode-sidebar--primary-project-dir
                (directory-file-name (expand-file-name project-dir)))
          (setq opencode-sidebar--status-store (make-hash-table :test 'equal))
          (setq opencode-sidebar--known-project-dirs
                (list opencode-sidebar--primary-project-dir))
          (opencode--register-sidebar-buffer
           opencode-sidebar--primary-project-dir (current-buffer))
          (opencode-sidebar--init-tree)
          (setq header-line-format " OpenCode Sessions — loading…")
          ;; Cleanup on kill
          (add-hook 'kill-buffer-hook
                    #'opencode-sidebar--cleanup nil t)
          ;; Initial data fetch for primary project
          (opencode-sidebar--refresh-project opencode-sidebar--primary-project-dir))
        buf))))

;;; --- Focus session ---

(defun opencode-sidebar--focus-session (session-id)
  "Move point to the node matching SESSION-ID in the sidebar, if found.
Uses treemacs DOM lookup via the node's key path."
  (when session-id
    (let ((session-key (concat "session/" session-id)))
      ;; Try under "Opened Session" group first, then each project group
      (or (treemacs-goto-node
           (list 'opencode-sidebar-root "group/opened" session-key))
          (cl-some
           (lambda (dir)
             (treemacs-goto-node
              (list 'opencode-sidebar-root
                    (concat "group/project/" dir)
                    session-key)))
           opencode-sidebar--known-project-dirs)))))

;;; --- SSE handlers ---

(defun opencode-sidebar--schedule-rerender ()
  "Schedule a debounced rerender after idle time.
Uses `opencode-sidebar-refresh-delay' seconds of idle time."
  (opencode-sidebar--log "SCHEDULE-RERENDER >>>")
  (opencode--debounce 'opencode-sidebar--refresh-timer
                      opencode-sidebar-refresh-delay
                      (lambda ()
                        (opencode-sidebar--log "SCHEDULE-RERENDER timer-fired!")
                        (opencode-sidebar--rerender))
                      'idle))

(defun opencode-sidebar--on-session-event (event)
  "Handle SSE EVENT for the global sidebar.
Updates status store, discovers new projects, invalidates caches."
  (let ((event-type (plist-get event :type))
        (event-dir (plist-get event :directory)))
    (opencode-sidebar--log "SSE-EVENT type=%s dir=%s" event-type event-dir)
    ;; Discover new project dirs
    (when (and event-dir
               (not (member event-dir opencode-sidebar--known-project-dirs)))
      (push event-dir opencode-sidebar--known-project-dirs))
    ;; Update status store
    (let* ((props (plist-get event :properties))
           (sid (or (plist-get props :sessionID)
                    (plist-get (plist-get props :info) :id)
                    (plist-get (plist-get props :info) :sessionID))))
      (when sid
        (pcase event-type
          ("session.status"
           (let ((status-type (plist-get (plist-get props :status) :type)))
             (when status-type
               (puthash sid (intern status-type) opencode-sidebar--status-store))))
          ("session.idle"
           (puthash sid 'idle opencode-sidebar--status-store))
          ("question.asked"
           (puthash sid 'question opencode-sidebar--status-store))
          ("permission.asked"
           (puthash sid 'permission opencode-sidebar--status-store))
          ((or "question.replied" "question.rejected" "permission.replied")
           (puthash sid 'busy opencode-sidebar--status-store)))))
    ;; Invalidate project session cache on data changes
    (when (and event-dir
               (member event-type '("session.updated" "session.deleted"))
               (opencode-api-cache-project-sessions event-dir :cache t))
      (opencode-api-cache-invalidate-project-sessions event-dir)
      ;; Re-fetch asynchronously (never block the SSE filter)
      (opencode-api-cache-project-sessions
       event-dir
       :callback (lambda (_sessions)
                   (opencode-sidebar--schedule-rerender))))
    ;; Debounced rerender
    (opencode-sidebar--schedule-rerender)
    (run-hook-with-args 'opencode-sidebar-on-session-event-hook event)))

;;; --- Cleanup ---

(defun opencode-sidebar--cleanup ()
  "Clean up when the sidebar buffer is killed."
  (opencode--deregister-sidebar-buffer
   (or opencode-sidebar--primary-project-dir ""))
  (when (timerp opencode-sidebar--refresh-timer)
    (cancel-timer opencode-sidebar--refresh-timer)))

;;; --- Chat registry hooks ---

(defun opencode-sidebar--on-chat-registry-change (&rest _)
  "Rerender the sidebar when chat buffers are opened or closed."
  (when-let ((buf (get-buffer opencode-sidebar--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (opencode-sidebar--discover-project-dirs)
        (opencode-sidebar--schedule-rerender)))))

(advice-add 'opencode--register-chat-buffer :after
            #'opencode-sidebar--on-chat-registry-change)
(advice-add 'opencode--deregister-chat-buffer :after
            #'opencode-sidebar--on-chat-registry-change)

(provide 'opencode-sidebar)
;;; opencode-sidebar.el ends here

