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
Displays an existing opencode buffer, or errors when none exists."
  (if-let ((buf (opencode-window--find-buffer)))
      (opencode-window-display-buffer buf)
    (user-error "No OpenCode buffer exists; use `opencode-chat' or `opencode-toggle-sidebar'")))

(defun opencode-window--find-buffer ()
  "Find the most recent user-facing opencode buffer."
  (seq-find
   (lambda (buf)
     (and (string-prefix-p "*opencode:" (buffer-name buf))
          (not (string= (buffer-name buf) "*opencode: log*"))
          (not (string= (buffer-name buf) "*opencode: debug*"))))
   (buffer-list)))

;;; --- Floating frame ---

(defun opencode-window-open-frame (&optional buffer)
  "Open a new floating frame for OpenCode.
BUFFER is the buffer to display; defaults to the latest opencode buffer."
  (interactive)
  (let* ((buf (or buffer
                  (opencode-window--find-buffer)
                  (user-error "No OpenCode buffer exists; use `opencode-chat' first")))
         (frame (make-frame (append opencode-float-frame-alist
                                     '((name . "OpenCode"))))))
    (set-frame-parameter frame 'opencode-frame t)
    (with-selected-frame frame
      (switch-to-buffer buf))
    frame))

;;; --- Child frame (subframe hosting a buffer) ---

(defcustom opencode-child-frame-alist
  '((width . 90) (height . 28))
  "Default size for opencode child frames (subframes).
WIDTH/HEIGHT are in columns/lines."
  :type 'alist
  :group 'opencode-window)

(defun opencode-window-child-frame (buffer &optional placement)
  "Display BUFFER in a child frame (subframe) of the selected frame.
The child frame is anchored to the selected window.  PLACEMENT is
`top' (default) or `bottom'.  On a non-graphic display (terminal),
falls back to a bottom side window.  Returns the child frame, or the
window in the terminal fallback."
  (if (not (display-graphic-p))
      (display-buffer-in-side-window
       buffer '((side . bottom) (slot . 0)
                (window-parameters (no-other-window . t))))
    (let* ((parent (selected-frame))
           (parent-win (selected-window))
           (width (or (alist-get 'width opencode-child-frame-alist) 90))
           (height (or (alist-get 'height opencode-child-frame-alist) 28))
           (frame (make-frame
                   `((parent-frame . ,parent)
                     (minibuffer . nil)
                     (undecorated . t)
                     (skip-taskbar . t)
                     (left-fringe . 8)
                     (right-fringe . 8)
                     (vertical-scroll-bars . nil)
                     (horizontal-scroll-bars . nil)
                     (menu-bar-lines . 0)
                     (tool-bar-lines . 0)
                     (tab-bar-lines . 0)
                     (internal-border-width . 2)
                     (width . ,width)
                     (height . ,height)
                     (visibility . nil)))))
      (set-frame-parameter frame 'opencode-frame t)
      (opencode-window--position-child-frame frame parent parent-win
                                             height (or placement 'top))
      (with-selected-frame frame
        (switch-to-buffer buffer))
      (make-frame-visible frame)
      (select-frame-set-input-focus frame)
      frame)))

(defun opencode-window--position-child-frame (frame parent parent-win height placement)
  "Anchor child FRAME to PARENT-WIN within PARENT at top or bottom per PLACEMENT.
HEIGHT is the frame height in lines."
  (let* ((edges (window-inside-pixel-edges parent-win))
         (char-h (frame-char-height parent))
         (left (nth 0 edges))
         (top (nth 1 edges))
         (bottom (nth 3 edges)))
    (set-frame-position
     frame left
     (if (eq placement 'bottom)
         (max top (- bottom (* (+ 1 height) char-h)))
       top))))

;;; --- Sidebar ---

(defun opencode-window-toggle-sidebar (&optional project-root)
  "Toggle the global session sidebar in the current frame.
PROJECT-ROOT overrides the auto-detected project directory.
If the current buffer is a chat buffer, focuses that session in the sidebar."
  (interactive)
  ;; Capture chat session-id before switching to sidebar context
  (let* ((source-win (selected-window))
         (prev-session-id (when (bound-and-true-p opencode-chat--state)
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
       (with-current-buffer sidebar-buf
         (opencode-sidebar--remember-main-window source-win))
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
      (with-current-buffer sidebar-buf
        (opencode-sidebar--remember-main-window source-win))
      (when-let ((win (display-buffer-in-side-window
                       sidebar-buf
                       `((side . left)
                         (slot . -1)
                          (window-width . 35)
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
          (with-current-buffer buf
            (opencode-sidebar--remember-main-window source-win))
          (when-let ((win (display-buffer-in-side-window
                           buf
                           `((side . left)
                             (slot . -1)
                              (window-width . 35)
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
