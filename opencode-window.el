;;; opencode-window.el --- Window and frame management for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Window and frame management for opencode.el.
;; Supports multiple display modes: side window, floating frame, split, full.
;; Uses Emacs 30 `display-buffer' infrastructure with `category' alist entry.

;;; Code:

(require 'seq)
(require 'project)
(require 'opencode-sidebar)
(require 'opencode-server)

(defvar opencode-default-directory)

(defgroup opencode-window nil
  "OpenCode window and frame management."
  :group 'opencode
  :prefix "opencode-window-")

;;; --- Customization ---

(defcustom opencode-window-display 'side
  "How to display OpenCode windows.
- `side'  — Side window (right by default, configurable).
- `float' — Separate floating frame.
- `split' — Split current frame horizontally.
- `full'  — Full frame (replaces current window layout)."
  :type '(choice (const :tag "Side window" side)
                 (const :tag "Floating frame" float)
                 (const :tag "Split current frame" split)
                 (const :tag "Full frame" full))
  :group 'opencode-window)

(defcustom opencode-window-side 'right
  "Which side to place the OpenCode side window.
Only used when `opencode-window-display' is `side'."
  :type '(choice (const left) (const right) (const bottom))
  :group 'opencode-window)

(defcustom opencode-window-width 80
  "Width of the OpenCode side window in columns."
  :type 'integer
  :group 'opencode-window)

(defcustom opencode-float-frame-alist
  '((width . 100) (height . 50) (left . 0.7) (top . 0.1))
  "Frame parameters for floating OpenCode frames."
  :type 'alist
  :group 'opencode-window)

(defcustom opencode-window-persistent t
  "When non-nil, side window survives `delete-other-windows' (C-x 1).
Uses `no-delete-other-windows' window parameter."
  :type 'boolean
  :group 'opencode-window)

;;; --- Display buffer actions ---

(defun opencode-window--side-action ()
  "Return `display-buffer' action for side window mode."
  `((display-buffer-in-side-window)
    (side . ,opencode-window-side)
    (slot . 0)
    (window-width . ,opencode-window-width)
    (window-parameters
     (no-delete-other-windows . ,opencode-window-persistent))
    (category . opencode)))

(defun opencode-window--float-action ()
  "Return `display-buffer' action for floating frame mode."
  `((display-buffer-pop-up-frame)
    (pop-up-frame-parameters . ,opencode-float-frame-alist)
    (dedicated . t)
    (category . opencode)))

(defun opencode-window--split-action ()
  "Return `display-buffer' action for split mode."
  '((display-buffer-in-direction)
    (direction . right)
    (window . main)
    (category . opencode)))

(defun opencode-window--full-action ()
  "Return `display-buffer' action for full frame mode."
  '((display-buffer-full-frame)
    (category . opencode)))

;;; --- Core display function ---

(defun opencode-window-display-buffer (buffer)
  "Display BUFFER according to `opencode-window-display' setting.
Returns the window displaying BUFFER."
  (let ((action (pcase opencode-window-display
                  ('side  (opencode-window--side-action))
                  ('float (opencode-window--float-action))
                  ('split (opencode-window--split-action))
                  ('full  (opencode-window--full-action))
                  (_      (opencode-window--side-action)))))
    (display-buffer buffer action)))

(defun opencode-window--display-buffer (buffer alist)
  "Custom `display-buffer' function for opencode buffers.
BUFFER is the buffer to display, ALIST is the action alist.
Routes to the appropriate display mode."
  (let ((action (pcase opencode-window-display
                  ('side  (opencode-window--side-action))
                  ('float (opencode-window--float-action))
                  ('split (opencode-window--split-action))
                  ('full  (opencode-window--full-action))
                  (_      (opencode-window--side-action)))))
    ;; Use the first display function from our action
    (let ((fns (car action))
          (merged-alist (append alist (cdr action))))
      (if (functionp fns)
          (funcall fns buffer merged-alist)
        (seq-some (lambda (fn) (funcall fn buffer merged-alist))
                 (if (listp fns) fns (list fns)))))))

;;; --- Window commands ---

(defun opencode-window-toggle ()
  "Toggle the OpenCode window (show/hide)."
  (interactive)
  (let ((win (opencode-window--find-window)))
    (if win
        (opencode-window--hide win)
      (opencode-window--show))))

(defun opencode-window--find-window ()
  "Find an existing opencode window, or nil."
  (seq-find
   (lambda (win)
     (let ((buf-name (buffer-name (window-buffer win))))
       (string-prefix-p "*opencode:" buf-name)))
   (window-list)))

(defun opencode-window--find-frame ()
  "Find an existing opencode floating frame, or nil."
  (seq-find
   (lambda (frame)
     (and (not (eq frame (selected-frame)))
          (seq-some (lambda (win)
                     (string-prefix-p "*opencode:"
                                      (buffer-name (window-buffer win))))
                   (window-list frame))))
   (frame-list)))

(defun opencode-window--hide (window)
  "Hide WINDOW.  If it's a side window, delete it.
If it's a floating frame, iconify or delete the frame."
  (let ((frame (window-frame window)))
    (if (eq frame (selected-frame))
        ;; Same frame — just delete the window
        (delete-window window)
      ;; Different frame — delete the frame
      (delete-frame frame))))

(defun opencode-window--show ()
  "Show the OpenCode window.
If there's an existing opencode buffer, display it.
Otherwise, display the session list for the current project."
  (let ((buf (or (opencode-window--find-buffer)
                 (let ((dir (or (when-let ((proj (project-current)))
                                  (project-root proj))
                                opencode-default-directory
                                default-directory)))
                   (opencode-session--ensure-buffer dir)))))
    (opencode-window-display-buffer buf)))

(defun opencode-window--find-buffer ()
  "Find the most recent opencode buffer, preferring chat over sessions."
  (or (seq-find
       (lambda (buf)
         (and (string-prefix-p "*opencode:" (buffer-name buf))
              (not (string-prefix-p "*opencode: sessions" (buffer-name buf)))
              (not (string= (buffer-name buf) "*opencode: log*"))
              (not (string= (buffer-name buf) "*opencode: debug*"))))
       (buffer-list))
      (seq-find
       (lambda (buf)
         (string-prefix-p "*opencode: sessions" (buffer-name buf)))
       (buffer-list))))

;;; --- Floating frame ---

(defun opencode-window-open-frame (&optional buffer)
  "Open a new floating frame for OpenCode.
BUFFER is the buffer to display; defaults to session list."
  (interactive)
  (let* ((buf (or buffer
                  (opencode-window--find-buffer)
                  (let ((dir (or (when-let ((proj (project-current)))
                                   (project-root proj))
                                 opencode-default-directory
                                 default-directory)))
                    (opencode-session--ensure-buffer dir))))
         (frame (make-frame (append opencode-float-frame-alist
                                    '((name . "OpenCode"))))))
    (set-frame-parameter frame 'opencode-frame t)
    (with-selected-frame frame
      (switch-to-buffer buf))
    frame))

;;; --- Sidebar ---

(defun opencode-window-toggle-sidebar (&optional project-root)
  "Toggle the global session sidebar in the current frame.
PROJECT-ROOT overrides the auto-detected project directory.
If the current buffer is a chat buffer, focuses that session in the sidebar."
  (interactive)
  ;; Capture chat session-id before switching to sidebar context
  (let* ((prev-session-id (when (bound-and-true-p opencode-chat--state)
                            (opencode-chat--session-id)))
         (sidebar-buf (get-buffer opencode-sidebar--buffer-name))
         (sidebar-win (when sidebar-buf (get-buffer-window sidebar-buf)))
         (project-dir (directory-file-name
                       (expand-file-name
                        (or project-root
                            (when-let ((proj (project-current)))
                              (project-root proj))
                            opencode-default-directory
                            default-directory)))))
    (cond
     ;; Already visible and focusing on it → hide it
     ((and sidebar-win (eq sidebar-buf (current-buffer)))
      (delete-window sidebar-win))
     ;; Already visible but not selected it → focus it
     (sidebar-win
      (select-window sidebar-win)
      (when prev-session-id
        (opencode-sidebar--focus-session prev-session-id)))
     ;; Buffer exists but not visible → show it
     (sidebar-buf
      ;; Update primary project dir to current context
      (when (with-current-buffer sidebar-buf
              (not (equal project-dir opencode-sidebar--primary-project-dir)))
        (with-current-buffer sidebar-buf
          (setq opencode-sidebar--primary-project-dir project-dir)
          (unless (member project-dir opencode-sidebar--known-project-dirs)
            (push project-dir opencode-sidebar--known-project-dirs))
          ;; Fetch sessions for new project if not cached
          (unless (opencode-api-cache-project-sessions project-dir :cache t)
            (opencode-sidebar--refresh-project project-dir))
          (opencode-sidebar--rerender)))
      (when-let ((win (display-buffer-in-side-window
                       sidebar-buf
                       `((side . left)
                         (slot . -1)
                         (window-width . 45)
                         (window-parameters
                          (no-delete-other-windows . ,opencode-window-persistent))))))
        (select-window win)
        ;; Focus current session if coming from a chat buffer
        (when prev-session-id
          (opencode-sidebar--focus-session prev-session-id))))
     ;; No buffer yet → create it, then show in sidebar
     (t
      (unless (opencode-server-connected-p)
        (user-error "OpenCode server not connected.  Connect first with 'M-x opencode-start' or 'M-x opencode-attach'"))
      (let ((buf (opencode-sidebar--ensure-buffer project-dir)))
        (when buf
          (when-let ((win (display-buffer-in-side-window
                           buf
                           `((side . left)
                             (slot . -1)
                             (window-width . 45)
                             (window-parameters
                              (no-delete-other-windows . ,opencode-window-persistent))))))
            (select-window win)
            (when prev-session-id
              (opencode-sidebar--focus-session prev-session-id)))))))))

;;; --- Display buffer alist integration ---

(defun opencode-window--setup-display-rules ()
  "Install `display-buffer-alist' rules for opencode buffers."
  (add-to-list 'display-buffer-alist
               '("\\*opencode:" opencode-window--display-buffer
                 (category . opencode))))

(provide 'opencode-window)
;;; opencode-window.el ends here
