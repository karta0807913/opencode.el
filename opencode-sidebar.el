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
(require 'opencode-backend-core)
(require 'opencode-chat-state)
(require 'opencode-pipeline)
(require 'opencode-pipeline-view)

(declare-function opencode--register-sidebar-buffer "opencode" (&rest args))
(declare-function opencode--deregister-sidebar-buffer "opencode" (&rest args))
(declare-function opencode--chat-buffer-for-session "opencode" (session-id))
(declare-function opencode--all-chat-buffers "opencode" ())
(declare-function opencode--ensure-ready "opencode" ())
(declare-function opencode--open-chat-picker "opencode"
                  (&optional session-id backend directory))
(declare-function opencode-chat-open "opencode-chat"
                  (session-id &optional directory display-action backend))

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
  "Deprecated maximum number of sessions to fetch per project.
This option is retained for compatibility but is no longer used."
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

(defvar-local opencode-sidebar--last-main-window nil
  "Most recent non-sidebar window that focused the sidebar.")

(defvar-local opencode-sidebar--status-store (make-hash-table :test 'equal)
  "Hash: session-id (string) → status symbol.
Single source of truth for session status icons.
Updated exclusively from SSE events.
Values: busy, idle, retry, question, permission.")

(defvar-local opencode-sidebar--known-project-dirs nil
  "List of known project directories.
Includes primary + discovered from open chat buffers + SSE events.")

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
        (let* ((all
                (and dir
                     (opencode-backend-cached-project-sessions
                      dir 'opencode)))
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
    (dolist (buf (opencode--all-chat-buffers))
      (let* ((session (with-current-buffer buf
                        (opencode-chat--session)))
             (sid (with-current-buffer buf
                    (opencode-chat--session-id))))
        (when (and sid
                   (not (opencode-sidebar--ancestor-opened-p session)))
          (puthash sid t ids))))
    ids))

(defun opencode-sidebar--opened-session-items ()
  "Build session item plists for all opened sessions (cross-project).
Reads session data from each chat buffer's cached session plist.
Excludes child sessions whose parent is also opened."
  (let ((items '()))
    (dolist (buf (opencode--all-chat-buffers))
      (let* ((session (with-current-buffer buf (opencode-chat--session)))
             (sid (with-current-buffer buf (opencode-chat--session-id))))
        ;; Skip child sessions if any ancestor is also opened
        (when (and sid
                   (not (opencode-sidebar--ancestor-opened-p session)))
          (push (list :key (concat "session/" sid)
                      :session-id sid
                      :title (or (and session (plist-get session :title))
                                 "(untitled)")
                      :time (and session (plist-get session :time))
                      :summary (and session (plist-get session :summary))
                      :opened t)
                items))))
    (nreverse items)))

(defun opencode-sidebar--discover-project-dirs ()
  "Discover project directories from open chat buffers.
Adds any new directories to `opencode-sidebar--known-project-dirs'."
  (dolist (buf (opencode--all-chat-buffers))
    (let* ((session (with-current-buffer buf (opencode-chat--session)))
           (dir (and session (plist-get session :directory))))
      (when (and dir (not (member dir opencode-sidebar--known-project-dirs)))
        (push dir opencode-sidebar--known-project-dirs)))))

;;; --- Rendering helpers ---

(defcustom opencode-sidebar-global-project-name "(global)"
  "Display name for OpenCode's `global' project.

That project has \"/\" as its worktree, so its basename is empty and
there is no meaningful directory name to show."
  :type 'string
  :group 'opencode-sidebar)

(defun opencode-sidebar--project-name (dir)
  "Return a non-empty display name for project directory DIR.

Treemacs puts the `button' text property on the label text alone, so a
node rendered with an empty label carries no button at all: point can
never land on it, and it can be neither selected nor expanded.  Project
labels must therefore never be empty.

The plain basename is empty for a root worktree -- OpenCode's `global'
project has \"/\" as its worktree -- so name that one after
`opencode-sidebar-global-project-name', fall back to the path itself
via `opencode--shorten-path' otherwise, and to a placeholder when there
is no path at all."
  (let ((name (opencode--shorten-path dir)))
    (cond
     ((null name) "(unknown)")
     ((equal name "/") opencode-sidebar-global-project-name)
     (t name))))

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
                   (proj (and dir (opencode-sidebar--project-name dir))))
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
Shows \"(refreshing)\" indicator when a fetch is in-flight.
Never returns an empty string: a label-less node has no treemacs button
and so cannot be selected or expanded."
  (let* ((dir (plist-get item :project-dir))
         (raw-name (plist-get item :group-name))
         (name (if (and (stringp raw-name) (not (string-empty-p raw-name)))
                   raw-name
                 (opencode-sidebar--project-name dir))))
    (if (and dir
             (opencode-backend-project-sessions-refreshing-p
              dir 'opencode))
        (propertize (concat name " (refreshing)") 'face 'treemacs-directory-face)
      (propertize name 'face 'treemacs-directory-face))))

(defun opencode-sidebar--pipeline-execution-label (item)
  "Build a display label for pipeline execution ITEM."
  (let* ((view (plist-get item :pipeline-view))
         (title (plist-get view :title))
         (directory (plist-get view :directory))
         (project
          (and directory (opencode-sidebar--project-name directory)))
         (status (plist-get view :status))
         (current (plist-get view :current)))
    (concat
     (when project
       (propertize (format "[%s] " project)
                   'face 'treemacs-git-ignored-face))
     (propertize title 'face 'treemacs-directory-face)
     (propertize
      (format "  %s%s"
              status
              (if current (format " · %s" current) ""))
      'face 'treemacs-git-ignored-face))))

(defun opencode-sidebar--pipeline-node-label (item)
  "Build a display label for pipeline session node ITEM."
  (let* ((node-view (plist-get item :pipeline-node-view))
         (node-symbol (plist-get node-view :symbol))
         (status (plist-get node-view :status))
         (retry (plist-get node-view :retry-index))
         (retry-count (plist-get node-view :retry-count)))
    (concat
     (propertize (symbol-name node-symbol) 'face 'treemacs-directory-face)
     (propertize
      (format "  %s%s"
              status
              (if (> retry 0)
                  (format " · retry %d/%d" retry retry-count)
                ""))
      'face 'treemacs-git-ignored-face))))

(defun opencode-sidebar--pipeline-status-icon (status &optional indent)
  "Return an icon for pipeline STATUS.
When INDENT is non-nil, prefix the icon for a child row."
  (concat
   (if indent "  " "")
   (pcase status
     ('running   (propertize "⬤ " 'face 'opencode-session-active))
     ('retrying  (propertize "⬤ " 'face 'opencode-session-active))
     ('completed (propertize "✓ " 'face 'success))
     ('failed    (propertize "! " 'face 'error))
     ('stopped   (propertize "■ " 'face 'shadow))
     (_          (propertize "○ " 'face 'opencode-session-idle)))))

(defun opencode-sidebar--pipeline-execution-items ()
  "Return sidebar items for current pipeline executions."
  (mapcar
   (lambda (view)
     (let ((entry (plist-get view :entry))
           (execution-id (plist-get view :id)))
        (list :key (format "pipeline/%s/%s" entry execution-id)
              :pipeline-entry entry
              :pipeline-execution-id execution-id
              :pipeline-view view)))
    (opencode-pipeline-view-current-executions)))

(defun opencode-sidebar--pipeline-node-items (execution-view)
  "Return pipeline session-node items for EXECUTION-VIEW.
EXECUTION-VIEW is an immutable view plist produced by
`opencode-pipeline-view-execution'."
  (mapcar
   (lambda (node-view)
     (let ((node-symbol (plist-get node-view :symbol)))
       (list :key
               (format "pipeline/%s/%s/node/%s"
                       (plist-get execution-view :entry)
                       (plist-get execution-view :id)
                       node-symbol)
              :pipeline-entry (plist-get execution-view :entry)
              :pipeline-execution-id (plist-get execution-view :id)
              :pipeline-view execution-view
              :pipeline-node node-symbol
              :pipeline-node-view node-view
              :session-id (plist-get node-view :session-id)
              :title (symbol-name node-symbol)
              :project-dir (or (plist-get node-view :directory)
                               opencode-sidebar--primary-project-dir)
              :backend (or (plist-get node-view :backend)
                           opencode-backend-current))))
   (plist-get execution-view :nodes)))

;;; --- Actions ---

(defun opencode-sidebar--node-at-point ()
  "Return the treemacs node at point, or nil."
  (treemacs-node-at-point))

(defun opencode-sidebar--find-main-window ()
  "Return a non-sidebar window for content display.
Explicitly skips sidebar buffer windows and minibuffer.
If no suitable window exists, split the frame to create one."
  (let ((sidebar-buf (current-buffer)))
    (or (and (window-live-p opencode-sidebar--last-main-window)
             (not (eq (window-buffer opencode-sidebar--last-main-window) sidebar-buf))
             (not (window-minibuffer-p opencode-sidebar--last-main-window))
             opencode-sidebar--last-main-window)
        (seq-find
         (lambda (w)
           (and (not (eq (window-buffer w) sidebar-buf))
                (not (window-minibuffer-p w))))
         (window-list))
        (split-window (frame-root-window) nil 'right))))

(defun opencode-sidebar--remember-main-window (window)
  "Remember WINDOW as the main content window for sidebar RET actions."
  (when (and (window-live-p window)
             (not (eq (window-buffer window) (current-buffer)))
             (not (window-minibuffer-p window)))
    (setq opencode-sidebar--last-main-window window)))

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
            ;; Pipeline children carry their owning view too, so route them
            ;; before the execution row itself.
           ((plist-get item :pipeline-node)
            (if (plist-get item :session-id)
                (opencode-sidebar--open-session-in-window item target-win)
             (message "Pipeline node %s has no bound session yet"
                      (plist-get item :pipeline-node))))
             ;; Pipeline execution — open the interactive SVG status graph.
             ((plist-get item :pipeline-view)
              (select-window target-win)
              (opencode-pipeline-describe
               (or (opencode-pipeline-store-find-execution
                    (plist-get item :pipeline-execution-id))
                   (user-error "Pipeline execution no longer exists"))))
           ;; Session node — has :session-id
           ((plist-get item :session-id)
            (opencode-sidebar--open-session-in-window item target-win))))))))

(defun opencode-sidebar--open-session-in-window (item target-win)
  "Open the session described by ITEM in TARGET-WIN."
  (let ((session-id (plist-get item :session-id))
        (project-dir (opencode-sidebar--session-project-dir item))
        (backend (plist-get item :backend)))
    (select-window target-win)
    (opencode-chat-open session-id project-dir nil backend)))

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
  "Remove the pipeline execution or close/delete the session at point.
Pipeline child nodes are intentionally unaffected: their sessions remain.
In the Opened Session group, kill the chat buffer.  In project groups,
delete the session after confirmation."
  (interactive)
  (when-let ((node (opencode-sidebar--node-at-point)))
    (let ((item (button-get node :item)))
      (cond
        ;; A pipeline child is a reference to a session, not an owned session
        ;; record.  Child items also carry :pipeline-view, so this most
        ;; specific case must precede execution-row handling.
        ((and item (plist-get item :pipeline-node))
         nil)
        ;; Remove only the execution projection/runtime object.  Sessions are
        ;; retained.  Active executions must be stopped explicitly first.
        ((and item (plist-get item :pipeline-view))
          (let* ((view (plist-get item :pipeline-view))
                 (status (plist-get view :status))
                 (execution
                  (opencode-pipeline-store-find-execution
                   (plist-get item :pipeline-execution-id))))
           (unless execution
             (user-error "Pipeline execution no longer exists"))
           (when (memq status '(running stopping))
             (user-error "Stop pipeline before removing it"))
           (opencode-pipeline-reset execution)
           (opencode-sidebar--rerender)
           (message "Removed pipeline: %s"
                    (plist-get view :title))))
       ((and item (plist-get item :session-id))
        (if (plist-get item :opened)
            ;; Close: kill the chat buffer
            (let* ((sid (plist-get item :session-id))
                   (buf (opencode--chat-buffer-for-session sid)))
              (when (and buf (buffer-live-p buf))
                (kill-buffer buf))
              (opencode-sidebar--rerender))
          ;; Delete: confirm then delete
          (opencode-sidebar--delete-session-impl item)))))))

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

(defun opencode-sidebar--project-candidates (projects)
  "Build completion candidates from canonical PROJECTS.
Each candidate is a cons of a unique display label and project directory."
  (let ((seen (make-hash-table :test 'equal))
        candidates)
    (dolist (project (seq-into (or projects []) 'list))
      (when-let ((dir (plist-get project :directory)))
        (unless (gethash dir seen)
          (puthash dir t seen)
          (let* ((raw-name (plist-get project :name))
                 (name (if (and (stringp raw-name)
                                (not (string-empty-p raw-name)))
                           raw-name
                         (opencode-sidebar--project-name dir)))
                 (id (plist-get project :id))
                 (label (format "%s — %s%s"
                                name dir
                                (if (and id (not (equal id name)))
                                    (format " (%s)" id)
                                  ""))))
            (push (cons label dir) candidates)))))
    (nreverse candidates)))

(defun opencode-sidebar--read-project ()
  "Prompt for an OpenCode project and return its canonical directory."
  (unless (opencode-backend-supports-p 'list-projects 'opencode)
    (user-error "OpenCode backend does not support project listing"))
  (let* ((projects (opencode-backend-list-projects 'opencode))
         (candidates (opencode-sidebar--project-candidates projects)))
    (unless candidates
      (user-error "No OpenCode projects found"))
    (let ((choice (completing-read "OpenCode project: " candidates nil t)))
      (alist-get choice candidates nil nil #'equal))))

(defun opencode-sidebar--new-session-in-project (project-dir &optional backend)
  "Create a new session in PROJECT-DIR and open the chat buffer.
Prompts for an optional title.  BACKEND defaults to the current backend."
  (let* ((project-dir (and project-dir
                           (directory-file-name
                            (expand-file-name project-dir))))
         (opencode-default-directory
          (or project-dir opencode-default-directory))
         (sidebar-buf (current-buffer)))
    (condition-case err
        (let* ((title (read-string "Session title (optional): "))
               (_ (opencode--ensure-ready))
               (session (opencode-session-create
                         (if (string-empty-p title) nil title)
                         nil backend)))
          (when session
            (when (and project-dir
                       (not (member project-dir
                                    opencode-sidebar--known-project-dirs)))
              (push project-dir opencode-sidebar--known-project-dirs))
            (when project-dir
              (opencode-backend-invalidate-project-sessions
               project-dir 'opencode))
            (let ((target-win (opencode-sidebar--find-main-window)))
              (select-window target-win))
            (opencode-chat-open (plist-get session :id)
                                (or (plist-get session :directory)
                                    project-dir
                                    opencode-default-directory)
                                nil backend))
          (when (buffer-live-p sidebar-buf)
            (with-current-buffer sidebar-buf
              (opencode-sidebar--rerender))))
      (error
       (user-error "Failed to create session: %s" (error-message-string err))))))

(defun opencode-sidebar--new-session ()
  "Create a new session and open the chat buffer.
Prompts for an optional title.
The session is created in the project directory of the node at point."
  (interactive)
  (let* ((node (opencode-sidebar--node-at-point))
         (item (and node (button-get node :item)))
         (project-dir (or (plist-get item :project-dir)
                          opencode-sidebar--primary-project-dir)))
    (opencode-sidebar--new-session-in-project project-dir)))

(defun opencode-sidebar--chat-choose-project ()
  "Choose an OpenCode project, then run the regular chat picker there.
This is the sidebar equivalent of `C-c o c' after selecting a project."
  (interactive)
  (let ((sidebar-win (selected-window))
        (project-dir
         (condition-case err
             (progn
               (opencode--ensure-ready)
               (opencode-sidebar--read-project))
           (quit
            (signal 'quit nil))
            (error
             (user-error "Failed to choose project: %s"
                         (error-message-string err))))))
    (let ((target-win (opencode-sidebar--find-main-window)))
      (select-window target-win)
      (condition-case err
          (opencode--open-chat-picker nil 'opencode project-dir)
        (quit
         (when (window-live-p sidebar-win)
           (select-window sidebar-win))
         (signal (car err) (cdr err)))))))

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
  (let* ((all-sessions
          (opencode-backend-cached-project-sessions
           (or project-dir opencode-sidebar--primary-project-dir)
           'opencode))
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
  :closed-icon
  (cond
   ((plist-get item :file-path) "  ")
    ((plist-get item :pipeline-node)
     (opencode-sidebar--pipeline-status-icon
      (plist-get (plist-get item :pipeline-node-view) :status)
      t))
   (t (opencode-sidebar--child-session-icon item)))
  :open-icon
  (cond
   ((plist-get item :file-path) "  ")
    ((plist-get item :pipeline-node)
     (opencode-sidebar--pipeline-status-icon
      (plist-get (plist-get item :pipeline-node-view) :status)
      t))
   (t (opencode-sidebar--child-session-icon item)))
  :label
  (cond
   ((plist-get item :file-path)
    (opencode-sidebar--file-label item))
   ((plist-get item :pipeline-node)
    (opencode-sidebar--pipeline-node-label item))
   (t (opencode-sidebar--child-session-label item)))
  :key (plist-get item :key)
  :children
  (let ((session-id (plist-get item :session-id))
        (project-dir (plist-get item :project-dir)))
    (if (or (plist-get item :file-path)
            (plist-get item :pipeline-node))
        (funcall callback nil)
      (funcall callback
               (opencode-sidebar--build-subagent-children session-id project-dir))))
  :child-type 'opencode-sidebar-child
  :async? t
  :ret-action #'opencode-sidebar--ret-action)

;; Expandable: session node (async children via diff + message APIs)
(treemacs-define-expandable-node-type opencode-session
  :closed-icon
  (if-let ((view (plist-get item :pipeline-view)))
      (concat "▸ "
              (opencode-sidebar--pipeline-status-icon
               (plist-get view :status)))
    (opencode-sidebar--session-icon item nil))
  :open-icon
  (if-let ((view (plist-get item :pipeline-view)))
      (concat "▾ "
              (opencode-sidebar--pipeline-status-icon
               (plist-get view :status)))
    (opencode-sidebar--session-icon item t))
  :label
  (if (plist-get item :pipeline-view)
      (opencode-sidebar--pipeline-execution-label item)
    (opencode-sidebar--session-label item))
  :key (plist-get item :key)
  :children
  (if-let ((view (plist-get item :pipeline-view)))
      (funcall callback
               (opencode-sidebar--pipeline-node-items view))
    (let ((session-id (plist-get item :session-id))
          (project-dir (or (plist-get item :project-dir)
                           opencode-sidebar--primary-project-dir))
          (buf (current-buffer)))
      (opencode-sidebar--log "EXPAND >>> sid=%s" session-id)
      (let ((opencode-default-directory
             (or project-dir opencode-default-directory)))
        (opencode-backend-get-diff
         session-id
         (lambda (response)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (condition-case err
                   (let* ((diff-body (plist-get response :body))
                          (diff-entries
                           (and diff-body (seq-into diff-body 'list)))
                          (files (opencode-sidebar--build-file-children
                                  session-id diff-entries))
                          (subagents
                           (opencode-sidebar--build-subagent-children
                            session-id project-dir))
                          (children (append subagents files)))
                     (opencode-sidebar--log
                      "EXPAND <<< sid=%s children=%d"
                      session-id (length children))
                     (let ((inhibit-read-only t))
                       (funcall callback children)))
                 (error
                  (opencode-sidebar--log
                   "EXPAND error: %s"
                   (error-message-string err)))))))))))
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
       ('pipeline
        (funcall callback (opencode-sidebar--pipeline-execution-items)))
       ('opened
        ;; Synchronous: read from public chat-buffer registry accessors.
        (let ((items (opencode-sidebar--opened-session-items)))
          (funcall callback items)))
      ('project
       ;; Read from cache or fetch async
        (let* ((opened-ids (opencode-sidebar--opened-session-ids))
               (cached
                (opencode-backend-cached-project-sessions
                 project-dir 'opencode)))
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
            (opencode-backend-fetch-project-sessions
             project-dir
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
                       (funcall callback items)))))
             nil 'opencode)))))))
  :child-type 'opencode-session
  :async? t)

;; Variadic root: invisible container for all groups
(treemacs-define-variadic-entry-node-type opencode-sidebar-root
  :key 'opencode-sidebar-root
  :children
  (progn
    ;; Discover project dirs from open chat buffers.
    (opencode-sidebar--discover-project-dirs)
    (let* ((opened-group (list :key "group/opened"
                               :group-name "Opened Session"
                               :group-type 'opened))
           (pipeline-group (list :key "group/pipeline"
                                 :group-name "Pipeline"
                                 :group-type 'pipeline))
           (primary-dir opencode-sidebar--primary-project-dir)
           (primary-name (and primary-dir
                              (opencode-sidebar--project-name primary-dir)))
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
                                  :group-name (opencode-sidebar--project-name dir)
                                  :group-type 'project
                                  :project-dir dir))
                          other-dirs))
           (groups (list opened-group pipeline-group)))
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
  "c" #'opencode-sidebar--new-session
  "C" #'opencode-sidebar--chat-choose-project)

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
    (opencode-backend-invalidate-project-sessions project-dir 'opencode)
    (opencode-sidebar--rerender) ; show refreshing indicator
    (opencode-backend-fetch-project-sessions
     project-dir
     (lambda (_sessions)
       (when (buffer-live-p buf)
         (with-current-buffer buf
            (opencode-sidebar--rerender))))
     t 'opencode)))

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
    (opencode-backend-ensure-ready 'opencode)
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
               (opencode-backend-cached-project-sessions
                event-dir 'opencode))
      (opencode-backend-invalidate-project-sessions event-dir 'opencode)
      ;; Re-fetch asynchronously (never block the SSE filter)
      (opencode-backend-fetch-project-sessions
       event-dir
       (lambda (_sessions)
         (opencode-sidebar--schedule-rerender))
       nil 'opencode))
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

(defun opencode-sidebar--on-pipeline-state-changed (&rest _)
  "Rerender the sidebar after a pipeline state change."
  (when-let ((buf (get-buffer opencode-sidebar--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (opencode-sidebar--schedule-rerender)))))

(advice-add 'opencode--register-chat-buffer :after
            #'opencode-sidebar--on-chat-registry-change)
(advice-add 'opencode--deregister-chat-buffer :after
            #'opencode-sidebar--on-chat-registry-change)
(add-hook 'opencode-pipeline-state-changed-hook
          #'opencode-sidebar--on-pipeline-state-changed)

(provide 'opencode-sidebar)
;;; opencode-sidebar.el ends here
