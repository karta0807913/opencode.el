;;; opencode-permission.el --- Permission request popup for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Backend-driven permission popup.  OpenCode supplies permission requests via
;; SSE events; Pi supplies them via RPC extension UI requests.  The UI receives
;; normalized OpenCode-shaped events either way.  When the agent needs
;; file/tool permission,
;; the chat buffer's input area is replaced with the permission details
;; and approve/reject keybindings.  After responding, the original input
;; text is restored.

;;; Code:

(require 'cl-lib)
(require 'opencode-backend-core)
(require 'opencode-faces)
(require 'opencode-popup)
(require 'opencode-log)
(require 'opencode-util)

;; Cross-module reference for input-start marker
(declare-function opencode-chat--backend "opencode-chat-state" (&optional state))

;; Avoid byte-compile warning — defined in opencode-sse.el
(defvar opencode-sse-permission-replied-hook)
(defvar opencode-sse-permission-asked-hook)

;;; --- State ---

(defvar-local opencode-permission--pending nil
  "FIFO list of pending permission request plists.
Buffer-local in each chat buffer; backend events dispatch to the correct
buffer via `opencode-event--dispatch-chat'.")

(defvar-local opencode-permission--current nil
  "Currently displayed permission request plist.")

(defconst opencode-permission--buffer-name "*opencode: permission*"
  "Legacy standalone popup buffer name used during cleanup.")

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

;;; --- Backend event handler ---

(defun opencode-permission--on-asked (event)
  "Handle a `permission.asked' OpenCode-shaped EVENT.
Extract the permission request from EVENT properties and queue it.
Runs in the chat buffer context (dispatched by session-id)."
  (when-let* ((props (plist-get event :properties)))
    (setq opencode-permission--pending
          (append opencode-permission--pending (list props)))
    (opencode-permission--show-next)))

;;; --- Display ---


(cl-defun opencode-permission--format-patterns-short (&key patterns permission)
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
- no chat buffer is available at all."
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
            ;; Render failed -- restore the input tail before unblocking
            ;; future popups.  Rendering deletes everything after
            ;; messages-end, including child-session navigation.
            (opencode--debug "opencode-permission: render error: %S" err)
            (setq opencode-permission--current nil)
            (when-let* ((recovery-error
                         (opencode-popup--recover-render-error)))
              (opencode--debug
               "opencode-permission: render recovery error: %S"
               recovery-error))
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
                            :patterns (or always-pats patterns)
                            :permission permission)))
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

;;; --- Reply ---

(cl-defun opencode-permission-reply (&key id choice message backend)
  "Reply to permission request ID with CHOICE.
CHOICE is \"once\", \"always\", or \"reject\".  MESSAGE is an optional
reply message.  BACKEND identifies the request backend and defaults to
`opencode-backend-current'.  This is the public API for users handling
permission requests from backend hooks."
  (opencode-backend-reply-permission id choice message backend))

(cl-defun opencode-permission--default-always-message (&key request)
  "Return the default always-allow message for permission REQUEST."
  (let* ((always-pats (plist-get request :always))
         (patterns (plist-get request :patterns))
         (permission (or (plist-get request :permission) "unknown")))
    (if (and always-pats (length> always-pats 0))
        (mapconcat #'identity always-pats ", ")
      (if (and patterns (length> patterns 0))
          (mapconcat #'identity patterns ", ")
        permission))))

(cl-defun opencode-permission--reply (&key choice message id request)
  "Send CHOICE reply for the current permission request.
CHOICE is \"once\", \"always\", or \"reject\".
MESSAGE is an optional rejection reason string.
ID and REQUEST let Lisp callers reply to a specific request instead of
the currently displayed popup."
  (unless (or request opencode-permission--current)
    (user-error "No active permission request"))
  (let* ((target (or request opencode-permission--current))
         (perm-id (or id (plist-get target :id)))
         (saved-current opencode-permission--current))
    (opencode--debug "opencode-permission: replying id=%s choice=%s message=%S" perm-id choice message)
    (condition-case err
        (opencode-permission-reply
         :id perm-id
         :choice choice
         :message message
         :backend (opencode-chat--backend))
      (error
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

(defun opencode-permission--allow-once (&optional id)
  "Allow the current permission request once."
  (interactive)
  (opencode-permission--reply :choice "once" :id id))

(defun opencode-permission--allow-always ()
  "Allow the current permission request always.
Sends the pattern being approved in the message field so the user
can see exactly what was always-allowed in the permission popup."
  (interactive)
  (opencode-permission--reply
   :choice "always"
   :message (opencode-permission--default-always-message
             :request opencode-permission--current)))

(defun opencode-permission--reject ()
  "Reject the current permission request."
  (interactive)
  (opencode-permission--reply :choice "reject"))

(defun opencode-permission--reject-with-message ()
  "Reject the current permission request with a reason message."
  (interactive)
  (let ((msg (read-string "Rejection reason: ")))
    (opencode-permission--reply :choice "reject" :message msg)))

;;; --- Backend replied handler ---

(defun opencode-permission--on-replied (event)
  "Handle a `permission.replied' OpenCode-shaped EVENT.
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
