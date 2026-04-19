;;; opencode-ui.el --- Section rendering for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Magit-style collapsible section rendering for opencode.el.
;; Provides the foundational UI primitives used by chat, session, and
;; diff buffers: sections with overlays, separator lines, headers,
;; and keyboard navigation.
;;
;; Sections use overlays (not text properties) so that nested sections
;; (e.g. a tool-call inside a message) work correctly — overlays stack
;; and we can always find the innermost one at point.

;;; Code:

(require 'opencode-faces)

(defgroup opencode-ui nil
  "OpenCode UI rendering."
  :group 'opencode
  :prefix "opencode-ui-")

;;; --- Section data structure ---
;;
;; Each section is an overlay with these properties:
;;   `opencode-section'       — plist identifying the section (:type :id :data)
;;   `opencode-collapsed'     — non-nil if section is collapsed

(defun opencode-ui--make-section (type &optional id data rear-advance)
  "Create a section plist.
TYPE is a symbol (e.g., `message', `tool-call', `session').
ID is an optional unique identifier.
DATA is an optional plist of section-specific data.
When REAR-ADVANCE is non-nil, the overlay will be created with
`rear-advance' so insertions at its end are included in the overlay
\(used by streaming reasoning sections so deltas join the section)."
  (list :type type :id id :data data :rear-advance rear-advance))

;;; --- Section insertion ---

(defmacro opencode-ui--with-section (section &rest body)
  "Insert SECTION content from BODY.
SECTION is a section plist from `opencode-ui--make-section'.  It may
additionally carry a `:rear-advance t' flag — when present, the
section overlay is created with `rear-advance' so subsequent
insertions at the overlay's end (e.g. streaming deltas appending to
an initially-empty reasoning section) are INCLUDED in the overlay.
Without this flag, streamed content lands outside the section and
the collapse toggle can only hide the header line.

BODY is evaluated with `inhibit-read-only' bound to t."
  (declare (indent 1) (debug t))
  `(let ((inhibit-read-only t)
         (section-start (point))
         (section-val ,section))
     ,@body
     (let* ((section-end (point))
             (rear-advance (plist-get section-val :rear-advance))
             (ov (make-overlay section-start section-end nil nil rear-advance)))
       (overlay-put ov 'opencode-section section-val)
       (overlay-put ov 'evaporate t)
       ov)))

;;; --- Section queries ---

(defun opencode-ui--innermost-section-overlay (&optional pos)
  "Return the innermost (smallest) section overlay at POS."
  (let* ((p (or pos (point)))
         (overlays (append (overlays-at p)
                           (when (> p (point-min))
                             (overlays-at (1- p)))))
         (best nil)
         (best-size most-positive-fixnum))
    (dolist (ov overlays)
      (when (overlay-get ov 'opencode-section)
        (let ((size (- (overlay-end ov) (overlay-start ov))))
          (when (< size best-size)
            (setq best ov
                  best-size size)))))
    best))

(defun opencode-ui--section-at (&optional pos)
  "Return the section plist at POS (default: point), or nil.
Returns the innermost section when sections are nested."
  (when-let* ((ov (opencode-ui--innermost-section-overlay pos)))
    (overlay-get ov 'opencode-section)))

(defun opencode-ui--section-start (&optional pos)
  "Return the start position of the section at POS."
  (when-let* ((ov (opencode-ui--innermost-section-overlay pos)))
    (overlay-start ov)))

(defun opencode-ui--section-end (&optional pos)
  "Return the end position of the section at POS."
  (when-let* ((ov (opencode-ui--innermost-section-overlay pos)))
    (overlay-end ov)))

(defun opencode-ui--section-type (&optional pos)
  "Return the type of the section at POS."
  (plist-get (opencode-ui--section-at pos) :type))

(defun opencode-ui--section-id (&optional pos)
  "Return the ID of the section at POS."
  (plist-get (opencode-ui--section-at pos) :id))

;;; --- Section collapse/expand ---

(defun opencode-ui--section-collapsed-p (&optional pos)
  "Return non-nil if the section at POS is collapsed."
  (when-let* ((ov (opencode-ui--innermost-section-overlay pos)))
    (overlay-get ov 'opencode-collapsed)))

(defun opencode-ui--swap-collapse-icon (ov new-char)
  "Replace the collapse/expand icon in overlay OV header with NEW-CHAR."
  (let ((search-start (overlay-start ov)))
    (save-excursion
      (goto-char search-start)
      (let ((eol (pos-eol)))
        (while (< (point) eol)
          (if (get-text-property (point) 'opencode-collapse-icon)
              (progn
                (let ((icon-face (get-text-property (point) 'face)))
                  (delete-char 1)
                  (insert (propertize new-char
                                      'face icon-face
                                      'opencode-collapse-icon t)))
                (goto-char eol))
            (forward-char 1)))))))

(defun opencode-ui--reset-nested-collapsed (ov)
  "Reset collapsed state of all section overlays nested inside OV.
Removes `[collapsed]' indicators, clears `opencode-collapsed' property,
and swaps icons back to expanded for any inner sections that were
independently collapsed."
  (let ((start (overlay-start ov))
        (end (overlay-end ov)))
    (dolist (inner (overlays-in start end))
      (when (and (not (eq inner ov))
                 (overlay-get inner 'opencode-section)
                 (overlay-get inner 'opencode-collapsed))
        ;; Remove [collapsed] indicator from inner header line
        (let ((inner-start (overlay-start inner)))
          (save-excursion
            (goto-char inner-start)
            (let* ((eol (pos-eol))
                   (search-end (min (1+ eol) (overlay-end inner)))
                   (ind-start (text-property-any inner-start search-end
                                                 'opencode-collapsed-indicator t)))
              (when ind-start
                (let ((ind-end (or (next-single-property-change
                                    ind-start 'opencode-collapsed-indicator
                                    nil search-end)
                                   search-end)))
                  (delete-region ind-start ind-end))))))
        (overlay-put inner 'opencode-collapsed nil)
        (opencode-ui--swap-collapse-icon inner "▼")))))

(defun opencode-ui--toggle-section (&optional pos)
  "Toggle collapse/expand of the innermost section at POS."
  (interactive)
  (let ((ov (opencode-ui--innermost-section-overlay (or pos (point)))))
    (when ov
      (let* ((inhibit-read-only t)
             (start (overlay-start ov))
             (end (overlay-end ov))
             ;; Body starts after the header line's newline
             (body-start (save-excursion
                           (goto-char start)
                           (min (1+ (pos-eol)) end))))
        (if (overlay-get ov 'opencode-collapsed)
            ;; Expand: remove [collapsed] indicator, then show body
            (progn
              ;; Remove [collapsed] indicator from header line
              (save-excursion
                (goto-char start)
                (let* ((eol (pos-eol))
                       (search-end (min (1+ eol) (overlay-end ov)))
                       (ind-start (text-property-any start search-end
                                                      'opencode-collapsed-indicator t)))
                  (when ind-start
                    (let ((ind-end (or (next-single-property-change
                                        ind-start 'opencode-collapsed-indicator
                                        nil search-end)
                                       search-end)))
                      (delete-region ind-start ind-end)))))
              ;; Reset any nested sections that were independently collapsed
              (opencode-ui--reset-nested-collapsed ov)
              ;; Recalculate body-start and end after deletion
              (let* ((new-end (overlay-end ov))
                     (new-body-start (save-excursion
                                       (goto-char start)
                                       (min (1+ (pos-eol)) new-end))))
                ;; Only remove 'invisible where value is 'opencode-section
                ;; Preserve other invisible values (e.g., 'opencode-md for markdown)
                (let ((pos new-body-start))
                  (while (< pos new-end)
                    (let ((next (or (next-single-property-change pos 'invisible nil new-end)
                                     new-end))
                          (val (get-text-property pos 'invisible)))
                      (when (eq val 'opencode-section)
                        (remove-text-properties pos next '(invisible nil)))
                      (setq pos next)))))
              (overlay-put ov 'opencode-collapsed nil)
              (opencode-ui--swap-collapse-icon ov "▼"))
          ;; Collapse: hide everything after the first line
          (when (< body-start end)
            (put-text-property body-start end
                               'invisible 'opencode-section)
            (overlay-put ov 'opencode-collapsed t)
            (opencode-ui--swap-collapse-icon ov "▶")
            ;; Append [collapsed] indicator at end of header line
            (save-excursion
              (goto-char start)
              (goto-char (pos-eol))
              (insert (propertize " [collapsed]"
                                  'face 'font-lock-comment-face
                                  'opencode-collapsed-indicator t)))))))))

;;; --- Section navigation ---

(defun opencode-ui--next-section ()
  "Move to the next section."
  (interactive)
  (let ((pos (point))
        (found nil))
    ;; Move past current position using overlay boundaries
    (while (and (not (eobp)) (not found))
      (let ((next (next-overlay-change (point))))
        (if (= next (point))
            ;; No more overlay changes — we're at eob
            (goto-char (point-max))
          (goto-char next)
          (when (opencode-ui--section-at next)
            (let ((start (opencode-ui--section-start next)))
              (when (and start (> start pos))
                (goto-char start)
                (setq found t)))))))
    (unless found
      (goto-char pos)
      (message "No next section"))))

(defun opencode-ui--prev-section ()
  "Move to the previous section."
  (interactive)
  (let ((pos (point))
        (found nil))
    ;; Move backward using overlay boundaries
    (while (and (not (bobp)) (not found))
      (let ((prev (previous-overlay-change (point))))
        (if (= prev (point))
            ;; No more overlay changes — we're at bob
            (goto-char (point-min))
          (goto-char prev)
          (let ((section (opencode-ui--section-at prev)))
            (when section
              (let ((start (opencode-ui--section-start prev)))
                (when (and start (< start pos))
                  (goto-char start)
                  (setq found t))))))))
    (unless found
      (goto-char pos)
      (message "No previous section"))))

;;; --- Text insertion helpers ---

(defun opencode-ui--insert-separator ()
  "Insert a horizontal separator line.
Uses a space with `display' property for full-width extension."
  (let ((inhibit-read-only t))
    (insert (propertize " "
                        'face 'opencode-separator
                        'read-only t
                        'display '(space :width text))
            "\n")))

(defun opencode-ui--insert-header (text &optional face)
  "Insert a section header TEXT with optional FACE."
  (let ((inhibit-read-only t))
    (insert (propertize text 'face (or face 'opencode-header))
            "\n")))

(defun opencode-ui--insert-line (text &optional face)
  "Insert a line of TEXT with optional FACE."
  (let ((inhibit-read-only t))
    (insert (if face (propertize text 'face face) text)
            "\n")))

(defun opencode-ui--insert-prop (text &rest properties)
  "Insert TEXT with PROPERTIES applied."
  (let ((inhibit-read-only t))
    (insert (apply #'propertize text properties))))

(defun opencode-ui--insert-icon (type)
  "Insert a status icon for TYPE.
TYPE is one of: `active', `idle', `archived', `pending',
`running', `success', `error', `expanded', `collapsed'."
  (let ((inhibit-read-only t)
        (icon (pcase type
                ('active    (propertize "⬤" 'face 'opencode-session-active))
                ('idle      (propertize "○" 'face 'opencode-session-idle))
                ('archived  (propertize "◌" 'face 'opencode-session-archived))
                ('pending   (propertize "○" 'face 'opencode-todo-pending))
                ('running   (propertize "⏳" 'face 'opencode-tool-running))
                ('success   (propertize "✓" 'face 'opencode-tool-success))
                ('error     (propertize "✗" 'face 'opencode-tool-error))
                ('expanded  (propertize "▼" 'face 'opencode-section-indicator))
                ('collapsed (propertize "▶" 'face 'opencode-section-indicator))
                (_          "·"))))
    ;; Mark expand/collapse icons so toggle-section can find and swap them
    (when (memq type '(expanded collapsed))
      (put-text-property 0 (length icon) 'opencode-collapse-icon t icon))
    (insert icon)))

(defun opencode-ui--insert-tree-guide (last-p)
  "Insert a tree guide character.
If LAST-P is non-nil, insert └─, otherwise insert ├─."
  (let ((inhibit-read-only t))
    (insert (propertize (if last-p "└─ " "├─ ")
                        'face 'opencode-tree-guide))))

;;; --- Buffer helpers ---

(defun opencode-ui--read-only-buffer ()
  "Make the current buffer read-only with special properties."
  (setq buffer-read-only t
        truncate-lines t)
  (buffer-disable-undo))

(defmacro opencode-ui--save-excursion (&rest body)
  "Execute BODY preserving point relative to section content.
Useful when re-rendering a buffer — saves the current section ID
and restores point to the same section afterward."
  (declare (indent 0) (debug t))
  `(let ((saved-section-id (opencode-ui--section-id))
         (saved-col (current-column))
         (saved-line-offset
          (when (opencode-ui--section-start)
            (count-lines (opencode-ui--section-start)
                         (point)))))
     ,@body
     ;; Restore position
     (if saved-section-id
         (let ((found nil))
           ;; Use overlays-in to find the section with matching ID
           (dolist (ov (overlays-in (point-min) (point-max)))
             (when (and (not found)
                        (overlay-get ov 'opencode-section)
                        (equal (plist-get (overlay-get ov 'opencode-section) :id)
                               saved-section-id))
               (goto-char (overlay-start ov))
               (when saved-line-offset
                 (forward-line saved-line-offset))
               (move-to-column saved-col)
               (setq found t)))
           (unless found
             (goto-char (point-min))))
       (goto-char (point-min)))))

(provide 'opencode-ui)
;;; opencode-ui.el ends here
