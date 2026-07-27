;;; opencode-markdown.el --- Markdown fontification for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Markdown fontification for assistant text parts.
;;
;; Parsing is `markdown-mode''s; this file is the bridge.  It decides which
;; spans of the chat buffer are markdown, drives them through `jit-lock', and
;; translates `markdown-mode''s faces and markup-hiding onto this package's
;; own faces and invisibility spec.
;;
;; IMPORTANT: Rendered prose lines start at column 0.  The one-column
;; gutter is a `line-prefix' display property applied by
;; `opencode--prose-prefix', not a character in the buffer, so a span
;; handed to `markdown-mode' is real markdown with no leading indent.

;;; Code:

(require 'cl-lib)
(require 'markdown-mode)
(require 'opencode-faces)

;;; --- Customization ---

(defcustom opencode-markdown-fontify-enabled t
  "When non-nil, fontify markdown in assistant text parts."
  :type 'boolean
  :group 'opencode)

(defcustom opencode-markdown-max-fontified-code-blocks 20
  "Maximum number of code blocks to syntax-highlight per fontified span.
Spans with more blocks than this get the code-block face only, no
per-language syntax highlighting."
  :type 'integer
  :group 'opencode)

(defcustom opencode-markdown-max-code-block-lines 300
  "Maximum number of lines in a code block for syntax highlighting.
Code blocks exceeding this limit get the code-block background face only,
skipping the expensive temp-buffer font-lock pass.
Set to nil to disable the limit."
  :type '(choice integer (const nil))
  :group 'opencode)

(defvar opencode-markdown-fontify-max-size 32768
  "Obsolete.  Region size that used to trigger deferred fontification.
`jit-lock' now decides what to fontify and when, so there is no size at
which a region is handled differently.")
(make-obsolete-variable 'opencode-markdown-fontify-max-size
                        "fontification is driven by jit-lock." "0.2.0")

;;; --- Internal: markdown-mode bridge ---

;; Parsing is delegated to `markdown-mode' rather than hand-rolled here.  The
;; regexes this replaced were line-anchored and context-free, so they could not
;; see setext headings, ordered lists, links, tables, reference definitions or
;; escaped markers, and they mis-parsed emphasis inside words.  `markdown-mode'
;; is already a declared dependency of this package.
;;
;; It cannot simply be turned on in the chat buffer: it is a major mode, and its
;; keywords need its own syntax table, `syntax-propertize-function' and buffer
;; locals, none of which can coexist with the chat buffer's read-only
;; transcript, input area and keymaps.  So the span is fontified in a temp
;; buffer and the resulting properties are copied back --- the same technique
;; the old code already used for syntax-highlighting fenced code blocks, just
;; applied to the whole span instead of only the code.

(defconst opencode-markdown--face-map
  '((markdown-header-face-1     . opencode-md-header-1)
    (markdown-header-face-2     . opencode-md-header-2)
    (markdown-header-face-3     . opencode-md-header-3)
    (markdown-header-face-4     . opencode-md-header-4)
    (markdown-header-face-5     . opencode-md-header-4)
    (markdown-header-face-6     . opencode-md-header-4)
    (markdown-bold-face         . opencode-md-bold)
    (markdown-italic-face       . opencode-md-italic)
    (markdown-inline-code-face  . opencode-md-inline-code)
    (markdown-code-face         . opencode-md-code-block)
    (markdown-pre-face          . opencode-md-code-block)
    (markdown-language-keyword-face . opencode-md-code-block-header)
    (markdown-markup-face       . opencode-md-marker)
    (markdown-header-delimiter-face . opencode-md-marker)
    (markdown-header-rule-face  . opencode-md-hr)
    (markdown-hr-face           . opencode-md-hr)
    (markdown-list-face         . opencode-md-list-marker)
    (markdown-blockquote-face   . opencode-md-blockquote))
  "Map `markdown-mode' faces onto this package's own.
Keeping the `opencode-md-*' faces means themes and user customisation
that already target them keep working, and the visible result of the
switch is limited to what `markdown-mode' parses differently.  Faces
with no local equivalent --- links, URLs, tables, and the `font-lock-*'
faces from natively highlighted code --- are passed through unchanged.")

(defun opencode-markdown--map-face (face)
  "Translate FACE, a face symbol or list, through `opencode-markdown--face-map'."
  (cond
   ((symbolp face) (or (cdr (assq face opencode-markdown--face-map)) face))
   ((listp face) (mapcar #'opencode-markdown--map-face face))
   (t face)))

(defconst opencode-markdown--fence-re "^```\\w*$"
  "Regexp matching an opening or closing fenced code block line.")

(defun opencode-markdown--worth-highlighting-p ()
  "Return non-nil if the current buffer's code blocks are worth highlighting.
Applies `opencode-markdown-max-fontified-code-blocks' and
`opencode-markdown-max-code-block-lines' to the temp buffer holding the
span about to be fontified."
  (save-excursion
    (goto-char (point-min))
    (let ((blocks 0)
          (longest 0)
          (open nil)
          (ok t))
      (while (re-search-forward opencode-markdown--fence-re nil t)
        (if open
            (progn
              (setq blocks (1+ blocks))
              (setq longest (max longest (count-lines open (point))))
              (setq open nil))
          (setq open (point))))
      (when (> blocks opencode-markdown-max-fontified-code-blocks)
        (setq ok nil))
      (when (and opencode-markdown-max-code-block-lines
                 (> longest opencode-markdown-max-code-block-lines))
        (setq ok nil))
      ok)))

(defun opencode-markdown--collect-props (text)
  "Fontify TEXT with `markdown-mode' and return the properties to copy.
Each element is (BEG END FACE HIDDEN), with offsets zero-based relative
to TEXT and HIDDEN non-nil when the span is markup to be hidden.

`markdown-mode' hides markup two different ways --- an `invisible'
property on most markers, and a `display' of the empty string on header
delimiters --- and substitutes glyphs for others, rendering a list
bullet as ● and a blockquote marker as ▌.  Both hiding mechanisms are
normalised onto this package's single `opencode-md' invisibility spec;
the glyph substitutions are deliberately dropped so the transcript keeps
the appearance it has today."
  (let ((props nil))
    (with-temp-buffer
      (insert text)
      (delay-mode-hooks (markdown-mode))
      (setq-local markdown-hide-markup t)
      ;; Native code-block highlighting runs each block's own major mode over
      ;; the block, which is by far the most expensive thing here.  The two
      ;; limits below are the same guards the previous hand-rolled code
      ;; applied; without them a single huge fence would be highlighted in
      ;; full on the redisplay that first scrolls it into view.
      (setq-local markdown-fontify-code-blocks-natively
                  (opencode-markdown--worth-highlighting-p))
      (font-lock-ensure)
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let* ((next (or (next-property-change pos) (point-max)))
                 (face (get-text-property pos 'face))
                 (display (get-text-property pos 'display))
                 (hidden (or (eq (get-text-property pos 'invisible) 'markdown-markup)
                             (equal display ""))))
            (when (or face hidden)
              (push (list (1- pos) (1- next)
                          (and face (opencode-markdown--map-face face))
                          hidden)
                    props))
            (setq pos next)))))
    (opencode-markdown--fix-bold-italic text (nreverse props))))

(defconst opencode-markdown--bold-italic-re
  "\\(\\*\\*\\*\\)\\([^*\n]+\\)\\(\\*\\*\\*\\)"
  "Regexp matching a ***bold italic*** span.")

(defun opencode-markdown--fix-bold-italic (text props)
  "Correct PROPS for ***bold italic*** spans in TEXT.

Workaround for markdown-mode 2.8-alpha, which mis-parses this construct:
given `***word***' it hides the opening `**', applies bold to `*word'
with the asterisk inside the emphasis, and leaves the closing `*'
unstyled outside the span --- so the user sees stray asterisks.  Verified
against a full `markdown-mode' buffer with its own font-lock, so it is
upstream behaviour rather than an artefact of fontifying in a temp
buffer.

`***bold italic***' is common in model output, which is why this is
corrected here instead of accepted.  Entries overlapping a matched span
are dropped and replaced with the correct marker/content split.  Remove
this once upstream parses the construct correctly."
  (let ((ranges nil)
        (fixes nil)
        (pos 0))
    (while (string-match opencode-markdown--bold-italic-re text pos)
      (let ((beg (match-beginning 0))
            (end (match-end 0))
            (cbeg (match-beginning 2))
            (cend (match-end 2)))
        (push (cons beg end) ranges)
        (push (list beg cbeg 'opencode-md-marker t) fixes)
        (push (list cbeg cend 'opencode-md-bold-italic nil) fixes)
        (push (list cend end 'opencode-md-marker t) fixes)
        (setq pos end)))
    (if (null ranges)
        props
      (append
       (seq-remove (lambda (entry)
                     (let ((b (nth 0 entry)) (e (nth 1 entry)))
                       (seq-some (lambda (r) (and (< b (cdr r)) (> e (car r))))
                                 ranges)))
                   props)
       (nreverse fixes)))))

(defun opencode-markdown--apply-props (start props)
  "Apply PROPS, offsets relative to START, to the current buffer."
  (pcase-dolist (`(,beg ,end ,face ,hidden) props)
    (let ((b (+ start beg))
          (e (+ start end)))
      ;; Apply each face separately, innermost last: passing the list to
      ;; `add-face-text-property' would nest it inside the base face rather
      ;; than extending the flat list the rest of this package expects.
      (dolist (f (reverse (ensure-list face)))
        (when f (add-face-text-property b e f)))
      (when hidden
        (put-text-property b e 'invisible 'opencode-md)))))

(defconst opencode-markdown--base-faces
  '(opencode-assistant-body opencode-user-body opencode-reasoning default)
  "Faces the renderer applies at insertion time, which fontification must keep.
Everything else inside a marked span is owned by fontification and is
removed before a re-fontify.  This is a keep-list rather than a
remove-list because `markdown-mode' can emit faces this file never names
--- link, URL and table faces, plus whatever `font-lock-*' faces a code
block's own major mode produces --- and all of them have to be cleared
for a re-run to be idempotent.")

(defun opencode-markdown--strip-faces (start end)
  "Remove fontification faces from START..END for idempotent re-fontification.
Preserves the base faces listed in `opencode-markdown--base-faces' that
were set during insertion.  Also removes the `invisible' property with
value `opencode-md'.

`jit-lock' re-runs the worker over text it has already fontified, and
`add-face-text-property' accumulates, so without this a header would
compound its :height on every pass."
  (let ((pos start))
    (while (< pos end)
      (let* ((face-val (get-text-property pos 'face))
             (next (or (next-single-property-change pos 'face nil end) end)))
        (when face-val
          (let* ((face-list (if (listp face-val) face-val (list face-val)))
                 (clean (seq-filter (lambda (f)
                                      (memq f opencode-markdown--base-faces))
                                    face-list)))
            (cond
             ((null clean)
              (remove-text-properties pos next '(face nil)))
             ((equal clean (ensure-list face-val))
              nil)                      ; unchanged, skip
             ((cdr clean)
              (put-text-property pos next 'face clean))
             (t
              (put-text-property pos next 'face (car clean))))))
        (setq pos next)))
    ;; Also strip markdown invisibility
    (let ((pos start))
      (while (< pos end)
        (let ((next (or (next-single-property-change pos 'invisible nil end) end)))
          (when (eq (get-text-property pos 'invisible) 'opencode-md)
            (remove-text-properties pos next '(invisible nil)))
          (setq pos next))))))

;;; --- Internal: jit-lock integration ---

;; Markdown fontification is driven by `jit-lock', not by explicit calls from
;; the renderer.  The renderer marks the spans it wants treated as markdown
;; with the `opencode-markdown' text property; jit-lock then calls
;; `opencode-markdown-jit-fontify' for whatever part of the buffer is about to
;; be displayed, and re-calls it after a change invalidates a span.
;;
;; This replaces a hand-rolled idle timer that captured region bounds and
;; fontified them ~0.2s later.  That design had to solve, badly, three problems
;; jit-lock already solves: positions drifting while SSE deltas insert into the
;; buffer before the timer fires, redundant passes queued once per delta, and
;; fontifying transcript that the user cannot see.  Nothing crosses a timer
;; here, so none of them can recur.

(defun opencode-markdown-mark-region (start end)
  "Mark START..END as markdown for `jit-lock' to fontify later.
Called by the renderer in place of fontifying inline.  Marking is O(1)
in the size of the span and defers all matching work to the point where
the text is actually about to be displayed."
  (put-text-property start end 'opencode-markdown t)
  ;; A freshly marked span has never been through `jit-lock'; clearing
  ;; `fontified' is what makes it ask us about this text on next redisplay.
  (put-text-property start end 'fontified nil))

(defun opencode-markdown--run-bounds (pos limit)
  "Return (RUN-START . RUN-END) of the marked run covering POS, or nil.
LIMIT bounds the forward search.  A run is a maximal span carrying a
non-nil `opencode-markdown' property."
  (when (get-text-property pos 'opencode-markdown)
    (cons (or (previous-single-property-change (1+ pos) 'opencode-markdown)
              (point-min))
          (or (next-single-property-change pos 'opencode-markdown nil limit)
              limit))))

(defun opencode-markdown--widen-to-fences (run-start run-end start end)
  "Widen START..END so no fenced code block is cut in half.
Bounded by RUN-START..RUN-END.  Fences are the only construct here that
spans lines, so everything else needs no more than whole-line bounds.
Widening to the enclosing fence rather than to the whole run is what
keeps a large message lazy: only the fences actually on screen are
processed."
  (save-excursion
    (let ((beg (max run-start (progn (goto-char start) (pos-bol))))
          (fin (min run-end (progn (goto-char end) (pos-bol 2))))
          (open nil))
      ;; Odd number of fences between the run start and BEG means BEG is
      ;; inside a block; rewind to that block's opening fence.
      (goto-char run-start)
      (while (re-search-forward opencode-markdown--fence-re beg t)
        (setq open (unless open (match-beginning 0))))
      (when open (setq beg open))
      ;; Likewise, a fence left open at FIN must be followed to its close.
      (setq open nil)
      (goto-char beg)
      (while (re-search-forward opencode-markdown--fence-re fin t)
        (setq open (unless open (match-beginning 0))))
      (when open
        (goto-char fin)
        (setq fin (if (re-search-forward opencode-markdown--fence-re run-end t)
                      (min run-end (1+ (match-end 0)))
                    run-end)))
      (cons beg fin))))

(defun opencode-markdown-jit-fontify (start end)
  "Fontify marked markdown spans overlapping START..END.
The `jit-lock' worker installed by `opencode-markdown-setup'.  Spans the
renderer never marked (tool output, headers, footers) are skipped, so
markdown syntax appearing in them is left alone."
  (when opencode-markdown-fontify-enabled
    (let ((pos start)
          (limit (point-max)))
      (while (< pos end)
        (if-let* ((run (opencode-markdown--run-bounds pos limit)))
            (let ((bounds (opencode-markdown--widen-to-fences
                           (car run) (cdr run) pos (min end (cdr run)))))
              (opencode-markdown--fontify-region-impl (car bounds) (cdr bounds))
              ;; Tell jit-lock about text we fontified beyond what it asked
              ;; for, so widening does not cost a second pass over the same
              ;; fence when the next chunk scrolls in.
              (put-text-property (car bounds) (cdr bounds) 'fontified t)
              (setq pos (max (cdr bounds) (1+ pos))))
          (setq pos (or (next-single-property-change pos 'opencode-markdown nil end)
                        end)))))))

(defun opencode-markdown-setup ()
  "Install markdown fontification in the current buffer via `jit-lock'."
  (jit-lock-register #'opencode-markdown-jit-fontify))

;;; --- Public API ---

(defun opencode-markdown-fontify-region (start end)
  "Fontify markdown elements in region START to END, synchronously.
Idempotent: strips any previously-applied markdown faces before
re-applying, so calling this multiple times on the same region
does not cause face accumulation (e.g. compounding :height).
Processes fenced code blocks first (with syntax highlighting),
then inline markdown on non-code-block regions.

In the chat buffer, fontification is driven by `jit-lock' via
`opencode-markdown-mark-region' instead; this entry point remains for
callers that need a region fontified right now regardless of what is
on screen.
  code-blocks (first, returns exclusion ranges) ->
  bold-italic -> bold -> italic -> inline-code ->
  headers -> blockquotes -> lists -> horizontal rules."
  (when opencode-markdown-fontify-enabled
    (opencode-markdown--fontify-region-impl start end)))

(defun opencode-markdown--fontify-region-impl (start end)
  "Internal: synchronously fontify markdown in region START to END."
  (condition-case err
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (save-excursion
          (save-match-data
            ;; Strip first: `jit-lock' re-runs over text it has already
            ;; fontified, and `add-face-text-property' accumulates.
            (opencode-markdown--strip-faces start end)
            (opencode-markdown--apply-props
             start
             (opencode-markdown--collect-props
              (buffer-substring-no-properties start end))))))
    (error
     (message "opencode-markdown: fontification error: %S" err))))

(provide 'opencode-markdown)
;;; opencode-markdown.el ends here
