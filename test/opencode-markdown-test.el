;;; opencode-markdown-test.el --- Tests for opencode-markdown.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for markdown fontification engine.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-markdown)

;;; --- Helper ---

(defun opencode-markdown-test--has-face-p (text face)
  "Return non-nil if TEXT in current buffer has FACE applied."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward text nil t)
      (let ((actual (get-text-property (match-beginning 0) 'face)))
        (cond
         ((null actual) nil)
         ((symbolp actual) (eq actual face))
         ((listp actual) (memq face actual))
         (t nil))))))

(defun opencode-markdown-test--invisible-p (text)
  "Return non-nil if TEXT in current buffer has invisible property `opencode-md'."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward text nil t)
      (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(defun opencode-markdown-test--no-face-p (text face)
  "Return non-nil if TEXT in current buffer does NOT have FACE applied."
  (save-excursion
    (goto-char (point-min))
    (if (search-forward text nil t)
        (let ((actual (get-text-property (match-beginning 0) 'face)))
          (cond
           ((null actual) t)
           ((symbolp actual) (not (eq actual face)))
           ((listp actual) (not (memq face actual)))
           (t t)))
      t)))

;;; --- A. Inline Element Fontification ---

(ert-deftest opencode-markdown-bold-face ()
  "Verify bold **text** gets `opencode-md-bold' face applied.
Without this, bold emphasis renders as plain text — users lose visual distinction."
  (with-temp-buffer
    (insert " Hello **world** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-bold))))

(ert-deftest opencode-markdown-italic-face ()
  "Verify italic *text* gets `opencode-md-italic' face applied.
Without this, italic emphasis renders as plain text — users lose visual distinction."
  (with-temp-buffer
    (insert " Hello *world* there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-italic))))

(ert-deftest opencode-markdown-bold-italic-face ()
  "Verify ***text*** gets `opencode-md-bold-italic' face applied.
Without this, combined bold-italic renders as plain text — users lose visual distinction."
  (with-temp-buffer
    (insert " Hello ***world*** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-bold-italic))))

(ert-deftest opencode-markdown-inline-code-face ()
  "Verify backtick `code` gets `opencode-md-inline-code' face applied.
Without this, inline code renders as plain text — code snippets lack visual distinction."
  (with-temp-buffer
    (insert " Hello `code` there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "code" 'opencode-md-inline-code))))

(ert-deftest opencode-markdown-header-faces ()
  "Verify H1–H4 (#–####) get corresponding header faces.
Without this, headers render at body text size — document structure becomes invisible."
  (dolist (spec '((1 "opencode-md-header-1" "# Title")
                  (2 "opencode-md-header-2" "## Title")
                  (3 "opencode-md-header-3" "### Title")
                  (4 "opencode-md-header-4" "#### Title")))
    (with-temp-buffer
      (insert (concat " " (nth 2 spec)))
      (opencode-markdown-fontify-region (point-min) (point-max))
      (should (opencode-markdown-test--has-face-p
               "Title" (intern (nth 1 spec)))))))

(ert-deftest opencode-markdown-blockquote-face ()
  "Verify > quoted text gets `opencode-md-blockquote' face applied.
Without this, blockquotes render as plain text — quoted content loses visual distinction."
  (with-temp-buffer
    (insert " > quoted text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "quoted text" 'opencode-md-blockquote))))

(ert-deftest opencode-markdown-list-marker-face ()
  "Verify - marker gets `opencode-md-list-marker' face applied.
Without this, list markers blend with content — list structure becomes harder to scan."
  (with-temp-buffer
    (insert " - item text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "-" 'opencode-md-list-marker))))

(ert-deftest opencode-markdown-hr-face ()
  "Verify --- horizontal rule gets `opencode-md-hr' face applied.
Without this, horizontal rules render as plain dashes — section breaks lose visual weight."
  (with-temp-buffer
    (insert " ---")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "---" 'opencode-md-hr))))

;;; --- B. Marker Hiding ---

(ert-deftest opencode-markdown-bold-markers-invisible ()
  "Verify bold ** markers get invisible property `opencode-md'.
Without this, raw ** markers clutter the display — bold text shows ugly syntax markers."
  (with-temp-buffer
    (insert " Hello **world** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening **
    (goto-char (point-min))
    (search-forward "**")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))
    ;; Closing **
    (search-forward "**")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-markers-have-marker-face ()
  "Verify hidden markers also have `opencode-md-marker' face as fallback.
Without this, revealed markers (when invisibility disabled) have no styling — look broken."
  (with-temp-buffer
    (insert " Hello **world** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening ** should have marker face
    (goto-char (point-min))
    (search-forward "**")
    (should (opencode-markdown-test--has-face-p "**" 'opencode-md-marker))
    ;; Inline code backticks
    (erase-buffer)
    (insert " Hello `code` there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "`")
    (should (let ((face (get-text-property (match-beginning 0) 'face)))
              (if (listp face)
                  (memq 'opencode-md-marker face)
                (eq face 'opencode-md-marker))))))

(ert-deftest opencode-markdown-header-marker-invisible ()
  "Verify header ## marker is hidden with invisible `opencode-md'.
Without this, raw ## prefixes clutter display — headers show ugly syntax markers."
  (with-temp-buffer
    (insert " ## Title")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; The "## " marker (after the leading space) should be invisible
    (goto-char (point-min))
    (search-forward "##")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

;;; --- C. Face Composition ---

(ert-deftest opencode-markdown-face-composition ()
  "Verify fontification composes with existing face via `add-face-text-property'.
Without this, markdown faces override base faces — assistant body styling lost on formatted text."
  (with-temp-buffer
    (insert " Hello **world** there")
    ;; Pre-apply a base face to the entire region
    (add-face-text-property (point-min) (point-max) 'opencode-assistant-body)
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; "world" should have BOTH faces
    (goto-char (point-min))
    (search-forward "world")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (listp face))
      (should (memq 'opencode-md-bold face))
      (should (memq 'opencode-assistant-body face)))))

;;; --- D. Code Blocks ---

(ert-deftest opencode-markdown-code-block-face ()
  "Verify code block content gets `opencode-md-code-block' face applied.
Without this, fenced code blocks render as plain text — code snippets lack visual distinction."
  (with-temp-buffer
    (insert " ```elisp\n (defun foo ())\n ```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "(defun foo ())" 'opencode-md-code-block))))

(ert-deftest opencode-markdown-code-block-fence-invisible ()
  "Verify fence lines (```) are hidden with invisible `opencode-md'.
Without this, raw ``` fences clutter display — code blocks show ugly boundary markers."
  (with-temp-buffer
    (insert " ```elisp\n (defun foo ())\n ```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening fence should be invisible
    (goto-char (point-min))
    (should (eq (get-text-property (point-min) 'invisible) 'opencode-md))
    ;; Closing fence should be invisible
    (goto-char (point-max))
    (search-backward "```" nil t)
    ;; The closing fence starts with " ```" — check the space before it
    (should (eq (get-text-property (point) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-code-block-no-language ()
  "Verify code block without language tag still gets fontified.
Without this, language-less code blocks render as plain text — breaks common markdown usage."
  (with-temp-buffer
    (insert " ```\n some code\n ```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "some code" 'opencode-md-code-block))))

(ert-deftest opencode-markdown-code-block-excludes-inline ()
  "Verify inline markdown (**bold**) is not fontified inside code blocks.
Without this, code examples with markdown syntax get garbled — breaks code display integrity."
  (with-temp-buffer
    (insert " ```python\n x = **not bold**\n ```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; "not bold" should NOT have bold face
    (should (opencode-markdown-test--no-face-p "not bold" 'opencode-md-bold))))

;;; --- E. Toggle / Disabled ---

(ert-deftest opencode-markdown-disabled-toggle ()
  "Verify when `opencode-markdown-fontify-enabled' is nil, no faces are applied.
Without this, users cannot disable fontification — no escape hatch for rendering issues."
  (with-temp-buffer
    (insert " Hello **world** there\n # Title\n > quote")
    (let ((opencode-markdown-fontify-enabled nil))
      (opencode-markdown-fontify-region (point-min) (point-max)))
    (should (opencode-markdown-test--no-face-p "world" 'opencode-md-bold))
    (should (opencode-markdown-test--no-face-p "Title" 'opencode-md-header-1))
    (should (opencode-markdown-test--no-face-p "quote" 'opencode-md-blockquote))))

;;; --- F. Edge Cases ---

(ert-deftest opencode-markdown-empty-region ()
  "Verify fontifying an empty region does not error.
Without this, empty buffers crash the fontification engine — breaks robustness guarantee."
  (with-temp-buffer
    (opencode-markdown-fontify-region (point-min) (point-max))))

(ert-deftest opencode-markdown-plain-text-no-faces ()
  "Verify plain text without markdown gets no markdown faces.
Without this, random text triggers false positive matches — breaks display of normal prose."
  (with-temp-buffer
    (insert " Just some plain text without any markdown.")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-bold))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-italic))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-inline-code))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-header-1))))

(ert-deftest opencode-markdown-italic-marker-invisible ()
  "Verify italic * markers get invisible property `opencode-md'.
Without this, raw * markers clutter display — italic text shows ugly syntax markers."
  (with-temp-buffer
    (insert " Hello *world* there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening * — the italic regex captures the * in group 1
    (goto-char (point-min))
    (search-forward "*")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-inline-code-marker-invisible ()
  "Verify inline code backtick markers get invisible property `opencode-md'.
Without this, raw backticks clutter display — inline code shows ugly syntax markers."
  (with-temp-buffer
    (insert " Hello `code` there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening backtick
    (goto-char (point-min))
    (search-forward "`")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-list-star-marker ()
  "Verify star list marker (* item) gets `opencode-md-list-marker' face.
Without this, star-style lists render differently than dash-style — inconsistent list display."
  (with-temp-buffer
    (insert " * item text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; The * at position 2 (after leading space) should have list-marker face
    (goto-char (point-min))
    (forward-char 1) ;; skip leading space
    (should (let ((face (get-text-property (point) 'face)))
              (if (listp face)
                  (memq 'opencode-md-list-marker face)
                (eq face 'opencode-md-list-marker))))))

(provide 'opencode-markdown-test)
;;; opencode-markdown-test.el ends here
