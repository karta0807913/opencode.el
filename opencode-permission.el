;;; opencode-permission.el --- Permission request popup for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; SSE-driven permission popup.  When the agent needs file/tool permission,
;; the chat buffer's input area is replaced with the permission details
;; and approve/reject keybindings.  After responding, the original input
;; text is restored.
;;
;; Falls back to a standalone side-window buffer when no chat buffer found.

;;; Code:

(require 'opencode-api)
(require 'opencode-faces)
(require 'opencode-popup)
(require 'opencode-log)
(require 'opencode-util)

;; Cross-module reference for input-start marker

;; Avoid byte-compile warning — defined in opencode-sse.el
(defvar opencode-sse-permission-replied-hook)
(defvar opencode-sse-permission-asked-hook)

;;; --- State ---

(defvar-local opencode-permission--pending nil
  "FIFO list of pending permission request plists.
Buffer-local in each chat buffer; SSE events dispatch to the correct
buffer via `opencode-event--dispatch-chat'.")

(defvar-local opencode-permission--current nil
  "Currently displayed permission request plist.")

;;; --- Buffer name (standalone fallback) ---

(defconst opencode-permission--buffer-name "*opencode: permission*"
  "Buffer name for the permission popup.")

;;; --- Inline keymap ---

(defvar-keymap opencode-permission--inline-map
  :doc "Keymap active on the inline permission region in chat buffers."
  "a" #'opencode-permission--allow-once
  "A" #'opencode-permission--allow-always
  "r" #'opencode-permission--reject
  "m" #'opencode-permission--reject-with-message
  "q" #'opencode-permission--reject
  "<escape>" #'opencode-permission--reject
  ;; Block self-insert so random keys don't corrupt the UI
  "<remap> <self-insert-command>" #'ignore)

;;; --- Standalone keymap + mode ---

(defvar-keymap opencode-permission-mode-map
  :doc "Keymap for `opencode-permission-mode'."
  :parent special-mode-map
  "a" #'opencode-permission--allow-once
  "A" #'opencode-permission--allow-always
  "r" #'opencode-permission--reject
  "m" #'opencode-permission--reject-with-message
  "q" #'opencode-permission--reject)

(define-derived-mode opencode-permission-mode special-mode "OpenCode Permission"
  "Major mode for the OpenCode permission request popup (standalone fallback).

\\{opencode-permission-mode-map}"
  :group 'opencode
  (setq truncate-lines t)
  (buffer-disable-undo))

;;; --- SSE handler ---

(defun opencode-permission--on-asked (event)
  "Handle a `permission.asked' SSE EVENT.
Extract the permission request from EVENT properties and queue it.
Runs in the chat buffer context (dispatched by session-id)."
  (when-let* ((props (plist-get event :properties)))
    (setq opencode-permission--pending
          (append opencode-permission--pending (list props)))
    (opencode-permission--show-next)))

;;; --- Display ---


(defun opencode-permission--format-patterns-short (patterns permission)
  "Format PATTERNS as a short semicolon-separated string for button labels.
Each individual pattern is truncated to 20 chars.  Falls back to PERMISSION
if PATTERNS is empty.  Uses `opencode--truncate-string' from opencode-util."
  (if (and patterns (length> patterns 0))
      (mapconcat (lambda (p)
                   (opencode--truncate-string p 20))
                 patterns
                 "; ")
    permission))

(defun opencode-permission--show-next ()
  "Pop the next pending request and display it.
If no pending requests remain, do nothing."
  (opencode-popup--show-next
   'opencode-permission--pending
   #'opencode-permission--show))

(defun opencode-permission--show (request)
  "Display permission REQUEST inline in a chat buffer.
Returns non-nil on success.  Returns nil (push back to queue) when:
- the target buffer is busy with another popup,
- the target buffer has no valid input area (child session / loading), or
- no chat buffer is available at all.
The standalone buffer is only used by `render-standalone' for tests."
  (let ((chat-buf (opencode-popup--find-chat-buffer request)))
    (cond
     ;; Chat buffer found, available, and has valid input area
     ((and chat-buf
           (not (buffer-local-value 'opencode-popup--inline-p chat-buf))
           (opencode-popup--input-area-valid-p chat-buf))
      (with-current-buffer chat-buf
        (condition-case err
            (progn
              (setq opencode-permission--current request)
              (opencode-popup--save-input)
              (opencode-permission--render-inline request)
              t)
          (error
           ;; Render failed -- restore state so future popups aren't blocked
           (opencode--debug "opencode-permission: render error: %S" err)
           (setq opencode-permission--current nil)
           (when (overlayp opencode-popup--overlay)
             (delete-overlay opencode-popup--overlay))
           (setq opencode-popup--inline-p nil
                 opencode-popup--saved-input nil
                 opencode-popup--overlay nil)
           nil))))
     ;; Busy, no input area, or no buffer -- push back to queue
     (t nil))))

;;; --- Inline rendering (chat buffer input area) ---

(defun opencode-permission--render-inline (request)
  "Render permission REQUEST inline, replacing the chat buffer input area."
  (let* ((permission (or (plist-get request :permission) "unknown"))
         (patterns (plist-get request :patterns)))
    (opencode-popup--with-inline-region opencode-permission--inline-map opencode-permission
      ;; Title
      (insert (propertize "─── Permission Required ───" 'face 'opencode-popup-border) "\n")
      ;; Permission type
      (insert " " (propertize "Permission: " 'face 'bold)
              (propertize permission 'face 'opencode-popup-title) "\n")
      ;; Patterns
      (insert " " (propertize "Patterns:   " 'face 'bold)
              (if (and patterns (length> patterns 0))
                  (mapconcat #'identity patterns ", ")
                "none")
              "\n")
      ;; Action hints as face-styled buttons
      (insert "  ")
      (insert (propertize " a Allow once " 'face 'opencode-popup-option))
      (insert " ")
      (let* ((always-pats (plist-get request :always))
             (pattern-str (opencode-permission--format-patterns-short
                           (or always-pats patterns) permission)))
        (insert (propertize (format " A Allow always (%s) " pattern-str)
                            'face 'opencode-popup-option)))
      (insert " ")
      (insert (propertize " r Reject " 'face 'opencode-popup-option))
      (insert " ")
      (insert (propertize " m Reject+msg " 'face 'opencode-popup-option))
      (insert "\n"))
    ;; Tag the overlay so cross-buffer dismissal can find it by id.
    (when (overlayp opencode-popup--overlay)
      (overlay-put opencode-popup--overlay
                   'opencode-popup-request-id (plist-get request :id)))))

;;; --- Standalone rendering (fallback / tests) ---

(defun opencode-permission--render-standalone (request)
  "Render permission REQUEST in a standalone side-window buffer."
  (let ((buf (get-buffer-create opencode-permission--buffer-name))
        (permission (or (plist-get request :permission) "unknown"))
        (patterns (plist-get request :patterns))
        (session-id (or (plist-get request :sessionID) "unknown"))
        (perm-id (or (plist-get request :id) "unknown")))
    (with-current-buffer buf
      (opencode-permission-mode)
      (setq opencode-permission--current request)
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Border
        (insert (propertize "── Permission Required ──"
                            'face 'opencode-popup-border)
                "\n\n")
        ;; Title
        (insert (propertize "Permission Required"
                            'face 'opencode-popup-title)
                "\n\n")
        ;; Details
        (insert (propertize "Permission: " 'face 'bold)
                permission "\n")
        (insert (propertize "Patterns:   " 'face 'bold)
                (if (and patterns (length> patterns 0))
                    (mapconcat #'identity patterns ", ")
                  "none")
                "\n")
        (insert (propertize "Session:    " 'face 'bold)
                session-id "\n")
        (insert (propertize "Request ID: " 'face 'bold)
                perm-id "\n\n")
        ;; Key hints
        (let* ((always-pats (plist-get request :always))
               (pattern-str (opencode-permission--format-patterns-short
                             (or always-pats patterns) permission)))
          (insert (propertize "[a]" 'face 'opencode-popup-key)
                  " Allow once  "
                  (propertize "[A]" 'face 'opencode-popup-key)
                  (format " Allow always (%s)  " pattern-str)
                  (propertize "[r]" 'face 'opencode-popup-key)
                  " Reject  "
                  (propertize "[m]" 'face 'opencode-popup-key)
                  " Reject with message\n"))
        (goto-char (point-min))))
    ;; Display in side window
    (display-buffer buf
                    '(display-buffer-in-side-window
                      . ((side . bottom)
                         (window-height . 8)
                         (no-delete-other-windows . t))))))

;;; --- Reply ---

(defun opencode-permission--reply (choice &optional message)
  "Send CHOICE reply for the current permission request.
CHOICE is \"once\", \"always\", or \"reject\".
MESSAGE is an optional rejection reason string."
  (unless opencode-permission--current
    (user-error "No active permission request"))
  (let* ((perm-id (plist-get opencode-permission--current :id))
         (body (if message
                   (list :reply choice :message message)
                 (list :reply choice)))
         (saved-current opencode-permission--current))
    (opencode--debug "opencode-permission: replying id=%s choice=%s body=%S" perm-id choice body)
    (condition-case err
        (opencode-api--request
         "POST"
         (format "/permission/%s/reply" perm-id)
         body)
      (opencode-api-error
       (message "opencode-permission: reply failed: %s" (error-message-string err))))
    ;; Clean up — but only if on-replied didn't already handle it.
    ;; The sync HTTP call above can trigger accept-process-output,
    ;; which lets the SSE permission.replied event fire on-replied
    ;; re-entrantly.  If that happened, --current is already nil.
    (when (eq opencode-permission--current saved-current)
      (setq opencode-permission--current nil)
      ;; Dual-dispatch duplicate purge — see opencode-popup.el comment.
      (opencode-popup--purge-pending-by-id 'opencode-permission--pending perm-id)
      (opencode-popup--cleanup saved-current
                               opencode-permission--buffer-name
                               #'opencode-permission--show-next))))

;;; --- Interactive commands ---

(defun opencode-permission--allow-once ()
  "Allow the current permission request once."
  (interactive)
  (opencode-permission--reply "once"))

(defun opencode-permission--allow-always ()
  "Allow the current permission request always.
Sends the pattern being approved in the message field so the user
can see exactly what was always-allowed in the permission popup."
  (interactive)
  (let* ((always-pats (plist-get opencode-permission--current :always))
         (patterns (plist-get opencode-permission--current :patterns))
         (permission (or (plist-get opencode-permission--current :permission) "unknown"))
         (pattern-str (if (and always-pats (length> always-pats 0))
                          (mapconcat #'identity always-pats ", ")
                        (if (and patterns (length> patterns 0))
                            (mapconcat #'identity patterns ", ")
                          permission))))
    (opencode-permission--reply "always" pattern-str)))

(defun opencode-permission--reject ()
  "Reject the current permission request."
  (interactive)
  (opencode-permission--reply "reject"))

(defun opencode-permission--reject-with-message ()
  "Reject the current permission request with a reason message."
  (interactive)
  (let ((msg (read-string "Rejection reason: ")))
    (opencode-permission--reply "reject" msg)))

;;; --- SSE replied handler ---

(defun opencode-permission--on-replied (event)
  "Handle a `permission.replied' SSE EVENT.
Dismiss the permission popup if it matches the replied request, and
remove stale copies from pending queues in all buffers.
This handles the case where the permission was replied to elsewhere
\(e.g., in the TUI or another Emacs instance), and cleans up
dual-queued requests from multi-buffer dispatch (child + root parent)."
  (when-let* ((props (plist-get event :properties))
              (request-id (plist-get props :requestID)))
    (opencode--debug "opencode-permission: on-replied requestID=%s" request-id)
    ;; Purge from every buffer's pending queue.
    (opencode-popup--purge-pending-by-id 'opencode-permission--pending request-id)
    ;; Dismiss any displayed popup with that id.
    (opencode-popup--dismiss-by-id
     request-id
     (lambda ()
       (opencode--debug "opencode-permission: dismissing popup in %s" (buffer-name))
       (setq opencode-permission--current nil)
       (opencode-popup--cleanup nil
                                opencode-permission--buffer-name
                                #'opencode-permission--show-next)))))

;;; --- Hook registration is centralized in opencode.el ---

(provide 'opencode-permission)
;;; opencode-permission.el ends here
