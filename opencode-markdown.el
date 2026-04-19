;;; opencode-markdown.el --- Markdown fontification for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Markdown fontification engine for assistant text parts.
;; Applies faces and hides markers for inline markdown elements
;; and fenced code blocks with optional syntax highlighting.
;; Called after text part rendering (not during streaming).
;;
;; Supported elements: bold, italic, bold-italic, inline code,
;; headers (H1-H4), blockquotes, unordered lists, horizontal rules,
;; fenced code blocks (```lang ... ```).
;;
;; IMPORTANT: Each rendered line starts with " " (one space) because
;; `opencode-chat--render-text-part' does (concat " " line).  All
;; regexes account for this leading space.

;;; Code:

(require 'opencode-faces)

;;; --- Customization ---

(defcustom opencode-markdown-fontify-enabled t
  "When non-nil, fontify markdown in assistant text parts."
  :type 'boolean
  :group 'opencode)

(defcustom opencode-markdown-max-fontified-code-blocks 20
  "Maximum number of code blocks to syntax-highlight per region.
Blocks beyond this limit get background face only, no syntax highlighting."
  :type 'integer
  :group 'opencode)

(defcustom opencode-markdown-max-code-block-lines 300
  "Maximum number of lines in a code block for syntax highlighting.
Code blocks exceeding this limit get the code-block background face only,
skipping the expensive temp-buffer font-lock pass.
Set to nil to disable the limit."
  :type '(choice integer (const nil))
  :group 'opencode)

(defcustom opencode-markdown-fontify-max-size 32768
  "Maximum region size (chars) for synchronous markdown fontification.
Regions larger than this are deferred to an idle timer to avoid blocking.
Set to nil to always fontify synchronously."
  :type '(choice integer (const nil))
  :group 'opencode)

;;; --- Internal: Bold-Italic ---

(defun opencode-markdown--fontify-bold-italic (start end)
  "Apply bold-italic face and hide markers in region START to END.
Matches ***text*** patterns.  Must run before bold and italic."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "\\*\\*\\*\\([^*]+?\\)\\*\\*\\*" end t)
      ;; Content face
      (add-face-text-property (match-beginning 1) (match-end 1)
                              'opencode-md-bold-italic )
      ;; Opening *** markers
      (add-face-text-property (match-beginning 0) (match-beginning 1)
                              'opencode-md-marker )
      (put-text-property (match-beginning 0) (match-beginning 1)
                         'invisible 'opencode-md)
      ;; Closing *** markers
      (add-face-text-property (match-end 1) (match-end 0)
                              'opencode-md-marker )
      (put-text-property (match-end 1) (match-end 0)
                         'invisible 'opencode-md))))

;;; --- Internal: Bold ---

(defun opencode-markdown--fontify-bold (start end)
  "Apply bold face and hide markers in region START to END.
Matches **text** patterns.  Must run after bold-italic."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "\\*\\*\\([^*]+?\\)\\*\\*" end t)
      ;; Skip if already processed (part of ***...*** that was made invisible)
      (unless (eq (get-text-property (match-beginning 0) 'invisible) 'opencode-md)
        ;; Content face
        (add-face-text-property (match-beginning 1) (match-end 1)
                                'opencode-md-bold )
        ;; Opening ** markers
        (add-face-text-property (match-beginning 0) (match-beginning 1)
                                'opencode-md-marker )
        (put-text-property (match-beginning 0) (match-beginning 1)
                           'invisible 'opencode-md)
        ;; Closing ** markers
        (add-face-text-property (match-end 1) (match-end 0)
                                'opencode-md-marker )
        (put-text-property (match-end 1) (match-end 0)
                           'invisible 'opencode-md)))))

;;; --- Internal: Italic ---

(defun opencode-markdown--fontify-italic (start end)
  "Apply italic face and hide markers in region START to END.
Matches *text* patterns (single star, not adjacent to another star).
Must run after bold-italic and bold to avoid conflicts."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "\\(?:^\\|[^*\\\\]\\)\\(\\*\\)\\([^*\n]+?\\)\\(\\*\\)\\(?:[^*]\\|$\\)" end t)
      ;; Skip if the opening * is already invisible (part of ** or ***)
      (unless (eq (get-text-property (match-beginning 1) 'invisible) 'opencode-md)
        ;; Content face
        (add-face-text-property (match-beginning 2) (match-end 2)
                                'opencode-md-italic )
        ;; Opening * marker
        (add-face-text-property (match-beginning 1) (match-end 1)
                                'opencode-md-marker )
        (put-text-property (match-beginning 1) (match-end 1)
                           'invisible 'opencode-md)
        ;; Closing * marker
        (add-face-text-property (match-beginning 3) (match-end 3)
                                'opencode-md-marker )
        (put-text-property (match-beginning 3) (match-end 3)
                           'invisible 'opencode-md)))))

;;; --- Internal: Inline Code ---

(defun opencode-markdown--fontify-inline-code (start end)
  "Apply inline code face and hide backtick markers in region START to END.
Matches `code` patterns."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "\\(`\\)\\([^`\n]+?\\)\\(`\\)" end t)
      ;; Content face
      (add-face-text-property (match-beginning 2) (match-end 2)
                              'opencode-md-inline-code )
      ;; Opening backtick
      (add-face-text-property (match-beginning 1) (match-end 1)
                              'opencode-md-marker )
      (put-text-property (match-beginning 1) (match-end 1)
                         'invisible 'opencode-md)
      ;; Closing backtick
      (add-face-text-property (match-beginning 3) (match-end 3)
                              'opencode-md-marker )
      (put-text-property (match-beginning 3) (match-end 3)
                         'invisible 'opencode-md))))

;;; --- Internal: Headers ---

(defun opencode-markdown--fontify-headers (start end)
  "Apply header faces and hide markers in region START to END.
Matches # through #### headers.  Note: each line has a leading
space from the renderer, so `# Title' appears as ` # Title'."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "^ \\(#\\{1,4\\}\\) +\\(.+\\)$" end t)
      (let* ((hashes (match-string 1))
             (level (length hashes))
             (face (pcase level
                     (1 'opencode-md-header-1)
                     (2 'opencode-md-header-2)
                     (3 'opencode-md-header-3)
                     (_ 'opencode-md-header-4))))
        ;; Apply header face to the text content
        (add-face-text-property (match-beginning 2) (match-end 2)
                                face )
        ;; Hide the "# " marker (hashes + space after them)
        (add-face-text-property (match-beginning 1)
                                (match-beginning 2)
                                'opencode-md-marker )
        (put-text-property (match-beginning 1)
                           (match-beginning 2)
                           'invisible 'opencode-md)))))

;;; --- Internal: Blockquotes ---

(defun opencode-markdown--fontify-blockquotes (start end)
  "Apply blockquote face in region START to END.
Matches `> text' patterns (with leading space from renderer)."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "^ \\(>\\) +\\(.+\\)$" end t)
      ;; Apply blockquote face to the text content
      (add-face-text-property (match-beginning 2) (match-end 2)
                              'opencode-md-blockquote )
      ;; Style the > marker
      (add-face-text-property (match-beginning 1) (match-end 1)
                              'opencode-md-marker ))))

;;; --- Internal: Unordered Lists ---

(defun opencode-markdown--fontify-lists (start end)
  "Apply list marker face in region START to END.
Matches `- item' and `* item' patterns (with leading space)."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "^ \\([*-]\\) +" end t)
      ;; Only apply face to the marker character, not the content
      (add-face-text-property (match-beginning 1) (match-end 1)
                              'opencode-md-list-marker ))))

;;; --- Internal: Horizontal Rules ---

(defun opencode-markdown--fontify-hr (start end)
  "Apply horizontal rule face in region START to END.
Matches `---', `***', `___' patterns (with leading space)."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "^ \\([-*_]\\{3,\\}\\) *$" end t)
      (add-face-text-property (match-beginning 1) (match-end 1)
                              'opencode-md-hr ))))

;;; --- Internal: Code Block Helpers ---
(defconst opencode-markdown--lang-aliases
  '(("elisp"      . "emacs-lisp")
    ("emacs"       . "emacs-lisp")
    ("lisp"        . "emacs-lisp")
    ("bash"        . "sh")
    ("shell"       . "sh")
    ("zsh"         . "sh")
    ("cpp"         . "c++")
    ("js"          . "js")
    ("javascript"  . "js")
    ("ts"          . "typescript")
    ("yml"         . "yaml")
    ("golang"      . "go")
    ("rs"          . "rust")
    ("dockerfile"  . "dockerfile")
    ("el"          . "emacs-lisp"))
  "Alist mapping markdown language identifiers to Emacs mode stems.
Each entry is (ALIAS . MODE-STEM) where MODE-STEM is tried as
MODE-STEM-mode and MODE-STEM-ts-mode.")
(defun opencode-markdown--lang-mode (lang)
  "Return major mode function for LANG, or nil if not available.
Consults `opencode-markdown--lang-aliases' to resolve common
markdown language identifiers (elisp, bash, js, etc.) to their
corresponding Emacs major mode."
  (let* ((canonical (or (cdr (assoc (downcase lang)
                                    opencode-markdown--lang-aliases))
                        lang))
         (mode-name (intern (concat canonical "-mode")))
         (ts-mode-name (intern (concat canonical "-ts-mode"))))
    (cond
     ((fboundp mode-name) mode-name)
     ((fboundp ts-mode-name) ts-mode-name)
     (t nil))))

(defun opencode-markdown--syntax-highlight (code lang code-start)
  "Syntax-highlight CODE for LANG, copy faces to CODE-START.
Skips if CODE exceeds `opencode-markdown-max-code-block-lines'."
  (let ((mode (opencode-markdown--lang-mode lang)))
    (when (and mode
              ;; Skip expensive font-lock for very large code blocks
              (or (null opencode-markdown-max-code-block-lines)
                  (<= (cl-count ?\n code) opencode-markdown-max-code-block-lines)))
      (condition-case err
          (let ((props nil))
            (with-temp-buffer
              (insert code)
              (delay-mode-hooks (funcall mode))
              (font-lock-ensure)
              ;; Collect face properties
              (goto-char (point-min))
              (let ((pos (point-min)))
                (while (< pos (point-max))
                  (let ((face (get-text-property pos 'face))
                        (next (or (next-single-property-change pos 'face)
                                  (point-max))))
                    (when face
                      (push (list (+ code-start (1- pos))
                                  (+ code-start (1- next))
                                  face)
                            props))
                    (setq pos next)))))
            ;; Apply collected faces -- PREPEND (not append) so syntax
            ;; highlighting foreground takes priority over the base
            ;; opencode-assistant-body face which inherits default foreground.
            (dolist (prop props)
              (add-face-text-property (nth 0 prop) (nth 1 prop)
                                      (nth 2 prop))))
        (error (opencode--debug "opencode-markdown: syntax highlighting error: %S" err))))))

;;; --- Internal: Fenced Code Blocks ---

(defun opencode-markdown--fontify-code-blocks (start end)
  "Fontify fenced code blocks in region START to END.
Returns list of (BLOCK-START . BLOCK-END) ranges for exclusion.
Each line has a leading space from the renderer, so fences
appear as ` ```lang' and ` ```'."
  (let ((ranges nil)
        (count 0))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "^ ```\\(\\w*\\)$" end t)
        (let ((fence-open-start (match-beginning 0))
              (fence-open-end (1+ (match-end 0)))  ; include newline
              (lang (match-string 1)))
          ;; Find matching closing fence
          (when (re-search-forward "^ ```$" end t)
            (let* ((fence-close-start (match-beginning 0))
                   (fence-close-end (min (1+ (match-end 0)) end))
                   (code-start fence-open-end)
                   (code-end fence-close-start))
              ;; Record range for exclusion
              (push (cons fence-open-start fence-close-end) ranges)
              ;; Background face on entire block (including fences)
              (add-face-text-property fence-open-start fence-close-end
                                      'opencode-md-code-block )
              ;; Fence line faces and invisibility
              (add-face-text-property fence-open-start fence-open-end
                                      'opencode-md-code-block-header )
              (put-text-property fence-open-start fence-open-end
                                 'invisible 'opencode-md)
              (add-face-text-property fence-close-start fence-close-end
                                      'opencode-md-code-block-header )
              (put-text-property fence-close-start fence-close-end
                                 'invisible 'opencode-md)
              ;; Syntax highlighting if language present and under limit
              (setq count (1+ count))
              (when (and (length> lang 0)
                         (<= count opencode-markdown-max-fontified-code-blocks)
                         (< code-start code-end))
                (opencode-markdown--syntax-highlight
                 (buffer-substring-no-properties code-start code-end)
                 lang code-start)))))))
    (nreverse ranges)))

;;; --- Internal: Region Exclusion Helpers ---

(defun opencode-markdown--safe-regions (start end exclude-ranges)
  "Return list of (START . END) regions in START..END not in EXCLUDE-RANGES.
EXCLUDE-RANGES is a list of (BEG . FIN) cons cells to skip."
  (let ((regions nil)
        (pos start))
    (dolist (range (sort (copy-sequence exclude-ranges)
                         (lambda (a b) (< (car a) (car b)))))
      (when (< pos (car range))
        (push (cons pos (car range)) regions))
      (setq pos (max pos (cdr range))))
    (when (< pos end)
      (push (cons pos end) regions))
    (nreverse regions)))

(defun opencode-markdown--fontify-inline (start end exclude-ranges)
  "Run inline fontification on START to END, skipping EXCLUDE-RANGES.
EXCLUDE-RANGES is a list of (BEG . FIN) cons cells for code blocks."
  (let ((regions (opencode-markdown--safe-regions start end exclude-ranges)))
    (dolist (region regions)
      (let ((rstart (car region))
            (rend (cdr region)))
        (opencode-markdown--fontify-bold-italic rstart rend)
        (opencode-markdown--fontify-bold rstart rend)
        (opencode-markdown--fontify-italic rstart rend)
        (opencode-markdown--fontify-inline-code rstart rend)
        (opencode-markdown--fontify-headers rstart rend)
        (opencode-markdown--fontify-blockquotes rstart rend)
        (opencode-markdown--fontify-lists rstart rend)
        (opencode-markdown--fontify-hr rstart rend)))))

(defconst opencode-markdown--faces
  '(opencode-md-bold opencode-md-italic opencode-md-bold-italic
    opencode-md-inline-code opencode-md-header-1 opencode-md-header-2
    opencode-md-header-3 opencode-md-header-4 opencode-md-blockquote
    opencode-md-list-marker opencode-md-hr opencode-md-marker
    opencode-md-code-block opencode-md-code-block-header)
  "All faces applied by markdown fontification.")

(defun opencode-markdown--strip-faces (start end)
  "Remove markdown faces from START..END for idempotent re-fontification.
Preserves base faces (e.g. `opencode-assistant-body') set during insertion.
Also removes `invisible' property with value `opencode-md'."
  (let ((pos start))
    (while (< pos end)
      (let* ((face-val (get-text-property pos 'face))
             (next (or (next-single-property-change pos 'face nil end) end)))
        (when face-val
          (let* ((face-list (if (listp face-val) (copy-sequence face-val) (list face-val)))
                 (clean (seq-remove (lambda (f) (memq f opencode-markdown--faces))
                                    face-list)))
            (cond
             ((null clean)
              (remove-text-properties pos next '(face nil)))
             ((equal clean (ensure-list face-val))
              nil)  ; unchanged, skip
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

;;; --- Public API ---

(defun opencode-markdown-fontify-region (start end)
  "Fontify markdown elements in region START to END.
Idempotent: strips any previously-applied markdown faces before
re-applying, so calling this multiple times on the same region
does not cause face accumulation (e.g. compounding :height).
Processes fenced code blocks first (with syntax highlighting),
then inline markdown on non-code-block regions.
For regions exceeding `opencode-markdown-fontify-max-size' characters,
fontification is deferred to an idle timer to avoid blocking.
  code-blocks (first, returns exclusion ranges) ->
  bold-italic -> bold -> italic -> inline-code ->
  headers -> blockquotes -> lists -> horizontal rules."
  (when opencode-markdown-fontify-enabled
    (if (and opencode-markdown-fontify-max-size
             (> (- end start) opencode-markdown-fontify-max-size))
        ;; Defer large regions to idle timer
        (let ((buf (current-buffer))
              (s start)
              (e end))
          (run-with-idle-timer
           0.2 nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (opencode-markdown--fontify-region-impl s e))))))
      (opencode-markdown--fontify-region-impl start end))))

(defun opencode-markdown--fontify-region-impl (start end)
  "Internal: synchronously fontify markdown in region START to END."
  (condition-case err
      (let ((inhibit-read-only t))
        (save-excursion
          (save-match-data
            ;; Strip existing markdown faces first (idempotency)
            (opencode-markdown--strip-faces start end)
            ;; Code blocks first --- returns list of (start . end) ranges to exclude
            (let ((code-ranges (opencode-markdown--fontify-code-blocks start end)))
              ;; Inline fontification on non-code-block regions
              (opencode-markdown--fontify-inline start end code-ranges)))))
    (error
     (message "opencode-markdown: fontification error: %S" err))))

(provide 'opencode-markdown)
;;; opencode-markdown.el ends here
