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
    (insert "Hello **world** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-bold))))

(ert-deftest opencode-markdown-italic-face ()
  "Verify italic *text* gets `opencode-md-italic' face applied.
Without this, italic emphasis renders as plain text — users lose visual distinction."
  (with-temp-buffer
    (insert "Hello *world* there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-italic))))

(ert-deftest opencode-markdown-bold-italic-face ()
  "Verify ***text*** gets `opencode-md-bold-italic' face applied.
Without this, combined bold-italic renders as plain text — users lose visual distinction.

markdown-mode 2.8-alpha mis-parses this construct, leaving stray
asterisks on screen; `opencode-markdown--fix-bold-italic' corrects it.
This test is what pins that workaround."
  (with-temp-buffer
    (insert "Hello ***world*** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-bold-italic))))

(ert-deftest opencode-markdown-inline-code-face ()
  "Verify backtick `code` gets `opencode-md-inline-code' face applied.
Without this, inline code renders as plain text — code snippets lack visual distinction."
  (with-temp-buffer
    (insert "Hello `code` there")
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
      (insert (nth 2 spec))
      (opencode-markdown-fontify-region (point-min) (point-max))
      (should (opencode-markdown-test--has-face-p
               "Title" (intern (nth 1 spec)))))))

(ert-deftest opencode-markdown-blockquote-face ()
  "Verify > quoted text gets `opencode-md-blockquote' face applied.
Without this, blockquotes render as plain text — quoted content loses visual distinction."
  (with-temp-buffer
    (insert "> quoted text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "quoted text" 'opencode-md-blockquote))))

(ert-deftest opencode-markdown-list-marker-face ()
  "Verify - marker gets `opencode-md-list-marker' face applied.
Without this, list markers blend with content — list structure becomes harder to scan."
  (with-temp-buffer
    (insert "- item text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "-" 'opencode-md-list-marker))))

(ert-deftest opencode-markdown-hr-face ()
  "Verify --- horizontal rule gets `opencode-md-hr' face applied.
Without this, horizontal rules render as plain dashes — section breaks lose visual weight."
  (with-temp-buffer
    (insert "---")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "---" 'opencode-md-hr))))

;;; --- B. Marker Hiding ---

(ert-deftest opencode-markdown-bold-markers-invisible ()
  "Verify bold ** markers get invisible property `opencode-md'.
Without this, raw ** markers clutter the display — bold text shows ugly syntax markers."
  (with-temp-buffer
    (insert "Hello **world** there")
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
    (insert "Hello **world** there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening ** should have marker face
    (goto-char (point-min))
    (search-forward "**")
    (should (opencode-markdown-test--has-face-p "**" 'opencode-md-marker))
    ;; Inline code backticks
    (erase-buffer)
    (insert "Hello `code` there")
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
    (insert "## Title")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; The "## " marker should be invisible
    (goto-char (point-min))
    (search-forward "##")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

;;; --- C. Face Composition ---

(ert-deftest opencode-markdown-face-composition ()
  "Verify fontification composes with the face the renderer recorded.
Without this, markdown faces override base faces — assistant body styling lost on formatted text.

The base face must be recorded in `opencode-base-face', which is what
`opencode-chat--emit' does at insertion time.  Stripping keys off that
property rather than off a list of known face names, so a face applied
without recording it is treated as fontification's own and removed --- as
`opencode-markdown-strip-drops-unrecorded-face' asserts."
  (with-temp-buffer
    (insert "Hello **world** there")
    ;; Pre-apply a base face the way the renderer does.
    (add-face-text-property (point-min) (point-max) 'opencode-assistant-body)
    (put-text-property (point-min) (point-max)
                       'opencode-base-face 'opencode-assistant-body)
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
    (insert "```elisp\n(defun foo ())\n```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "(defun foo ())" 'opencode-md-code-block))))

(ert-deftest opencode-markdown-code-block-fence-invisible ()
  "Verify fence lines (```) are hidden with invisible `opencode-md'.
Without this, raw ``` fences clutter display — code blocks show ugly boundary markers."
  (with-temp-buffer
    (insert "```elisp\n(defun foo ())\n```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening fence should be invisible
    (goto-char (point-min))
    (should (eq (get-text-property (point-min) 'invisible) 'opencode-md))
    ;; Closing fence should be invisible
    (goto-char (point-max))
    (search-backward "```" nil t)
    ;; The closing fence line is invisible in full
    (should (eq (get-text-property (point) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-code-block-no-language ()
  "Verify code block without language tag still gets fontified.
Without this, language-less code blocks render as plain text — breaks common markdown usage."
  (with-temp-buffer
    (insert "```\nsome code\n```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "some code" 'opencode-md-code-block))))

(ert-deftest opencode-markdown-code-block-excludes-inline ()
  "Verify inline markdown (**bold**) is not fontified inside code blocks.
Without this, code examples with markdown syntax get garbled — breaks code display integrity."
  (with-temp-buffer
    (insert "```python\nx = **not bold**\n```")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; "not bold" should NOT have bold face
    (should (opencode-markdown-test--no-face-p "not bold" 'opencode-md-bold))))

;;; --- E. Toggle / Disabled ---

(ert-deftest opencode-markdown-disabled-toggle ()
  "Verify when `opencode-markdown-fontify-enabled' is nil, no faces are applied.
Without this, users cannot disable fontification — no escape hatch for rendering issues."
  (with-temp-buffer
    (insert "Hello **world** there\n # Title\n > quote")
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
    (insert "Just some plain text without any markdown.")
    (opencode-markdown-fontify-region (point-min) (point-max))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-bold))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-italic))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-inline-code))
    (should (opencode-markdown-test--no-face-p "plain text" 'opencode-md-header-1))))

(ert-deftest opencode-markdown-italic-marker-invisible ()
  "Verify italic * markers get invisible property `opencode-md'.
Without this, raw * markers clutter display — italic text shows ugly syntax markers."
  (with-temp-buffer
    (insert "Hello *world* there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening * — the italic regex captures the * in group 1
    (goto-char (point-min))
    (search-forward "*")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-inline-code-marker-invisible ()
  "Verify inline code backtick markers get invisible property `opencode-md'.
Without this, raw backticks clutter display — inline code shows ugly syntax markers."
  (with-temp-buffer
    (insert "Hello `code` there")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; Opening backtick
    (goto-char (point-min))
    (search-forward "`")
    (should (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md))))

(ert-deftest opencode-markdown-list-star-marker ()
  "Verify star list marker (* item) gets `opencode-md-list-marker' face.
Without this, star-style lists render differently than dash-style — inconsistent list display."
  (with-temp-buffer
    (insert "* item text")
    (opencode-markdown-fontify-region (point-min) (point-max))
    ;; The * opens the line, at column 0
    (goto-char (point-min))
    (should (let ((face (get-text-property (point) 'face)))
              (if (listp face)
                  (memq 'opencode-md-list-marker face)
                (eq face 'opencode-md-list-marker))))))

;;; --- E. jit-lock integration ---

(defun opencode-markdown-test--jit-buffer (text)
  "Insert TEXT into the current buffer marked as markdown, jit-lock style.
Leaves the span unfontified so a test can drive
`opencode-markdown-jit-fontify' over a chosen slice of it."
  (insert text)
  (opencode-markdown-mark-region (point-min) (point-max)))

(ert-deftest opencode-markdown-jit-marks-without-fontifying ()
  "Verify marking a region does not fontify it.
Marking must stay O(1) in span size — the whole point of moving to
jit-lock is that rendering a message does no matching work."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "Hello **world** there")
    (should (opencode-markdown-test--no-face-p "world" 'opencode-md-bold))
    (should (get-text-property (point-min) 'opencode-markdown))
    (should-not (get-text-property (point-min) 'fontified))))

(ert-deftest opencode-markdown-jit-fontifies-marked-region ()
  "Verify the jit-lock worker fontifies spans the renderer marked."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "Hello **world** there")
    (opencode-markdown-jit-fontify (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "world" 'opencode-md-bold))))

(ert-deftest opencode-markdown-jit-skips-unmarked-region ()
  "Verify markdown syntax outside a marked span is left alone.
Tool output and headers are rendered without the marker property, and
stray asterisks in a shell command must not become emphasis."
  (with-temp-buffer
    (insert "tool output with **stars** in it")
    (opencode-markdown-jit-fontify (point-min) (point-max))
    (should (opencode-markdown-test--no-face-p "stars" 'opencode-md-bold))))

(ert-deftest opencode-markdown-jit-partial-chunk-fontifies-only-its-lines ()
  "Verify a jit-lock chunk fontifies its own lines, not the whole span.
Laziness is the reason for the migration: asking for one line must not
drag the rest of a long message through the matcher."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "**first**\n**second**\n")
    (goto-char (point-min))
    (opencode-markdown-jit-fontify (point-min) (pos-eol))
    (should (opencode-markdown-test--has-face-p "first" 'opencode-md-bold))
    (should (opencode-markdown-test--no-face-p "second" 'opencode-md-bold))))

(ert-deftest opencode-markdown-jit-widens-to-enclosing-code-fence ()
  "Verify a chunk landing inside a fenced block widens to the whole fence.
Fences are the only multi-line construct here.  A chunk boundary falling
between the fences would otherwise leave the block unrecognised and its
body fontified as prose — the `**not bold**' below would gain emphasis."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "```\n**not bold**\n```\n")
    ;; Ask only for the middle line, which carries no fence of its own.
    (goto-char (point-min))
    (forward-line 1)
    (opencode-markdown-jit-fontify (point) (pos-eol))
    (should (opencode-markdown-test--no-face-p "not bold" 'opencode-md-bold))
    (should (opencode-markdown-test--has-face-p "not bold" 'opencode-md-code-block))))

(ert-deftest opencode-markdown-jit-marks-fontified-after-pass ()
  "Verify the worker records widened text as fontified.
jit-lock only clears `fontified' on change, so text fontified beyond the
requested chunk must be reported or it is matched again on next scroll."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "**bold**\n")
    (opencode-markdown-jit-fontify (point-min) (point-max))
    (should (get-text-property (point-min) 'fontified))))

(ert-deftest opencode-markdown-jit-is-idempotent ()
  "Verify repeated jit-lock passes do not accumulate faces.
jit-lock re-calls the worker on the same text after any change, so a
non-idempotent pass would compound :height on headers."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "# Title")
    (dotimes (_ 3)
      (opencode-markdown-jit-fontify (point-min) (point-max)))
    (goto-char (point-min))
    (search-forward "Title")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (if (listp face)
                  (= 1 (seq-count (lambda (f) (eq f 'opencode-md-header-1)) face))
                (eq face 'opencode-md-header-1))))))

(ert-deftest opencode-markdown-jit-chunking-matches-single-pass ()
  "Verify chunked fontification produces the same faces as one whole-span pass.
`jit-lock' splits a span at `jit-lock-chunk-size' boundaries that have
nothing to do with markdown structure, and re-splits it on every scroll,
so a full re-render does not heal a bad split.  What makes this safe is
that the worker rounds every chunk outward to whole lines, so
consecutive chunks overlap by up to a line and multi-line constructs are
always seen whole by some chunk.  That is the invariant, and it is worth
asserting because it is a property of the widening, not of markdown-mode."
  (let* ((text (concat "See [the docs][ref] for details.\n"
                      "Section title\n=============\nbody after\n"
                      "```elisp\n(defun foo () 1)\n```\n"
                      (mapconcat (lambda (i) (format "filler line %d" i))
                                 (number-sequence 1 120) "\n")
                      "\n[ref]: http://example.com\n"))
        (faces-of
         (lambda (chunk)
           (with-temp-buffer
             (insert text)
             (opencode-markdown-mark-region (point-min) (point-max))
             (if (null chunk)
                 (opencode-markdown-jit-fontify (point-min) (point-max))
               (let ((pos (point-min)))
                 (while (< pos (point-max))
                   (let ((e (min (point-max) (+ pos chunk))))
                     (opencode-markdown-jit-fontify pos e)
                     (setq pos e)))))
             (let (out (pos (point-min)))
               (while (< pos (point-max))
                 (push (get-text-property pos 'face) out)
                 (setq pos (1+ pos)))
               (nreverse out))))))
    (let ((whole (funcall faces-of nil)))
      (dolist (chunk '(97 250 500 1500))
        (should (equal whole (funcall faces-of chunk)))))))

(ert-deftest opencode-markdown-glyph-substitution-off-by-default ()
  "Verify list markers keep their literal character by default.
`markdown-mode' replaces a list bullet with ● via a `display' property;
the transcript renders the marker it always has unless asked otherwise."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer "- item text")
    (opencode-markdown-jit-fontify (point-min) (point-max))
    (goto-char (point-min))
    (should-not (get-text-property (point) 'display))))

(ert-deftest opencode-markdown-glyph-substitution-opt-in ()
  "Verify `opencode-markdown-substitute-glyphs' restores markdown-mode's glyphs."
  (let ((opencode-markdown-substitute-glyphs t))
    (with-temp-buffer
      (opencode-markdown-test--jit-buffer "- item text")
      (opencode-markdown-jit-fontify (point-min) (point-max))
      (goto-char (point-min))
      (should (equal "●" (get-text-property (point) 'display))))))

(ert-deftest opencode-markdown-table-fontified ()
  "Verify markdown tables are recognised and faced.
The hand-rolled matchers this replaced had no table support at all."
  (with-temp-buffer
    (opencode-markdown-test--jit-buffer
     "| Feature | Status |\n|---------|--------|\n| tables  | yes    |\n")
    (opencode-markdown-jit-fontify (point-min) (point-max))
    (should (opencode-markdown-test--has-face-p "Feature" 'opencode-md-table))
    (should (opencode-markdown-test--has-face-p "tables" 'opencode-md-table))))

(ert-deftest opencode-markdown-strip-drops-unrecorded-face ()
  "Verify a face applied without `opencode-base-face' is stripped.
This is the contract that replaced a hand-maintained list of the
renderer's face names: fontification keeps exactly what the renderer
recorded and clears everything else, so markdown-mode faces this package
never names still clear on a re-fontify."
  (with-temp-buffer
    (insert "Hello **world** there")
    (add-face-text-property (point-min) (point-max) 'opencode-assistant-body)
    (opencode-markdown-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "there")
    (should (opencode-markdown-test--no-face-p "there" 'opencode-assistant-body))))

(ert-deftest opencode-markdown-props-cache-reuses-parse ()
  "Verify an identical span is parsed once and served from cache.
A structural re-render re-marks every span, so `jit-lock' re-parses text
that did not change; the parse is a pure function of the span and the
glyph option, so it is cached."
  (clrhash opencode-markdown--props-cache)
  (let ((text "Hello **world** there"))
    (should (equal (opencode-markdown--collect-props text)
                   (opencode-markdown--collect-props text)))
    (should (= 1 (hash-table-count opencode-markdown--props-cache)))
    ;; The glyph option changes the answer, so it is part of the key.
    (let ((opencode-markdown-substitute-glyphs t))
      (opencode-markdown--collect-props text))
    (should (= 2 (hash-table-count opencode-markdown--props-cache)))))

(provide 'opencode-markdown-test)
;;; opencode-markdown-test.el ends here
