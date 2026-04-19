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
(require 'opencode-api)
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
(defvar opencode-chat-streaming-fontify-delay)

;;; --- File path keymap (for edit tool sections) ---

(defun opencode-chat-message--estimate-line-number ()
  "Estimate the file line number at point from diff context.
Searches backward for an @@ hunk header and counts lines forward.
Returns a line number or nil."
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
          (+ hunk-line offset))))))

(defun opencode-chat-message-open-file-at-point ()
  "Open the file at point, using `opencode-file-path' text property.
If the file is already displayed in a window, switch to that window.
Estimates the line number from surrounding diff hunk context."
  (interactive)
  (let ((path (get-text-property (point) 'opencode-file-path))
        (line (opencode-chat-message--estimate-line-number)))
    (if path
        (let ((abs-path (expand-file-name path)))
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
            (user-error "File not found: %s" abs-path)))
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

(declare-function opencode-chat--schedule-refresh "opencode-chat" ())
(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))

;;; --- Internal state ---

;; `--store', `--diff-cache', `--diff-shown' all live in the
;; `opencode-chat-state' struct; the defvar-locals here were removed in
;; the Step 5 struct migration (2026-04-18).  Access them through
;; (opencode-chat--store), (opencode-chat--diff-cache),
;; (opencode-chat--diff-shown) — readers — and `opencode-chat--set-store'
;; / `--set-diff-cache' / `--set-diff-shown' — writers.

;; The six slots formerly declared here — current-message-id,
;; streaming-part-id / msg-id / fontify-timer / region-start,
;; messages-end — now live in the `opencode-chat-state' struct.  Reads
;; go through the generated `opencode-chat--SLOT' functions, writes
;; through `opencode-chat--set-SLOT'.

;; Tool renderer registry (`opencode-chat--tool-renderers'),
;; `opencode-chat-register-tool-renderer', tool input-summary helpers,
;; and all built-in body renderers (bash, read/write, grep/glob, task,
;; edit, todowrite) have moved to `opencode-tool-render.el'.  Dispatch
;; goes through `opencode-chat--render-tool-body-dispatch'; collapse
;; heuristics consult `opencode-chat--builtin-tool-p'.

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
this is the input to rendering, not the rendered parts' markers."
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

(defun opencode-chat--store-part-marker (msg-id part-id)
  "Return the marker for PART-ID in MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-get info :marker)))

(defun opencode-chat--store-part-type (msg-id part-id)
  "Return the type string for PART-ID in MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id))
              (parts (plist-get entry :parts))
              (info (gethash part-id parts)))
    (plist-get info :type)))

(defun opencode-chat--store-set-part (msg-id part-id type marker)
  "Register PART-ID under MSG-ID with TYPE and MARKER.
Frees any previous marker for this part."
  (let* ((entry (opencode-chat--store-ensure msg-id))
         (parts (plist-get entry :parts)))
    (when-let* ((old (gethash part-id parts))
                (m (plist-get old :marker)))
      (when (markerp m) (set-marker m nil)))
    (puthash part-id (list :type type :marker marker) parts)))

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
   ;; Fallback: buffer scan
   (let ((found nil))
     (dolist (ov (overlays-in (point-min) (point-max)))
       (let ((sec (overlay-get ov 'opencode-section)))
         (when (and sec (equal (plist-get sec :id) id))
           (setq found ov))))
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
  "Free all markers and clear the store."
  (maphash (lambda (_msg-id entry)
             (when-let* ((parts (plist-get entry :parts)))
               (maphash (lambda (_part-id info)
                          (when-let* ((m (plist-get info :marker)))
                            (when (markerp m) (set-marker m nil))))
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

(defun opencode-chat--clear-streaming-state ()
  "Clear all streaming-related buffer-local state.
Cancels fontify timer, frees streaming markers, and clears parts hash."
  (when-let* ((timer (opencode-chat--streaming-fontify-timer)))
    (cancel-timer timer)
    (opencode-chat--set-streaming-fontify-timer nil))
  (when-let* ((region-start (opencode-chat--streaming-region-start)))
    (set-marker region-start nil))
  (opencode-chat--set-streaming-part-id nil)
  (opencode-chat--set-streaming-msg-id nil)
  (opencode-chat--set-streaming-region-start nil)
  ;; streaming-assistant-info is kept in chat.el for SSE routing.
  )

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
        (part-id (plist-get part :id)))
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
    ;; Track part position for streaming updates.
    ;; Text/reasoning markers start with insertion type nil so that tool
    ;; parts inserted at the same position (via `message-insert-pos')
    ;; don't push the marker forward.  The marker is switched to type t
    ;; on the first streaming delta (in `append-delta'), so subsequent
    ;; deltas correctly advance it.  Non-text markers use type t directly
    ;; since they are not streaming targets.
    (when-let* ((part-id part-id)
                (cur-msg-id (opencode-chat--current-message-id)))
      (let ((insertion-type (not (member type '("text" "reasoning")))))
        (opencode-chat--store-set-part
         cur-msg-id part-id
         type (copy-marker (point) insertion-type))))))

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
      (let* ((stripe (propertize opencode--stripe-char 'face block-face))
             (part-start (point))
             ;; Build the entire text block as one string with space-prefixed lines
             (prefixed (mapconcat (lambda (l) (concat " " l))
                                  (string-lines text) "\n")))
        (insert (propertize prefixed 'face body-face))
        ;; Single property call for the entire block
        (put-text-property part-start (point) 'line-prefix stripe)
        ;; Trailing newline: omit only for unfinished (streaming) parts
        (unless unfinished-p
          (insert "\n"))
        ;; Fontify markdown in assistant text parts (not during streaming)
        (when (eq role 'assistant)
          (opencode-markdown-fontify-region part-start (point)))))))

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
         (section (opencode-ui--make-section 'subtask
                                             (plist-get part :id)
                                             part))
         (section-ov
          (opencode-ui--with-section section
            ;; Header line
            (let ((header-start (point)))
              (insert " ")
              (opencode-ui--insert-icon 'collapsed)
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
              (let ((body-start (point))
                    (prefixed (mapconcat (lambda (l) (concat " " l))
                                        (string-lines prompt) "\n")))
                (insert (propertize prefixed 'face 'default))
                (insert "\n")
                (put-text-property body-start (point) 'line-prefix stripe)
                (opencode-markdown-fontify-region body-start (point)))))))
    ;; Collapse by default
    (when section-ov
      (let* ((start (overlay-start section-ov))
             (end (overlay-end section-ov))
             (body-start (save-excursion
                           (goto-char start)
                           (min (1+ (pos-eol)) end))))
        (when (< body-start end)
          (put-text-property body-start end 'invisible 'opencode-section)
          (overlay-put section-ov 'opencode-collapsed t)
          (save-excursion
            (goto-char start)
            (goto-char (pos-eol))
            (insert (propertize " [collapsed]"
                                'face 'font-lock-comment-face
                                'opencode-collapsed-indicator t))))))))

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
         (section (opencode-ui--make-section 'tool-call (plist-get part :id) part))
         (tool-prefix (propertize opencode--stripe-char 'face 'opencode-assistant-block))
         ;; Collapse built-ins by default, except edit / todowrite which
         ;; are always expanded (diff and todo tables are the whole point).
         ;; MCP / unregistered tools stay expanded so the user can see
         ;; their arbitrary payload.
         (should-collapse-p
          (and (opencode-chat--builtin-tool-p tool-name)
               (not (string= tool-name "edit"))
               (not (string-match-p "todowrite\\|todo_write" tool-name))))
         (section-ov
          (opencode-ui--with-section section
            ;; Header line
            (let ((header-start (point)))
              (insert " ")
              (opencode-ui--insert-icon (if should-collapse-p 'collapsed 'expanded))
              (insert " ")
              (insert (propertize tool-name 'face 'opencode-tool-name))
              (when (and arg-summary
                         (stringp arg-summary)
                         (not (string-empty-p arg-summary)))
                (insert " ")
                (insert (propertize (format "(%s)" (opencode--truncate-string arg-summary 60))
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
            ;; Body: data-driven dispatch through the registry.
            (let ((body-start (point)))
              (opencode-chat--render-tool-body-dispatch tool-name input output metadata)
              (when (> (point) body-start)
                (put-text-property body-start (max body-start (1- (point)))
                                   'line-prefix tool-prefix))))))
    ;; Default-collapse built-in non-edit / non-todo sections.
    (when (and should-collapse-p section-ov)
      (let* ((start (overlay-start section-ov))
             (end (overlay-end section-ov))
             (body-start (save-excursion
                           (goto-char start)
                           (min (1+ (pos-eol)) end))))
        (when (< body-start end)
          (put-text-property body-start end 'invisible 'opencode-section)
          (overlay-put section-ov 'opencode-collapsed t)
          (save-excursion
            (goto-char start)
            (goto-char (pos-eol))
            (insert (propertize " [collapsed]"
                                'face 'font-lock-comment-face
                                'opencode-collapsed-indicator t))))))))


(defun opencode-chat--render-reasoning-part (part)
  "Render a reasoning/thinking PART.
Uses assistant block face for left border.
Always renders the header so that streaming deltas (via `message.part.delta')
have a marker position to insert at.  Content is rendered only when non-empty.

The section overlay is created with `rear-advance' so streaming
deltas that land at the overlay's end (initial render with empty
text → marker at header-newline = overlay-end) are INCLUDED in the
overlay.  Without this the TAB toggle can only collapse the header
line; streamed Thinking content would stay visible outside the
section."
  (let ((text (or (plist-get part :text) ""))
        (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block))
        (section (opencode-ui--make-section 'reasoning (plist-get part :id)
                                            nil 'rear-advance)))
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
          (insert "\n"))))))

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
Each line gets a space prefix (if at bolp), assistant-body (or reasoning)
face, line-prefix stripe with opencode-assistant-block, read-only, and keymap.
Uses `split-string' instead of `string-lines' to preserve trailing newlines
in deltas (e.g. \"Hello\\n\" must insert the newline so the next delta
starts at `bolp' and gets the space prefix)."
  (let* ((inhibit-read-only t)
         (body-face (if (string= field "reasoning")
                        'opencode-reasoning
                      'opencode-assistant-body))
         (stripe (propertize opencode--stripe-char 'face 'opencode-assistant-block))
         (lines (split-string text "\n"))
         (num-lines (length lines))
         (region-start (point)))
    (cl-loop for line in lines
             for i from 0
             do
             ;; Add space prefix at beginning of line
             (when (bolp)
               (setq line (concat " " line)))
             (insert (propertize line 'face body-face))
             ;; Insert newline between lines (not after the last one)
             (when (< i (1- num-lines))
               (insert "\n")))
    ;; Apply all shared properties once over the entire inserted region
    (opencode-chat--apply-message-props region-start (point)
                                        (list 'line-prefix stripe))))

(defun opencode-chat--schedule-streaming-fontify ()
  "Schedule debounced markdown fontification of the streaming region.
If a timer is already pending, cancel and reschedule so that
fontification runs `opencode-chat-streaming-fontify-delay' seconds
after the last delta arrives."
  (opencode--debounce (cons #'opencode-chat--streaming-fontify-timer
                            #'opencode-chat--set-streaming-fontify-timer)
                      opencode-chat-streaming-fontify-delay
                      #'opencode-chat--fontify-streaming-region))

(defun opencode-chat--fontify-streaming-region ()
  "Fontify the current streaming text region with markdown.
Uses `opencode-chat--streaming-region-start' as the region start
and the current streaming marker position as the end.
Only applies inline markdown (bold, italic, headers, code, lists, hr).
Fenced code block syntax highlighting is deferred to final render."
  (when-let* ((region-start (opencode-chat--streaming-region-start)))
    (let* ((start (marker-position region-start))
           (streaming-msg-id (opencode-chat--streaming-msg-id))
           (streaming-part-id (opencode-chat--streaming-part-id))
           (messages-end (opencode-chat--messages-end))
           (marker (when (and streaming-msg-id streaming-part-id)
                    (opencode-chat--store-part-marker
                     streaming-msg-id streaming-part-id)))
           (end (cond
                 (marker (marker-position marker))
                 (messages-end (marker-position messages-end))
                 (t nil))))
      (when (and start end (< start end))
        (condition-case err
            (let ((inhibit-read-only t))
              (save-excursion
                (save-match-data
                  (opencode-markdown-fontify-region start end))))
          (error
           (opencode--debug
            "opencode-chat: streaming fontify error: %S" err)))))))

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

(defun opencode-chat--update-part-inline (part)
  "Update a non-text PART directly in the chat buffer.
Case 1: existing section overlay — delete region and re-render in-place.
Case 2: no overlay — bootstrap at message-insert-pos or messages-end.
Case 3: no insertion point — defer to schedule-refresh."
  (let* ((part-id (plist-get part :id))
         (msg-id (plist-get part :messageID))
         (part-type (plist-get part :type))
         (ov (opencode-chat--store-find-overlay part-id))
         (inhibit-read-only t))
    (cond
     ;; Case 1: Existing overlay — delete region and re-render in-place
     ((and ov (overlay-buffer ov))
      (let ((start (overlay-start ov))
            (end (overlay-end ov)))
        (let ((siblings
               (cl-loop for o in (overlays-at end)
                        when (and (overlay-get o 'opencode-section)
                                  (not (eq o ov))
                                  (= (overlay-start o) end))
                        collect o)))
          ;; Delete ALL overlays with this part-id (not just the first)
          (dolist (o (overlays-in (point-min) (point-max)))
            (when-let* ((sec (overlay-get o 'opencode-section))
                        ((equal (plist-get sec :id) part-id)))
              (when (not (eq o ov))
                (delete-region (overlay-start o) (overlay-end o))
                (delete-overlay o))))
          (delete-overlay ov)
          ;; Clear cached overlay in store
          (when msg-id
            (when-let* ((entry (opencode-chat--store-get msg-id))
                        (parts (plist-get entry :parts))
                        (pinfo (gethash part-id parts)))
              (plist-put pinfo :overlay nil)))
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (pcase part-type
              ("tool"        (opencode-chat--render-tool-part part))
              ("step-start"  (opencode-chat--render-step-start part))
              ("step-finish" (opencode-chat--render-step-finish part))
              ("subtask"     (opencode-chat--render-subtask-part
                              part (or (opencode-chat--msg-role msg-id) 'user))))
            (when (> (point) start)
              (opencode-chat--apply-message-props start (point)))
            (dolist (o siblings)
              (when (overlay-buffer o)
                (move-overlay o (point) (overlay-end o))))
            ;; Re-cache new overlay and marker
            (when msg-id
              (opencode-chat--store-set-part
               msg-id part-id part-type (copy-marker (point) t))
              ;; Cache the newly created overlay
              (when-let* ((new-ov (opencode-chat--store-find-overlay part-id))
                          (entry (opencode-chat--store-get msg-id))
                          (parts (plist-get entry :parts))
                          (pinfo (gethash part-id parts)))
                (plist-put pinfo :overlay new-ov)))))))
     ;; Case 2: No overlay — insert at message-end or messages-end
     ((let* ((pos (or (opencode-chat--message-insert-pos msg-id)
                      (when-let* ((end (opencode-chat--messages-end)))
                        (marker-position end)))))
        (when pos
          (save-excursion
            (goto-char pos)
            (unless (bolp) (insert "\n"))
            (let ((start (point)))
              (pcase part-type
                ("tool"        (opencode-chat--render-tool-part part))
                ("step-start"  (opencode-chat--render-step-start part))
                ("step-finish" (opencode-chat--render-step-finish part))
                ("subtask"     (opencode-chat--render-subtask-part
                                part (or (opencode-chat--msg-role msg-id) 'user))))
              (when (> (point) start)
                (opencode-chat--apply-message-props start (point)))
              (when msg-id
                (opencode-chat--store-set-part
                 msg-id part-id part-type (copy-marker (point) t))
                ;; Cache newly created overlay
                (when-let* ((new-ov (opencode-chat--store-find-overlay part-id))
                            (entry (opencode-chat--store-get msg-id))
                            (parts (plist-get entry :parts))
                            (pinfo (gethash part-id parts)))
                  (plist-put pinfo :overlay new-ov)))))
          t)))
     ;; Case 3: No insertion point — defer
     (t
      (opencode-chat--schedule-refresh)))))

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
If it exists, updates header/footer in-place."
  (if (opencode-chat-message-exists-p msg-id)
      (opencode-chat--update-message-inline msg-id data)
    (let ((parts (plist-get data :parts))
          (info (if (plist-get data :role)
                    data
                  ;; DATA is already a full msg plist with :info
                  (plist-get data :info))))
      (opencode-chat--insert-message-at-end
       (list :info (or info data) :parts parts)))))

(defun opencode-chat-message-delete (msg-id)
  "Delete message MSG-ID from buffer and store.
Frees all part markers, removes the overlay, deletes the buffer region."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
      (when (overlay-buffer ov)
        (delete-region (overlay-start ov) (overlay-end ov))
        (delete-overlay ov))))
  ;; Clean store entry (frees markers)
  (when-let* ((entry (opencode-chat--store-get msg-id)))
    (when-let* ((parts (plist-get entry :parts)))
      (maphash (lambda (_pid info)
                 (when-let* ((m (plist-get info :marker)))
                   (when (markerp m) (set-marker m nil))))
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
    (let ((buffer-undo-list t))
      (opencode-chat--update-part-inline part))
    :upserted)

   ;; Streaming delta
   (delta
    (let ((type (or part-type
                    (opencode-chat--store-part-type msg-id part-id))))
      (cond
       ;; Case 1: marker exists → append
       ((opencode-chat--append-delta msg-id part-id delta type)
        :streamed)
       ;; Case 2: message overlay exists → create marker, append.
       ;; When the previous streaming part's last delta ended mid-line
       ;; (no trailing newline), insert a separator so the new part
       ;; starts at bolp — otherwise the first delta for this part
       ;; glues onto the previous part's tail (e.g. reasoning text
       ;; concatenated with the assistant's first response word).
       ((when-let* ((pos (opencode-chat--message-insert-pos msg-id)))
          (save-excursion
            (goto-char pos)
            (unless (bolp)
              (let ((inhibit-read-only t))
                (insert "\n"))
              (setq pos (point)))
            ;; Invariant: after the guard, the marker's anchor MUST be at
            ;; bolp — otherwise the new streaming part's first delta will
            ;; glue onto the previous part's tail (the bug pinned by
            ;; `opencode-chat-streaming-new-part-breaks-line').
            (cl-assert (save-excursion (goto-char pos) (bolp)) t
                       "new streaming part marker must anchor at bolp"))
          (opencode-chat--store-set-part msg-id part-id (or type "text")
                                        (copy-marker pos nil))
          (opencode-chat--append-delta msg-id part-id delta (or type "text"))
          :streamed))
       ;; Case 3: no message → caller must bootstrap
       (t :need-msg))))

   ;; New text/reasoning part without delta — render in-place.
   ;; Ensure the render starts at bolp so a new reasoning header or
   ;; empty text placeholder doesn't glue onto the previous part's
   ;; tail when it didn't end on a newline.
   ((and part-id
         (not (opencode-chat--store-part-marker msg-id part-id)))
    (when-let* ((pos (opencode-chat--message-insert-pos msg-id)))
      (let* ((inhibit-read-only t)
             (buffer-undo-list t)
             (role (or (opencode-chat--msg-role msg-id) 'assistant)))
        (save-excursion
          (goto-char pos)
          (unless (bolp)
            (insert "\n")
            (setq pos (point)))
          (opencode-chat--render-part part role)
          (when (> (point) pos)
            (opencode-chat--apply-message-props pos (point)))))
      :rendered))

   ;; Finalized part — no-op
   (t nil)))

(defun opencode-chat-message-set-state (msg-id state)
  "Set the state for MSG-ID to STATE (:queued, :sending, or nil)."
  (plist-put (opencode-chat--store-ensure msg-id) :state state))

(defun opencode-chat-message-state (msg-id)
  "Return the current state for MSG-ID, or nil."
  (when-let* ((entry (opencode-chat--store-get msg-id)))
    (plist-get entry :state)))

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
    (set-marker-insertion-type end-marker nil)
    (save-excursion
      (goto-char end-marker)
      (let ((start (point))
            (inhibit-read-only t)
            (buffer-undo-list t))
        (opencode-chat--render-message msg)
        (opencode-chat--apply-message-props start (point))
        (set-marker end-marker (point))))
    (set-marker-insertion-type end-marker t)
    t))

(defun opencode-chat--update-message-inline (msg-id info)
  "Update an existing message MSG-ID header and footer from INFO.
Re-renders the header line (first line of the message section) so the
timestamp, agent, model, and tokens reflect the latest server data.
For assistant messages with `:completed' time, also re-renders the
footer line (token counts + duration)."
  (when-let* ((ov (opencode-chat--store-find-overlay msg-id))
              ((overlay-buffer ov)))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (role (plist-get info :role))
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
                (opencode-chat--apply-message-props footer-start (point))))))
        t))))



(defun opencode-chat--append-delta (msg-id part-id delta field)
  "Append streaming DELTA for PART-ID in MSG-ID.
FIELD is the part type (\"text\" or \"reasoning\").
Moves point to the part marker before inserting so text lands at the
correct buffer position.  Also initializes streaming region tracking
on first delta for a part.
Returns t on success, nil if no marker found for PART-ID."
  (let ((marker (opencode-chat--store-part-marker msg-id part-id)))
    (when (and marker (marker-position marker))
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        ;; Switch marker to insertion type t so it advances as deltas
        ;; are inserted.  Starts as nil (set in `render-part') to
        ;; prevent tool parts inserted at the same position from
        ;; pushing the marker forward before any text arrives.
        (set-marker-insertion-type marker t)
        (save-excursion
          (goto-char (marker-position marker))
          ;; Initialize streaming region tracking on first delta
          (unless (opencode-chat--streaming-part-id)
            (opencode-chat--set-streaming-msg-id msg-id)
            (opencode-chat--set-streaming-part-id part-id)
            (opencode-chat--set-streaming-region-start (copy-marker (point) nil)))
          ;; Invariant: streaming-msg-id and streaming-part-id are both
          ;; set or both nil — losing one would orphan the fontify timer.
          (cl-assert (eq (and (opencode-chat--streaming-part-id) t)
                         (and (opencode-chat--streaming-msg-id) t))
                     t "streaming {msg,part}-id must be paired")
          (opencode-chat--insert-streaming-delta delta field)))
      t)))

(defun opencode-chat-message-clear-all ()
  "Clear all message state after erase-buffer.
Nils messages-end, clears all hash tables, cancels streaming timers,
frees all markers."
  (opencode-chat--set-messages-end nil)
  (opencode-chat--clear-streaming-state)
  (opencode-chat--store-clear)
  (when (hash-table-p (opencode-chat--diff-shown))
    (clrhash (opencode-chat--diff-shown)))
  (opencode-chat--set-current-message-id nil))

(defun opencode-chat-message-clear-streaming ()
  "Clear streaming state only."
  (opencode-chat--clear-streaming-state))

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
  (opencode-api-get
   (format "/session/%s/diff" session-id)
   (lambda (diffs)
     (when (and diffs (arrayp diffs))
       (seq-doseq (d diffs)
         (let ((msg-id (plist-get d :messageID)))
           (when msg-id
             (puthash msg-id d (opencode-chat--diff-cache)))))))))

(defun opencode-chat-message-render-all (messages)
  "Render all MESSAGES in sequence.
MESSAGES is a vector of message plists (each with :info and :parts)."
  (seq-doseq (msg messages)
    (opencode-chat--render-message msg)))

(provide 'opencode-chat-message)
;;; opencode-chat-message.el ends here
