;;; opencode-status.el --- Server status popup for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Interactive popup showing MCP, LSP, and Formatter status from the
;; opencode server.  Fetches /mcp/status, /lsp/status, /formatter/status
;; and renders them in a small bottom popup buffer.
;;
;; Keybindings:
;;   n/p   — move between items
;;   SPC   — toggle connect/disconnect (MCP) or enable/disable
;;   g     — refresh
;;   q     — close

;;; Code:

(require 'opencode-api)
(require 'opencode-log)

(defvar opencode-default-directory)

(defconst opencode-status--buffer-name "*opencode: status*"
  "Buffer name for the server status popup.")

;;; --- Buffer-local state ---

(defvar-local opencode-status--mcp-data nil
  "Alist of (name . status-plist) for MCP servers.")

(defvar-local opencode-status--lsp-data nil
  "List of LSP server plists.")

(defvar-local opencode-status--formatter-data nil
  "List of formatter plists.")

;;; --- Keymap ---

(defvar-keymap opencode-status-mode-map
  :doc "Keymap for `opencode-status-mode'."
  "n"   #'opencode-status--next
  "p"   #'opencode-status--prev
  "SPC" #'opencode-status--toggle
  "g"   #'opencode-status--refresh
  "q"   #'opencode-status--quit
  "RET" #'opencode-status--toggle)

;;; --- Major mode ---

(define-derived-mode opencode-status-mode special-mode "OpenCode Status"
  "Major mode for viewing OpenCode server status.
\\{opencode-status-mode-map}"
  :group 'opencode
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (buffer-disable-undo))

;;; --- Faces ---

(defface opencode-status-connected
  '((t :foreground "#50fa7b" :weight bold))
  "Face for connected/enabled status."
  :group 'opencode)

(defface opencode-status-disconnected
  '((t :foreground "#ff5555" :weight bold))
  "Face for disconnected/disabled/failed status."
  :group 'opencode)

(defface opencode-status-section
  '((t :weight bold :underline t))
  "Face for section headers."
  :group 'opencode)

(defface opencode-status-name
  '((t :weight bold))
  "Face for server/tool names."
  :group 'opencode)

(defface opencode-status-hint
  '((t :foreground "#6272a4" :slant italic))
  "Face for hint text."
  :group 'opencode)

;;; --- Data fetching ---

(defun opencode-status--fetch-mcp ()
  "Fetch MCP server status.  Returns alist of (name . status-plist)."
  (condition-case err
      (let ((result (opencode-api-get-sync "/mcp/status")))
        (when (and result (listp result))
          ;; Server returns a plist like (:server1 (:status "connected") ...)
          ;; Convert to alist of (name-string . status-plist)
          (let ((alist nil))
            (while result
              (let ((key (pop result))
                    (val (pop result)))
                (push (cons (substring (symbol-name key) 1) val) alist)))
            (nreverse alist))))
    (error
     (opencode--debug "opencode-status: MCP fetch failed: %s"
                      (error-message-string err))
     nil)))

(defun opencode-status--fetch-lsp ()
  "Fetch LSP server status.  Returns list of plists."
  (condition-case err
      (let ((result (opencode-api-get-sync "/lsp/status")))
        (if (vectorp result) (append result nil) result))
    (error
     (opencode--debug "opencode-status: LSP fetch failed: %s"
                      (error-message-string err))
     nil)))

(defun opencode-status--fetch-formatter ()
  "Fetch formatter status.  Returns list of plists."
  (condition-case err
      (let ((result (opencode-api-get-sync "/formatter/status")))
        (if (vectorp result) (append result nil) result))
    (error
     (opencode--debug "opencode-status: formatter fetch failed: %s"
                      (error-message-string err))
     nil)))

;;; --- Rendering ---

(defun opencode-status--mcp-status-string (status-plist)
  "Format MCP STATUS-PLIST as a human-readable string with face."
  (let ((status (plist-get status-plist :status)))
    (pcase status
      ("connected"
       (propertize "connected" 'face 'opencode-status-connected))
      ("disabled"
       (propertize "disabled" 'face 'opencode-status-disconnected))
      ("failed"
       (propertize (format "failed: %s"
                           (or (plist-get status-plist :error) "unknown"))
                   'face 'opencode-status-disconnected))
      ("needs_auth"
       (propertize "needs auth" 'face 'opencode-status-disconnected))
      ("needs_client_registration"
       (propertize (format "needs registration: %s"
                           (or (plist-get status-plist :error) ""))
                   'face 'opencode-status-disconnected))
      (_
       (propertize (or status "unknown") 'face 'font-lock-comment-face)))))

(defun opencode-status--mcp-toggleable-p (status-plist)
  "Return non-nil if MCP server with STATUS-PLIST can be toggled."
  (member (plist-get status-plist :status)
          '("connected" "disabled" "failed")))

(defun opencode-status--render-entry (type name on-p status-label extra-info hint data)
  "Insert a single status row for an MCP/LSP/Formatter entry.

TYPE is the symbol `mcp', `lsp', or `formatter' — stored on the row as
  the `opencode-status-type' text property.
NAME is the entry's display name (string).
ON-P is non-nil when the entry is connected/enabled (green bullet);
  nil otherwise (red bullet).
STATUS-LABEL is the pre-rendered status string (with its own face).
EXTRA-INFO is a dimmed tail string (LSP root path, formatter extensions,
  or the empty string).
HINT is a trailing italic hint (\" [SPC: connect]\" for MCP) or \"\".
DATA is the raw plist stored on the row as `opencode-status-data'.

The whole row (from bullet to newline) carries `opencode-status-type',
`opencode-status-name', and `opencode-status-data' text properties so
that `opencode-status--next'/`--prev'/`--toggle' can locate the row."
  (let ((line-start (point))
        (face (if on-p 'opencode-status-connected 'opencode-status-disconnected))
        (bullet (if on-p "●" "○")))
    (insert (propertize (format "  %s " bullet) 'face face)
            (propertize (format "%-20s" name) 'face 'opencode-status-name)
            " "
            status-label
            (or extra-info "")
            (propertize (or hint "") 'face 'opencode-status-hint)
            "\n")
    (put-text-property line-start (point) 'opencode-status-type type)
    (put-text-property line-start (point) 'opencode-status-name name)
    (put-text-property line-start (point) 'opencode-status-data data)))

(defun opencode-status--render-mcp-entry (name-status)
  "Render one MCP entry — NAME-STATUS is (NAME . STATUS-PLIST)."
  (let* ((name (car name-status))
         (status (cdr name-status))
         (on-p (equal (plist-get status :status) "connected"))
         (hint (if (opencode-status--mcp-toggleable-p status)
                   (if on-p " [SPC: disconnect]" " [SPC: connect]")
                 "")))
    (opencode-status--render-entry
     'mcp name on-p
     (opencode-status--mcp-status-string status)
     nil hint status)))

(defun opencode-status--render-lsp-entry (lsp)
  "Render one LSP entry from plist LSP."
  (let* ((name (or (plist-get lsp :name) (plist-get lsp :id) "unknown"))
         (status (plist-get lsp :status))
         (root (or (plist-get lsp :root) ""))
         (on-p (equal status "connected"))
         (face (if on-p 'opencode-status-connected 'opencode-status-disconnected)))
    (opencode-status--render-entry
     'lsp name on-p
     (propertize (or status "") 'face face)
     (if (string-empty-p root)
         ""
       (propertize (format "  %s" root) 'face 'font-lock-comment-face))
     nil lsp)))

(defun opencode-status--render-formatter-entry (fmt)
  "Render one formatter entry from plist FMT."
  (let* ((name (or (plist-get fmt :name) "unknown"))
         (on-p (eq (plist-get fmt :enabled) t))
         (extensions (plist-get fmt :extensions))
         (ext-str (if (and extensions (> (length extensions) 0))
                      (mapconcat #'identity
                                 (if (vectorp extensions)
                                     (append extensions nil)
                                   extensions)
                                 " ")
                    ""))
         (face (if on-p 'opencode-status-connected 'opencode-status-disconnected)))
    (opencode-status--render-entry
     'formatter name on-p
     (propertize (if on-p "enabled" "disabled") 'face face)
     (if (string-empty-p ext-str)
         ""
       (propertize (format "  %s" ext-str) 'face 'font-lock-comment-face))
     nil fmt)))

(defun opencode-status--render-section (title data render-fn)
  "Render a section with TITLE and DATA, delegating each row to RENDER-FN.
If DATA is nil/empty, insert a \"(none)\" placeholder instead."
  (insert (propertize title 'face 'opencode-status-section) "\n")
  (if data
      (dolist (entry data) (funcall render-fn entry))
    (insert (propertize "  (none)\n" 'face 'font-lock-comment-face))))

(defun opencode-status--render ()
  "Render all status sections in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (opencode-status--render-section
     "MCP Servers" opencode-status--mcp-data
     #'opencode-status--render-mcp-entry)
    (insert "\n")
    (opencode-status--render-section
     "LSP Servers" opencode-status--lsp-data
     #'opencode-status--render-lsp-entry)
    (insert "\n")
    (opencode-status--render-section
     "Formatters" opencode-status--formatter-data
     #'opencode-status--render-formatter-entry)
    ;; Footer
    (insert "\n"
            (propertize "[n/p] navigate  [SPC] toggle  [g] refresh  [q] quit"
                        'face 'opencode-status-hint)
            "\n")
    (goto-char (point-min))
    ;; Move to first data line (skip section header)
    (forward-line 1)))

;;; --- Interactive commands ---

(defun opencode-status--next ()
  "Move to the next status entry."
  (interactive)
  (let ((found nil))
    (save-excursion
      (forward-line 1)
      (while (and (not (eobp)) (not found))
        (when (get-text-property (point) 'opencode-status-name)
          (setq found (point)))
        (unless found (forward-line 1))))
    (when found (goto-char found))))

(defun opencode-status--prev ()
  "Move to the previous status entry."
  (interactive)
  (let ((found nil))
    (save-excursion
      (forward-line -1)
      (while (and (not (bobp)) (not found))
        (when (get-text-property (point) 'opencode-status-name)
          (setq found (point)))
        (unless found (forward-line -1))))
    (when found (goto-char found))))

(defun opencode-status--toggle ()
  "Toggle the status of the entry at point.
For MCP: connect/disconnect.  Other types: no-op with message."
  (interactive)
  (let ((type (get-text-property (point) 'opencode-status-type))
        (name (get-text-property (point) 'opencode-status-name))
        (data (get-text-property (point) 'opencode-status-data)))
    (unless type
      (user-error "No entry at point"))
    (pcase type
      ('mcp
       (let ((status (plist-get data :status)))
         (cond
          ((equal status "connected")
           (opencode-api-post-sync
            "/mcp/disconnect"
            (list :name name))
           (message "Disconnecting %s..." name))
          ((member status '("disabled" "failed"))
           (opencode-api-post-sync
            "/mcp/connect"
            (list :name name))
           (message "Connecting %s..." name))
          (t (message "Cannot toggle %s (status: %s)" name status)))
         (opencode-status--refresh)))
      (_ (message "Toggle not supported for %s entries" type)))))

(defun opencode-status--refresh ()
  "Refresh all status data and re-render."
  (interactive)
  (setq opencode-status--mcp-data (opencode-status--fetch-mcp))
  (setq opencode-status--lsp-data (opencode-status--fetch-lsp))
  (setq opencode-status--formatter-data (opencode-status--fetch-formatter))
  (opencode-status--render)
  (message "Status refreshed"))

(defun opencode-status--quit ()
  "Close the status popup."
  (interactive)
  (when-let ((win (get-buffer-window (current-buffer))))
    (delete-window win))
  (kill-buffer (current-buffer)))

;;; --- Entry point ---

;;;###autoload
(defun opencode-server-status ()
  "Show server status popup (MCP, LSP, Formatter)."
  (interactive)
  (let ((buf (get-buffer-create opencode-status--buffer-name)))
    (with-current-buffer buf
      (opencode-status-mode)
      (opencode-status--refresh))
    (display-buffer buf
                    '((display-buffer-at-bottom)
                      (window-height . fit-window-to-buffer)
                      (dedicated . t)))))

(provide 'opencode-status)
;;; opencode-status.el ends here
