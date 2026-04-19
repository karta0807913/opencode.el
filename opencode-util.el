;;; opencode-util.el --- Shared utility functions for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; Author: opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Common utility functions shared across opencode.el modules.
;; Provides time formatting, file status mapping, diff statistics,
;; and right-aligned insertion helpers.

;;; Code:

(require 'opencode-faces)
(require 'json)
(require 'subr-x)

;;; --- Time formatting ---

(defun opencode--normalize-timestamp (ts)
  "Normalize timestamp TS to seconds.
Millisecond timestamps (> 1e12) are divided by 1000.
Returns a float, or nil for non-number input."
  (when (numberp ts)
    (if (> ts 1e12) (/ ts 1000.0) (float ts))))


(defun opencode--time-ago (timestamp &optional short)
  "Return a human-readable relative time string for TIMESTAMP.
TIMESTAMP is a number representing seconds or milliseconds since epoch.
Millisecond timestamps (> 1e12) are automatically converted.

When SHORT is nil, return verbose format:
  \"just now\", \"5 min ago\", \"2 hours ago\", \"3 days ago\".
When SHORT is non-nil, return compact format:
  \"now\", \"5m\", \"2h\", \"3d\", \"1w\".

Return \"\" for non-number input."
  (if (not (numberp timestamp))
      ""
    (let* ((secs (opencode--normalize-timestamp timestamp))
           (delta (- (float-time) secs)))
      (if short
          (cond
           ((< delta 60)     "now")
           ((< delta 3600)   (format "%dm" (floor (/ delta 60))))
           ((< delta 86400)  (format "%dh" (floor (/ delta 3600))))
           ((< delta 604800) (format "%dd" (floor (/ delta 86400))))
           (t                (format "%dw" (floor (/ delta 604800)))))
        (cond
         ((< delta 60)    "just now")
         ((< delta 3600)  (format "%d min ago" (/ delta 60)))
         ((< delta 86400) (format "%d hours ago" (/ delta 3600)))
         (t               (format "%d days ago" (/ delta 86400))))))))

;;; --- Debounced timers ---

(defun opencode--debounce (timer-ref delay fn &optional idle)
  "Cancel any pending timer in TIMER-REF, schedule FN to run after DELAY.
TIMER-REF is either a symbol naming a dynamic variable, or a cons
\(GETTER . SETTER) of zero-arg and one-arg functions for accessing a
storage location (e.g. a struct slot) that cannot be named as a plain
variable.  If IDLE is non-nil, use `run-with-idle-timer' instead of
`run-with-timer'.  FN runs in the originating buffer if it is still
alive when the timer fires.  Used across modules (chat refresh,
sidebar rerender, streaming fontify) to coalesce bursts of SSE events
into a single deferred action."
  (let* ((cons-ref (consp timer-ref))
         (getter (if cons-ref (car timer-ref) (lambda () (symbol-value timer-ref))))
         (setter (if cons-ref (cdr timer-ref) (lambda (v) (set timer-ref v))))
         (current (funcall getter)))
    (when (timerp current)
      (cancel-timer current))
    (let ((buf (current-buffer)))
      (funcall setter
               (funcall (if idle #'run-with-idle-timer #'run-with-timer)
                        delay nil
                        (lambda ()
                          (when (buffer-live-p buf)
                            (with-current-buffer buf
                              (funcall setter nil)
                              (funcall fn)))))))))

;;; --- File status ---

(defun opencode--file-status-char (status)
  "Return a single-character string for file STATUS.
Maps: \"modified\"->\"M\", \"added\"->\"A\", \"deleted\"->\"D\",
\"renamed\"->\"R\", anything else->\"?\"."
  (pcase status
    ("modified" "M")
    ("added"    "A")
    ("deleted"  "D")
    ("renamed"  "R")
    (_          "?")))

;;; --- Diff statistics ---

(defun opencode--format-diff-stats (additions deletions &optional files)
  "Format diff statistics as a string.
ADDITIONS and DELETIONS are integers.
When FILES is provided and > 0, append file count.
Returns \"+N -N\" or \"+N -N  N files\"."
  (let ((base (format "+%d -%d" additions deletions)))
    (if (and files (> files 0))
        (format "%s  %d files" base files)
      base)))

;;; --- Right-aligned insertion ---

(defun opencode-ui--insert-right-align (min-col)
  "Insert spaces to right-align subsequent text at MIN-COL.
Always inserts at least 2 spaces from the current column."
  (let ((target (max (+ (current-column) 2) min-col)))
    (insert (make-string (max 1 (- target (current-column))) ?\s))))

;;; --- ID generation ---

(defun opencode-util--random-string (length)
  "Generate a random string of LENGTH characters (base62)."
  (let ((chars "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        (str (make-string length 0)))
    (dotimes (i length)
      (aset str i (aref chars (random 62))))
    str))

(defvar opencode-util--id-counter 0
  "Counter for ID generation within the same millisecond.")

(defvar opencode-util--id-last-ms 0
  "Last millisecond timestamp used for ID generation.")

(defun opencode-util--generate-id (&optional prefix)
  "Generate a unique ID string matching OpenCode server format.
PREFIX is an optional string to prepend (e.g. \"msg\", \"prt\").
Format: PREFIX_<12 hex timestamp><14 base62 random> = 30 chars total.

The server rejects messages with IDs older than the latest message.
The hex portion must always be incrementing. We use (ms * 4096 + counter)
to ensure strict ordering even for rapid-fire ID generation."
  (let* ((ms (floor (* (float-time) 1000))))
    ;; Reset or increment counter based on millisecond
    (if (= ms opencode-util--id-last-ms)
        (setq opencode-util--id-counter (1+ opencode-util--id-counter))
      (setq opencode-util--id-last-ms ms
            opencode-util--id-counter 0))
    (let* ((timestamp-val (logand (+ (* ms 4096) opencode-util--id-counter)
                                  #xFFFFFFFFFFFF))
           (time-hex (format "%012x" timestamp-val))
           (random-suffix (opencode-util--random-string 14)))
      (if prefix
          (format "%s_%s%s" prefix time-hex random-suffix)
        (format "%s%s" time-hex random-suffix)))))


;;; --- JSON parsing ---

(defun opencode--json-parse (string)
  "Parse JSON STRING with standard opencode settings.
Uses plist objects, array types, nil for null, :false for false."
  (json-parse-string string
                     :object-type 'plist
                     :array-type 'array
                     :null-object nil
                     :false-object :false))

(defun opencode-util--json-serialize (object)
  "Serialize OBJECT to JSON string with standard opencode settings.
Uses :false for false."
  (json-serialize object
                  :null-object nil
                  :false-object :false))


;;; --- Diff rendering ---


(defun opencode-diff--line-face (line &optional default-face)
  "Return face for diff LINE based on prefix character.
Falls back to DEFAULT-FACE if LINE doesn't match any diff prefix."
  (cond
   ((string-prefix-p "+" line) 'opencode-diff-added)
   ((string-prefix-p "-" line) 'opencode-diff-removed)
   ((string-prefix-p "@@" line) 'opencode-diff-hunk-header)
   (t default-face)))

(defun opencode--insert-diff-lines (text indent &optional default-face skip-empty)
  "Insert each line of diff TEXT with INDENT prefix and syntax-colored face.
DEFAULT-FACE is the fallback face (default: font-lock-comment-face).
When SKIP-EMPTY is non-nil, skip empty lines.
Always skips unified diff file headers (--- and +++ lines)."
  (dolist (line (string-lines text))
    (unless (or (string-prefix-p "---" line)
                (string-prefix-p "+++" line)
                (and skip-empty (string-empty-p line)))
      (let ((face (opencode-diff--line-face line (or default-face 'font-lock-comment-face))))
        (insert (propertize (format "%s%s\n" indent line) 'face face))))))

(defun opencode--insert-prefixed-lines (text indent prefix face)
  "Insert each line of TEXT with INDENT, PREFIX string, and FACE."
  (dolist (line (string-lines text))
    (insert (propertize (format "%s%s%s\n" indent prefix line) 'face face))))

;;; --- String truncation ---

(defun opencode--truncate-string (str max-len)
  "Truncate STR to MAX-LEN characters with ellipsis if needed.
Uses Emacs built-in `truncate-string-to-width' with \"…\" ellipsis.
Returns STR unchanged if it fits within MAX-LEN."
  (if (and (stringp str) (> (length str) max-len))
      (truncate-string-to-width str max-len nil nil "…")
    (or str "")))

;;; --- Path shortening ---

(defun opencode--shorten-path (path)
  "Shorten PATH for display by extracting the filename or last directory.
Returns the non-directory part of PATH, handling both files and directories.
Returns PATH unchanged if it's nil, empty, or has no directory component."
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((name (file-name-nondirectory (directory-file-name path))))
      (if (string-empty-p name) path name))))

;;; --- Duration formatting ---

(defun opencode--format-duration (seconds)
  "Format SECONDS as a human-readable duration string.
Uses Emacs built-in `format-seconds' with compact format.
Returns \"Xh Ym Zs\", \"Ym Zs\", or \"Zs\" depending on magnitude.
Returns nil for non-positive SECONDS."
  (when (and (numberp seconds) (> seconds 0))
    (let ((secs (round seconds)))
      (cond
       ((>= secs 3600) (format-seconds "%hh%mm%ss" secs))
       ((>= secs 60)   (format-seconds "%mm%ss" secs))
       (t              (format-seconds "%ss" secs))))))

(defun opencode--format-duration-from-timestamps (start end)
  "Format duration between START and END timestamps.
Both timestamps can be in seconds or milliseconds (auto-detected).
Returns a formatted duration string, or nil if invalid."
  (when (and (numberp start) (numberp end) (> end start))
    (let* ((start-secs (opencode--normalize-timestamp start))
           (end-secs (opencode--normalize-timestamp end)))
      (opencode--format-duration (- end-secs start-secs)))))

;;; --- MIME type handling ---

(defun opencode--mime-to-extension (mime)
  "Return file extension for MIME type string.
Uses Emacs built-in `mailcap-mime-type-to-extension'.
Returns \"bin\" for unknown MIME types."
  (require 'mailcap)
  (or (mailcap-mime-type-to-extension mime) "bin"))

(defun opencode--image-filename (mime)
  "Return a suggested filename for an image with MIME type.
Uses `opencode--mime-to-extension' to determine the extension."
  (format "clipboard-image.%s" (opencode--mime-to-extension mime)))

;;; --- Data URL encoding ---

(defun opencode--image-to-data-url (data mime &optional max-size)
  "Encode image DATA to a base64 data URL string.
DATA is a unibyte string containing the raw image bytes.
MIME is the MIME type string (e.g. \"image/png\").
MAX-SIZE, if non-nil, is the maximum allowed size in bytes.
Signals `user-error' if DATA exceeds MAX-SIZE."
  (when (and max-size (> (length data) max-size))
    (user-error "Image too large: %s (max %s)"
                (file-size-human-readable (length data))
                (file-size-human-readable max-size)))
  (concat "data:" mime ";base64," (base64-encode-string data t)))

;;; --- UI constants ---

(defconst opencode--stripe-char "\u258E"
  "Left block stripe character (▎) used for message borders.")

(provide 'opencode-util)

;;; opencode-util.el ends here
