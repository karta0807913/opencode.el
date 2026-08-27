;;; opencode-chat-message.el --- Message store and renderer for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; DB-like message store with CRUD operations keyed by message-id.
;; Owns all message-level state: rendering, streaming, part tracking,
;; diff caching.  Exposes a public API for chat.el's SSE router.
;; Does NOT know about SSE events, sessions, or input areas.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'opencode-faces)
(require 'opencode-ui)
(require 'opencode-markdown)
(require 'opencode-log)
(require 'opencode-util)
(require 'opencode-backend-core)
(require 'opencode-diff)
(require 'opencode-agent)
(require 'opencode-chat-state)
(require 'opencode-domain)
(require 'opencode-todo)
(require 'opencode-tool-render)
(require 'color)

;; Keymap defined in chat.el, used by apply-message-props
(defvar opencode-chat-message-map)
;; Defcustom defined in chat.el

;;; --- File path keymap (for edit tool sections) ---

(defun opencode-chat-message--find-unique-line-sequence (lines needle)
  "Return the zero-based start of unique NEEDLE in LINES, or nil."
  (when needle
    (let ((limit (- (length lines) (length needle)))
          (index 0)
          found)
      (while (<= index limit)
        (when (equal needle
                     (seq-subseq lines index (+ index (length needle))))
          (if found
              (setq found :multiple
                    index (1+ limit))
            (setq found index)))
        (cl-incf index))
      (and (integerp found) found))))

(defun opencode-chat-message--apply-patch-file-lines (path)
  "Return current contents of PATH as lines, preferring a visiting buffer."
  (when path
    (let ((buffer (find-buffer-visiting path)))
      (cond
       ((buffer-live-p buffer)
        (with-current-buffer buffer
          (string-lines
           (buffer-substring-no-properties (point-min) (point-max)))))
       ((file-readable-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (string-lines (buffer-string))))))))

(defun opencode-chat-message--apply-patch-line (path metadata)
  "Resolve an apply_patch line in PATH from deterministic METADATA.
Prefer the post-image for an already-applied patch, then the pre-image
for a patch that is not yet applied.  Ambiguous or missing images return
nil rather than choosing an arbitrary match."
  (let ((operation (plist-get metadata :operation))
        (pre-image (plist-get metadata :pre-image))
        (post-image (plist-get metadata :post-image))
        (pre-offset (plist-get metadata :pre-offset))
        (post-offset (plist-get metadata :post-offset)))
    (cond
     ((and (eq operation 'add) (integerp post-offset))
      (1+ post-offset))
     ((when-let* ((lines (opencode-chat-message--apply-patch-file-lines path))
                  (start
                   (opencode-chat-message--find-unique-line-sequence
                    lines post-image))
                  ((integerp post-offset)))
        (+ start post-offset 1)))
     ((when-let* ((lines (opencode-chat-message--apply-patch-file-lines path))
                  (start
                   (opencode-chat-message--find-unique-line-sequence
                    lines pre-image))
                  ((integerp pre-offset)))
        (+ start pre-offset 1))))))

(defun opencode-chat-message--estimate-line-number (&optional path)
  "Estimate the file line number at point from diff context.
Searches backward for an @@ hunk header and counts lines forward.
For apply_patch, resolve deterministic hunk metadata against PATH only
when the user navigates, so transcript rendering never depends on the
current workspace.
Returns a line number or nil."
  (let ((metadata
         (get-text-property (point) 'opencode-apply-patch-line)))
    (if metadata
        ;; Do not fall back to a raw @@ range when deterministic apply_patch
        ;; context is present but no longer matches the workspace.  Historical
        ;; ranges may be stale; opening without a line is safer.
        (opencode-chat-message--apply-patch-line path metadata)
      (save-excursion
        (let ((target-pos (point))
              (hunk-line nil))
          ;; Search backward for @@ -N,M +L,K @@
          (when (re-search-backward "@@ [^@]+ \\+\\([0-9]+\\)" nil t)
            (setq hunk-line (string-to-number (match-string 1)))
            ;; Count forward from hunk header to target, tracking new-file lines
            (forward-line 1)
            (let ((offset 0))
              (while (< (point) target-pos)
                (let ((ch (char-after)))
                  (when (and ch (not (= ch ?-)))
                    ;; Context lines and + lines advance the new-file line counter
                    (cl-incf offset)))
                (forward-line 1))
              (+ hunk-line offset))))))))

(defun opencode-chat-message-open-file-at-point ()
  "Open the file at point, using `opencode-file-path' text property.
If the file is already displayed in a window, switch to that window.
Estimates the line number from surrounding diff hunk context."
  (interactive)
  (let* ((path (get-text-property (point) 'opencode-file-path))
         (abs-path (and path (expand-file-name path)))
         (line (opencode-chat-message--estimate-line-number abs-path)))
    (if path
        (if (file-exists-p abs-path)
            (let ((existing-buf (find-buffer-visiting abs-path)))
              (if-let ((win (and existing-buf
                                 (get-buffer-window existing-buf t))))
                  ;; File already visible — switch to that window
                  (progn
                    (select-window win)
                    (when line (goto-char (point-min)) (forward-line (1- line))))
                ;; Open in other window
                (find-file-other-window abs-path)
                (when line (goto-char (point-min)) (forward-line (1- line)))))
          (user-error "File not found: %s" abs-path))
      (user-error "No file at point"))))

(defvar opencode-chat-message-file-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'opencode-chat-message-open-file-at-point)
    (define-key map (kbd "o") #'opencode-chat-message-open-file-at-point)
    map)
  "Keymap for clickable file paths in chat messages.
Used as the `keymap' text property on edit tool body regions so that
RET/o opens the edited file.  `opencode-chat--apply-message-props'
knows not to overwrite existing `keymap' properties, so this map is
preserved across re-renders without needing a parent-chain trick.")

(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))

;;; --- Internal state ---

;; `--store', `--diff-cache', `--diff-shown' all live in the
;; `opencode-chat-state' struct; the defvar-locals here were removed in
;; the Step 5 struct migration (2026-04-18).  Access them through
;; (opencode-chat--store), (opencode-chat--diff-cache),
;; (opencode-chat--diff-shown) — readers — and `opencode-chat--set-store'
;; / `--set-diff-cache' / `--set-diff-shown' — writers.

;; The two slots formerly declared here — current-message-id and
;; messages-end — now live in the `opencode-chat-state' struct.  Reads
;; go through the generated `opencode-chat--SLOT' functions, writes
;; through `opencode-chat--set-SLOT'.

;; Tool renderer registries, `opencode-chat-set-tool-renderer',
;; `opencode-chat-remove-tool-renderer',
;; tool input-summary helpers, and all built-in body renderers (bash,
;; read/write, grep/glob, task, edit, todowrite) have moved to
;; `opencode-tool-render.el'.  Dispatch goes through
;; `opencode-chat--tool-render-model'.

;;; --- Store accessors ---

(defun opencode-chat-message-sorted-ids ()
  "Return store message IDs sorted ascending (oldest first).
Message IDs are lexicographically ascending by creation time."
  (sort (hash-table-keys (opencode-chat--store)) #'string<))

(defun opencode-chat-message-info (msg-id)
  "Return the info plist for MSG-ID from the store, or nil.
The info plist contains :role, :agent, :modelID, :providerID, :tokens, etc."
  (when-let* ((entry (gethash msg-id (opencode-chat--store)))
              (msg (plist-get entry :msg)))
    (plist-get msg :info)))

(defun opencode-chat-message-parts (msg-id)
  "Return the raw API parts vector/list for MSG-ID, or nil.
Returns the exact parts structure from the message as delivered by
the /session/:id/message API, so callers can iterate it with
`seq-doseq' and access `:type', `:text', etc. without reaching into
the store internals.  Distinct from the store's per-part-id hash —
this is the input to rendering, not the rendered parts' range overlays."
  (when-let* ((entry (gethash msg-id (opencode-chat--store)))
              (msg (plist-get entry :msg)))
    (plist-get msg :parts)))

;;; --- Store accessors (private) ---

(defun opencode-chat--store-get (msg-id)
  "Return store entry plist for MSG-ID, or nil."
  (gethash msg-id (opencode-chat--store)))

(defun opencode-chat--store-ensure (msg-id)
  "Return store entry for MSG-ID, creating if needed."
  (or (gethash msg-id (opencode-chat--store))
      (let ((entry (list :parts (make-hash-table :test 'equal)
                         :overlay nil
                         :state nil)))
        (puthash msg-id entry (opencode-chat--store))
        entry)))

(defun opencode-chat--store-part-overlay (msg-id part-id)
  "Return the range overlay for PART-ID in MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-get info :range-overlay)))

(defun opencode-chat--store-part-section-overlay (msg-id part-id)
  "Return the cached UI section overlay for PART-ID in MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-get info :overlay)))

(defun opencode-chat--store-part-type (msg-id part-id)
  "Return the type string for PART-ID in MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-get info :type)))

(defun opencode-chat--store-set-part (msg-id part-id type range-overlay)
  "Register PART-ID under MSG-ID with TYPE and RANGE-OVERLAY.
Deletes any previous range overlay for this part while preserving its
cached UI section overlay."
  (let* ((entry (opencode-chat--store-ensure msg-id))
         (parts (plist-get entry :parts))
         (old (gethash part-id parts))
         (section-overlay (and old (plist-get old :overlay))))
    (when-let* ((old-range (and old (plist-get old :range-overlay))))
      (when (overlayp old-range) (delete-overlay old-range)))
    (puthash part-id
             (list :type type
                   :range-overlay range-overlay
                   :overlay section-overlay)
             parts)))

(defun opencode-chat--section-overlay-at (pos id)
  "Return the section overlay beginning at POS whose section id is ID."
  (seq-find
   (lambda (ov)
     (when-let* ((section (overlay-get ov 'opencode-section)))
       (and (= (overlay-start ov) pos)
            (equal (plist-get section :id) id))))
   (overlays-at pos)))

(defun opencode-chat--store-cache-part-section (msg-id part-id pos)
  "Cache PART-ID's UI section overlay beginning at POS, when present."
  (when-let* ((section (opencode-chat--section-overlay-at pos part-id))
              (entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-put info :overlay section)
    section))

(defun opencode-chat--store-find-overlay (id)
  "Return the section overlay whose :id matches ID.
Checks the store first (message :overlay or part :overlay).
Falls back to buffer scan and caches the result."
  (or
   ;; Check store: message-level overlay
   (when-let* ((entry (opencode-chat--store-get id))
               (ov (plist-get entry :overlay))
               ((overlay-buffer ov)))
     ov)
   ;; Check store: part-level overlay
   (catch 'found
     (maphash (lambda (_mid e)
                (when-let* ((parts (plist-get e :parts))
                            (pinfo (gethash id parts))
                            (ov (plist-get pinfo :overlay))
                            ((overlay-buffer ov)))
                  (throw 'found ov)))
              (opencode-chat--store))
     nil)
   ;; Fallback: buffer scan.  Reaching here means the store and the buffer
   ;; disagree --- the section exists on screen but the store does not know
   ;; its overlay.  The scan repairs that silently, which is why the desync
   ;; has never been diagnosed; log it so the underlying cause is visible.
   (let ((found nil))
     (dolist (ov (overlays-in (point-min) (point-max)))
       (let ((sec (overlay-get ov 'opencode-section)))
         (when (and sec (equal (plist-get sec :id) id))
           (setq found ov))))
     (when found
       (opencode--debug
        "opencode-chat: store/buffer desync --- overlay for %s found only by buffer scan"
        id))
     ;; Cache result in store
     (when found
       (let ((entry (opencode-chat--store-get id)))
         (if entry
             (plist-put entry :overlay found)
           (maphash (lambda (_mid e)
                      (when-let* ((parts (plist-get e :parts))
                                  (pinfo (gethash id parts)))
                        (plist-put pinfo :overlay found)))
                    (opencode-chat--store)))))
     found)))

(defun opencode-chat--store-clear ()
  "Delete all stored overlays and clear the store."
  (maphash (lambda (_msg-id entry)
             (when-let* ((ov (plist-get entry :overlay)))
               (when (overlayp ov) (delete-overlay ov)))
             (when-let* ((parts (plist-get entry :parts)))
                (maphash (lambda (_part-id info)
                           (when-let* ((range (plist-get info :range-overlay)))
                             (when (overlayp range) (delete-overlay range)))
                           (when-let* ((ov (plist-get info :overlay)))
                             (when (overlayp ov) (delete-overlay ov))))
                         parts)))
           (opencode-chat--store))
  (clrhash (opencode-chat--store)))

;;; --- Helpers ---

(defun opencode-chat--format-time (info)
  "Format the creation time from message INFO."
  (let* ((time-data (plist-get info :time))
         (created (or (and time-data (plist-get time-data :created))
                      (plist-get info :createdAt))))
    (if (numberp created)
        (format-time-string "%H:%M:%S"
                            (seconds-to-time
                             (opencode--normalize-timestamp created)))
      "")))

(defun opencode-chat--format-duration (info)
  "Format the duration from message INFO as e.g. \"1m2s\" or \"5s\".
Returns nil if timestamps are not available.
Uses `opencode--format-duration-from-timestamps' from opencode-util."
  (let* ((time-data (plist-get info :time))
         (created (and time-data (plist-get time-data :created)))
         (completed (and time-data (plist-get time-data :completed))))
    (opencode--format-duration-from-timestamps created completed)))

(defmacro opencode-chat--maybe-in-chat (state &rest body)
  "Run BODY in STATE's buffer when STATE is non-nil, otherwise here.
Lets a primitive take an optional state without every caller that
already arranged the buffer paying for a redundant switch."
  (declare (indent 1) (debug t))
  (let ((s (make-symbol "state")))
    `(let ((,s ,state))
       (if ,s
           (opencode-chat--with-chat ,s ,@body)
         (progn ,@body)))))

(defmacro opencode-chat--with-chat (state &rest body)
  "Run BODY in the buffer STATE describes, with STATE as its chat state.
Signals if STATE has no live buffer.

This is the entry point for code that holds a chat state and wants to
act on it.  Every accessor and section primitive below assumes the right
buffer is current; without this, each caller arranged that itself with
`with-current-buffer' and a buffer it had looked up separately, which is
how buffer and state came to be tracked in two places."
  (declare (indent 1) (debug t))
  (let ((s (make-symbol "state"))
        (buf (make-symbol "buffer")))
    `(let* ((,s ,state)
            (,buf (and ,s (opencode-chat-state-buffer ,s))))
       (unless (buffer-live-p ,buf)
         (error "Chat state has no live buffer"))
       (with-current-buffer ,buf ,@body))))

(defvar opencode-chat--transcript-depth 0
  "Non-zero while a transcript mutation is in progress.
Only the outermost `opencode-chat--in-transcript' repairs the undo
list; an inner one would shift the same edit twice.")

(defun opencode-chat--shift-undo-entry (elt delta)
  "Return undo entry ELT with its buffer positions moved by DELTA.
Throws `opencode-chat--undo-unshiftable' for shapes whose positions
cannot be located --- notably `apply' entries, which bury them in
arbitrary function arguments."
  (cond
   ;; Boundaries, first-change markers and marker adjustments hold no
   ;; position we own: markers are adjusted by the insertion itself.
   ((null elt) elt)
   ((eq (car-safe elt) t) elt)
   ((markerp (car-safe elt)) elt)
   ((integerp elt) (+ elt delta))
   ;; (BEG . END) — text was inserted there.
   ((and (consp elt) (integerp (car elt)) (integerp (cdr elt)))
    (cons (+ (car elt) delta) (+ (cdr elt) delta)))
   ;; (TEXT . POS) — text was deleted there; a negative POS records that
   ;; point was at the end of the deletion, so the sign must survive.
   ((and (consp elt) (stringp (car elt)) (integerp (cdr elt)))
    (cons (car elt)
          (if (< (cdr elt) 0) (- (cdr elt) delta) (+ (cdr elt) delta))))
   ;; (nil PROPERTY VALUE BEG . END) — a text property changed.
   ((and (consp elt) (null (car elt)))
    (let ((bounds (nthcdr 3 elt)))
      (unless (and (consp bounds)
                   (integerp (car bounds))
                   (integerp (cdr bounds)))
        (throw 'opencode-chat--undo-unshiftable 'discard))
      (cl-list* nil (nth 1 elt) (nth 2 elt)
                (cons (+ (car bounds) delta) (+ (cdr bounds) delta)))))
   (t (throw 'opencode-chat--undo-unshiftable 'discard))))

(defun opencode-chat--shift-undo-list (delta)
  "Move every position recorded in `buffer-undo-list' by DELTA.

Transcript redraws are kept out of the undo list because they are not
user edits.  That leaves the entries already recorded for the input area
holding absolute positions that Emacs will not adjust --- it adjusts
markers, not undo entries, and it only keeps undo positions consistent
because normally every edit is recorded.  So an insertion above the
input area leaves each recorded position DELTA characters too early, and
the next `undo' rewrites whatever transcript now sits there.

The shift is exact rather than approximate: every transcript edit is
strictly before `input-start' and every recorded edit strictly after it,
so all recorded positions move by the same amount.

The list is rewritten through its existing cons cells rather than
rebuilt.  Those cells are identity-significant: `pending-undo-list' is a
tail of this list and `undo-equiv-table' is keyed by tails, so a fresh
list from `mapcar' would strand an undo already in progress on the old,
unshifted cells and drop every redo record with it.  Mutating in place
means an undo chain and its redo history simply keep working, and
nothing global --- `last-command', `pending-undo-list' --- has to be
cleared from what is usually a process filter running while the user is
editing some other buffer.

An entry that cannot be rewritten takes the whole history with it: an
undo list pointing at the wrong text is worse than no undo list.  The
validation pass runs first so a rejected entry cannot leave the list
half-shifted."
  (when (and (/= delta 0) (consp buffer-undo-list))
    (if (eq t
            (catch 'opencode-chat--undo-unshiftable
              (let ((cell buffer-undo-list))
                (while (consp cell)
                  (opencode-chat--shift-undo-entry (car cell) delta)
                  (setq cell (cdr cell))))
              t))
        (let ((cell buffer-undo-list))
          (while (consp cell)
            (setcar cell (opencode-chat--shift-undo-entry (car cell) delta))
            (setq cell (cdr cell))))
      (setq buffer-undo-list nil))))

(defmacro opencode-chat--in-transcript (&rest body)
  "Run BODY as a mutation of the rendered transcript.

Binds the two things every mutation site needs and several were setting
by hand: `inhibit-read-only', because the transcript carries a
`read-only' text property, and `buffer-undo-list' to t, because redraws
are not user edits and must not consume the undo history of the input
area, which shares this buffer.  Point is restored.

Excluding the redraw from the undo list is only half of it: the entries
already in the list are absolute positions that the redraw silently
invalidates, so the outermost mutation repairs them through
`opencode-chat--shift-undo-list'.  That repair is an unwind form, not a
trailing one --- a renderer that mutates and then signals would
otherwise leave exactly the corruption this exists to prevent.

Mutating the transcript from anywhere else is a bug: the input area,
prompt and footer live in the same buffer below `messages-end', so an
unguarded `delete-region' can eat what the user is typing."
  (declare (indent 0) (debug t))
  (let ((size (make-symbol "size")))
    `(let ((,size (buffer-size)))
       (unwind-protect
           (let ((inhibit-read-only t)
                 (buffer-undo-list t)
                 (opencode-chat--transcript-depth
                  (1+ opencode-chat--transcript-depth)))
             (save-excursion ,@body))
         ;; Runs after the bindings above unwind, so the shift sees the
         ;; buffer's real undo list and the restored nesting depth.
         (when (zerop opencode-chat--transcript-depth)
           (opencode-chat--shift-undo-list (- (buffer-size) ,size)))))))

(defun opencode-chat--insert-section (pos render &optional state)
  "Draw a new section at POS by calling RENDER.  Return the position past it.
STATE, when given, names the chat to draw into; it defaults to the
current buffer's.

Starts the section on a line of its own.  A section beginning mid-line
would glue onto whatever preceded it, and its first line would render
without the gutter its `line-prefix' assumes."
  (opencode-chat--maybe-in-chat state
    (opencode-chat--in-transcript
      (goto-char pos)
      (unless (bolp) (insert "\n"))
      (let ((start (point)))
        (funcall render)
        (when (> (point) start)
          (opencode-chat--apply-message-props start (point)))
        (point)))))

(defun opencode-chat--render-part-by-type (part part-type msg-id)
  "Draw PART of PART-TYPE belonging to MSG-ID at point."
  (pcase part-type
    ("tool"        (opencode-chat--render-tool-part part))
    ("step-start"  (opencode-chat--render-step-start part))
    ("step-finish" (opencode-chat--render-step-finish part))
    ("subtask"     (opencode-chat--render-subtask-part
                    part (or (opencode-chat--msg-role msg-id) 'user)))))

(defun opencode-chat--part-range-overlay (start end part-id)
  "Create PART-ID's data range overlay from START to END.
The front boundary advances and the rear boundary does not: text
inserted at START belongs to the preceding part, while text inserted at
END belongs to the following part unless this part explicitly extends
its own range."
  (let ((ov (make-overlay start end nil t nil)))
    (overlay-put ov 'opencode-part-id part-id)
    ov))

(defun opencode-chat--recache-part (msg-id part-id part-type start end)
  "Record PART-ID's range from START to END after an inline redraw.
The UI section overlay is looked up rather than passed in because the
renderer creates it, and which overlay covers the section is only
knowable once drawing is done."
  (when msg-id
    (opencode-chat--store-set-part
     msg-id part-id part-type
     (opencode-chat--part-range-overlay start end part-id))
    (opencode-chat--store-cache-part-section msg-id part-id start)))

(defun opencode-chat--replace-section (ov render &optional state)
  "Redraw the section spanned by overlay OV by calling RENDER.
STATE, when given, names the chat to act on; it defaults to the current
buffer's.
RENDER takes no arguments and draws the replacement with point at the
section start.  Returns the position just past the new text.

Sections that begin exactly where OV ended are moved to abut the new
text, so a replacement of a different length neither strands its
neighbour nor overlaps it.

Bounds are read from OV at call time rather than captured beforehand:
callers may delete other overlays first, and any deletion earlier in the
buffer shifts plain integer positions while the overlay tracks.  Asserts
the section stops short of the input area, as `--delete-section' does."
  (opencode-chat--maybe-in-chat state
   (let* ((start (overlay-start ov))
         (end (overlay-end ov))
         (limit (opencode-chat--input-start))
         (limit-pos (and (markerp limit) (marker-position limit)))
         (siblings (cl-loop for o in (overlays-at end)
                            when (and (overlay-get o 'opencode-section)
                                      (not (eq o ov))
                                      (= (overlay-start o) end))
                            collect o)))
    (cl-assert (or (null limit-pos) (null end) (<= end limit-pos)) t
               "section overlay extends into the input area")
    (delete-overlay ov)
    (opencode-chat--in-transcript
      (goto-char start)
      (delete-region start end)
      (funcall render)
      (when (> (point) start)
        (opencode-chat--apply-message-props start (point)))
      (dolist (o siblings)
        (when (overlay-buffer o)
          (move-overlay o (point) (overlay-end o))))
      (point)))))

(defun opencode-chat--delete-section (ov &optional state)
  "Delete the text spanned by section overlay OV, and OV itself.
STATE, when given, names the chat to act on; it defaults to the current
buffer's.

Asserts the section stops short of the input area.  The check is cheap
and the failure it catches is not: the input area shares this buffer, so
an overlay that has drifted into it would take the user's unsent text
with it.

The boundary is `input-start', not `messages-end'.  Status badges --- the
queued and retry indicators --- are deliberately inserted at
`messages-end' with insertion type nil, so they sit just past it and are
legitimately outside the transcript proper.  Covered by
`opencode-chat-delete-section-leaves-input-alone'."
  (opencode-chat--maybe-in-chat state
   (when (overlay-buffer ov)
    (let* ((start (overlay-start ov))
           (end (overlay-end ov))
           (limit (opencode-chat--input-start))
           (limit-pos (and (markerp limit) (marker-position limit))))
      (cl-assert (or (null limit-pos) (null end) (<= end limit-pos)) t
                 "section overlay extends into the input area")
      (opencode-chat--in-transcript
        (when (and start end (> end start))
          (delete-region start end))
        (delete-overlay ov))))))

(defun opencode-chat--emit (text face &optional prefix state)
  "Insert TEXT into the transcript faced with FACE.  Return (START . END).
PREFIX, when given, becomes the `line-prefix' over the inserted region.
STATE, when given, names the chat to insert into; it defaults to the
current buffer's.

The single write path for transcript content.  Every caller used to
decide independently how to propertize, whether to add a `line-prefix',
and whether the text needed a gutter -- which is why the one-column
prose gutter ended up duplicated across three render sites and a
`bolp' check in the streaming path, and had to be found by grep to
change.

FACE is also recorded in `opencode-base-face'.  Markdown fontification
composes faces on top of whatever the renderer set and has to strip them
again to stay idempotent; without a recorded base it could only tell the
two apart by keeping a hand-maintained list of the renderer's face
names.  Recording it makes that mechanical."
  (opencode-chat--maybe-in-chat state
    (let ((start (point)))
      (insert (propertize text 'face face 'opencode-base-face face))
      (when prefix
        (put-text-property start (point) 'line-prefix prefix))
      (cons start (point)))))

(defun opencode-chat--apply-message-props (start end &optional extra-props)
  "Apply standard message properties from START to END.
Sets `read-only' to t and `keymap' to `opencode-chat-message-map',
EXCEPT in sub-regions that already carry an `opencode-file-path' text
property — those regions keep their own keymap
\(`opencode-chat-message-file-map') so RET still opens the edited file.

If EXTRA-PROPS is provided, merge those properties as well.  EXTRA-PROPS
must not include `keymap' or `read-only' (callers should set those via
the dedicated mechanism).

The `opencode-file-path' opt-out is the single source of truth for
\"this region has its own keymap\".  Any new click-able sub-region must
set that property so this function knows to skip it."
  (let ((pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'opencode-file-path nil end)))
        (unless (get-text-property pos 'opencode-file-path)
          (put-text-property pos next 'keymap opencode-chat-message-map))
        (setq pos next))))
  (add-text-properties start end (append (or extra-props nil) '(read-only t))))

;;; --- Collapse state that outlives a redraw ---

(defun opencode-chat--record-collapse-override (section collapsed-p)
  "Remember that the user set SECTION to COLLAPSED-P.
Registered on `opencode-ui-section-toggled-functions'.  Keyed by section
id rather than by overlay, because the overlay is discarded every time
the section is redrawn --- which, for a tool, is once per status change."
  (when (and opencode-chat--state (plist-get section :id))
    (puthash (plist-get section :id) (and collapsed-p t)
             (opencode-chat--collapse-overrides))))

(add-hook 'opencode-ui-section-toggled-functions
          #'opencode-chat--record-collapse-override)

(defun opencode-chat--section-collapsed-p (id default)
  "Return whether the section identified by ID should render collapsed.
An explicit choice the user made with TAB wins over DEFAULT, which is
whatever the renderer considers a sensible starting state."
  (let ((table (and id opencode-chat--state
                    (opencode-chat--collapse-overrides))))
    (if (and table (not (eq (gethash id table :absent) :absent)))
        (gethash id table)
      default)))

(defun opencode-chat--apply-collapse-state (ov collapsed-p)
  "Collapse section overlay OV when COLLAPSED-P is non-nil."
  (when (and ov collapsed-p)
    (opencode-ui--collapse-section ov)))

(defun opencode-chat--agent-chip-face (color)
  "Return a face spec for an agent mention chip tinted with COLOR.
COLOR is a hex string (e.g. \"#34d399\").  Returns an anonymous face
plist with box, background, and foreground derived from COLOR.
Falls back to `opencode-mention-agent' if COLOR is nil."
  (if (not color)
      'opencode-mention-agent
    (let ((dark-p (eq (frame-parameter nil 'background-mode) 'dark)))
      (if dark-p
          `(:box (:line-width 1 :color ,color)
            :background ,(color-darken-name color 60)
            :foreground ,(color-lighten-name color 20)
            :weight bold)
        `(:box (:line-width 1 :color ,color)
          :background ,(color-lighten-name color 40)
          :foreground ,(color-darken-name color 30)
          :weight bold)))))

(defun opencode-chat--agent-badge-face (color)
  "Return a face spec for an agent badge tinted with COLOR.
COLOR is a hex string.  Falls back to `opencode-agent-badge' if nil."
  (if (not color)
      'opencode-agent-badge
    `(:foreground ,color :weight bold)))

;;; --- Message rendering ---

(defun opencode-chat--render-message (msg)
  "Render a single message MSG.
MSG is a plist from the API with :info and :parts."
  (let* ((info (plist-get msg :info))
         (parts (plist-get msg :parts))
         (role (plist-get info :role))
         (msg-id (plist-get info :id))
         (section (opencode-ui--make-section 'message msg-id info)))
    (opencode-chat--set-current-message-id msg-id)
    (insert "\n")
    (let ((ov (opencode-ui--with-section section
               (if (string= role "user")
                   (opencode-chat--render-user-message info parts)
                 (opencode-chat--render-assistant-message info parts)))))
      ;; A message the user collapsed stays collapsed across the redraw
      ;; this call is part of.
      (opencode-chat--apply-collapse-state
       ov (opencode-chat--section-collapsed-p msg-id nil))
      ;; Cache overlay + original message data in store
      (when msg-id
        (let ((entry (opencode-chat--store-ensure msg-id)))
          (plist-put entry :overlay ov)
          (plist-put entry :msg msg)
          ;; Invariant: a rendered entry has BOTH :msg and :overlay.
          ;; Prior bugs left one set and the other nil, which caused
          ;; downstream lookups (find-overlay, message-info) to give
          ;; inconsistent views of the same message.
          (cl-assert (and (plist-get entry :msg)
                          (plist-get entry :overlay))
                     t "rendered store entry must have both :msg and :overlay"))))))

(defun opencode-chat--render-user-message (info parts)
  "Render a user message with INFO and PARTS.
Uses face-based borders: `:overline' on header, `:box' left-stripe
on body lines, `:underline' on footer."
  (let ((time-str (opencode-chat--format-time info)))
    ;; Header line with overline
    (insert (propertize " " 'face '(opencode-user-header opencode-message-header-line)))
    (opencode-ui--insert-icon 'expanded)
    (insert (propertize (concat " You  " time-str)
                        'face '(opencode-user-header opencode-message-header-line)))
    (insert "\n")
    ;; Body with left-border face
    (when parts
      (seq-doseq (part parts)
        (opencode-chat--render-part part 'user)))
    ;; Footer line with underline
    (insert (propertize " " 'face 'opencode-message-footer-line))
    (insert "\n")))

(defun opencode-chat--insert-assistant-header-line (agent-name model time-str &optional with-icon)
  "Insert the assistant header line with AGENT-NAME, MODEL, and TIME-STR.
If WITH-ICON is non-nil, insert a collapse/expand icon after the leading space.
This is the shared header rendering used by both full refresh and streaming
bootstrap."
  (let ((agent-color (when agent-name
                       (plist-get (opencode-agent--find-by-name agent-name) :color))))
    (insert (propertize " " 'face '(opencode-assistant-header opencode-message-header-line)))
    (when with-icon
      (opencode-ui--insert-icon 'expanded))
    (let ((header-parts (list " Assistant ")))
      (when agent-name
        (push (propertize agent-name 'face (opencode-chat--agent-badge-face agent-color)) header-parts)
        (push " " header-parts))
      (unless (string-empty-p model)
        (let ((short-model (car (last (split-string model "/")))))
          (push (propertize short-model 'face 'opencode-agent-badge) header-parts)
          (push " " header-parts)))
      (push time-str header-parts)
      (insert (propertize (apply #'concat (nreverse header-parts))
                          'face '(opencode-assistant-header opencode-message-header-line)))
      (insert "\n"))))

(defun opencode-chat--render-assistant-message (info parts)
  "Render an assistant message with INFO and PARTS.
Uses face-based borders: `:overline' on header, `:box' left-stripe
on body lines, `:underline' on footer."
  (let* ((time-str (opencode-chat--format-time info))
         (agent-name (plist-get info :agent))
         (model (or (plist-get info :modelID)
                    (let ((m (plist-get info :model)))
                      (when (listp m) (plist-get m :modelID)))
                    ""))
         (tokens (plist-get info :tokens)))
    ;; Header line with overline and collapse icon
    (opencode-chat--insert-assistant-header-line agent-name model time-str 'with-icon)
    ;; Parts with left-border face
    (when parts
      (seq-doseq (part parts)
        (opencode-chat--render-part part 'assistant)))
    ;; Error message (e.g. MessageAbortedError)
    (when-let* ((err (plist-get info :error)))
        (let* ((err-name (or (plist-get err :name) "Error"))
               (err-data (plist-get err :data))
               (err-msg (when err-data (plist-get err-data :message)))
               (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block))
               (start (point)))
          (insert (propertize (format " %s%s"
                                      err-name
                                      (if err-msg (format ": %s" err-msg) ""))
                              'face 'opencode-tool-error))
          (put-text-property start (point) 'line-prefix stripe)
          (insert "\n")))
    ;; Footer line with token info + duration + underline
    (let ((footer-parts (list " "))
          (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block))
          (footer-start (point))
          (duration (opencode-chat--format-duration info)))
      (when tokens
        (let ((input (or (plist-get tokens :input) 0))
              (output (or (plist-get tokens :output) 0))
              (cache (plist-get tokens :cache))
              (cache-read 0)
              (cache-write 0))
          (when cache
            (setq cache-read (or (plist-get cache :read) 0))
            (setq cache-write (or (plist-get cache :write) 0)))
          (when (> (+ input output) 0)
            (push (propertize
                   (format "\u2B06%s \u2B07%s"
                           (opencode-chat--format-token-count input)
                           (opencode-chat--format-token-count output))
                   'face 'opencode-tokens)
                  footer-parts)
            (when (> (+ cache-read cache-write) 0)
              (push (propertize
                     (format "  cache: %s read, %s write"
                             (opencode-chat--format-token-count cache-read)
                             (opencode-chat--format-token-count cache-write))
                     'face 'opencode-tokens)
                    footer-parts))
            (push " " footer-parts))))
      (when duration
        (push (propertize "\u00B7" 'face 'opencode-tokens) footer-parts)
        (push " " footer-parts)
        (push (propertize duration 'face 'opencode-tokens) footer-parts)
        (push " " footer-parts))
      (insert (propertize (apply #'concat (nreverse footer-parts))
                          'face 'opencode-message-footer-line))
      (put-text-property footer-start (point) 'line-prefix stripe)
      (insert "\n"))))

;;; --- Part rendering ---

(defun opencode-chat--render-part (part role)
  "Render a single PART plist.  ROLE is `user' or `assistant'."
  (let ((type (plist-get part :type))
        (part-id (plist-get part :id))
        (start (point)))
    (pcase type
      ("text"       (opencode-chat--render-text-part part role))
      ("tool"       (opencode-chat--render-tool-part part))
      ("reasoning"  (opencode-chat--render-reasoning-part part))
      ("step-start" (opencode-chat--render-step-start part))
      ("step-finish" (opencode-chat--render-step-finish part))
      ("file"        (opencode-chat--render-file-part part role))
      ("agent"       (opencode-chat--render-agent-part part role))
      ("subtask"     (opencode-chat--render-subtask-part part role))
      (_            (opencode-chat--render-text-part part role)))
    ;; Every part owns a data range overlay, separate from any collapsible
    ;; UI section overlay the renderer created.  Its boundaries exclude
    ;; insertions at either shared edge until this part explicitly resizes
    ;; it, so neighbouring parts cannot move or absorb one another.
    (when-let* ((part-id part-id)
                 (cur-msg-id (opencode-chat--current-message-id)))
      (opencode-chat--store-set-part
       cur-msg-id part-id type
       (opencode-chat--part-range-overlay start (point) part-id))
      (opencode-chat--store-cache-part-section
       cur-msg-id part-id start))))

(defun opencode-chat--render-text-part (part role)
  "Render a text PART.  ROLE determines the face.
Each line gets a line-prefix with a stripe character carrying the block face.
For unfinished assistant text parts (still streaming), the trailing newline
on the last line is omitted so streaming deltas can append seamlessly."
  (let* ((text (or (plist-get part :text) ""))
         (block-face (if (eq role 'user) 'opencode-user-block 'opencode-assistant-block))
         (body-face (if (eq role 'user) 'opencode-user-body 'opencode-assistant-body))
         (time-data (plist-get part :time))
         (unfinished-p (and (eq role 'assistant)
                            time-data
                            (plist-get time-data :start)
                            (not (plist-get time-data :end)))))
    (unless (string-empty-p text)
      (let* ((stripe (opencode--prose-prefix block-face))
             ;; Normalise line endings exactly as before; the gutter that used
             ;; to be prepended per line now lives in the line-prefix.
             (body (string-join (string-lines text) "\n"))
             (part-start (car (opencode-chat--emit body body-face stripe))))
        ;; Trailing newline: omit only for unfinished (streaming) parts
        (unless unfinished-p
          (insert "\n"))
        ;; Fontify markdown in assistant text parts (not during streaming)
        (when (eq role 'assistant)
          (opencode-markdown-mark-region part-start (point)))))))

(defun opencode-chat--render-file-part (part role)
  "Render a file mention PART.  ROLE determines the line-prefix stripe."
  (let* ((filename (or (plist-get part :filename) "unknown"))
         (mime (or (plist-get part :mime) ""))
         (icon (if (string-prefix-p "image/" mime) " \U0001f5bc " " \U0001f4c1 "))
         (block-face (if (eq role 'user) 'opencode-user-block 'opencode-assistant-block))
         (stripe (propertize opencode--stripe-char 'face block-face))
         (start (point)))
    (insert (propertize (concat icon filename) 'face 'opencode-mention-file))
    (put-text-property start (point) 'line-prefix stripe)
    (insert "\n")))

(defun opencode-chat--render-agent-part (part role)
  "Render an agent mention PART.  ROLE determines the line-prefix stripe."
  (let* ((name (or (plist-get part :name) "unknown"))
         (agent-color (plist-get (opencode-agent--find-by-name name) :color))
         (face (opencode-chat--agent-chip-face agent-color))
         (block-face (if (eq role 'user) 'opencode-user-block 'opencode-assistant-block))
         (stripe (propertize opencode--stripe-char 'face block-face))
         (start (point)))
    (insert (propertize (concat " \U0001f916 " name) 'face face))
    (put-text-property start (point) 'line-prefix stripe)
    (insert "\n")))

(defun opencode-chat--render-subtask-part (part role)
  "Render a subtask PART as a collapsible section.
ROLE determines the line-prefix stripe.
A subtask represents a delegated command (e.g. /review) with its own agent.
The header shows the command name, description, agent, and model.
The body shows the full prompt text and is collapsed by default."
  (let* ((command (or (plist-get part :command) "subtask"))
         (description (or (plist-get part :description) ""))
         (prompt (plist-get part :prompt))
         (agent (plist-get part :agent))
         (model-info (plist-get part :model))
         (block-face (if (eq role 'user) 'opencode-user-block 'opencode-assistant-block))
         (stripe (propertize opencode--stripe-char 'face block-face))
         (part-id (plist-get part :id))
         (collapsed-p (opencode-chat--section-collapsed-p part-id t))
         (section (opencode-ui--make-section 'subtask part-id part nil t))
         (section-ov
          (opencode-ui--with-section section
            ;; Header line
            (let ((header-start (point)))
              (insert " ")
              (opencode-ui--insert-icon (if collapsed-p 'collapsed 'expanded))
              (insert " ")
              (insert (propertize (concat "/" command) 'face 'opencode-subtask-name))
              (unless (string-empty-p description)
                (insert (propertize (concat "  " description)
                                    'face 'opencode-subtask-description)))
              (when agent
                (insert (propertize (concat "  \U0001f916 " agent)
                                    'face 'opencode-agent-badge)))
              (when-let* ((model-id (plist-get model-info :modelID)))
                (insert (propertize (concat "  " model-id)
                                    'face 'opencode-model-badge)))
              (put-text-property header-start (point) 'line-prefix stripe)
              (insert "\n"))
            ;; Body: full prompt text with markdown rendering
            (when (and prompt (stringp prompt) (not (string-empty-p prompt)))
              ;; Prompt text is prose; the header above it is chrome and
              ;; keeps the bare stripe.
              (let ((body-start
                     (car (opencode-chat--emit
                           (concat (string-join (string-lines prompt) "\n") "\n")
                           'default
                           (opencode--prose-prefix block-face)))))
                (opencode-markdown-mark-region body-start (point)))))))
    (opencode-chat--apply-collapse-state section-ov collapsed-p)))

(defun opencode-chat--render-tool-part (part)
  "Render a tool call PART with status indicator.
Supports both old format (:toolName/:args/:state string/:duration) and
new API format (:tool/:state plist with :status/:input/:output) via
`opencode-chat--normalize-tool-part' in opencode-tool-render.el.
Tool calls are visually indented under their parent assistant message
using `line-prefix' with the assistant block stripe.

Body rendering dispatches to the registry in opencode-tool-render.el;
unregistered tools route to the MCP-generic renderer."
  (let* ((norm (opencode-chat--normalize-tool-part part))
         (tool-name   (plist-get norm :tool-name))
         (state       (plist-get norm :state))
         (duration    (plist-get norm :duration))
         (arg-summary (plist-get norm :arg-summary))
         (input       (plist-get norm :input))
         (output      (plist-get norm :output))
         (metadata    (plist-get norm :metadata))
          (tool-prefix (propertize opencode--stripe-char 'face 'opencode-assistant-block))
          (model (opencode-chat--tool-render-model
                  tool-name state input output metadata part arg-summary))
          (render-tool-name (or (plist-get model :tool-name) tool-name))
          (summary (if (plist-member model :summary)
                       (plist-get model :summary)
                     arg-summary))
          (part-id (plist-get part :id))
          (should-collapse-p
           (opencode-chat--section-collapsed-p
            part-id
            (and (plist-member model :collapsed-p)
                 (plist-get model :collapsed-p))))
          (section (opencode-ui--make-section 'tool-call part-id part nil t))
          (section-ov
           (opencode-ui--with-section section
             ;; Header line
             (let ((header-start (point)))
               (insert " ")
               (opencode-ui--insert-icon (if should-collapse-p 'collapsed 'expanded))
               (insert " ")
               (insert (propertize render-tool-name 'face 'opencode-tool-name))
               (when (and summary
                          (stringp summary)
                          (not (string-empty-p summary)))
                 (insert " ")
                 (insert (propertize (format "(%s)" (opencode--truncate-string summary 60))
                                     'face 'opencode-tool-arg)))
               (when (and duration (> duration 0))
                 (let* ((secs (round (/ duration 1000.0)))
                       (dur-str (if (>= secs 60)
                                    (format "%dm%ds" (/ secs 60) (mod secs 60))
                                  (format "%ds" secs))))
                  (insert " ")
                  (insert (propertize (format "· %s" dur-str)
                                      'face 'opencode-tool-duration))))
              (let ((status-col (max (+ (current-column) 2) 55)))
                (insert (make-string (max 1 (- status-col (current-column))) ?\s)))
              (pcase state
                ("pending"   (insert (propertize "○" 'face 'opencode-tool-pending)))
                ("running"   (insert (propertize "⏳" 'face 'opencode-tool-running)))
                ("completed" (insert (propertize "✓" 'face 'opencode-tool-success)))
                ("error"     (insert (propertize "✗" 'face 'opencode-tool-error)))
                (_           (insert "·")))
              (put-text-property header-start (point) 'line-prefix tool-prefix)
               (insert "\n"))
             ;; Body: declarative fields returned by the tool renderer.
             (let ((body-start (point)))
               (opencode-chat--render-tool-field (plist-get model :input))
               (opencode-chat--render-tool-field (plist-get model :output))
               (when (> (point) body-start)
                 (put-text-property body-start (max body-start (1- (point)))
                                    'line-prefix tool-prefix))))))
    (opencode-chat--apply-collapse-state section-ov should-collapse-p)))


(defun opencode-chat--render-reasoning-part (part)
  "Render a reasoning/thinking PART.
Uses assistant block face for left border.
Always renders the header so that streaming deltas (via `message.part.delta')
have a marker position to insert at.  Content is rendered only when non-empty.

The section advertises that it grows even when initially bodyless, so
the user may collapse it before the first delta.  Streaming explicitly
extends both the data range and this UI section; neither boundary uses
rear advancement that could absorb the following part."
  (let* ((text (or (plist-get part :text) ""))
         (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block))
         (part-id (plist-get part :id))
         (section (opencode-ui--make-section 'reasoning part-id
                                             nil nil
                                             'front-advance 'grows)))
    (opencode-chat--apply-collapse-state
     (opencode-ui--with-section section
       ;; Header line — always rendered
       (let ((line-start (point)))
         (insert " ")
         (opencode-ui--insert-icon 'expanded)
         (insert (propertize " Thinking..." 'face 'opencode-reasoning))
         (put-text-property line-start (point) 'line-prefix stripe)
         (insert "\n"))
       ;; Content — only when text is non-empty.
       ;; Uses `insert-streaming-delta' so both streaming and refresh
       ;; paths produce identical per-line formatting (space prefix,
       ;; face, line-prefix, trailing newline handling).
       (when (not (string-empty-p text))
         (opencode-chat--insert-streaming-delta text "reasoning")
         ;; Ensure trailing newline so subsequent parts start on a new line
         (unless (bolp)
           (insert "\n"))))
     (opencode-chat--section-collapsed-p part-id nil))))

(defun opencode-chat--render-step-start (_part)
  "Render a step-start PART with a display property separator."
  (let ((line-start (point))
        (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block)))
    (insert (propertize " "
                        'face 'opencode-step-separator
                        'display '(space :width 50)))
    (put-text-property line-start (point) 'line-prefix stripe)
    (insert "\n")))

(defun opencode-chat--render-step-finish (part)
  "Render a step-finish PART with cost summary.
Uses assistant block face for left border."
  (let ((cost (plist-get part :cost)))
    (when (and cost (> cost 0))
      (let ((line-start (point))
            (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block)))
        (insert " ")
        (insert (propertize "Step: " 'face 'opencode-step-summary))
        (insert (propertize (format "$%.4f" cost) 'face 'opencode-cost))
        (put-text-property line-start (point) 'line-prefix stripe)
        (insert "\n")))))

;;; --- Streaming delta insertion ---

(defun opencode-chat--insert-streaming-delta (text field)
  "Insert streaming delta TEXT for FIELD type.
Each line gets assistant-body (or reasoning) face, a prose line-prefix
with opencode-assistant-block, read-only, and keymap.
TEXT is inserted verbatim so a trailing newline survives (e.g. a
\"Hello\\n\" delta must keep the newline so the next delta starts on a
line of its own)."
  (let* ((inhibit-read-only t)
         (body-face (if (string= field "reasoning")
                        'opencode-reasoning
                      'opencode-assistant-body))
         (stripe (opencode--prose-prefix 'opencode-assistant-block))
         (region-start (point)))
    (opencode-chat--emit text body-face)
    ;; Apply all shared properties once over the entire inserted region
    (opencode-chat--apply-message-props region-start (point)
                                        (list 'line-prefix stripe))
    ;; A section the user collapsed mid-stream has to stay collapsed.
    ;; `insert' does not inherit `invisible', so without this every
    ;; delta reappears inside the section that is supposedly hidden.
    (when (opencode-ui--in-collapsed-section-p region-start)
      (put-text-property region-start (point) 'invisible 'opencode-section))
    ;; Assistant prose is markdown; reasoning is not, matching what the
    ;; non-streaming render path marks.  `jit-lock' refontifies this span
    ;; on its own after each delta, so no timer is scheduled here.
    (unless (string= field "reasoning")
      (opencode-markdown-mark-region region-start (point)))))

(defun opencode-chat--message-insert-pos (msg-id)
  "Return the insertion point for new parts of message MSG-ID (before footer).
Finds the message section overlay and searches forward for the footer face."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id)))
    (save-excursion
      (goto-char (overlay-start ov))
      (if-let* ((match (text-property-search-forward
                        'face 'opencode-message-footer-line t)))
          (prop-match-beginning match)
        (overlay-end ov)))))

(defun opencode-chat--update-part-inline (part &optional owner-msg-id)
  "Update a non-text PART directly in the chat buffer.
OWNER-MSG-ID, when given, is the normalized owning message id.  It is
preferred over PART's `:messageID' so backends may carry ownership at
the event-properties level.
Case 1: existing range overlay — delete its text and re-render in-place.
Case 2: no live range — bootstrap at message-insert-pos or messages-end.
Case 3: no insertion point — return `:needs-refresh'.

This message-owned primitive never schedules chat/controller work itself.
Callers must interpret `:needs-refresh' in the chat controller."
  (let* ((part-id (plist-get part :id))
         (msg-id (or owner-msg-id (plist-get part :messageID)))
         (part-type (plist-get part :type))
         (range (opencode-chat--store-part-overlay msg-id part-id))
         (section (opencode-chat--store-part-section-overlay msg-id part-id))
         (inhibit-read-only t))
    (cond
     ;; Case 1: Existing range — redraw exactly that part in place.
     ((and (overlayp range) (overlay-buffer range))
      (let ((start (overlay-start range))
            (end (overlay-end range)))
        ;; The part owns both overlays.  Delete their handles before replacing
        ;; the text so no lookup can return a stale boundary mid-redraw.
        (delete-overlay range)
        (when (and (overlayp section) (overlay-buffer section))
          (delete-overlay section))
        (when (> end start)
          (opencode-chat--in-transcript
            (delete-region start end)))
        (let ((new-end
               (opencode-chat--insert-section
                start
                (lambda ()
                  (opencode-chat--render-part-by-type
                   part part-type msg-id)))))
          (opencode-chat--recache-part
           msg-id part-id part-type start new-end))
        :upserted))
     ;; A stored but dead range is a desync, not proof that the part was never
     ;; rendered.  Preserve the entry for reset cleanup and request a canonical
     ;; refresh rather than inserting a duplicate.
     ((and range (not (overlay-buffer range)))
      (opencode--debug
       "opencode-chat: dead part range during inline update msg=%s part=%s"
       msg-id part-id)
      :needs-refresh)
     ;; Case 2: No overlay — insert at message-end or messages-end
     ((let ((pos (or (opencode-chat--message-insert-pos msg-id)
                     (when-let* ((end (opencode-chat--messages-end)))
                       (marker-position end)))))
         (when pos
           (let (start)
             (let ((end
                    (opencode-chat--insert-section
                     pos
                     (lambda ()
                       (setq start (point))
                       (opencode-chat--render-part-by-type
                        part part-type msg-id)))))
               (opencode-chat--recache-part
                msg-id part-id part-type (or start pos) end)))
           :upserted)))
      ;; Case 3: No insertion point — defer
      (t :needs-refresh))))

;;; --- Public API ---

(defun opencode-chat--msg-role (msg-id)
  "Return \\='user or \\='assistant for MSG-ID from overlay data."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id))
              (sec (overlay-get ov 'opencode-section))
              (data (plist-get sec :data)))
    (if (equal (plist-get data :role) "user") 'user 'assistant)))

(defun opencode-chat-message-upsert (msg-id data)
  "Create or update message MSG-ID with DATA (info plist).
DATA may include :parts for initial rendering.
If the message doesn't exist, renders it at messages-end.
If it exists, updates header/footer in-place.

Return `:inserted', `:updated', or `:needs-refresh'.  The latter means
the message store could not render safely in the current buffer state;
the chat controller should schedule a refresh."
  (if (opencode-chat-message-exists-p msg-id)
      (if (opencode-chat--update-message-inline msg-id data)
          :updated
        :needs-refresh)
    (let ((parts (plist-get data :parts))
          (info (if (plist-get data :role)
                    data
                  ;; DATA is already a full msg plist with :info
                  (plist-get data :info))))
      (if (opencode-chat--insert-message-at-end
           (list :info (or info data) :parts parts))
          :inserted
        :needs-refresh))))

(defun opencode-chat-message-delete (msg-id)
  "Delete message MSG-ID from buffer and store.
Deletes all part range overlays, removes the message overlay and text.

Goes through `opencode-chat--delete-section' rather than deleting the
region directly, so the public delete gets the same guard as every other
section removal: a message overlay that has drifted into the input area
must not take the user's unsent text with it."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id)))
    (opencode-chat--delete-section ov))
  ;; Clean store entry (deletes part-owned overlays)
  (when-let* ((entry (opencode-chat--store-get msg-id)))
    (when-let* ((parts (plist-get entry :parts)))
      (maphash (lambda (_pid info)
                 (when-let* ((range (plist-get info :range-overlay)))
                   (when (overlayp range) (delete-overlay range)))
                 (when-let* ((part-ov (plist-get info :overlay)))
                   (when (overlayp part-ov) (delete-overlay part-ov))))
               parts))
    (remhash msg-id (opencode-chat--store))))

(defun opencode-chat-message-update-part (msg-id part-id part-type part delta)
  "Handle a part update for MSG-ID.
PART-ID and PART-TYPE identify the part.  PART is the full part plist
\(from message.part.updated) or nil (for message.part.delta).
DELTA is the streaming text or nil.

Returns:
  :streamed  — delta appended (caller should schedule fontify)
  :upserted  — non-text part rendered inline
  :rendered  — new text/reasoning part rendered in-place
  :need-msg  — no message overlay, caller must bootstrap message
  nil        — no-op (finalized part or nothing to do)"
  (cond
    ;; Non-text part (tool, step-*) — upsert inline
    ((not (or (null part-type)
              (string= part-type "text")
              (string= part-type "reasoning")))
     (opencode-chat--in-transcript
       (opencode-chat--update-part-inline part msg-id)))

   ;; Streaming delta
   (delta
    (let ((type (or part-type
                    (opencode-chat--store-part-type msg-id part-id))))
      (cond
       ;; Case 1: range overlay exists → append
       ((opencode-chat--append-delta msg-id part-id delta type)
        :streamed)
       ;; Case 2: message overlay exists → create a zero-width range, append.
       ;; When the previous streaming part's last delta ended mid-line
       ;; (no trailing newline), insert a separator so the new part
       ;; starts at bolp — otherwise the first delta for this part
       ;; glues onto the previous part's tail (e.g. reasoning text
       ;; concatenated with the assistant's first response word).
       ((when-let* ((pos (opencode-chat--message-insert-pos msg-id)))
          (save-excursion
            (goto-char pos)
            (unless (bolp)
              (let ((inhibit-read-only t)
                    (buffer-undo-list t))
                (insert "\n"))
              (setq pos (point)))
            ;; Invariant: after the guard, the range's anchor MUST be at
            ;; bolp — otherwise the new streaming part's first delta will
            ;; glue onto the previous part's tail (the bug pinned by
            ;; `opencode-chat-streaming-new-part-breaks-line').
            (cl-assert (save-excursion (goto-char pos) (bolp)) t
                       "new streaming part range must anchor at bolp"))
          (opencode-chat--store-set-part msg-id part-id (or type "text")
                                        (opencode-chat--part-range-overlay
                                         pos pos part-id))
          (opencode-chat--append-delta msg-id part-id delta (or type "text"))
          :streamed))
       ;; Case 3: no message → caller must bootstrap
       (t :need-msg))))

   ;; New text/reasoning part without delta — render in-place.
   ;; Ensure the render starts at bolp so a new reasoning header or
   ;; empty text placeholder doesn't glue onto the previous part's
   ;; tail when it didn't end on a newline.
   ((and part-id
         (not (opencode-chat--store-part-overlay msg-id part-id)))
    (when-let* ((pos (opencode-chat--message-insert-pos msg-id)))
      (let ((role (or (opencode-chat--msg-role msg-id) 'assistant)))
        (opencode-chat--insert-section
         pos
         (lambda () (opencode-chat--render-part part role))))
      :rendered))

   ;; Finalized part — no-op
   (t nil)))

(defun opencode-chat-message-has-parts-p (msg-id)
  "Return non-nil if MSG-ID has any registered parts."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts)))
    (> (hash-table-count parts) 0)))

(defun opencode-chat-message-exists-p (msg-id)
  "Return non-nil if MSG-ID has a section overlay in the buffer."
  (opencode-chat--store-find-overlay msg-id))

;; --- Internal: insert/update helpers ---

(defun opencode-chat--insert-message-at-end (msg)
  "Insert MSG at messages-end."
  (when-let* ((end-marker (opencode-chat--messages-end))
              ((marker-position end-marker)))
    ;; Invariant: the marker must belong to this buffer — a past bug
    ;; had `clear-all' nil the marker's position while leaving the
    ;; struct slot non-nil, causing insertions to land in whatever
    ;; buffer the marker's old home had become.
    (cl-assert (eq (marker-buffer end-marker) (current-buffer)) t
               "messages-end marker must belong to the current buffer")
    ;; Insertion type nil while drawing so the marker stays at the old end
    ;; rather than being dragged along, then moved explicitly to the new one.
    (set-marker-insertion-type end-marker nil)
    (set-marker end-marker
                (opencode-chat--insert-section
                 end-marker
                 (lambda () (opencode-chat--render-message msg))))
    (set-marker-insertion-type end-marker t)
    t))

(defun opencode-chat--update-message-inline (msg-id info)
  "Update an existing message MSG-ID header and footer from INFO.
Re-renders the header line (first line of the message section) so the
timestamp, agent, model, and tokens reflect the latest server data.
For assistant messages with `:completed' time, also re-renders the
footer line (token counts + duration).

Both re-renders replace text the collapse machinery owns --- the header
carries the `[collapsed]' indicator and the icon, the footer sits inside
the hidden body --- so a collapsed message is put back into agreement
with its overlay at the end."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id))
              ((overlay-buffer ov)))
    (opencode-chat--in-transcript
     (let* ((role (plist-get info :role))
           (start (overlay-start ov))
           (end (overlay-end ov)))
      (when (and start end (< start end))
        (save-excursion
          ;; --- Re-render header line ---
          (goto-char start)
          (let ((header-end (min (1+ (pos-eol)) end)))
            (delete-region start header-end)
            (goto-char start)
            (if (string= role "user")
                (let ((time-str (opencode-chat--format-time info)))
                  (insert (propertize " " 'face '(opencode-user-header opencode-message-header-line)))
                  (opencode-ui--insert-icon 'expanded)
                  (insert (propertize (concat " You  " time-str)
                                      'face '(opencode-user-header opencode-message-header-line)))
                  (insert "\n"))
              (let ((time-str (opencode-chat--format-time info))
                    (agent-name (plist-get info :agent))
                    (model (or (plist-get info :modelID)
                               (let ((m (plist-get info :model)))
                                 (when (listp m) (plist-get m :modelID)))
                               "")))
                ;; insert-assistant-header-line already appends \n
                (opencode-chat--insert-assistant-header-line agent-name model time-str 'with-icon)))

            (opencode-chat--apply-message-props start (point)))
          ;; --- Re-render footer line for assistant messages ---
          (when (and (not (string= role "user"))
                     (plist-get (plist-get info :time) :completed))
            ;; Find and replace the footer line (has opencode-message-footer-line face)
            (goto-char (overlay-start ov))
            (when-let* ((match (text-property-search-forward
                                'face 'opencode-message-footer-line t)))
              (let ((footer-start (prop-match-beginning match))
                    (footer-end (min (1+ (prop-match-end match))
                                     (overlay-end ov))))
                (delete-region footer-start footer-end)
                (goto-char footer-start)
                ;; If the last streaming text/reasoning part ended mid-line
                ;; (no trailing newline — unfinished parts omit it for delta
                ;; concatenation), the footer would glue onto its tail.
                ;; Ensure the footer starts on its own line.
                (unless (bolp)
                  (insert "\n")
                  (setq footer-start (point)))
                (let ((tokens (plist-get info :tokens))
                      (footer-parts (list " "))
                      (duration (opencode-chat--format-duration info)))
                  (when tokens
                    (let ((input (or (plist-get tokens :input) 0))
                          (output (or (plist-get tokens :output) 0))
                          (cache (plist-get tokens :cache))
                          (cache-read 0)
                          (cache-write 0))
                      (when cache
                        (setq cache-read (or (plist-get cache :read) 0))
                        (setq cache-write (or (plist-get cache :write) 0)))
                      (when (> (+ input output) 0)
                        (push (propertize
                               (format "\u2B06%s \u2B07%s"
                                       (opencode-chat--format-token-count input)
                                       (opencode-chat--format-token-count output))
                               'face 'opencode-tokens)
                              footer-parts)
                        (when (> (+ cache-read cache-write) 0)
                          (push (propertize
                                 (format "  cache: %s read, %s write"
                                         (opencode-chat--format-token-count cache-read)
                                         (opencode-chat--format-token-count cache-write))
                                 'face 'opencode-tokens)
                                footer-parts))
                        (push " " footer-parts))))
                  (when duration
                    (push (propertize "\u00B7" 'face 'opencode-tokens) footer-parts)
                    (push " " footer-parts)
                    (push (propertize duration 'face 'opencode-tokens) footer-parts)
                    (push " " footer-parts))
                  (insert (propertize (apply #'concat (nreverse footer-parts))
                                      'face 'opencode-message-footer-line))
                  (insert "\n"))
                (opencode-chat--apply-message-props footer-start (point))
                ;; The old footer ran to the overlay's end, so deleting it
                ;; shrank the overlay to the footer's start; the overlay
                ;; does not advance on insertion, so the replacement landed
                ;; outside it.  A message whose footer is not in its own
                ;; section cannot be collapsed --- and worse, every part
                ;; inserted afterwards goes to `--message-insert-pos',
                ;; which is now the overlay's end, and lands outside too.
                (when (< (overlay-end ov) (point))
                  (move-overlay ov (overlay-start ov) (point)))))))
        ;; Both re-renders above wrote over text the collapse machinery
        ;; owns.  Re-collapsing is idempotent and restores the icon, the
        ;; indicator, and the hidden state of the new footer.
        (when (overlay-get ov 'opencode-collapsed)
          (opencode-ui--collapse-section ov))
        t)))))



(defun opencode-chat--append-delta (msg-id part-id delta field)
  "Append streaming DELTA for PART-ID in MSG-ID.
FIELD is the part type (\"text\" or \"reasoning\").
Inserts at the end of the part's range overlay, then explicitly extends
that range over the new text.  Returns t on success, nil if no live
range overlay exists for PART-ID."
  (let ((range (opencode-chat--store-part-overlay msg-id part-id)))
    (when (and (overlayp range) (overlay-buffer range))
      (opencode-chat--in-transcript
        (let ((start (overlay-start range))
              (end (overlay-end range))
              ;; Only reasoning streams into a part-owned collapsible
              ;; section.  Text parts have no UI section; avoiding the
              ;; lookup also avoids irrelevant work per text delta.
              (section (and (equal field "reasoning")
                            (opencode-chat--store-part-section-overlay
                             msg-id part-id))))
          (save-excursion
            (goto-char end)
            (opencode-chat--insert-streaming-delta delta field)
            (when (and section (overlay-get section 'opencode-collapsed))
              (put-text-property end (point)
                                 'invisible 'opencode-section))
            ;; The range uses rear-advance=nil so neighbouring inserts do
            ;; not move it.  Only this part's own mutation extends it.
            (move-overlay range start (point))
            ;; A reasoning part also owns a collapsible UI section.  It uses
            ;; the same explicit extension rule as the data range so the
            ;; following part is never absorbed at a shared boundary.
            (when (and section
                       (= (overlay-end section) end)
                       (< end (point)))
              (move-overlay section (overlay-start section) (point))))))
      t)))

(defun opencode-chat-message-clear-all ()
  "Clear all message state after erase-buffer.
Nils messages-end, clears all hash tables, and deletes stored overlays."
  (when-let* ((end (opencode-chat--messages-end)))
    (set-marker end nil))
  (opencode-chat--set-messages-end nil)
  (opencode-chat--store-clear)
  (when (hash-table-p (opencode-chat--diff-shown))
    (clrhash (opencode-chat--diff-shown)))
  (opencode-chat--set-current-message-id nil))

(defun opencode-chat-message-reset ()
  "Reset all message-owned state after transcript erasure.
Semantic alias for `opencode-chat-message-clear-all'.  Prefer this in
cross-module code; generated state setters are compatibility shims and
same-owner implementation details."
  (opencode-chat-message-clear-all))

(defun opencode-chat-message-messages-end ()
  "Return the messages-end marker (read accessor)."
  (opencode-chat--messages-end))

(defun opencode-chat-message-init-messages-end (pos)
  "Create messages-end marker at POS with nil insertion type."
  (when-let* ((prev (opencode-chat--messages-end)))
    (set-marker prev nil))
  (opencode-chat--set-messages-end (copy-marker pos nil))
  ;; Invariant: after init, messages-end must be a live marker with a
  ;; position — streaming deltas crash the moment this is nil or marker
  ;; has no buffer.
  (cl-assert (and (markerp (opencode-chat--messages-end))
                  (marker-position (opencode-chat--messages-end)))
             t "messages-end must be a live marker after init"))

(defun opencode-chat-message-invalidate-diffs ()
  "Clear the diff cache."
  (when (hash-table-p (opencode-chat--diff-cache))
    (clrhash (opencode-chat--diff-cache))))

(defun opencode-chat-message-prefetch-diffs (session-id)
  "Async fetch diffs for SESSION-ID and populate cache."
  (opencode-backend-get-diff
   session-id
   (lambda (diffs)
     (let ((body (or (plist-get diffs :body) diffs)))
       (when (and body (arrayp body))
         (seq-doseq (d body)
           (let ((msg-id (plist-get d :messageID)))
             (when msg-id
               (puthash msg-id d (opencode-chat--diff-cache))))))))
   nil
   (when (fboundp 'opencode-chat--backend) (opencode-chat--backend))))

(defun opencode-chat-message-render-all (messages)
  "Render all MESSAGES in sequence.
MESSAGES is a vector of message plists (each with :info and :parts)."
  (seq-doseq (msg messages)
    (opencode-chat--render-message msg)))

(provide 'opencode-chat-message)
;;; opencode-chat-message.el ends here
