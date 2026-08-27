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

(defun opencode-ui--make-section (type &optional id data rear-advance
                                       front-advance grows)
  "Create a section plist.
TYPE is a symbol (e.g., `message', `tool-call', `session').
ID is an optional unique identifier.
DATA is an optional plist of section-specific data.
When REAR-ADVANCE is non-nil, the overlay will be created with
`rear-advance' so insertions at its end are included in the overlay
\(used by streaming reasoning sections so deltas join the section).
When FRONT-ADVANCE is non-nil, insertions at the section's beginning
stay outside it.  Part-level sections use this so a late delta appended
to the preceding part cannot become part of the following section.
When GROWS is non-nil, an empty section may still collapse because later
content will be added by an explicit range update."
  (list :type type :id id :data data
        :rear-advance rear-advance
        :front-advance front-advance
        :grows grows))

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
             (front-advance (plist-get section-val :front-advance))
             (rear-advance (plist-get section-val :rear-advance))
             (ov (make-overlay section-start section-end nil
                               front-advance rear-advance)))
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

(defun opencode-ui--section-type (&optional pos)
  "Return the type of the section at POS."
  (plist-get (opencode-ui--section-at pos) :type))

(defun opencode-ui--section-id (&optional pos)
  "Return the ID of the section at POS."
  (plist-get (opencode-ui--section-at pos) :id))

;;; --- Section collapse/expand ---

(defvar opencode-ui-section-toggled-functions nil
  "Abnormal hook run after `opencode-ui--toggle-section' flips a section.
Each function receives the section plist and non-nil when the section is
now collapsed.

A section overlay does not outlive the text it covers, so a redraw of
that text silently reverts whatever the user chose with TAB.  This file
keeps no memory of its own --- it does not know which redraws are
coming, or what identifies a section across one --- so it reports the
choice and lets the buffer that owns the content remember it.")

(defun opencode-ui--section-collapsed-p (&optional pos)
  "Return non-nil if the section at POS is collapsed."
  (when-let* ((ov (opencode-ui--innermost-section-overlay pos)))
    (overlay-get ov 'opencode-collapsed)))

(defun opencode-ui--in-collapsed-section-p (pos)
  "Return non-nil when POS lies inside a collapsed section.
Text inserted at POS is therefore hidden, and must be marked hidden
itself: `insert' does not inherit the `invisible' property, so streamed
content appended into a collapsed section would otherwise reappear one
delta at a time."
  (let ((found nil))
    (dolist (ov (overlays-at pos))
      (when (and (overlay-get ov 'opencode-section)
                 (overlay-get ov 'opencode-collapsed))
        (setq found t)))
    found))

(defun opencode-ui--section-body-start (ov)
  "Return the first position of OV's body: just past its header line.
Bounded by OV's end, so a section that is only a header reports an
empty body rather than running into the next one."
  (save-excursion
    (goto-char (overlay-start ov))
    (min (1+ (pos-eol)) (overlay-end ov))))

(defun opencode-ui--collapsed-indicator-bounds (ov)
  "Return (START . END) of OV's `[collapsed]' indicator, or nil."
  (let* ((start (overlay-start ov))
         (search-end (opencode-ui--section-body-start ov))
         (ind-start (text-property-any start search-end
                                       'opencode-collapsed-indicator t)))
    (when ind-start
      (cons ind-start
            (or (next-single-property-change ind-start
                                             'opencode-collapsed-indicator
                                             nil search-end)
                search-end)))))

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

(defun opencode-ui--recollapse-nested (ov)
  "Re-hide the sections nested in OV that are collapsed in their own right.
Expanding OV clears `invisible' across its whole body, inner sections
included.  Those carry their own collapsed state, and a choice the user
made about them specifically, so opening the outer section must not open
them too: that would leave an inner section looking expanded while its
overlay still says collapsed, and the next redraw would snap it shut
again."
  (dolist (inner (overlays-in (overlay-start ov) (overlay-end ov)))
    (when (and (not (eq inner ov))
               (overlay-get inner 'opencode-section)
               (overlay-get inner 'opencode-collapsed))
      (opencode-ui--collapse-section inner))))

(defun opencode-ui--collapse-section (ov)
  "Collapse section overlay OV.  Return non-nil if it collapsed.

A section with nothing under its header collapses only if it is one that
grows into itself --- the `grows' flag from
`opencode-ui--make-section'.  A reasoning section exists from the moment
the part is announced, when it is a header and nothing else, and the
user can fold it away before its first delta arrives; refusing to record
that left the header claiming expanded and every later delta visible.  A
section that is complete when drawn and simply has no body, like a
subtask carrying no prompt, has nothing to collapse and must not claim
otherwise.

Idempotent, and deliberately so: a caller that redraws part of a
collapsed section's header deletes the `[collapsed]' indicator with it,
and re-running this is how it puts the header back in agreement with the
overlay.  Re-running must not then stack a second indicator."
  (let* ((body-start (opencode-ui--section-body-start ov))
         (end (overlay-end ov))
         (has-body (< body-start end)))
    (when (or has-body
              (plist-get (overlay-get ov 'opencode-section) :grows)
              ;; Compatibility for non-chat sections that still grow via
              ;; rear-advance rather than explicit `move-overlay'.
              (plist-get (overlay-get ov 'opencode-section) :rear-advance))
      (when has-body
        (put-text-property body-start end 'invisible 'opencode-section))
      (overlay-put ov 'opencode-collapsed t)
      (opencode-ui--swap-collapse-icon ov "▶")
      (unless (opencode-ui--collapsed-indicator-bounds ov)
        (save-excursion
          (goto-char (overlay-start ov))
          (goto-char (pos-eol))
          (insert (propertize " [collapsed]"
                              'face 'font-lock-comment-face
                              'opencode-collapsed-indicator t))))
      t)))

(defun opencode-ui--expand-section (ov)
  "Expand section overlay OV, leaving sections nested in it as they were."
  (when-let* ((bounds (opencode-ui--collapsed-indicator-bounds ov)))
    (delete-region (car bounds) (cdr bounds)))
  ;; Only clear `invisible' where the value is ours.  Markdown hides its
  ;; own markup under `opencode-md' and has to survive an expand.
  (let ((pos (opencode-ui--section-body-start ov))
        (end (overlay-end ov)))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'invisible nil end)
                      end)))
        (when (eq (get-text-property pos 'invisible) 'opencode-section)
          (remove-text-properties pos next '(invisible nil)))
        (setq pos next))))
  (overlay-put ov 'opencode-collapsed nil)
  (opencode-ui--swap-collapse-icon ov "▼")
  (opencode-ui--recollapse-nested ov))

(defun opencode-ui--toggle-section (&optional pos)
  "Toggle collapse/expand of the innermost section at POS."
  (interactive)
  (when-let* ((ov (opencode-ui--innermost-section-overlay (or pos (point)))))
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
      (if (overlay-get ov 'opencode-collapsed)
          (opencode-ui--expand-section ov)
        (opencode-ui--collapse-section ov))
      (run-hook-with-args 'opencode-ui-section-toggled-functions
                          (overlay-get ov 'opencode-section)
                          (and (overlay-get ov 'opencode-collapsed) t)))))

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

(provide 'opencode-ui)
;;; opencode-ui.el ends here
