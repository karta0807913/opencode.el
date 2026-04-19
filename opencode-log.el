;;; opencode-log.el --- Debug logging for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; Author: opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Centralized debug logging infrastructure for opencode.el.
;; All debug messages go to *opencode: debug* buffer when `opencode-debug' is non-nil.
;;
;; Usage:
;;   (setq opencode-debug t)
;;   (opencode--debug "format string %s" arg)
;;   M-x opencode-show-debug-log
;;   M-x opencode-clear-debug-log

;;; Code:

(defgroup opencode-log nil
  "Debug logging for opencode.el."
  :group 'opencode
  :prefix "opencode-debug-")

;;; --- Customization ---

(defcustom opencode-debug nil
  "When non-nil, enable debug logging to *opencode: debug* buffer.
Debug messages are written with timestamps and auto-truncated
to `opencode-debug-max-lines' to prevent unbounded growth."
  :type 'boolean
  :group 'opencode-log)

(defcustom opencode-debug-max-lines 10000
  "Maximum number of lines to keep in the debug buffer.
When the buffer exceeds this limit, oldest lines are deleted from the top."
  :type 'integer
  :group 'opencode-log)

;;; --- Internal state ---

(defvar opencode-log--buffer-name "*opencode: debug*"
  "Name of the debug log buffer.")

(defvar opencode-log--line-count 0
  "Approximate number of lines in the debug buffer.
Tracked incrementally to avoid O(n) `count-lines' on every log call.")

;;; --- Debug logging function ---

(defun opencode--debug (format-string &rest args)
  "Write a debug message to the debug buffer.
FORMAT-STRING and ARGS are passed to `format'.
When `opencode-debug' is nil, returns immediately without side effects.
Wraps the entire operation in `condition-case' to ensure debug logging
never crashes the caller.

Windows displaying the buffer that have point at the end (tailing)
will auto-scroll to show the new message.  All other windows preserve
their current position, matching the behavior of `*Messages*'.

Line count is tracked incrementally via `opencode-log--line-count'.
Truncation deletes half of max-lines at once to amortize the cost."
  (when opencode-debug
    (condition-case err
        (let* ((existing (get-buffer opencode-log--buffer-name))
               (buf (get-buffer-create opencode-log--buffer-name))
               (msg (apply #'format format-string args))
               (timestamp (format-time-string "%H:%M:%S.%3N")))
          ;; Reset counter when buffer was freshly created
          (unless existing
            (setq opencode-log--line-count 0))
          (with-current-buffer buf
            ;; Collect windows displaying this buffer and whether they
            ;; are "tailing" (point at end) before we insert.
            (let* ((windows (get-buffer-window-list buf nil t))
                   (tailing (mapcar (lambda (w)
                                      (>= (window-point w) (point-max)))
                                    windows)))
              (save-excursion
                (goto-char (point-max))
                (let ((inhibit-read-only t))
                  (insert (format "[%s] %s\n" timestamp msg))))
              (setq opencode-log--line-count (1+ opencode-log--line-count))
              ;; Truncate when exceeding max lines.
              ;; Delete half of max-lines at once so we don't truncate
              ;; on every single log call after reaching the limit.
              (when (> opencode-log--line-count opencode-debug-max-lines)
                (let ((delete-count (/ opencode-debug-max-lines 2)))
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line delete-count)
                    (let ((inhibit-read-only t))
                      (delete-region (point-min) (point))))
                  (setq opencode-log--line-count
                        (- opencode-log--line-count delete-count))))
              ;; Scroll tailing windows to the new end, leave others alone.
              (let ((idx 0))
                (dolist (w windows)
                  (when (and (window-live-p w) (nth idx tailing))
                    (set-window-point w (point-max)))
                  (setq idx (1+ idx)))))))
      (error
       ;; Last resort: log to *Messages* if debug logging itself fails
       (message "opencode--debug error: %s" (error-message-string err))))))

;;; --- Interactive commands ---

(defun opencode-show-debug-log ()
  "Display the debug log buffer in a window."
  (interactive)
  (let ((buf (get-buffer opencode-log--buffer-name)))
    (if buf
        (display-buffer buf)
      (user-error "Debug log buffer does not exist.  Enable `opencode-debug' first"))))

(defun opencode-clear-debug-log ()
  "Erase all contents of the debug log buffer."
  (interactive)
  (let ((buf (get-buffer opencode-log--buffer-name)))
    (if buf
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer))
          (setq opencode-log--line-count 0)
          (message "Debug log cleared"))
      (message "Debug log buffer does not exist"))))

(provide 'opencode-log)

;;; opencode-log.el ends here
