;;; opencode-diff.el --- Inline diff display for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Display file diffs from GET /session/:id/diff with diff-mode faces.
;; Provides a major mode for viewing diffs, navigating between files,
;; reverting changes, and opening files at point.

;;; Code:

(require 'diff-mode)
(require 'seq)
(require 'opencode-api)
(require 'opencode-ui)
(require 'opencode-faces)
(require 'opencode-log)
(require 'opencode-util)

(defvar opencode-default-directory)

(defconst opencode-diff--face-remapping-alist
  '((diff-added . opencode-diff-added)
    (diff-removed . opencode-diff-removed)
    (diff-hunk-header . opencode-diff-hunk-header)
    (diff-file-header . opencode-diff-file-header))
  "Face remapping alist for diff buffers using opencode faces.")

;;; --- Buffer-local variables ---

(defvar-local opencode-diff--session-id nil
  "Session ID for the current diff buffer.")

(defvar-local opencode-diff--message-id nil
  "Message ID for the current diff buffer.
When non-nil, diffs are scoped to this message.")

(defvar-local opencode-diff--diffs nil
  "Vector of diff plists for the current buffer.")

;;; --- Keymap ---

(defvar-keymap opencode-diff-mode-map
  :doc "Keymap for `opencode-diff-mode'."
  "q" #'quit-window
  "o" #'opencode-diff--open-file-at-point
  "r" #'opencode-diff--revert
  "g" #'opencode-diff--refresh
  "n" #'opencode-diff--next-file
  "p" #'opencode-diff--prev-file
  "RET" #'opencode-diff--open-file-at-point)

;;; --- Major mode ---

(define-derived-mode opencode-diff-mode diff-mode "OpenCode Diff"
  "Major mode for viewing OpenCode session diffs.
Derives from `diff-mode' for structure recognition and hunk parsing.
Font-lock is disabled; faces are applied manually during rendering
to preserve custom face names in text properties.
\\{opencode-diff-mode-map}"
  :group 'opencode
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (font-lock-mode -1)
  (setq-local diff-refine nil)
  (setq-local face-remapping-alist opencode-diff--face-remapping-alist)
  (buffer-disable-undo))

;;; --- API functions ---

(defun opencode-diff--fetch (session-id &optional message-id)
  "Fetch file diffs for SESSION-ID, optionally scoped to MESSAGE-ID.
Returns a vector of diff plists, or nil on error."
  (condition-case err
      (opencode-api-get-sync
       (format "/session/%s/diff" session-id)
       (when message-id `(("messageID" . ,message-id))))
    (error
     (message "Failed to fetch diffs: %s" (error-message-string err))
     nil)))

;;; --- Rendering ---

(defun opencode-diff--render ()
  "Render the diff list in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (or (null opencode-diff--diffs)
            (length= opencode-diff--diffs 0))
        ;; Empty state
        (insert (propertize "No changes in this session.\n"
                            'face 'font-lock-comment-face))
      ;; Render each file diff
      (let ((first t))
        (seq-doseq (diff opencode-diff--diffs)
          (if first
              (setq first nil)
            (insert "\n"))
          (opencode-diff--render-file diff))))  ;; close seq-doseq, let, if
    ;; Footer
    (insert "\n")
    (opencode-ui--insert-separator)
    (insert (propertize "[o] open file  [r] revert  [n/p] next/prev file  [g] refresh  [q] quit"
                        'face 'font-lock-comment-face)
            "\n")))

(defun opencode-diff--generate-unified (before after path)
  "Generate a unified diff string from BEFORE and AFTER content for PATH.
Returns a string of unified diff lines, or nil if inputs are empty."
  (when (or before after)
    (let ((before-file (make-temp-file "opencode-diff-before"))
          (after-file (make-temp-file "opencode-diff-after")))
      (unwind-protect
          (progn
            (with-temp-file before-file
              (insert (or before "")))
            (with-temp-file after-file
              (insert (or after "")))
            (with-temp-buffer
              (call-process "diff" nil t nil
                            "-u"
                            "--label" (concat "a/" path)
                            "--label" (concat "b/" path)
                            before-file after-file)
              (let ((output (buffer-string)))
                (unless (string-empty-p output)
                  output))))
        (delete-file before-file)
        (delete-file after-file)))))

(defun opencode-diff--render-file (file-diff)
  "Render a single FILE-DIFF plist in the current buffer."
  (let* ((path (or (plist-get file-diff :path)
                   (plist-get file-diff :file)
                   "unknown"))
         (additions (or (plist-get file-diff :additions) 0))
         (deletions (or (plist-get file-diff :deletions) 0))
         (patch (plist-get file-diff :patch))
         (before (plist-get file-diff :before))
         (after (plist-get file-diff :after))
         (section (opencode-ui--make-section 'diff-file path file-diff)))
    (opencode-ui--with-section section
      ;; File header
      (insert (propertize (format "%s  (+%d -%d)" path additions deletions)
                          'face 'opencode-diff-file-header
                          'opencode-diff-file path)
              "\n")
      ;; Patch content: prefer :patch, fall back to generating from :before/:after
      (let ((diff-text (or (and patch (not (string-empty-p patch)) patch)
                           (opencode-diff--generate-unified before after path))))
        (if diff-text
            (progn
              ;; Prepend unified diff file headers for diff-mode structure
              ;; recognition, unless the patch already contains them.
              (unless (string-prefix-p "---" diff-text)
                (insert (format "--- a/%s\n+++ b/%s\n" path path)))
              (opencode-diff--render-patch diff-text path))
          (insert (propertize "  (no changes)\n"
                              'face 'font-lock-comment-face)))))))

(defun opencode-diff--render-patch (patch-string file-path)
  "Render PATCH-STRING with diff faces.
FILE-PATH is stored as a text property on each line."
  (dolist (line (string-lines patch-string))
    (let ((face (opencode-diff--line-face line)))
      (insert (propertize (concat line "\n")
                          'face face
                          'opencode-diff-file file-path)))))

;;; --- Buffer management ---

(defun opencode-diff--open (session-id)
  "Open a diff buffer for SESSION-ID showing all changes."
  (let ((buf (get-buffer-create "*opencode: diff*"))
        (project-root opencode-default-directory))
    (with-current-buffer buf
      (opencode-diff-mode)
      (when project-root
        (setq default-directory (file-name-as-directory project-root)))
      (setq opencode-diff--session-id session-id)
      (setq opencode-diff--message-id nil)
      (setq opencode-diff--diffs (opencode-diff--fetch session-id))
      (opencode-diff--render))
    (display-buffer buf)))

(defun opencode-diff--open-for-message (session-id message-id)
  "Open a diff buffer for SESSION-ID scoped to MESSAGE-ID."
  (let ((buf (get-buffer-create "*opencode: diff*"))
        (project-root opencode-default-directory))
    (with-current-buffer buf
      (opencode-diff-mode)
      (when project-root
        (setq default-directory (file-name-as-directory project-root)))
      (setq opencode-diff--session-id session-id)
      (setq opencode-diff--message-id message-id)
      (setq opencode-diff--diffs (opencode-diff--fetch session-id message-id))
      (opencode-diff--render))
    (display-buffer buf)))

;;; --- Interactive commands ---

(defun opencode-diff--revert ()
  "Revert the changes shown in this diff buffer.
Requires a message ID to be set."
  (interactive)
  (unless opencode-diff--message-id
    (user-error "No message ID — cannot revert"))
  (unless opencode-diff--session-id
    (user-error "No session ID"))
  (when (yes-or-no-p "Revert these changes? ")
    (condition-case err
        (let ((revert-body (list :messageID opencode-diff--message-id :partID "")))
          (opencode--debug "opencode-diff: reverting sid=%s body=%S"
                   opencode-diff--session-id revert-body)
          (opencode-api-post-sync
           (format "/session/%s/revert" opencode-diff--session-id)
           revert-body)
          (opencode--debug "opencode-diff: revert succeeded")
          (opencode-diff--refresh))
      (error
       (message "Revert failed: %s" (error-message-string err))))))

(defun opencode-diff--open-file-at-point ()
  "Open the file associated with the current line.
Uses `default-directory' (set to project root) to resolve relative paths."
  (interactive)
  (let ((file (get-text-property (point) 'opencode-diff-file)))
    (if file
        (let ((abs-path (expand-file-name file)))
          (if (file-exists-p abs-path)
              (find-file abs-path)
            (user-error "File not found: %s" abs-path)))
      (user-error "No file at point"))))

(defun opencode-diff--next-file ()
  "Move point to the next file header."
  (interactive)
  (let ((pos (point))
        (found nil))
    ;; Move past current file header if on one
    (when (get-text-property (point) 'opencode-diff-file)
      (let ((current-file (get-text-property (point) 'opencode-diff-file)))
        (while (and (not (eobp))
                    (equal (get-text-property (point) 'opencode-diff-file)
                           current-file))
          (forward-line 1))))
    ;; Find next line with file header face
    (while (and (not (eobp)) (not found))
      (when (eq (get-text-property (point) 'face) 'opencode-diff-file-header)
        (setq found t))
      (unless found
        (forward-line 1)))
    (unless found
      (goto-char pos)
      (message "No next file"))))

(defun opencode-diff--prev-file ()
  "Move point to the previous file header."
  (interactive)
  (let ((pos (point))
        (found nil))
    ;; Move before current file header
    (when (eq (get-text-property (point) 'face) 'opencode-diff-file-header)
      (forward-line -1))
    ;; Search backward for file header face
    (while (and (not (bobp)) (not found))
      (forward-line -1)
      (when (eq (get-text-property (point) 'face) 'opencode-diff-file-header)
        (setq found t)))
    (unless found
      (goto-char pos)
      (message "No previous file"))))

(defun opencode-diff--refresh ()
  "Refresh the diff buffer by re-fetching from the API."
  (interactive)
  (when opencode-diff--session-id
    (setq opencode-diff--diffs
          (opencode-diff--fetch opencode-diff--session-id
                                opencode-diff--message-id))
    (opencode-diff--render)
    (message "Diffs refreshed")))

(provide 'opencode-diff)
;;; opencode-diff.el ends here
