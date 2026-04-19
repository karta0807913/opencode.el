;;; opencode-chat-input.el --- Input area for opencode chat -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Input area subsystem for the OpenCode chat buffer.
;; Owns: input rendering, input text extraction, clipboard/image paste,
;; chip overlays (@-mention, /slash-command), input history, footer info.
;; Does NOT know about SSE events, session lifecycle, or message rendering.
;;
;; Public API uses `opencode-chat-input-' prefix.
;; Internal functions keep `opencode-chat--' prefix (zero rename from chat.el).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ring)
(require 'color)
(require 'project)
(require 'opencode-faces)
(require 'opencode-ui)
(require 'opencode-log)
(require 'opencode-util)
(require 'opencode-api)
(require 'opencode-agent)
(require 'opencode-config)
(require 'opencode-session)
(require 'opencode-chat-state)
(require 'opencode-chat-message)
(require 'opencode-todo)

;; Buffer-local vars owned by chat.el — accessed here
(defvar opencode-chat-message-map)

;; Functions defined in chat.el — forward-declare to avoid circular requires
(declare-function opencode-chat--child-session-p "opencode-chat" ())
(declare-function opencode-chat--drain-popup-queue "opencode-chat" ())

;; `--optimistic-msg-id' lives in the opencode-chat-state struct; the
;; defvar-local was removed in the Step 5 struct migration (2026-04-18).

(defvar-local opencode-chat-on-message-sent-hook nil
  "Hook run after a user message is sent via `opencode-chat--send'.
Called with one argument, a plist:
  (:text USER-TEXT :session-id SID :message-id MSG-ID
   :mentions MENTION-LIST)")

;;; --- Defcustoms ---

(defcustom opencode-chat-image-max-size 10485760
  "Maximum allowed image size in bytes for clipboard paste (default 10 MB)."
  :type 'integer
  :group 'opencode-chat)

(defcustom opencode-chat-input-history-size 50
  "Maximum number of sent messages to keep in the input history ring."
  :type 'integer
  :group 'opencode-chat)

;;; --- Internal state ---

;; The following slots live in the opencode-chat-state struct; their
;; `defvar-local's were removed in the Step 5 struct migration
;; (2026-04-18).  Read via `(opencode-chat--SLOT)', write via
;; `(opencode-chat--set-SLOT VALUE)':
;;   input-start            — marker for the start of the input area
;;   input-history          — ring of previously sent input strings
;;   input-history-index    — current index when browsing history
;;   input-history-saved    — saved text from before history browsing
;;   mention-cache          — (TICK . CANDIDATES) cache for @-mentions
;;   inline-todos           — vector of todo items for footer display
;;   inline-todos-ov        — overlay covering the inline todo footer

(defconst opencode-chat--mention-cache-ttl 30
  "Seconds before the @-mention candidate cache is considered stale.")


;;; --- Keymap ---

(defvar-keymap opencode-chat-input-map
  :doc "Keymap for the editable input area (applied via text property).
Only binds keys that must override Evil state maps or need special
handling at the read-only boundary.  All other input-area bindings
\(C-c C-c, TAB, DEL, etc.) live in `opencode-chat-mode-map' and work
fine because Evil doesn't shadow C-c prefixes or those keys.
`kill-line' (C-k) works natively via `field' text properties (like eshell).
`kill-whole-line' needs explicit binding because it always tries to
delete the newline which belongs to the read-only `footer' field."
  "C-p" #'opencode-command-select
  "C-t" #'opencode-chat--cycle-variant
  "C-j" #'opencode-chat--input-history-next
  "C-k" #'opencode-chat--input-history-prev
  "C-S-<backspace>" #'opencode-chat--kill-whole-line)

(declare-function opencode-command-select "opencode-command" ())


;;; --- Input area rendering ---

(defun opencode-chat--input-after-change (beg end _len)
  "Ensure newly inserted text in the input area inherits the input keymap.
BEG and END are the region of the change.  When text is yanked from
another buffer, it arrives without `opencode-chat-input-map', causing
keybindings (C-p, etc.) to stop working on that text.  This hook
applies the correct properties to any unpropertied text in the input area."
  (when (and (opencode-chat--input-start)
             (< beg end)
             (let ((input-start (marker-position (opencode-chat--input-start))))
               (and input-start
                    (>= beg input-start))))
    (let ((inhibit-modification-hooks t))
      (save-excursion
        (let ((pos beg))
          (while (< pos end)
            (if (get-text-property pos 'read-only)
                ;; Skip past read-only regions entirely
                (setq pos (or (next-single-property-change pos 'read-only nil end) end))
              ;; Editable region — ensure correct properties
              (let ((next (or (next-single-property-change pos 'read-only nil end) end)))
                (unless (eq (get-text-property pos 'keymap) opencode-chat-input-map)
                  (put-text-property pos next 'keymap opencode-chat-input-map))
                (unless (get-text-property pos 'opencode-input)
                  (put-text-property pos next 'opencode-input t))
                (setq pos next)))))))))

(defun opencode-chat--input-content-start ()
  "Return the start position of the editable input content.
Skips the prompt (which is read-only).
Returns nil if input area is not initialized."
  (when (opencode-chat--input-start)
    (let ((pos (marker-position (opencode-chat--input-start))))
      (if (get-text-property pos 'read-only)
          (or (next-single-property-change pos 'read-only) pos)
        pos))))

(defun opencode-chat--input-content-end ()
  "Return the end position of the editable input region.
This is the first position after the prompt that has the `read-only'
text property, i.e. the boundary between user text and the help line."
  (when-let* ((pos (opencode-chat--input-content-start)))
      (while (and (< pos (point-max))
                  (not (get-text-property pos 'read-only)))
        (setq pos (or (next-single-property-change pos 'read-only)
                      (point-max))))
      pos))

(defun opencode-chat--input-text ()
  "Return the text from the input area, including multiple lines."
  (when-let* ((start (opencode-chat--input-content-start)))
    (save-excursion
      (goto-char start)
      (let ((start (point))
            (end (opencode-chat--input-content-end)))
        (string-trim (buffer-substring-no-properties start end))))))

(defun opencode-chat--replace-input (text)
  "Replace the editable input area content with TEXT.
If TEXT is nil or empty, inserts a single-space placeholder.
Applies the standard input-area text properties (face, keymap, opencode-input)."
  (when-let* ((start (opencode-chat--input-content-start)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char start)
        (delete-region start (opencode-chat--input-content-end))
        (insert (propertize (if (and text (not (string-empty-p text))) text " ")
                            'face 'opencode-input-area
                            'opencode-input t
                            'keymap opencode-chat-input-map))))))

(defun opencode-chat--clear-input ()
  "Clear the input area text, including multiple lines."
  (opencode-chat--replace-input nil))

(defun opencode-chat--in-input-area-p ()
  "Return non-nil when point is in the editable input content.
Uses the `opencode-input' text property — which is stamped on the
editable placeholder by `render-input-area' / `replace-input' and
auto-healed onto yanked text by `input-after-change' — as the single
source of truth for \"this character belongs to the input region\".
Naturally returns nil at `point-max' (no character there), in the
message area, in the prompt, in the footer, and in the help line."
  (get-text-property (point) 'opencode-input))

(defun opencode-chat--kill-whole-line ()
  "Kill all editable input text (all lines).
Unlike `kill-whole-line', this only deletes within the editable region
\(between prompt and footer), so it never hits a read-only boundary.
Works correctly with multi-line input — kills everything from the first
editable character to the last."
  (interactive)
  (let ((start (opencode-chat--input-content-start))
        (end (opencode-chat--input-content-end)))
    (when (and start end (< start end))
      (kill-region start end))))

(defun opencode-chat--goto-latest ()
  "Scroll to the latest message / input area."
  (interactive)
  (when-let* ((start (opencode-chat--input-content-start)))
    (goto-char start)))

(defun opencode-chat--render-update-notification ()
  "Render the update-available notification if one exists.
Returns non-nil if a notification was rendered."
  (opencode-chat--state-ensure)
  (when-let* ((info (opencode-chat-state-update-available opencode-chat--state))
              (latest (plist-get info :latest)))
    (let ((msg (format "⬆ Update available: %s" latest)))
      (insert (propertize msg 'face 'opencode-update-notification))
      (insert "\n")
      t)))

(defun opencode-chat--insert-shortcut (key label)
  "Insert a styled KEY + LABEL shortcut hint.
KEY is displayed with `opencode-popup-key' face, LABEL with comment face."
  (insert (propertize (concat " " key " ") 'face 'opencode-popup-key))
  (insert (propertize (concat " " label) 'face 'font-lock-comment-face)))

(defun opencode-chat--render-footer-info ()
  "Render session info footer above the input area.
Shows: Model, Agent, Token usage, Context percentage.
Reads all display data from `opencode-chat--state'.
The region is tagged with `opencode-footer-info' text property so that
`opencode-chat--refresh-footer' can find and replace it cheaply."
  (opencode-chat--state-ensure)
  (let* ((inhibit-read-only t)
         (session (opencode-chat--session))
         (st opencode-chat--state)
         (agent (opencode-chat-state-agent st))
         (agent-color (opencode-chat-state-agent-color st))
         (model-id (opencode-chat-state-model-id st))
         (provider-id (opencode-chat-state-provider-id st))
         (variant (opencode-chat-state-variant st))
         (tokens (or (opencode-chat-state-tokens st)
                     (list :total 0 :input 0 :output 0 :reasoning 0
                           :cache-read 0 :cache-write 0)))
         (ctx-limit (or (opencode-chat-state-context-limit st)
                        ;; Re-try from provider cache (may have populated since state-init)
                        (let ((lim (when (and provider-id model-id)
                                     (opencode-config--model-context-limit
                                      provider-id model-id))))
                          (when lim
                            (opencode-chat--set-context-limit lim))
                          lim)))
         (total-tok (plist-get tokens :total))
         (footer-start (point)))

    ;; Top separator
    (opencode-ui--insert-separator)

    ;; Model badge
    (when model-id
      (insert (propertize (format "[%s]" model-id)
                         'face 'opencode-model-badge
                         'read-only t
                         'keymap opencode-chat-message-map
                         'front-sticky '(read-only)
                         'rear-nonsticky t)))

    ;; Line 1: dot · Agent · variant
    ;; Use font-lock-comment-face for inline dots — NOT opencode-separator
    ;; (which has :strike-through t on GUI, causing a line through the dot)
    (insert (propertize " · " 'face 'font-lock-comment-face 'read-only t))
    (insert (propertize (or agent "unknown")
                       'face (opencode-chat--agent-badge-face agent-color)
                       'read-only t))
    (when (plist-get session :parentID)
      (insert (propertize " [Sub-agent]" 'face 'opencode-agent-badge 'read-only t)))
    (when variant
      (insert (propertize " · " 'face 'font-lock-comment-face 'read-only t))
      (insert (propertize variant 'face 'opencode-variant-badge 'read-only t)))
    (insert (propertize "\n" 'read-only t))

    ;; Line 2: Token usage breakdown
    (let ((input (plist-get tokens :input))
          (output (plist-get tokens :output))
          (cache-read (plist-get tokens :cache-read))
          (cache-write (plist-get tokens :cache-write)))
      (when (> total-tok 0)
        (insert (propertize
                 (format " Tokens: %s  (\u2B06%s \u2B07%s  cache: %s read, %s write)\n"
                        (opencode-chat--format-token-count total-tok)
                        (opencode-chat--format-token-count input)
                        (opencode-chat--format-token-count output)
                        (opencode-chat--format-token-count cache-read)
                        (opencode-chat--format-token-count cache-write))
                 'face 'opencode-tokens
                 'read-only t))))
    ;; Line 3: Context percentage with progress bar
    (when (and ctx-limit (> ctx-limit 0))
      (let* ((percentage (if (> total-tok 0)
                             (/ (* total-tok 100.0) ctx-limit)
                           0.0))
             (remaining (max 0 (- ctx-limit total-tok)))
             (bar-width 20)
             (filled (min bar-width (max 0 (floor (* bar-width (/ percentage 100.0))))))
             (empty (- bar-width filled))
             (bar-face (cond
                        ((>= percentage 90) 'opencode-tool-error)
                        ((>= percentage 70) 'warning)
                        (t 'opencode-tokens)))
             ;; Apply face to bar string BEFORE format to avoid pattern overlay
             (bar (propertize (concat (make-string filled ?█)
                                     (make-string empty ?░))
                             'face bar-face)))
        (insert (propertize
                 (format " Context: %s %5.1f%%  (%s / %s)  %s remaining\n"
                        bar
                        percentage
                        (opencode-chat--format-token-count total-tok)
                        (opencode-chat--format-token-count ctx-limit)
                        (opencode-chat--format-token-count remaining))
                 'read-only t))))
    ;; Bottom separator
    (opencode-ui--insert-separator)
    ;; Tag the whole footer so refresh-footer can find it
    (put-text-property footer-start (point) 'opencode-footer-info t)))

(defun opencode-chat--refresh-footer ()
  "Re-render just the footer info section (model, agent, tokens, context).
Finds the region tagged with `opencode-footer-info' and replaces it.
Preserves the inline todos overlay position: when the footer region is
deleted, any overlay starting at its end gets its start collapsed to the
deletion point.  After re-rendering, the overlay is moved back to the
correct position (end of the new footer)."
  (let* ((m-end (opencode-chat-message-messages-end))
         (inhibit-read-only t)
         (buffer-undo-list t)
         (start (when (and m-end (marker-position m-end))
                  (text-property-any (marker-position m-end) (point-max)
                                     'opencode-footer-info t))))
    (when start
      (let* ((end (next-single-property-change start 'opencode-footer-info nil (point-max)))
             ;; Remember if the inline todos overlay starts at the footer boundary
             (ov (opencode-chat--inline-todos-ov))
             (ov-adjacent (and ov (overlay-buffer ov)
                               (= (overlay-start ov) end))))
        (save-excursion
          (goto-char start)
          (delete-region start end)
          (opencode-chat--render-footer-info)
          ;; Fix up the inline todos overlay: after delete+re-insert its start
          ;; collapsed to the deletion point, now covering the new footer text.
          ;; Move it back to the end of the newly rendered footer.
          (when (and ov-adjacent (overlay-buffer ov))
            (move-overlay ov (point) (overlay-end ov))))))))

;;; --- Inline todo list ---

(defun opencode-chat--render-inline-todos (todos)
  "Render inline todo list for TODOS vector in the chat footer area.
Uses `opencode-todo--render-compact' for consistent rendering.
Wraps the rendered region in `(opencode-chat--inline-todos-ov)' for O(1)
find-and-replace by `opencode-chat--refresh-inline-todos'.
Only renders when TODOS is non-nil and non-empty."
  (when (and todos (> (length todos) 0))
    (let ((start (point)))
      (insert (propertize " Todos " 'face 'opencode-todo-table-header))
      (insert "\n")
      (opencode-todo--render-compact todos :indent " " :bar-width 10
                                         :max-content-len 60 :show-priority t)
      ;; Mark as read-only so input-content-end doesn't bleed into it
      (add-text-properties start (point) '(read-only t))
      ;; Track region with overlay for cheap refresh
      (when (opencode-chat--inline-todos-ov)
        (delete-overlay (opencode-chat--inline-todos-ov)))
      (opencode-chat--set-inline-todos-ov (make-overlay start (point)))
      (overlay-put (opencode-chat--inline-todos-ov) 'opencode-inline-todos t))))

(defun opencode-chat--refresh-inline-todos (todos)
  "Re-render the inline todo section with TODOS vector.
Uses the overlay `(opencode-chat--inline-todos-ov)' for O(1) lookup.
Deletes the old region and re-renders in place."
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (cond
     ;; Overlay exists — delete region, re-render in place
     ((and (opencode-chat--inline-todos-ov)
           (overlay-buffer (opencode-chat--inline-todos-ov)))
      (let ((start (overlay-start (opencode-chat--inline-todos-ov))))
        (save-excursion
          (delete-region start (overlay-end (opencode-chat--inline-todos-ov)))
          (delete-overlay (opencode-chat--inline-todos-ov))
          (opencode-chat--set-inline-todos-ov nil)
          (goto-char start)
          (opencode-chat--render-inline-todos todos))))
     ;; No overlay yet — insert after footer-info if todos exist
     ((and todos (> (length todos) 0))
      (let ((start (text-property-any
                    (marker-position (opencode-chat-message-messages-end))
                    (point-max) 'opencode-footer-info t)))
        (when start
          (let ((after-footer (next-single-property-change
                               start 'opencode-footer-info nil (point-max))))
            (save-excursion
              (goto-char after-footer)
              (opencode-chat--render-inline-todos todos)))))))))

(defun opencode-chat--render-input-area ()
  "Render the input area at the bottom of the chat buffer.
Now includes footer info section (model, agent, tokens, context) above input.
The separator and prompt are read-only; the space after the prompt
is editable; the help line below is read-only.
Uses `field' text properties so `kill-line' (C-k) naturally stops at the
boundary between the editable input and the surrounding read-only regions,
matching how eshell handles its prompt."
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    ;; Update notification (if available) -- displayed before footer
    (let ((notif-start (point)))
      (opencode-chat--render-update-notification)
      (when (> (point) notif-start)
        (opencode-chat--apply-message-props notif-start (point))))
    (opencode-chat-message-init-messages-end (point))

    (opencode-ui--insert-separator)
    (insert (propertize "> " 'face 'opencode-input-prompt
                        'read-only t
                        'field 'prompt
                        'keymap opencode-chat-message-map
                        'front-sticky '(read-only field)
                        'rear-nonsticky '(read-only field keymap face)))
    ;; Set input-start BEFORE the editable space so that
    ;; `input-content-start' can find the first non-read-only char.
    (when (opencode-chat--input-start)
      (set-marker (opencode-chat--input-start) nil))
    (opencode-chat--set-input-start (point-marker))
    ;; Editable input placeholder — this is where the user types.
    ;; The text-property `keymap' ensures our bindings (C-p, C-c C-c, etc.)
    ;; beat Evil state maps in keymap lookup priority.
    ;; No `field' property here — the editable area is the "default" field (nil),
    ;; so `line-beginning-position' and `line-end-position' are constrained to it.
    (insert (propertize " " 'face 'opencode-input-area
                        'opencode-input t
                        'keymap opencode-chat-input-map))

    ;; Post-input help line (read-only, no front-sticky so typing
    ;; at end of input line doesn't inherit read-only)
    (let ((post-start (point)))
      (insert "\n")
      (opencode-chat--render-footer-info)
      (opencode-chat--render-inline-todos (opencode-chat--inline-todos))
      (insert "\n")
      (opencode-chat--insert-shortcut "C-c C-c" "send")
      (insert "  ")
      (opencode-chat--insert-shortcut "C-c C-k" "abort")
      (insert "  ")
      (opencode-chat--insert-shortcut "C-c C-a" "attach")
      (insert "  ")
      (opencode-chat--insert-shortcut "TAB" "agent")
      (insert "  ")
      (opencode-chat--insert-shortcut "C-c g" "refresh")
      (insert "  ")
      (opencode-chat--insert-shortcut "C-c C-v" "image")
      (insert "\n")
      (add-text-properties post-start (point)
                           '(read-only t field footer)))
    (set-marker-insertion-type (opencode-chat-message-messages-end) t)))


;;; --- Input attachments ---

(defun opencode-chat--input-attachments ()
  "Extract mention and image data from chip overlays in the input area.
Returns a plist (:mentions MENTIONS :images IMAGES) where MENTIONS is
a list of plists with :type, :name, :path, :start, :end (positions
relative to the TRIMMED input text as returned by `opencode-chat--input-text'),
and IMAGES is a list of plists with :data-url, :mime, :filename.
Returns nil if input area is not set up."
  (when-let* ((input-start (opencode-chat--input-content-start))
              (input-end (opencode-chat--input-content-end)))
    ;; Compute the leading-whitespace offset so mention positions match the
    ;; trimmed text returned by `opencode-chat--input-text'.  The input area
    ;; always has a leading placeholder space (the editable " "), and users
    ;; may type additional whitespace.  `string-trim' in `input-text' strips
    ;; this, shifting all character positions leftward.
    (let* ((raw (buffer-substring-no-properties input-start input-end))
           (trimmed-start (if (string-match "\\`[ \t\n\r]+" raw)
                              (match-end 0)
                            0))
           (mentions nil)
           (images nil))
      (dolist (ov (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention))
                              (overlays-in input-start input-end)))
        (let ((meta (overlay-get ov 'opencode-mention))
              (img (overlay-get ov 'opencode-image-data)))
          (if img
              (push img images)
            (let ((rel-start (- (- (overlay-start ov) input-start) trimmed-start))
                  (rel-end (- (- (overlay-end ov) input-start) trimmed-start)))
              (push (list :type (plist-get meta :type)
                          :name (plist-get meta :name)
                          :path (plist-get meta :path)
                          :start rel-start
                          :end rel-end)
                    mentions)))))
      (list :mentions (nreverse mentions) :images (nreverse images)))))


;;; --- Clipboard image utilities ---

(defun opencode-chat--clipboard-image-bytes ()
  "Capture an image from the system clipboard.
Tries PNG first, then JPEG.  Only works in graphical Emacs sessions.
Returns a plist (:data BYTES :mime STRING) where BYTES is a unibyte string
and STRING is the MIME type (e.g. \"image/png\"), or nil if no image is found."
  (when (display-graphic-p)
    (or (when-let* ((data (gui-get-selection 'CLIPBOARD 'image/png)))
          (list :data data :mime "image/png"))
        (when-let* ((data (gui-get-selection 'CLIPBOARD 'image/jpeg)))
          (list :data data :mime "image/jpeg")))))

(defun opencode-chat--image-to-data-url (img)
  "Encode image plist IMG to a base64 data URL string.
IMG must be a plist with :data (unibyte string) and :mime (MIME type string).
Signals `user-error' if the image exceeds `opencode-chat-image-max-size'.
Uses `opencode--image-to-data-url' from opencode-util."
  (let ((data (plist-get img :data))
        (mime (plist-get img :mime)))
    (opencode--image-to-data-url data mime opencode-chat-image-max-size)))


;;; --- Chip overlay system ---

(defun opencode-chat--chip-create (start end type name &optional path image-data)
  "Create a mention chip overlay on region START..END.
TYPE is a symbol: `file', `agent', or `image'.
NAME is the display name (filename or agent name).
PATH is the absolute file path (for file mentions, nil for agents).
IMAGE-DATA, when non-nil, is a plist with :data-url, :mime, :filename
stored on the overlay for image chips."
  (let* ((agent-color (when (eq type 'agent)
                        (plist-get (opencode-agent--find-by-name name) :color)))
         (face (if (eq type 'file)
                   'opencode-mention-file
                 (opencode-chat--agent-chip-face agent-color)))
         (ov (make-overlay start end nil nil nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'cursor-intangible t)
    (overlay-put ov 'modification-hooks '(opencode-chat--chip-modification-hook))
    (overlay-put ov 'opencode-mention (list :type type :name name :path path))
    (overlay-put ov 'help-echo (or path name))
    (overlay-put ov 'rear-nonsticky '(cursor-intangible))
    (overlay-put ov 'evaporate t)
    (when image-data
      (overlay-put ov 'opencode-image-data image-data))
    ov))

(defun opencode-chat--chip-delete (ov)
  "Delete chip overlay OV and its underlying text atomically."
  (when (overlay-buffer ov)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region (overlay-start ov) (overlay-end ov))
      (delete-overlay ov))))

(defun opencode-chat--chip-modification-hook (ov after-p _beg _end &optional _len)
  "Overlay modification hook for chip OV.
When called before modification (AFTER-P nil), schedule chip deletion.
This ensures any edit attempt on chip text deletes the whole chip."
  (unless after-p
    (when (overlay-buffer ov)
      (run-with-timer 0 nil #'opencode-chat--chip-delete ov))))

(defun opencode-chat--chip-backspace ()
  "Delete the chip before point, or fall back to normal backspace.
If the character before point is the end of a mention chip overlay,
delete the entire chip.  Otherwise, delete one character backward."
  (interactive)
  (let ((chip-ov (and (> (point) (point-min))
                      (when-let* ((start (opencode-chat--input-content-start)))
                        (>= (point) start))
                      (seq-find (lambda (ov) (overlay-get ov 'opencode-mention))
                                (overlays-at (1- (point)))))))
    (if chip-ov
        (opencode-chat--chip-delete chip-ov)
      (call-interactively #'backward-delete-char-untabify))))


;;; --- @-mention completion-at-point ---

(defun opencode-chat--search-backward-at-sign (limit)
  "Search backward for `@' that is NOT inside a chip overlay.
Starts from point and searches back to LIMIT.
Returns the position of the `@' character, or nil if not found.
Skips positions covered by an `opencode-mention' overlay (existing chips)."
  (save-excursion
    (let ((pos (point))
          (found nil))
      (while (and (not found)
                  (setq pos (search-backward "@" limit t)))
        (if (seq-find (lambda (ov) (overlay-get ov 'opencode-mention))
                      (overlays-at pos))
            ;; This @ is inside a chip — keep searching backward
            nil
          (setq found pos)))
      found)))

(defun opencode-chat--mention-annotate (candidate)
  "Return annotation string for mention CANDIDATE.
Shows type indicator: file, folder, or agent."
  (let ((type (get-text-property 0 'opencode-mention-type candidate)))
    (pcase type
      ('agent  " \U0001F916 agent")
      ('folder " \U0001F4C1 folder")
      (_       " \U0001F4C4 file"))))

(defun opencode-chat--mention-fuzzy-match-p (input candidate)
  "Return non-nil if INPUT fuzzy-matches CANDIDATE.
Path-aware: splits INPUT on `/' and matches each segment against
CANDIDATE's corresponding tail.  For example:
  \"this/file.txt\" matches \"this/is/a/longlongpath/file.txt\"
  because segment \"this\" matches the first path component and
  segment \"file.txt\" matches a later component.

Within each segment, uses scattered-substring matching: every
character of the input segment must appear in order in the
candidate segment (but not necessarily contiguously).  For example:
  \"thislngtxt\" matches \"this/is/a/longlongpath/file.txt\"
  because t,h,i,s,l,n,g,t,x,t appear in order in the full path.

Empty INPUT matches everything."
  (if (string-empty-p input)
      t
    (if (string-search "/" input)
        ;; Path-segment mode: each input segment must match some
        ;; candidate segment in order (with gaps allowed).
        (let* ((in-segs (split-string input "/" t))
               (cand-segs (split-string candidate "/" t))
               (ci 0)  ; index into cand-segs
               (ok t))
          (dolist (iseg in-segs)
            (when ok
              (let ((found nil))
                (while (and (not found) (< ci (length cand-segs)))
                  (when (opencode-chat--fuzzy-substr-p iseg (nth ci cand-segs))
                    (setq found t))
                  (setq ci (1+ ci)))
                (unless found (setq ok nil)))))
          ok)
      ;; Single-segment mode: scattered substring across full candidate
      (opencode-chat--fuzzy-substr-p input candidate))))

(defun opencode-chat--fuzzy-substr-p (input candidate)
  "Return non-nil if every char of INPUT appears in CANDIDATE in order.
Case-insensitive.  INPUT and CANDIDATE are strings."
  (let ((il (length input))
        (cl (length candidate))
        (ii 0)
        (ci 0))
    (while (and (< ii il) (< ci cl))
      (when (char-equal (downcase (aref input ii))
                        (downcase (aref candidate ci)))
        (setq ii (1+ ii)))
      (setq ci (1+ ci)))
    (= ii il)))

(defun opencode-chat--mention-fuzzy-score (input candidate)
  "Return a numeric score for how well INPUT matches CANDIDATE.
Higher is better.  Returns nil if no match.
Scoring heuristics (descending priority):
  - Exact prefix match (highest)
  - Path-segment anchored matches (each segment starts at boundary)
  - Contiguous substring match
  - Scattered match (lowest, proportional to tightness)"
  (when (opencode-chat--mention-fuzzy-match-p input candidate)
    (let ((input-down (downcase input))
          (cand-down (downcase candidate)))
      (cond
       ;; Exact prefix
       ((string-prefix-p input-down cand-down)
        (+ 1000 (- 200 (min 200 (length candidate)))))
       ;; Contiguous substring anywhere
       ((string-search input-down cand-down)
        (+ 500 (- 200 (min 200 (length candidate)))))
       ;; Scattered match — score by how tight the match span is
       (t
        (let* ((il (length input-down))
               (cl (length cand-down))
               (ii 0) (ci 0) (first-ci nil) (last-ci 0))
          (while (and (< ii il) (< ci cl))
            (when (char-equal (aref input-down ii) (aref cand-down ci))
              (unless first-ci (setq first-ci ci))
              (setq last-ci ci)
              (setq ii (1+ ii)))
            (setq ci (1+ ci)))
          (if (= ii il)
              (let ((span (1+ (- last-ci (or first-ci 0)))))
                ;; Tighter span → higher score; shorter candidate → higher
                (max 1 (- 300
                         (min 200 (- span il))
                         (min 50 (/ (length candidate) 4)))))
            0)))))))

(defun opencode-chat--mention-completion-table (candidates)
  "Return a programmatic completion table for mention CANDIDATES.
Uses built-in fuzzy matching so `@thislngtxt' or `@this/file.txt'
find `this/is/a/longlongpath/file.txt' regardless of the user's
`completion-styles' configuration.

The table responds to the `metadata' action with an `opencode-mention'
category and annotation function.  For the `t' action (all-completions)
it returns candidates sorted by fuzzy score.  For the `nil' action
\(try-completion) it returns the best match or t."
  (lambda (string pred action)
    (pcase action
      ('metadata
       '(metadata
         (category . opencode-mention)
         (annotation-function . opencode-chat--mention-annotate)
         (cycle-sort-function . identity)
         (display-sort-function . identity)))
      ('t
       ;; All completions: fuzzy filter + sort by score (descending)
       (let* ((all (if (or (string-prefix-p "." string)
                           (string-prefix-p "/" string))
                       (append candidates
                               (opencode-chat--filesystem-candidates string))
                     candidates))
              (scored nil))
         (dolist (c all)
           (when (or (null pred) (funcall pred c))
             (when-let* ((score (opencode-chat--mention-fuzzy-score string c)))
               (push (cons score c) scored))))
         (mapcar #'cdr (sort scored (lambda (a b) (> (car a) (car b)))))))
      ('nil
       ;; Try completion: return longest common prefix or t
       (let* ((all (if (or (string-prefix-p "." string)
                           (string-prefix-p "/" string))
                       (append candidates
                               (opencode-chat--filesystem-candidates string))
                     candidates))
              (matches (cl-remove-if-not
                        (lambda (c)
                          (and (or (null pred) (funcall pred c))
                               (opencode-chat--mention-fuzzy-match-p string c)))
                        all)))
         (cond
          ((null matches) nil)
          ((= (length matches) 1)
           (if (string= string (car matches)) t (car matches)))
          (t
           ;; Multiple matches — return string itself (no expansion)
           ;; This tells the framework "yes there are matches, show them"
           (if (member string matches) t string)))))
      ('lambda
       ;; Test completion: does string exactly match a candidate?
       (let ((all (if (or (string-prefix-p "." string)
                          (string-prefix-p "/" string))
                      (append candidates
                              (opencode-chat--filesystem-candidates string))
                    candidates)))
         (and (member string all) t)))
      (_
       ;; Unknown action — delegate to default
       (let ((all (if (or (string-prefix-p "." string)
                          (string-prefix-p "/" string))
                      (append candidates
                              (opencode-chat--filesystem-candidates string))
                    candidates)))
         (complete-with-action action all string pred))))))

(defun opencode-chat--filesystem-candidates (prefix)
  "Generate filesystem candidates for PREFIX.
Handles paths starting with `./', `../', or `/' (absolute).
Lists files and directories from the resolved directory.
Each directory candidate has `opencode-mention-type' text property
set to `folder'."
  (condition-case err
      (let* ((root (or (when (project-current) (project-root (project-current)))
                       default-directory))
             (dir-part (or (file-name-directory prefix)
                          (if (string-prefix-p "/" prefix) "/" "./")))
             (abs-dir (if (file-name-absolute-p dir-part)
                         dir-part
                       (expand-file-name dir-part root)))
             (entries nil))
        (when (file-directory-p abs-dir)
          (dolist (entry (directory-files abs-dir nil))
            (unless (member entry '("." ".."))
              (let* ((full (expand-file-name entry abs-dir))
                     (is-dir (file-directory-p full))
                     (rel (concat dir-part entry (when is-dir "/"))))
                (if is-dir
                    (let ((s (copy-sequence rel)))
                      (put-text-property 0 (length s)
                                         'opencode-mention-type 'folder s)
                      (push s entries))
                  (push rel entries))))))
        (nreverse entries))
    (error (opencode--debug "opencode-chat: file completion error: %S" err))))

(defun opencode-chat--mention-type-for-name (name)
  "Return mention type symbol for NAME by checking the agent cache.
Completion frameworks may strip text properties from the selected
candidate, so this provides a reliable fallback.  Returns `agent'
if NAME matches a cached agent, `folder' if NAME ends with `/',
or nil (caller should default to `file')."
  (cond
   ;; Check agent cache
   ((let ((agents (opencode-agent--list)))
      (and (vectorp agents)
           (seq-find (lambda (a) (string= (plist-get a :name) name))
                     agents)))
    'agent)
   ;; Trailing / means folder
   ((string-suffix-p "/" name) 'folder)))

(defun opencode-chat--mention-exit (candidate status)
  "Create a chip overlay after CANDIDATE is selected.
STATUS is the completion status; we only act on `finished'.
Folder candidates are converted to `file' type for the API,
with the path ending in `/' and filename without trailing `/'."
  (opencode--debug "mention-exit: candidate=%S status=%S point=%d props=%S"
                   candidate status (point)
                   (get-text-property 0 'opencode-mention-type candidate))
  (when (eq status 'finished)
    (let* ((prop-type (get-text-property 0 'opencode-mention-type candidate))
           ;; Completion may strip text properties; fall back to agent
           ;; cache lookup when property is missing.
           (raw-type (or prop-type
                         (opencode-chat--mention-type-for-name
                          (substring-no-properties candidate))
                         'file))
           (raw-name (substring-no-properties candidate))
           ;; For folders: strip trailing / from display name
           (name (if (eq raw-type 'folder)
                     (directory-file-name raw-name)
                   raw-name))
           ;; Find the @ that started this completion.
           ;; Use input-start as limit (not candidate length) because
           ;; some completion frameworks insert extra text (e.g. agent
           ;; descriptions) making (point) much further than expected.
           (start (opencode-chat--search-backward-at-sign
                    (opencode-chat--input-content-start)))
           ;; Calculate chip end from start, not (point).  Completion
           ;; frameworks may insert annotation/description text after
           ;; the candidate; we must only cover @candidate.
           (chip-end (when start (+ start 1 (length raw-name))))
           ;; For API: folders are sent as 'file type
           (type (if (eq raw-type 'folder) 'file raw-type))
           (path (when (memq raw-type '(file folder))
                   (let ((base (or (when (project-current)
                                     (project-root (project-current)))
                                   default-directory)))
                     (if (eq raw-type 'folder)
                         (file-name-as-directory
                          (expand-file-name raw-name base))
                       (expand-file-name raw-name base))))))
      (opencode--debug "mention-exit: raw-type=%S start=%S chip-end=%S point=%d buf=%S"
                       raw-type start chip-end (point)
                       (buffer-substring-no-properties
                        (max (point-min)
                             (- (point) (min 40 (- (point) (point-min)))))
                        (point)))
      (if start
          (progn
            ;; Delete any extra text between chip-end and point that the
            ;; completion framework may have inserted (e.g. descriptions).
            (when (> (point) chip-end)
              (opencode--debug "mention-exit: deleting extra text [%d..%d]=%S"
                               chip-end (point)
                               (buffer-substring-no-properties chip-end (point)))
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t))
                (delete-region chip-end (point))))
            (opencode-chat--chip-create start chip-end type name path))
        (opencode--debug "mention-exit: FAILED -- @ not found, no chip created")))))

(defun opencode-chat--mention-candidates ()
  "Build the list of @-mention candidates.
Merges project files, directories, and agent names into a single list.
File candidates are plain strings.  Directory candidates have the
text property opencode-mention-type set to the symbol folder.
Agent candidates have it set to the symbol agent."
  ;; Return cached candidates if still fresh
  (or (when-let* ((cache (opencode-chat--mention-cache))
                  (tick (car cache))
                  (_ (< (- (float-time) tick) opencode-chat--mention-cache-ttl)))
        (cdr cache))
      (let ((candidates nil))
        ;; Files and directories from project
        (condition-case err
            (when-let* ((proj (project-current))
                        (root (project-root proj))
                        (files (project-files proj)))
              ;; Add file candidates
              (dolist (f files)
                (push (file-relative-name f root) candidates))
              ;; Extract unique directories from file paths
              (let ((dirs (make-hash-table :test 'equal)))
                (dolist (f files)
                  (let ((dir (file-name-directory (file-relative-name f root))))
                    (while dir
                      (unless (gethash dir dirs)
                        (puthash dir t dirs))
                      (let ((parent (directory-file-name dir)))
                        (setq dir (if (string= parent dir) nil
                                    (file-name-directory parent)))))))
                ;; Also scan top-level entries from filesystem (catches dirs
                ;; not represented in project-files, e.g. .github/)
                (condition-case err
                    (dolist (entry (directory-files root nil))
                      (unless (member entry '("." ".."))
                        (when (file-directory-p (expand-file-name entry root))
                          (puthash (file-name-as-directory entry) t dirs))))
                  (error (opencode--debug "opencode-chat: directory scan error: %S" err)))
                ;; Create folder candidates with text property
                (maphash (lambda (dir _)
                           (let ((s (copy-sequence dir)))
                             (put-text-property 0 (length s)
                                                'opencode-mention-type 'folder s)
                             (push s candidates)))
                         dirs)))
          (error (opencode--debug "opencode-chat: mention candidates error: %S" err)))
        ;; Agents from cache
        (condition-case err
            (let ((agents (opencode-agent--list)))
              (when (vectorp agents)
                (seq-doseq (agent agents)
                  (let ((name (plist-get agent :name))
                        (hidden (plist-get agent :hidden)))
                    (unless (eq hidden t)
                      (let ((s (copy-sequence name)))
                        (put-text-property 0 (length s) 'opencode-mention-type 'agent s)
                        (push s candidates)))))))
          (error (opencode--debug "opencode-chat: agent candidates error: %S" err)))
        (let ((result (nreverse candidates)))
          (opencode-chat--set-mention-cache (cons (float-time) result))
          result))))

(defun opencode-chat--mention-capf ()
  "Completion-at-point function for @-mentions in the input area.
Triggers when `@' is preceded by whitespace or is at the start of input.
Completes file names from the current project and agent names from cache.
Returns (START END COLLECTION . PROPS) or nil."
  (when-let* ((input-start (opencode-chat--input-content-start))
              (_ (>= (point) input-start)))
    (let* ((line-start (opencode-chat--search-backward-at-sign input-start)))
      (when line-start
        ;; Verify @ is preceded by whitespace or is at input start
        (let ((before-at (1- line-start)))
          (when (or (= line-start input-start)
                    (and (>= before-at input-start)
                         (memq (char-after before-at) '(?\s ?\t ?\n))))
            ;; Agent names may contain spaces (e.g. "Prometheus (Plan Builder)"),
            ;; so we cannot reject prefixes with spaces.  The completion table
            ;; already filters non-matching input; :exclusive 'no lets other
            ;; CAPFs run when nothing matches.
            (let* ((prefix-start (1+ line-start))  ; after the @
                   (candidates (opencode-chat--mention-candidates))
                   (table (opencode-chat--mention-completion-table candidates)))
              (list prefix-start (point) table
                    :exit-function #'opencode-chat--mention-exit
                    :exclusive 'no))))))))


;;; --- Slash command completion-at-point ---

(defun opencode-chat--slash-annotate (candidate)
  "Return annotation string for slash-command CANDIDATE.
Looks up the description from the commands cache and returns
a dash-separated string, or nil if no description is found."
  (let ((commands (opencode-config--commands)))
    (when (vectorp commands)
      (let ((desc nil))
        (seq-doseq (cmd commands)
          (when (and (null desc)
                     (string= (plist-get cmd :name) candidate))
            (setq desc (plist-get cmd :description))))
        (when desc
          (concat " \u2014 " (replace-regexp-in-string "[\n\r]+" " " desc)))))))

(defun opencode-chat--slash-completion-table (names)
  "Return a programmatic completion table for command NAMES.
The table responds to the `metadata' action with an `opencode-command'
category and `opencode-chat--slash-annotate' annotation function, so
completion frontends (vertico, corfu, company) and
`completion-styles' can handle matching.  Users can customise
per-category styles via `completion-category-overrides'."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata
          (category . opencode-command)
          (annotation-function . opencode-chat--slash-annotate))
      (complete-with-action action names string pred))))

(defun opencode-chat--slash-capf ()
  "Completion-at-point function for slash commands in the input area.
Triggers when \"/\" is the first non-whitespace character of the input
\(optionally preceded by spaces/tabs) and there is no space between
the \"/\" and point.  This ensures completion fires for pure slash
commands like \"/start-work\" or \"  /start-work\", but not for
mid-sentence mentions like \"hello /start-work\".
Completes command names from `opencode-config--command-names'.
Returns (START END COLLECTION . PROPS) or nil."
  (when-let* ((start (opencode-chat--input-content-start))
              (_ (>= (point) start)))
    (let* ((first-nonws (save-excursion
                          (goto-char start)
                          (skip-chars-forward " \t")
                          (point))))
      ;; Only trigger if "/" is the first non-whitespace character
      (when (and (< first-nonws (point-max))
                 (eq (char-after first-nonws) ?/)
                 ;; Point must be after the "/"
                 (> (point) first-nonws)
                 ;; No space between "/" and point (still typing command name)
                 (not (string-search
                       " "
                       (buffer-substring-no-properties (1+ first-nonws) (point)))))
        (let* ((cmd-start (1+ first-nonws))
               (cmd-end (point))
               (names (opencode-config--command-names))
               (table (opencode-chat--slash-completion-table names)))
          (list cmd-start cmd-end table
                :exclusive 'no))))))


;;; --- Clipboard image paste ---

(defun opencode-chat--paste-image ()
  "Capture a clipboard image and insert it as a chip in the input area.
Guards that point is in the input area.  Reads PNG then JPEG.
Encodes the image as a base64 data URL and creates a chip overlay."
  (interactive)
  (when-let* ((input-start (opencode-chat--input-content-start)))
    (unless (>= (point) input-start)
      (user-error "Point must be in the input area"))
    (let* ((img (opencode-chat--clipboard-image-bytes)))
      (unless img
        (user-error "No image found in clipboard"))
      (let* ((data-url (opencode-chat--image-to-data-url img))
             (mime (plist-get img :mime))
             (filename (opencode--image-filename mime))
             (chip-start (point))
             (img-data (list :data-url data-url :mime mime :filename filename)))
        (insert filename)
        (opencode-chat--chip-create chip-start (point) 'image filename nil img-data)))))

(defun opencode-chat--attach ()
  "Insert @ and trigger mention completion for files and agents."
  (interactive)
  (when-let* ((input-start (opencode-chat--input-content-start)))
    (unless (>= (point) input-start)
      (user-error "Point must be in the input area"))
    (insert "@")
    (completion-at-point)))


;;; --- Input history ---

(defun opencode-chat--input-history-init ()
  "Initialize the input history ring if not already created."
  (unless (opencode-chat--input-history)
    (opencode-chat--set-input-history
          (make-ring opencode-chat-input-history-size))))

(defun opencode-chat--input-history-push (text)
  "Add TEXT to the input history ring.
Skips empty strings and duplicates of the most recent entry."
  (opencode-chat--input-history-init)
  (when (and text (not (string-empty-p text)))
    (when (or (ring-empty-p (opencode-chat--input-history))
              (not (string= text (ring-ref (opencode-chat--input-history) 0))))
      (ring-insert (opencode-chat--input-history) text)))
  ;; Reset browsing state
  (opencode-chat--set-input-history-index nil)
  (opencode-chat--set-input-history-saved nil))

(defun opencode-chat--input-history-seed ()
  "Seed input history from user messages in the message store.
Extracts text parts from user messages (oldest first) and pushes them
into the ring.  Called after `render-messages' so the store is populated.
Skips if the ring already has entries (re-render)."
  (opencode-chat--input-history-init)
  (when (ring-empty-p (opencode-chat--input-history))
    (dolist (msg-id (opencode-chat-message-sorted-ids))
      (when-let* ((info (opencode-chat-message-info msg-id))
                  ((equal (plist-get info :role) "user"))
                  (parts (opencode-chat-message-parts msg-id)))
        (seq-doseq (part (if (vectorp parts) parts (vconcat parts)))
          (when (equal (plist-get part :type) "text")
            (let ((text (plist-get part :text)))
              (opencode-chat--input-history-push text))))))))

(defun opencode-chat--input-history-replace (text)
  "Replace the current input area content with TEXT."
  (let ((start (opencode-chat--input-content-start))
        (end (opencode-chat--input-content-end)))
    (when (and start end)
      (let ((inhibit-read-only t))
        (save-excursion
          (delete-region start end)
          (goto-char start)
          (insert text))
        (goto-char (+ start (length text)))))))

(defun opencode-chat--input-history-prev ()
  "Replace input with the previous (older) history entry.
On first invocation, saves the current input so it can be restored."
  (interactive)
  (opencode-chat--input-history-init)
  (when (ring-empty-p (opencode-chat--input-history))
    (user-error "No input history"))
  (let ((len (ring-length (opencode-chat--input-history)))
        (idx (or (opencode-chat--input-history-index) -1)))
    (when (>= (1+ idx) len)
      (user-error "End of input history"))
    ;; Save current input on first browse
    (when (null (opencode-chat--input-history-index))
      (opencode-chat--set-input-history-saved
            (or (opencode-chat--input-text) "")))
    (opencode-chat--set-input-history-index (1+ idx))
    (opencode-chat--input-history-replace
     (ring-ref (opencode-chat--input-history) (opencode-chat--input-history-index)))))

(defun opencode-chat--input-history-next ()
  "Replace input with the next (newer) history entry.
When past the newest entry, restores the saved input from before browsing."
  (interactive)
  (unless (opencode-chat--input-history-index)
    (user-error "Not browsing history"))
  (let ((idx (1- (opencode-chat--input-history-index))))
    (if (< idx 0)
        ;; Back to live input
        (progn
          (opencode-chat--input-history-replace
           (or (opencode-chat--input-history-saved) ""))
          (opencode-chat--set-input-history-index nil)
          (opencode-chat--set-input-history-saved nil))
      (opencode-chat--set-input-history-index idx)
      (opencode-chat--input-history-replace
       (ring-ref (opencode-chat--input-history) (opencode-chat--input-history-index))))))


;;; --- Interactive commands ---

(defun opencode-chat--parse-slash-command (text)
  "Parse TEXT \"/name arg1 arg2...\" into (NAME . ARGUMENTS-OR-NIL).
ARGUMENTS is the trimmed tail or nil if no args.  Assumes TEXT begins
with \"/\" — caller guards via `string-prefix-p'."
  (let* ((rest (substring text 1))
         (parts (split-string rest " " t)))
    (cons (car parts)
          (when (cdr parts)
            (string-trim (string-join (cdr parts) " "))))))

(defun opencode-chat--send-slash-command (text session-id)
  "Execute slash-command TEXT via POST /session/:id/command for SESSION-ID.
The command's agent (if defined) takes precedence over the buffer's
effective agent; model and variant always come from the buffer."
  (pcase-let* ((`(,command . ,arguments) (opencode-chat--parse-slash-command text))
               (cmd-def (opencode-config--find-command command))
               (cmd-agent (when cmd-def (plist-get cmd-def :agent)))
               (agent (or cmd-agent (opencode-chat--effective-agent)))
               (m (opencode-chat--effective-model))
               (model (when (and (plist-get m :providerID) (plist-get m :modelID))
                        (format "%s/%s"
                                (plist-get m :providerID)
                                (plist-get m :modelID))))
               (variant (opencode-chat--effective-variant)))
    (opencode--debug "opencode-chat: executing command /%s args=%S cmd-agent=%S agent=%s model=%s variant=%s sid=%s"
                     command arguments cmd-agent agent model variant session-id)
    (opencode-config-execute-command session-id command arguments agent model variant)))

(defun opencode-chat--send-prompt (text session-id new-msg-id mentions images)
  "Send TEXT as a prompt_async message for SESSION-ID.
NEW-MSG-ID is the optimistically-rendered message's ID.  MENTIONS
and IMAGES come from the input-area attachments.  Adds
`buffer-file-name' + active-region selection as `:context' when
present."
  (let* ((agent (opencode-chat--effective-agent))
         (model (opencode-chat--effective-model))
         (context (when (buffer-file-name)
                    (let ((ctx (list :filename (buffer-file-name))))
                      (when (and (use-region-p) (not (eq (point) (mark))))
                        (let ((start (min (point) (mark)))
                              (end (max (point) (mark))))
                          (setq ctx (plist-put ctx :selection
                                               (buffer-substring-no-properties start end)))))
                      ctx)))
         (prompt-body (opencode-api--prompt-body
                       text agent
                       (plist-get model :modelID)
                       (plist-get model :providerID)
                       (opencode-chat--effective-variant)
                       mentions images new-msg-id context)))
    (opencode--debug "opencode-chat: sending prompt_async sid=%s body=%S"
                     session-id prompt-body)
    (opencode-api-post
     (format "/session/%s/prompt_async" session-id)
     prompt-body
     (lambda (response)
       (opencode--debug "opencode-chat: prompt_async callback status=%s body=%S"
                        (plist-get response :status)
                        (plist-get response :body))
       ;; Response and state handled via SSE events + hooks
       nil))
    (message "Sent")))

(defun opencode-chat--send (&optional text-override)
  "Send the current input as a message.
If TEXT-OVERRIDE is non-nil, use it instead of reading from the input area.
If the input starts with \"/\", route via `--send-slash-command' (POST
/session/:id/command).  Otherwise send via `--send-prompt' (prompt_async)."
  (interactive)
  (unless (opencode-chat--session-id)
    (user-error "Buffer is not a opencode chat buffer"))
  (let* ((text (or text-override (opencode-chat--input-text)))
         (attachments (unless text-override (opencode-chat--input-attachments)))
         (mentions (plist-get attachments :mentions))
         (images (plist-get attachments :images))
         (new-msg-id (opencode-util--generate-id "msg"))
         (session-id (opencode-chat--session-id)))
    (when (and (or (null text) (string-empty-p text))
               (null images))
      (user-error "Nothing to send"))
    ;; Push to input history before clearing
    (unless text-override
      (opencode-chat--input-history-push text)
      (opencode-chat--clear-input))
    ;; Optimistic user-message insert
    (let* ((inhibit-read-only t)
           (now (* (float-time) 1000)))
      (opencode-chat-message-upsert
       new-msg-id
       `(:id ,new-msg-id
         :time (:created ,now)
         :role "user"
         :parts ((:sessionID ,session-id
                  :messageID ,new-msg-id
                  :id ,new-msg-id
                  :type "text"
                  :text ,text
                  :time (:start ,now :end ,now)))))
      (opencode-chat--set-optimistic-msg-id new-msg-id)
      ;; Reset undo — the sent message and cleared input must not be
      ;; undoable.  Without this, C-/ after send would reverse the
      ;; optimistic insert and resurrect the input text.
      (setq buffer-undo-list nil))
    ;; Dispatch by leading slash
    (if (string-prefix-p "/" text)
        (opencode-chat--send-slash-command text session-id)
      (opencode-chat--send-prompt text session-id new-msg-id mentions images))
    (run-hook-with-args 'opencode-chat-on-message-sent-hook
                        (list :text text
                              :session-id session-id
                              :message-id new-msg-id
                              :mentions mentions
                              :images images)))
  (opencode-chat--drain-popup-queue)
  ;; Move cursor to editable input position (after "> " prompt)
  (when-let* ((start (opencode-chat--input-content-start)))
    (goto-char start)))

(defun opencode-chat-abort ()
  "Abort the current generation."
  (interactive)
  (when (opencode-chat--session-id)
    (condition-case err
        (progn
          (opencode-session-abort (opencode-chat--session-id))
          ;; State cleanup (busy/queued) handled by session.idle/error SSE
          (message "Aborted"))
      (error (message "Abort failed: %s" (error-message-string err))))))

(defun opencode-chat--do-cycle-agent (delta)
  "Cycle agent by DELTA steps (1=forward, -1=backward) and update state."
  (let ((new-agent (opencode-agent--cycle (opencode-chat--effective-agent) delta)))
    (when new-agent
      (opencode-chat--set-agent new-agent)
      (opencode-chat--set-agent-color
       (plist-get (opencode-agent--find-by-name new-agent) :color))
      (opencode-chat--refresh-footer)
      (message "Agent: %s" new-agent))))

(defun opencode-chat--cycle-agent ()
  "Cycle forward through available agents."
  (interactive)
  (opencode-chat--do-cycle-agent 1))

(defun opencode-chat--cycle-agent-backward ()
  "Cycle backward through available agents."
  (interactive)
  (opencode-chat--do-cycle-agent -1))

(defun opencode-chat--cycle-variant ()
  "Cycle through available model variants (e.g. default, max).
The variant list comes from the current model's provider config.
Cycles: nil → first → second → ... → nil (back to default)."
  (interactive)
  (let* ((model (opencode-chat--effective-model))
         (provider-id (plist-get model :providerID))
         (model-id (plist-get model :modelID))
         (keys (opencode-config--variant-keys provider-id model-id)))
    (if (null keys)
        (message "No variants available for %s" (or model-id "unknown"))
      ;; Cycle: nil → first → second → ... → nil
      (let* ((current (opencode-chat--effective-variant))
             (pos (when current (seq-position keys current #'string=)))
             (next (cond
                    ((null current) (car keys))
                    ((or (null pos) (= pos (1- (length keys)))) nil)
                    (t (nth (1+ pos) keys)))))
        (opencode-chat--set-variant next)
        (opencode-chat--refresh-footer)
        (message "Variant: %s" (or next "default"))))))

(provide 'opencode-chat-input)
;;; opencode-chat-input.el ends here
