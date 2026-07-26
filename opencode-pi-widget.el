;;; opencode-pi-widget.el --- Pi extension widget/status surface -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Renders Pi extension fire-and-forget UI (`setWidget' / `setStatus') for a Pi
;; session.  These drive side-channel output such as the `/btw' extension's
;; answer, which Pi pushes as `extension_ui_request' events with no reply.
;;
;; Model: each session has a backing buffer holding keyed sections.
;;   - `opencode-pi-widget-set'    upserts a widget key (replace-on-update);
;;                                 nil LINES removes the key.
;;   - `opencode-pi-widget-status' upserts a one-line status key; nil clears.
;; When no widget/status keys remain, the surface is hidden.
;;
;; Presentation (same backing buffer, different container):
;;   - GUI (`display-graphic-p'): a native child frame anchored to the chat
;;     window (top for `aboveEditor', bottom for `belowEditor').  No posframe
;;     dependency — Emacs 30 child frames via `make-frame'.
;;   - Terminal: a bottom side window.
;;
;; The surface is per-session; `opencode-pi-widget-cleanup' tears it down on
;; chat-buffer kill / conn exit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-faces)

(defgroup opencode-pi-widget nil
  "Pi extension widget surface."
  :group 'opencode-pi
  :prefix "opencode-pi-widget-")

(defcustom opencode-pi-widget-max-height 20
  "Maximum height in lines of the Pi widget surface."
  :type 'integer
  :group 'opencode-pi-widget)

(defcustom opencode-pi-widget-width 72
  "Width in columns of the Pi widget child frame."
  :type 'integer
  :group 'opencode-pi-widget)

;;; --- Per-session surface state ---

(cl-defstruct (opencode-pi-widget-surface
               (:constructor opencode-pi-widget-surface--create)
               (:copier nil))
  "Backing state for one session's widget surface.
BUFFER holds the rendered content.  WIDGETS / STATUSES are ordered alists
of (KEY . LINES) and (KEY . TEXT).  FRAME is the child frame (GUI) or nil.
PLACEMENT is `aboveEditor' or `belowEditor'."
  buffer
  (widgets nil)
  (statuses nil)
  frame
  (placement 'aboveEditor))

(defvar opencode-pi-widget--surfaces (make-hash-table :test 'equal)
  "Map of Pi session-id -> `opencode-pi-widget-surface'.")

(defun opencode-pi-widget--buffer-name (session-id)
  "Return the backing buffer name for SESSION-ID's widget surface."
  (format " *opencode: pi-widget %s*" session-id))

(defun opencode-pi-widget--surface (session-id)
  "Return the surface for SESSION-ID, creating it if needed."
  (or (gethash session-id opencode-pi-widget--surfaces)
      (let* ((buf (get-buffer-create
                   (opencode-pi-widget--buffer-name session-id)))
             (surface (opencode-pi-widget-surface--create :buffer buf)))
        (with-current-buffer buf
          (setq buffer-read-only t)
          (setq mode-line-format nil)
          (setq cursor-type nil))
        (puthash session-id surface opencode-pi-widget--surfaces)
        surface)))

;;; --- Public model API ---

(defun opencode-pi-widget-set (session-id key lines &optional placement)
  "Upsert widget KEY for SESSION-ID with LINES (a list/vector of strings).
When LINES is nil, remove KEY.  PLACEMENT is `aboveEditor' (default) or
`belowEditor'.  Re-renders and shows or hides the surface."
  (let* ((surface (opencode-pi-widget--surface session-id))
         (lines (cond ((null lines) nil)
                      ((vectorp lines) (append lines nil))
                      ((listp lines) lines)
                      (t (list (format "%s" lines))))))
    (when placement
      (setf (opencode-pi-widget-surface-placement surface)
            (if (equal placement "belowEditor") 'belowEditor 'aboveEditor)))
    (setf (opencode-pi-widget-surface-widgets surface)
          (opencode-pi-widget--alist-put
           (opencode-pi-widget-surface-widgets surface) key lines))
    (opencode-pi-widget--rerender session-id surface)))

(defun opencode-pi-widget-status (session-id key text)
  "Upsert status KEY for SESSION-ID with string TEXT.
When TEXT is nil, remove KEY.  Re-renders the surface."
  (let ((surface (opencode-pi-widget--surface session-id)))
    (setf (opencode-pi-widget-surface-statuses surface)
          (opencode-pi-widget--alist-put
           (opencode-pi-widget-surface-statuses surface) key
           (and text (list text))))
    (opencode-pi-widget--rerender session-id surface)))

(defun opencode-pi-widget-cleanup (session-id)
  "Tear down SESSION-ID's widget surface (frame + buffer)."
  (when-let* ((surface (gethash session-id opencode-pi-widget--surfaces)))
    (opencode-pi-widget--hide surface)
    (when (buffer-live-p (opencode-pi-widget-surface-buffer surface))
      (kill-buffer (opencode-pi-widget-surface-buffer surface)))
    (remhash session-id opencode-pi-widget--surfaces)))

;;; --- Alist helper (ordered, nil VALUE removes) ---

(defun opencode-pi-widget--alist-put (alist key value)
  "Return ALIST with KEY set to VALUE, preserving order.
When VALUE is nil, KEY is removed.  KEY is compared with `equal'."
  (let ((existing (assoc key alist)))
    (cond
     ((and (null value) existing)
      (assoc-delete-all key (copy-sequence alist)))
     ((null value) alist)
     (existing
      (mapcar (lambda (cell)
                (if (equal (car cell) key) (cons key value) cell))
              alist))
     (t (append alist (list (cons key value)))))))

;;; --- Rendering ---

(defun opencode-pi-widget--empty-p (surface)
  "Return non-nil if SURFACE has no widget or status content."
  (and (null (opencode-pi-widget-surface-widgets surface))
       (null (opencode-pi-widget-surface-statuses surface))))

(defun opencode-pi-widget--rerender (session-id surface)
  "Render SURFACE's content into its buffer and show/hide it for SESSION-ID."
  (let ((buf (opencode-pi-widget-surface-buffer surface)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (opencode-pi-widget--insert-content surface))))
    (if (opencode-pi-widget--empty-p surface)
        (opencode-pi-widget--hide surface)
      (opencode-pi-widget--show session-id surface))))

(defun opencode-pi-widget--insert-content (surface)
  "Insert SURFACE's widgets and statuses into the current buffer."
  (let ((first t))
    (dolist (cell (opencode-pi-widget-surface-widgets surface))
      (unless first
        (insert (propertize (make-string (max 8 opencode-pi-widget-width) ?─)
                            'face 'opencode-popup-border)
                "\n"))
      (setq first nil)
      (dolist (line (cdr cell))
        (insert line "\n")))
    (when (opencode-pi-widget-surface-statuses surface)
      (unless first
        (insert (propertize (make-string (max 8 opencode-pi-widget-width) ?─)
                            'face 'opencode-popup-border)
                "\n"))
      (dolist (cell (opencode-pi-widget-surface-statuses surface))
        (dolist (line (cdr cell))
          (insert (propertize line 'face 'opencode-popup-title) "\n"))))))

(defun opencode-pi-widget--content-height (surface)
  "Return the line count to display for SURFACE, capped."
  (with-current-buffer (opencode-pi-widget-surface-buffer surface)
    (min opencode-pi-widget-max-height
         (max 1 (count-lines (point-min) (point-max))))))

;;; --- Presentation: child frame (GUI) / side window (terminal) ---

(defun opencode-pi-widget--show (session-id surface)
  "Show SURFACE for SESSION-ID via child frame (GUI) or side window (TTY)."
  (ignore session-id)
  (if (display-graphic-p)
      (opencode-pi-widget--show-frame surface)
    (opencode-pi-widget--show-window surface)))

(defun opencode-pi-widget--hide (surface)
  "Hide SURFACE's child frame and/or side window."
  (when-let* ((frame (opencode-pi-widget-surface-frame surface)))
    (when (frame-live-p frame) (delete-frame frame))
    (setf (opencode-pi-widget-surface-frame surface) nil))
  (when-let* ((buf (opencode-pi-widget-surface-buffer surface))
              (win (and (buffer-live-p buf) (get-buffer-window buf t))))
    (when (window-live-p win)
      (ignore-errors (delete-window win)))))

(defun opencode-pi-widget--show-window (surface)
  "Display SURFACE's buffer in a bottom side window (terminal fallback)."
  (let ((buf (opencode-pi-widget-surface-buffer surface)))
    (display-buffer-in-side-window
     buf `((side . bottom) (slot . 1)
           (window-height . ,(+ 1 (opencode-pi-widget--content-height surface)))
           (window-parameters (no-other-window . t))))))

(defun opencode-pi-widget--show-frame (surface)
  "Display SURFACE's buffer in a child frame anchored to the selected window."
  (let* ((buf (opencode-pi-widget-surface-buffer surface))
         (parent (selected-frame))
         (height (opencode-pi-widget--content-height surface))
         (existing (opencode-pi-widget-surface-frame surface))
         (frame (if (and existing (frame-live-p existing))
                    existing
                  (opencode-pi-widget--make-frame parent))))
    (setf (opencode-pi-widget-surface-frame surface) frame)
    (set-frame-size frame opencode-pi-widget-width height)
    (opencode-pi-widget--position-frame surface frame parent height)
    (with-selected-frame frame
      (switch-to-buffer buf t t))
    (make-frame-visible frame)))

(defun opencode-pi-widget--make-frame (parent)
  "Create an undecorated child frame of PARENT."
  (make-frame
   `((parent-frame . ,parent)
     (minibuffer . nil)
     (undecorated . t)
     (no-accept-focus . t)
     (no-focus-on-map . t)
     (skip-taskbar . t)
     (left-fringe . 0)
     (right-fringe . 0)
     (vertical-scroll-bars . nil)
     (horizontal-scroll-bars . nil)
     (menu-bar-lines . 0)
     (tool-bar-lines . 0)
     (tab-bar-lines . 0)
     (internal-border-width . 1)
     (unsplittable . t)
     (default-minibuffer-frame . ,parent)
     (visibility . nil))))

(defun opencode-pi-widget--position-frame (surface frame parent height)
  "Place FRAME at the top or bottom edge of PARENT per SURFACE placement.
HEIGHT is the frame height in lines."
  (let* ((edges (window-inside-pixel-edges (frame-selected-window parent)))
         (char-h (frame-char-height parent))
         (left (nth 0 edges))
         (top (nth 1 edges))
         (bottom (nth 3 edges)))
    (set-frame-position
     frame left
     (if (eq (opencode-pi-widget-surface-placement surface) 'belowEditor)
         (max top (- bottom (* (+ 1 height) char-h)))
       top))))

(provide 'opencode-pi-widget)
;;; opencode-pi-widget.el ends here
