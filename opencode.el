;;; opencode.el --- Emacs 30 frontend for OpenCode AI agent -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; Author: opencode.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (markdown-mode "2.6"))
;; Keywords: tools, ai, coding
;; URL: https://github.com/user/opencode.el
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Emacs 30 frontend for the OpenCode AI coding agent.
;; Talks to the OpenCode HTTP REST API and SSE event stream.
;;
;; Usage:
;;   M-x opencode-start    — Start the OpenCode server and connect
;;   M-x opencode-attach   — Attach to an existing server by port
;;   M-x opencode-chat     — Open a chat buffer for a session
;;   C-c o                 — Global command prefix (customizable)
;;
;; Features:
;;   - Spawns and manages the `opencode serve' subprocess
;;   - Real-time streaming via Server-Sent Events (SSE)
;;   - Session management with project grouping
;;   - Chat buffer with message rendering (text, tool calls, reasoning)
;;   - Floating frames and side window display modes
;;
;; Emacs 30 features used:
;;   - Native JSON (json-parse-string / json-serialize)
;;   - Native tree-sitter (for future code block highlighting)
;;   - visual-wrap-prefix-mode, visual-line-mode
;;   - mode-line-format-right-align
;;   - fast-read-process-output (default for SSE streaming)
;;   - display-buffer category entry
;;   - Styled underlines (dashes, dots, double-line)
;;   - font-lock-*-face (number, bracket, escape, function-call)
;;   - seq-keep, seq-do-indexed

;;; Code:

(require 'opencode-log)
(require 'opencode-markdown)
(require 'opencode-faces)
(require 'opencode-server)
(require 'opencode-api)
(require 'opencode-agent)
(require 'opencode-config)
(require 'opencode-domain)
(require 'opencode-event)
(require 'opencode-sse)
(require 'opencode-ui)
(require 'opencode-window)
(require 'opencode-session)
(require 'opencode-chat)
(require 'opencode-command)
(require 'opencode-permission)
(require 'opencode-question)
(require 'opencode-todo)
(require 'opencode-sidebar)
(require 'project)
(require 'seq)

;;; --- Customization group ---

(defgroup opencode nil
  "Emacs frontend for the OpenCode AI coding agent."
  :group 'tools
  :prefix "opencode-"
  :link '(url-link :tag "Homepage" "https://github.com/user/opencode.el"))

;;; --- Customization ---

(defcustom opencode-keymap-prefix "C-c o"
  "Prefix key for the opencode command map.
Change this before loading opencode.el or call
`opencode--setup-keymap' after changing."
  :type 'string
  :group 'opencode)

(defcustom opencode-default-directory nil
  "Default project directory for OpenCode.
When nil, uses `default-directory' of the current buffer."
  :type '(choice (const :tag "Use current buffer directory" nil)
                 (directory :tag "Fixed directory"))
  :group 'opencode)

;;; --- Version ---

(defconst opencode-version "0.1.0"
  "Version of opencode.el.")

;;; --- Global command map ---

(defvar-keymap opencode-command-map
  :doc "Global opencode commands (bound under opencode-keymap-prefix)."
  "o" #'opencode-start
  "O" #'opencode-attach
  "c" #'opencode-chat
  "l" #'opencode-list-sessions
  "n" #'opencode-new-session
  "a" #'opencode-abort
  "t" #'opencode-toggle-sidebar
  "q" #'opencode-disconnect
  "r" #'opencode-refresh)

;;; --- Minor mode ---

(defvar opencode-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map opencode-keymap-prefix opencode-command-map)
    map)
  "Keymap for `opencode-mode'.")

(defvar opencode--modeline-string nil
  "Current modeline string for opencode-mode.")

(defun opencode--modeline-update ()
  "Update the modeline string based on connection state."
  (setq opencode--modeline-string
        (cond
         ((opencode-server-connected-p)
          (propertize " OC:connected" 'face 'success))
         ((eq opencode-server--status 'starting)
          (propertize " OC:starting" 'face 'warning))
         (t
          (propertize " OC:off" 'face 'shadow))))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode opencode-mode
  "Global minor mode for the OpenCode AI coding agent.
When enabled, provides the `C-c o' prefix keymap and modeline indicator.

\\{opencode-mode-map}"
  :global t
  :lighter opencode--modeline-string
  :keymap opencode-mode-map
  :group 'opencode
  (if opencode-mode
      (progn
        (opencode--modeline-update)
        (add-hook 'opencode-server-connected-hook #'opencode--on-connected)
        (add-hook 'opencode-server-disconnected-hook #'opencode--on-disconnected))
    (remove-hook 'opencode-server-connected-hook #'opencode--on-connected)
    (remove-hook 'opencode-server-disconnected-hook #'opencode--on-disconnected)
    (opencode--modeline-update)))

;;; --- Hooks ---

(defun opencode--on-connected ()
  "Handle server connected event."
  (opencode--modeline-update)
  (message "OpenCode: connected on port %s" opencode-server--port)
  ;; Invalidate all micro-caches so we get fresh data from this server
  (opencode-api-invalidate-all-caches)
  ;; Load caches (startup-safe: failures are non-fatal, retried on next open)
  (opencode-api-cache-ensure-loaded)
  ;; Pre-warm commands cache so slash completion is instant
  (opencode-config-prewarm)
  ;; Always connect SSE when server connects
  (opencode-sse-connect))

(defun opencode--on-disconnected ()
  "Handle server disconnected event."
  (opencode--modeline-update)
  (message "OpenCode: disconnected"))

;;; --- Interactive commands ---

(defun opencode--ensure-directory ()
  "Ensure `opencode-default-directory' is set to the project root.
When nil, resolves using the same order as `opencode-start':
  1. Project root via `project-current' (detects .git, .hg, etc.)
  2. `default-directory' of the current buffer
Called from entry points that may bypass `opencode-start' (e.g.
`opencode-chat', `opencode-new-session')."
  (unless opencode-default-directory
    (setopt opencode-default-directory
            (directory-file-name
             (expand-file-name
              (or (when-let* ((proj (project-current t)))
                    (project-root proj))
                  default-directory))))))

(defun opencode--ensure-ready ()
  "Ensure opencode-mode is active and server is connected.
Activates `opencode-mode' if not already active, ensures the server
is connected, and sets the project directory."
  (unless opencode-mode (opencode-mode 1))
  (opencode-server-ensure)
  (opencode--ensure-directory))


;;;###autoload
(defun opencode-start (&optional directory)
  "Start the OpenCode server and connect.
DIRECTORY is the project directory.  When nil, the resolution order is:
  1. `opencode-default-directory' (if set)
  2. Project root via `project-current' (detects .git, .hg, etc.)
  3. `default-directory' of the current buffer
When called interactively with a prefix argument, prompts for the directory."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "OpenCode project directory: "))))
  (unless opencode-mode
    (opencode-mode 1))
  (let ((dir (directory-file-name
              (expand-file-name
               (or directory
                   opencode-default-directory
                   (when-let* ((proj (project-current t)))
                     (project-root proj))
                   default-directory)))))
    ;; Persist so API headers and sidebar use the same root
    (setopt opencode-default-directory dir)
    (opencode-server-start dir)
    ;; Open session list after server is ready (one-shot)
    (add-hook 'opencode-server-connected-hook #'opencode--open-session-list)))

;;;###autoload
(defun opencode-attach (url &optional directory)
  "Attach to an already-running OpenCode server at URL.
Unlike `opencode-start', this never spawns a subprocess.
URL can be:
  - A full URL: \"http://remote-host:4096\"
  - host:port:  \"remote-host:4096\"
  - Just a port: \"4096\"
DIRECTORY is the project directory (same resolution as `opencode-start').
Interactively, prompts for URL; with prefix arg also prompts for DIRECTORY."
  (interactive
   (list (read-string "OpenCode server URL (host:port or port): "
                      (if opencode-server-port
                          (format "%s:%d" opencode-server-host
                                  opencode-server-port)
                        "127.0.0.1:4096"))
         (when current-prefix-arg
           (read-directory-name "OpenCode project directory: "))))
  (unless opencode-mode
    (opencode-mode 1))
  (pcase-let ((`(,host . ,port) (opencode--parse-server-url url)))
    (let ((dir (directory-file-name
                (expand-file-name
                 (or directory
                     opencode-default-directory
                     (when-let* ((proj (project-current t)))
                       (project-root proj))
                     default-directory)))))
      (setopt opencode-default-directory dir)
      (setq opencode-server-host host
            opencode-server-port port)
      (opencode-server-start dir))))

(defun opencode--parse-server-url (input)
  "Parse INPUT into a (HOST . PORT) cons.
Accepts formats:
  \"http://host:port\"  → (\"host\" . port)
  \"host:port\"         → parsed as \"http://host:port\"
  \"port\"              → (\"127.0.0.1\" . port)
Uses `url-generic-parse-url' for robust parsing."
  (cond
   ;; Bare port number
   ((string-match-p "^[0-9]+$" input)
    (let ((port (string-to-number input)))
      (if (> port 0)
          (cons "127.0.0.1" port)
        (user-error "Invalid port: %s" input))))
   ;; Anything else — normalize to a URL and parse
   (t
    (let* ((url-str (if (string-match-p "^https?://" input)
                        input
                      (concat "http://" input)))
           (parsed (url-generic-parse-url url-str))
           (host (url-host parsed))
           (port (url-port parsed)))
      (when (or (null host) (string-empty-p host))
        (user-error "Cannot parse host from: %s" input))
      (cons host port)))))

(defun opencode--open-session-list ()
  "Open the session list after server is ready.
Runs once, then removes itself from the hook."
  (remove-hook 'opencode-server-connected-hook #'opencode--open-session-list)
  ;; preheat the cache
  (opencode-api--agents :callback (lambda (resp) resp))
  (opencode-api--providers :callback (lambda (resp) resp))
  (opencode-session-open-list opencode-default-directory))

;;;###autoload
(defun opencode-chat (&optional session-id)
  "Open a chat buffer for SESSION-ID.
If SESSION-ID is nil, prompts for a session from the list.
The completion list includes a \"\u2605 New session\" option at the top.
Auto-connects to the server if `opencode-server-port' is set.
The session list is scoped to the current buffer's project (via
`project-current'), so switching projects shows the right sessions."
  (interactive)
  (opencode--ensure-ready)
  ;; Use current buffer's project so the session list is scoped correctly
  ;; even when opencode-default-directory points to a different project.
  (let* ((current-dir (or (when-let ((proj (project-current)))
                            (project-root proj))
                          opencode-default-directory
                          default-directory))
         (opencode-default-directory current-dir)
         (result (or (and session-id (cons session-id nil))
                     (opencode--read-session "Chat session: "))))
    (when result
      (if (eq result 'new)
          (opencode-new-session)
        (opencode-chat-open (car result) (or (cdr result)
                                               current-dir))))))

;;;###autoload
(defun opencode-list-sessions ()
  "Open the session list buffer for the current project."
  (interactive)
  (opencode--ensure-ready)
  (opencode-session-open-list
   (or (when-let* ((proj (project-current)))
         (project-root proj))
       opencode-default-directory
       default-directory)))

;;;###autoload
(defun opencode-new-session (&optional title)
  "Create a new session with optional TITLE and open it."
  (interactive "sSession title (empty for untitled): ")
  (opencode--ensure-ready)
  (let* ((title (if (and title (not (string-empty-p title))) title nil))
         (session (opencode-session-create title)))
    (when session
      (opencode-chat-open (plist-get session :id)
                          (plist-get session :directory)))))

;;;###autoload
(defun opencode-abort ()
  "Abort the current generation in the active chat buffer."
  (interactive)
  (let ((buf (opencode--current-chat-buffer)))
    (if buf
        (with-current-buffer buf
          (opencode-chat-abort))
      (message "No active chat buffer"))))

;;;###autoload
(defun opencode-toggle-sidebar ()
  "Toggle the OpenCode session sidebar."
  (interactive)
  (opencode-window-toggle-sidebar))

;;;###autoload
(defun opencode-disconnect ()
  "Disconnect from the OpenCode server and stop the subprocess."
  (interactive)
  (opencode-sse--disconnect)
  (opencode-server--stop)
  (opencode--modeline-update)
  (message "OpenCode: disconnected"))

;;;###autoload
(defun opencode-refresh ()
  "Refresh all cached data from the server.
Invalidates agent, config, and command caches, re-fetches everything,
and schedules a refresh for all open chat and sidebar buffers.
Same behavior as `server.instance.disposed'."
  (interactive)
  (opencode--do-rebootstrap)
  (message "OpenCode: refreshed"))
;;; --- Helpers ---
(defun opencode--read-session (prompt)
  "Read a session with completing read using PROMPT.
Returns a cons (ID . DIRECTORY) for a selected session, the symbol
`new' for a new session, or nil.
The \"★ New session\" option is always available at the top."
  (let* ((sessions (opencode-session--list))
         (session-candidates
          (when sessions
            (mapcar
             (lambda (s)
               (let* ((id (plist-get s :id))
                      (title (or (plist-get s :title) "(untitled)"))
                      (dir (or (plist-get s :directory) ""))
                      (description (format "%s — %s (%s)"
                                           title
                                           (file-name-nondirectory
                                            (directory-file-name dir))
                                           id)))
                 (cons (if-let ((parentID (plist-get s :parentID)))
                            (format " - [%s] %s" (substring parentID 0 (min (length parentID) 10)) description)
                         description)
                       (cons id dir))))
             (append sessions nil))))
         (candidates (cons '("★ New session" . new) session-candidates))
         (choice (completing-read prompt candidates nil t)))
    (alist-get choice candidates nil nil #'equal)))

(defun opencode--current-chat-buffer ()
  "Return the current or most recent chat buffer, or nil.
Prefers the current buffer if it is a chat buffer, then
checks the registry, falling back to `buffer-list' scan."
  (or (and (eq major-mode 'opencode-chat-mode) (current-buffer))
      (car (opencode--all-chat-buffers))
      (seq-find
       (lambda (buf)
         (with-current-buffer buf
           (eq major-mode 'opencode-chat-mode)))
       (buffer-list))))

;;; --- Buffer registry ---

(defvar opencode--chat-registry (make-hash-table :test 'equal)
  "Hash table mapping session-id (string) to chat buffer.
Used for O(1) dispatch of SSE events to the correct chat buffer.")

(defvar opencode--sidebar-buffer nil
  "The single global sidebar buffer, or nil.")

(defun opencode--register-chat-buffer (session-id buffer)
  "Register BUFFER as the chat buffer for SESSION-ID.
Skips registration if SESSION-ID is nil or BUFFER is not live."
  (when (and session-id (buffer-live-p buffer))
    (puthash session-id buffer opencode--chat-registry)))

(defun opencode--deregister-chat-buffer (session-id)
  "Deregister chat buffer for SESSION-ID."
  (remhash session-id opencode--chat-registry))

(defun opencode--register-sidebar-buffer (&rest _args)
  "Register the current buffer as the global sidebar buffer.
Arguments are accepted but ignored for backward compatibility."
  (setq opencode--sidebar-buffer (current-buffer)))

(defun opencode--deregister-sidebar-buffer (&rest _args)
  "Deregister the global sidebar buffer.
Arguments are accepted but ignored for backward compatibility."
  (setq opencode--sidebar-buffer nil))

(defun opencode--chat-buffer-for-session (session-id)
  "Return chat buffer registered for SESSION-ID, or nil if not found.
Auto-deregisters if buffer has been killed."
  (let ((buf (gethash session-id opencode--chat-registry)))
    (if (and buf (buffer-live-p buf))
        buf
      (progn
        (opencode--deregister-chat-buffer session-id)
        nil))))

(defun opencode--sidebar-buffer-for-project (&optional _project-dir)
  "Return the global sidebar buffer, or nil if not found.
_PROJECT-DIR is accepted but ignored (single global sidebar).
Auto-deregisters if buffer has been killed."
  (if (and opencode--sidebar-buffer (buffer-live-p opencode--sidebar-buffer))
      opencode--sidebar-buffer
    (setq opencode--sidebar-buffer nil)
    nil))

(defun opencode--all-chat-buffers ()
  "Return list of all live chat buffers in registry.
Auto-deregisters any entries with killed buffers."
  (let ((live-buffers '()))
    (maphash (lambda (session-id buf)
               (if (buffer-live-p buf)
                   (push buf live-buffers)
                 (opencode--deregister-chat-buffer session-id)))
             opencode--chat-registry)
    live-buffers))

(defun opencode--all-sidebar-buffers ()
  "Return list containing the global sidebar buffer if live."
  (if (and opencode--sidebar-buffer (buffer-live-p opencode--sidebar-buffer))
      (list opencode--sidebar-buffer)
    (setq opencode--sidebar-buffer nil)
    nil))

(defun opencode--dispatch-to-chat-buffer (session-id handler event)
  "Call HANDLER with EVENT in the chat buffer registered for SESSION-ID.
Does nothing if buffer not found or not live. Wraps handler in `condition-case'
 to handle errors during SSE storms."
  (let ((buf (opencode--chat-buffer-for-session session-id)))
    (when buf
      (with-current-buffer buf
        (condition-case err
            (funcall handler event)
          (error (opencode--debug "dispatch: handler error in %s: %S" (buffer-name) err)))))))

(defun opencode--dispatch-to-all-chat-buffers (handler event)
  "Call HANDLER with EVENT in every live chat buffer.
Wraps each call in `condition-case' to handle errors."
  (dolist (buf (opencode--all-chat-buffers))
    (with-current-buffer buf
      (condition-case err
          (funcall handler event)
        (error (opencode--debug "dispatch: handler error in %s: %S" (buffer-name) err))))))

(defun opencode--dispatch-to-sidebar-buffer (project-dir handler event)
  "Call HANDLER with EVENT in the sidebar buffer registered for PROJECT-DIR.
Does nothing if buffer not found or not live. Wraps handler in `condition-case'
 to handle errors during SSE storms."
  (let ((buf (opencode--sidebar-buffer-for-project project-dir)))
    (when buf
      (with-current-buffer buf
        (condition-case err
            (funcall handler event)
          (error (opencode--debug "dispatch: handler error in %s: %S" (buffer-name) err)))))))

(defun opencode--dispatch-to-all-sidebar-buffers (handler event)
  "Call HANDLER with EVENT in every live sidebar buffer.
Wraps each call in `condition-case' to handle errors."
  (dolist (buf (opencode--all-sidebar-buffers))
    (with-current-buffer buf
      (condition-case err
          (funcall handler event)
        (error (opencode--debug "dispatch: handler error in %s: %S" (buffer-name) err))))))


;;; --- Centralized SSE hook registration ---

;; All SSE event → handler wiring lives in opencode-event.el.  This section
;; just declares the routes.  Each call to `opencode-event-route' registers
;; a stable named symbol on the relevant `opencode-sse-*-hook' (deduplicating
;; on reload) and records the entry in `opencode-event-routes' for test
;; introspection.

;; Chat events: dispatch via session-id registry to the owning chat buffer.
(opencode-event-route "message.updated"
                      'opencode-sse-message-updated-hook
                      #'opencode-chat--on-message-updated 'chat)
(opencode-event-route "message.removed"
                      'opencode-sse-message-removed-hook
                      #'opencode-chat--on-message-removed 'chat)
(opencode-event-route "message.part.updated"
                      'opencode-sse-message-part-updated-hook
                      #'opencode-chat--on-part-updated 'chat)
(opencode-event-route "session.updated"
                      'opencode-sse-session-updated-hook
                      #'opencode-chat--on-session-updated 'chat)
(opencode-event-route "session.status"
                      'opencode-sse-session-status-hook
                      #'opencode-chat--on-session-status 'chat)
(opencode-event-route "session.idle"
                      'opencode-sse-session-idle-hook
                      #'opencode-chat--on-session-idle 'chat)
(opencode-event-route "session.diff"
                      'opencode-sse-session-diff-hook
                      #'opencode-chat--on-session-diff 'chat)
(opencode-event-route "session.deleted"
                      'opencode-sse-session-deleted-hook
                      #'opencode-chat--on-session-deleted 'chat)
(opencode-event-route "session.error"
                      'opencode-sse-session-error-hook
                      #'opencode-chat--on-session-error 'chat)
(opencode-event-route "session.compacted"
                      'opencode-sse-session-compacted-hook
                      #'opencode-chat--on-session-compacted 'chat)
(opencode-event-route "server.instance.disposed"
                      'opencode-sse-server-instance-disposed-hook
                      #'opencode-chat--on-server-instance-disposed 'chat)
(opencode-event-route "installation.update-available"
                      'opencode-sse-installation-update-available-hook
                      #'opencode-chat--on-installation-update-available 'chat)
(opencode-event-route "todo.updated"
                      'opencode-sse-todo-updated-hook
                      #'opencode-chat--on-todo-updated 'chat)

;; Popup events: dispatch to originating buffer AND root-parent buffer so
;; the prompt appears in both and dismisses together.  Async walk handles
;; cache misses; depth cap defends against server-returned cycles.
(opencode-event-route "permission.asked"
                      'opencode-sse-permission-asked-hook
                      #'opencode-permission--on-asked 'popup)
(opencode-event-route "question.asked"
                      'opencode-sse-question-asked-hook
                      #'opencode-question--on-asked 'popup)

;; Sidebar: session lifecycle + popup events rerender the tree.
(dolist (spec '(("session.updated.sidebar"  opencode-sse-session-updated-hook)
                ("session.status.sidebar"   opencode-sse-session-status-hook)
                ("session.idle.sidebar"     opencode-sse-session-idle-hook)
                ("session.deleted.sidebar"  opencode-sse-session-deleted-hook)
                ("question.asked.sidebar"   opencode-sse-question-asked-hook)
                ("question.replied.sidebar" opencode-sse-question-replied-hook)
                ("question.rejected.sidebar" opencode-sse-question-rejected-hook)
                ("permission.asked.sidebar" opencode-sse-permission-asked-hook)
                ("permission.replied.sidebar" opencode-sse-permission-replied-hook)))
  (opencode-event-route (car spec) (cadr spec)
                        #'opencode-sidebar--on-session-event 'sidebar))

;; Global events: run the handler directly, no buffer context needed.
(opencode-event-route "permission.replied"
                      'opencode-sse-permission-replied-hook
                      #'opencode-permission--on-replied 'global)
(opencode-event-route "question.replied"
                      'opencode-sse-question-replied-hook
                      #'opencode-question--on-replied 'global)
(opencode-event-route "question.rejected"
                      'opencode-sse-question-rejected-hook
                      #'opencode-question--on-rejected 'global)
(opencode-event-route "todo.updated.global"
                      'opencode-sse-todo-updated-hook
                      #'opencode-todo--on-updated 'global)

;; Backward-compatible alias: tests consult this name to discover the
;; chat dispatch mapping.  Derive from the introspectable route table
;; so the contract is the same as opencode-event-route's registration.
(defconst opencode--sse-chat-dispatch-specs
  (mapcar (lambda (route)
            (cons (nth 1 route) (nth 2 route)))
          (seq-filter (lambda (route) (eq (nth 3 route) 'chat))
                      opencode-event-routes))
  "Alist mapping SSE hooks to chat handler functions.
Derived from `opencode-event-routes'.  Kept for scenario-test
introspection; new code should read `opencode-event-routes' directly.")

;; SSE internal: rebootstrap on disposal (debounced)
(defvar opencode--rebootstrap-timer nil
  "Timer for debounced re-bootstrap after server disposal.")

(defun opencode--do-rebootstrap ()
  "Re-bootstrap after server instance disposal.
Re-fetches agent info and refreshes all chat/sidebar buffers.
Chat buffers are refreshed directly via `opencode-chat--refresh' (not
the debounced schedule-refresh) because `refresh' has a built-in busy
guard that skips the fetch when the session is streaming, marking the
buffer stale instead.  This prevents slow /message requests against a
busy server.  This does NOT disconnect SSE — the connection stays alive."
  (opencode--debug "opencode: re-bootstrap starting")
  ;; 1. Invalidate agent cache and kick off async re-fetch
  (opencode-agent-invalidate)
  (opencode-api--agents)
  ;; 2. Refresh all chat buffers via registry
  (dolist (buf (opencode--all-chat-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (opencode-chat--refresh))))
  ;; 3. Schedule rerender for the global sidebar
  (dolist (buf (opencode--all-sidebar-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (opencode-sidebar--schedule-rerender))))
  (opencode--debug "opencode: re-bootstrap complete"))

(defun opencode--on-instance-disposed (event)
  "Handle `server.instance.disposed' EVENT by triggering re-bootstrap.
Debounced to 0.5s to avoid flicker on rapid disposal events."
  (let ((dir (plist-get (plist-get event :properties) :directory)))
    (opencode--debug "opencode: instance disposed for %s, scheduling rebootstrap" dir))
  (when opencode--rebootstrap-timer
    (cancel-timer opencode--rebootstrap-timer))
  (setq opencode--rebootstrap-timer
        (run-with-idle-timer 0.5 nil #'opencode--do-rebootstrap)))

(defun opencode--on-global-disposed (_event)
  "Handle `global.disposed' EVENT by re-bootstrapping.
Uses the same debounced timer as `on-instance-disposed' so that rapid
sequences coalesce into a single re-bootstrap."
  (opencode--debug "opencode: global.disposed — scheduling rebootstrap")
  (when opencode--rebootstrap-timer
    (cancel-timer opencode--rebootstrap-timer))
  (setq opencode--rebootstrap-timer
        (run-with-idle-timer 0.5 nil #'opencode--do-rebootstrap)))

(defun opencode--on-tui-toast (event)
  "Handle `tui.toast.show' EVENT by displaying the message in the minibuffer."
  (when-let* ((props (plist-get event :properties))
              (msg (plist-get props :message)))
    (message "OpenCode: %s" msg)))

(add-hook 'opencode-sse-server-instance-disposed-hook #'opencode--on-instance-disposed)
(add-hook 'opencode-sse-global-disposed-hook #'opencode--on-global-disposed)

;; Toast: show server-side toast messages in the minibuffer
(add-hook 'opencode-sse-tui-toast-show-hook #'opencode--on-tui-toast)

;;; --- Cleanup ---

(defun opencode-cleanup ()
  "Kill all OpenCode buffers and stop the server.
Use this to fully reset the OpenCode state."
  (interactive)
  (clrhash opencode--chat-registry)
  (setq opencode--sidebar-buffer nil)
  (opencode-sse--disconnect)
  (opencode-server--stop)
  (dolist (buf (buffer-list))
    (when (string-prefix-p "*opencode:" (buffer-name buf))
      (kill-buffer buf)))
  (opencode--modeline-update)
  (message "OpenCode: cleaned up"))

(provide 'opencode)
;;; opencode.el ends here
