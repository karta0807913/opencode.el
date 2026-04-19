;;; opencode-session.el --- Session management for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Session CRUD operations and session list buffer.
;; Provides `opencode-session-mode' — a major mode for the session list
;; with magit-style sections, TAB-expandable file lists, and project grouping.

;;; Code:

(require 'subr-x)
(require 'opencode-faces)
(require 'opencode-ui)
(require 'opencode-log)
(require 'opencode-util)
(require 'opencode-api)

(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))
(declare-function opencode-window-display-buffer "opencode-window" (buffer))

(defvar opencode-default-directory)

(defgroup opencode-session nil
  "OpenCode session management."
  :group 'opencode
  :prefix "opencode-session-")

;;; --- Internal state ---

(defvar-local opencode-session--list nil
  "Cached list of sessions (vector of plists).")

(defvar-local opencode-session--status nil
  "Cached session status map (plist of session-id → status plist).")

(defvar-local opencode-session--expanded nil
  "Set of expanded session IDs (showing file lists).")

(defvar-local opencode-session--diffs nil
  "Cache of session ID → diff data (vector of file diff plists).")

(defvar-local opencode-session--buffer-session-id nil
  "Session ID associated with the current buffer.")

;;; --- Session list buffer name ---

(defvar-local opencode-session--project-dir nil
  "Project directory this session list buffer serves.")

(defun opencode-session--buffer-name (project-dir)
  "Return the session list buffer name for PROJECT-DIR."
  (format "*opencode: sessions<%s>*"
          (file-truename (directory-file-name project-dir))))

;;; --- API functions ---

(defun opencode-session--list (&optional query-params)
  "Fetch the session list from the server (internal).
QUERY-PARAMS is an optional alist of query parameters.
Returns a vector of session plists."
  (opencode-api-get-sync "/session" query-params))

(defun opencode-session-list (&optional query-params)
  "Fetch the session list from the server.
QUERY-PARAMS is an optional alist of query parameters.
Returns a vector of session plists."
  (opencode-session--list query-params))

(defun opencode-session-get (session-id)
  "Fetch a single session by SESSION-ID.
Returns a session plist."
  (opencode-api-get-sync (format "/session/%s" session-id)))

(defun opencode-session-create (&optional title parent-id)
  "Create a new session with optional TITLE and PARENT-ID.
Returns the created session plist."
  (let ((body '()))
    (when title (setq body (plist-put body :title title)))
    (when parent-id (setq body (plist-put body :parentID parent-id)))
    (opencode--debug "opencode-session: creating session, body=%S" body)
    (opencode-api-post-sync "/session" body)))

(defun opencode-session-rename (session-id title)
  "Rename session SESSION-ID to TITLE.
Uses PATCH /session/:sessionID to update session metadata.
Returns the updated session plist."
  (plist-get
   (opencode-api--request "PATCH" (format "/session/%s" session-id)
                          (list :title title))
   :body))

(defun opencode-session-delete (session-id)
  "Delete session SESSION-ID."
  (plist-get
   (opencode-api--request "DELETE" (format "/session/%s" session-id))
   :body))

(defun opencode-session-abort (session-id)
  "Abort the active prompt in session SESSION-ID."
  (opencode--debug "opencode-session: aborting session %s" session-id)
  (opencode-api-post-sync (format "/session/%s/abort" session-id)))

(defun opencode-session-compact (session-id &optional model-id provider-id)
  "Compact (summarize) session SESSION-ID.
Requires MODEL-ID and PROVIDER-ID for the summarization model.
Triggers a summarization of the session history on the server."
  (let ((body (list :modelID model-id :providerID provider-id)))
    (opencode-api-post-sync (format "/session/%s/summarize" session-id) body)))

(defun opencode-session-fork (session-id &optional message-id)
  "Fork session SESSION-ID at MESSAGE-ID.
Returns the new session plist."
  (opencode-api-post-sync (format "/session/%s/fork" session-id)
                           (when message-id
                             (list :messageID message-id))))

(defun opencode-session-share (session-id)
  "Create a share link for session SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/share" session-id)))

(defun opencode-session-unshare (session-id)
  "Delete the share link for session SESSION-ID."
  (opencode-api-post-sync (format "/session/%s/unshare" session-id)))

(defun opencode-session-revert (session-id message-id)
  "Revert session SESSION-ID to state before MESSAGE-ID.
This effectively \\='undoes\\=' the conversation back to that point."
  (opencode-api-post-sync (format "/session/%s/revert" session-id)
                           (list :messageID message-id)))

(defun opencode-session-unrevert (session-id)
  "Un-revert (redo) session SESSION-ID to its latest state."
  (opencode-api-post-sync (format "/session/%s/unrevert" session-id)))

(defun opencode-session-status-all ()
  "Fetch status of all active sessions.
Returns a plist mapping session IDs to status plists."
  (opencode-api-get-sync "/session/status"))

(defun opencode-session-diff (session-id &optional message-id)
  "Fetch file diffs for SESSION-ID, optionally for MESSAGE-ID."
  (opencode-api-get-sync
   (format "/session/%s/diff" session-id)
   (when message-id `(("messageID" . ,message-id)))))

;;; --- Session data helpers ---

(defun opencode-session--title (session)
  "Return the title of SESSION plist."
  (or (plist-get session :title) "(untitled)"))

(defun opencode-session--id (session)
  "Return the ID of SESSION plist."
  (plist-get session :id))

(defun opencode-session--project-name (session)
  "Return the project name for SESSION, extracted from directory."
  (let ((dir (plist-get session :directory)))
    (if dir
        (file-name-nondirectory (directory-file-name dir))
      "default")))

(defun opencode-session--time-ago (session)
  "Return human-readable time-ago string for SESSION."
  (let* ((time-data (plist-get session :time))
         (updated (or (and time-data (plist-get time-data :updated))
                      (plist-get session :updatedAt))))
    (opencode--time-ago updated)))

(defun opencode-session--archived-p (session)
  "Return non-nil if SESSION is archived."
  (let ((time-data (plist-get session :time)))
    (and time-data (plist-get time-data :archived)
         (> (plist-get time-data :archived) 0))))

(defun opencode-session--status-type (session-id)
  "Return the status type for SESSION-ID (idle, busy, retry, or nil)."
  (when opencode-session--status
    (when-let* ((status (plist-get opencode-session--status (intern session-id))))
      (plist-get status :type))))

(defun opencode-session--summary (session)
  "Return the summary plist for SESSION."
  (plist-get session :summary))

;;; --- Session list buffer ---

(defvar-keymap opencode-session-mode-map
  :doc "Keymap for `opencode-session-mode'."
  "RET" #'opencode-session-open-at-point
  "TAB" #'opencode-session-toggle-expand
  "n" #'opencode-session-new-interactive
  "d" #'opencode-session-delete-at-point
  "f" #'opencode-session-fork-at-point
  "g" #'opencode-session-refresh
  "s" #'opencode-session-search
  "q" #'quit-window)

(define-derived-mode opencode-session-mode special-mode "OpenCode Sessions"
  "Major mode for the OpenCode session list.

\\{opencode-session-mode-map}"
  :group 'opencode-session
  (setq truncate-lines t)
  (buffer-disable-undo))

;;; --- Session list rendering ---

(defun opencode-session--render ()
  "Render the session list buffer."
  (let ((inhibit-read-only t)
        (sessions (seq-remove (lambda (s) (plist-get s :parentID))
                              opencode-session--list))
        (groups (make-hash-table :test 'equal)))
    (erase-buffer)
    ;; Group sessions by project
    (when sessions
      (seq-doseq (session sessions)
        (let* ((archived (opencode-session--archived-p session))
               (group-key (if archived "Archived"
                            (opencode-session--project-name session))))
          (puthash group-key
                   (cons session (gethash group-key groups))
                   groups))))
    ;; Render each group
    (let ((group-keys (hash-table-keys groups)))
      ;; Sort: non-archived first, then alphabetical
      (setq group-keys
            (sort group-keys
                  (lambda (a b)
                    (cond ((string= a "Archived") nil)
                          ((string= b "Archived") t)
                          (t (string< a b))))))
      (dolist (group-key group-keys)
        (opencode-session--render-group
         group-key (nreverse (gethash group-key groups)))))
    ;; Footer
    (insert "\n")
    (opencode-ui--insert-separator)
    (insert (propertize "[RET] open  [TAB] expand files  [n] new  [d] delete  [f] fork  [g] refresh"
                        'face 'font-lock-comment-face)
            "\n")))

(defun opencode-session--render-group (name sessions)
  "Render a project group with NAME and SESSIONS."
  (insert "\n")
  (opencode-ui--insert-line name 'opencode-project-header)
  (insert "\n")
  (dolist (session sessions)
    (opencode-session--render-session session)))

(defun opencode-session--render-session (session)
  "Render a single SESSION entry."
  (let* ((id (opencode-session--id session))
         (title (opencode-session--title session))
         (time-ago (opencode-session--time-ago session))
         (archived (opencode-session--archived-p session))
         (status-type (opencode-session--status-type id))
         (summary (opencode-session--summary session))
         (section (opencode-ui--make-section 'session id session)))
    (opencode-ui--with-section section
      ;; Status icon + title
      (insert "  ")
      (cond
       (archived   (opencode-ui--insert-icon 'archived))
       ((string= status-type "busy") (opencode-ui--insert-icon 'active))
       (t          (opencode-ui--insert-icon 'idle)))
      (insert "  ")
      (insert (propertize title 'face
                          (cond (archived 'opencode-session-archived)
                                (t 'opencode-session-title))))
      ;; Right-align time
      (opencode-ui--insert-right-align 55)
      (insert (propertize time-ago 'face 'opencode-session-time))
      (insert "\n")
      ;; Stats line
      (when summary
        (let ((additions (or (plist-get summary :additions) 0))
              (deletions (or (plist-get summary :deletions) 0))
              (files (or (plist-get summary :files) 0)))
          (insert "     ")
          (insert (propertize (opencode--format-diff-stats additions deletions files)
                              'face 'opencode-session-stats))
          (opencode-ui--insert-right-align 55)
          (insert (propertize id 'face 'opencode-session-id))
          (insert "\n")))
      ;; Expanded file list
      (when (gethash id opencode-session--expanded)
        (opencode-session--render-file-list id))
      (insert "\n"))))

(defun opencode-session--render-file-list (session-id)
  "Render the expanded file list for SESSION-ID."
  (let ((diffs (gethash session-id opencode-session--diffs)))
    (when (and diffs (length> diffs 0))
      (let ((len (length diffs)))
        (seq-do-indexed
         (lambda (diff idx)
           (let* ((file (or (plist-get diff :file) (plist-get diff :path) "?"))
                  (status (or (plist-get diff :status) "modified"))
                  (additions (or (plist-get diff :additions) 0))
                  (deletions (or (plist-get diff :deletions) 0))
                  (last-p (= idx (1- len)))
                  (status-char (opencode--file-status-char status))
                  (status-face (pcase status
                                 ("modified" 'opencode-file-modified)
                                 ("added" 'opencode-file-added)
                                 ("deleted" 'opencode-file-deleted)
                                 ("renamed" 'opencode-file-renamed)
                                 (_ 'default)))
                  (section (opencode-ui--make-section 'file file diff)))
             (opencode-ui--with-section section
               (insert "     ")
               (opencode-ui--insert-tree-guide last-p)
               (insert (propertize status-char 'face status-face))
               (insert " ")
               (insert (propertize file 'face 'default
                                   'opencode-file-path file))
               (opencode-ui--insert-right-align 50)
               (insert (propertize (opencode--format-diff-stats additions deletions)
                                   'face 'opencode-session-stats))
               (insert "\n"))))
         diffs)))))

;;; --- Interactive commands ---

(defun opencode-session-open-at-point ()
  "Open the session or file at point."
  (interactive)
  (let ((section (opencode-ui--section-at)))
    (when section
      (pcase (plist-get section :type)
        ('session
         (let ((id (plist-get section :id)))
           (when id (opencode-chat-open id opencode-session--project-dir))))
        ('file
         (let ((path (get-text-property (point) 'opencode-file-path)))
           (when path (find-file-other-window path))))))))

(defun opencode-session-toggle-expand ()
  "Toggle file list expansion for the session at point."
  (interactive)
  (let ((section (opencode-ui--section-at)))
    (when (and section (eq (plist-get section :type) 'session))
      (let ((id (plist-get section :id)))
        (if (gethash id opencode-session--expanded)
            (progn
              (remhash id opencode-session--expanded)
              (opencode-session--rerender))
          (puthash id t opencode-session--expanded)
          ;; Fetch diffs if not cached, then re-render
          (if (gethash id opencode-session--diffs)
              (opencode-session--rerender)
            (opencode-api-get
             (format "/session/%s/diff" id)
             (lambda (response)
               (let ((body (plist-get response :body)))
                 (when body
                   (puthash id body opencode-session--diffs)))
               (opencode-session--rerender)))))))))

(defun opencode-session--rerender ()
  "Re-render the session list buffer."
  (let ((buf (current-buffer)))
    (when (and (buffer-live-p buf) (eq major-mode 'opencode-session-mode))
      (opencode-ui--save-excursion
        (opencode-session--render)))))

(defun opencode-session-new-interactive ()
  "Create a new session interactively."
  (interactive)
  (let ((title (read-string "Session title (optional): ")))
    (condition-case err
        (let ((session (opencode-session-create
                        (unless (string-empty-p title) title))))
          (opencode-session-refresh)
          (message "Created session: %s" (opencode-session--title session)))
      (error (message "Failed to create session: %s"
                      (error-message-string err))))))

(defun opencode-session-delete-at-point ()
  "Delete the session at point."
  (interactive)
  (let ((section (opencode-ui--section-at)))
    (when (and section (eq (plist-get section :type) 'session))
      (let ((id (plist-get section :id))
            (title (opencode-session--title (plist-get section :data))))
        (when (yes-or-no-p (format "Delete session \"%s\"? " title))
          (condition-case err
              (progn
                (opencode-session-delete id)
                (opencode-session-refresh)
                (message "Deleted session: %s" title))
            (error (message "Failed to delete: %s"
                            (error-message-string err)))))))))

(defun opencode-session-fork-at-point ()
  "Fork the session at point."
  (interactive)
  (let ((section (opencode-ui--section-at)))
    (when (and section (eq (plist-get section :type) 'session))
      (let ((id (plist-get section :id)))
        (condition-case err
            (let ((new-session (opencode-session-fork id)))
              (opencode-session-refresh)
              (message "Forked session: %s"
                       (opencode-session--title new-session)))
          (error (message "Failed to fork: %s"
                          (error-message-string err))))))))

(defun opencode-session-search ()
  "Search sessions by title."
  (interactive)
  (let ((query (read-string "Search sessions: ")))
    (condition-case err
        (progn
          (setq opencode-session--list
                (opencode-session-list `(("search" . ,query))))
          (opencode-session--render))
      (error (message "Search failed: %s" (error-message-string err))))))

(defun opencode-session-refresh ()
  "Refresh the session list (async).
Fetches session list and status without blocking Emacs."
  (interactive)
  (let ((buf (current-buffer))
        (dir opencode-session--project-dir))
    (opencode-api-get
     "/session"
     (lambda (response)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((body (plist-get response :body)))
             (when body
               (setq opencode-session--list body))))))
     (when dir `(("directory" . ,dir))))
    (opencode-api-get
     "/session/status"
     (lambda (resp2)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((status (plist-get resp2 :body)))
             (when status
               (setq opencode-session--status status)))
           (opencode-ui--save-excursion
             (opencode-session--render))))))))

;;; --- Open session list ---

(defun opencode-session--ensure-buffer (project-dir)
  "Ensure the session list buffer for PROJECT-DIR exists.
Returns the buffer."
  (let ((buf (get-buffer-create (opencode-session--buffer-name project-dir))))
    (with-current-buffer buf
      (unless (eq major-mode 'opencode-session-mode)
        (opencode-session-mode)
        (setq opencode-session--project-dir project-dir)
        (setq opencode-session--expanded (make-hash-table :test 'equal))
        (setq opencode-session--diffs (make-hash-table :test 'equal)))
      (opencode-session-refresh))
    buf))

(defun opencode-session-open-list (&optional project-dir)
  "Open the session list buffer for PROJECT-DIR."
  (interactive)
  (let ((buf (opencode-session--ensure-buffer
              (or project-dir opencode-default-directory default-directory))))
    (opencode-window-display-buffer buf)))

(provide 'opencode-session)
;;; opencode-session.el ends here
