;;; opencode-chat.el --- Chat buffer for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Main conversation buffer for opencode.el.
;; Displays messages (user/assistant), renders parts (text, tool, reasoning),
;; handles streaming responses via SSE, provides input area for sending messages.
;;
;; Emacs 30: Uses `visual-wrap-prefix-mode', `mode-line-format-right-align',
;; `set-window-cursor-type' for input area vs read-only.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ring)
(require 'opencode-faces)
(require 'opencode-ui)
(require 'opencode-api)
(require 'opencode-sse)
(require 'opencode-log)
(require 'opencode-util)
(require 'opencode-api)
(require 'opencode-markdown)
(require 'opencode-session)
(require 'opencode-agent)
(require 'opencode-command)
(require 'opencode-config)
(require 'opencode-popup)
(require 'opencode-question)
(require 'opencode-permission)
(require 'opencode-chat-state)
(require 'opencode-chat-message)
(require 'opencode-chat-input)
(require 'opencode-api-cache)

(declare-function opencode--register-chat-buffer "opencode" (session-id buffer))
(declare-function opencode--deregister-chat-buffer "opencode" (session-id))

(defgroup opencode-chat nil
  "OpenCode chat buffer."
  :group 'opencode
  :prefix "opencode-chat-")

(defcustom opencode-chat-refresh-delay 0.3
  "Debounce delay in seconds for chat buffer refresh.
Lower values make the UI more responsive but increase CPU usage."
  :type 'number
  :group 'opencode-chat)

(defcustom opencode-chat-streaming-fontify-delay 0.4
  "Debounce delay in seconds for markdown fontification during streaming.
Fontification runs this many seconds after the last delta arrives."
  :type 'number
  :group 'opencode-chat)

(defcustom opencode-chat-message-limit 100
  "Maximum number of messages to fetch from the server.
Limits the history size to prevent performance issues with large sessions."
  :type 'integer
  :group 'opencode-chat)

;;; --- Internal state ---
;;
;; The six slots formerly declared here as `defvar-local's — refresh-timer,
;; streaming-assistant-info, refresh-state, queued-overlay, retry-overlay,
;; disposed-refresh-timer — now live in the `opencode-chat-state' struct.
;; Accessors are generated in `opencode-chat-state.el' (see the
;; `opencode-chat-state--define-slot' block).  The refresh state machine
;; helpers below wrap those accessors so callers never poke the slot
;; directly.

(defun opencode-chat--stale-p ()
  "Return non-nil if the buffer needs a refresh."
  (eq (opencode-chat--refresh-state) 'stale))

(defun opencode-chat--mark-stale ()
  "Mark the buffer as needing a refresh on the next opportunity.
No-op if a refresh is already in-flight or pending — those transitions
already guarantee a refresh will happen."
  (when (null (opencode-chat--refresh-state))
    (opencode-chat--set-refresh-state 'stale)))

(defun opencode-chat--refresh-begin ()
  "Transition to `in-flight' if a new refresh should start now.
Returns non-nil if the caller should actually fire an HTTP fetch.

The refresh state machine has four values:
  nil                  Idle — no refresh pending, no refresh running.
  `stale'              Refresh deferred (buffer busy/hidden).  The
                       next `session.idle' or `display-buffer' event
                       should call `opencode-chat--refresh'.
  `in-flight'          A refresh is currently executing (HTTP fetch
                       chain in progress).  Further calls are coalesced.
  `in-flight-pending'  A refresh is executing AND another was requested
                       during that execution.  On completion, exactly
                       one retry will fire.

All transitions go through `--mark-stale', `--refresh-begin',
`--refresh-end', and `--force-clear-refresh-guard' — do NOT call
`opencode-chat--set-refresh-state' directly from other modules.

Transitions:
  nil | stale   → in-flight           (fire fetch, return t)
  in-flight     → in-flight-pending   (coalesce, return nil)
  in-flight-pending → in-flight-pending (no change, return nil)"
  (let ((s (opencode-chat--refresh-state)))
    ;; Invariant: state must be one of the four documented values.
    (cl-assert (memq s '(nil stale in-flight in-flight-pending)) t
               "refresh-state must be nil/stale/in-flight/in-flight-pending")
    (pcase s
      ((or 'nil 'stale)
       (opencode-chat--set-refresh-state 'in-flight)
       t)
      ('in-flight
       (opencode-chat--set-refresh-state 'in-flight-pending)
       nil)
      ('in-flight-pending
       nil))))

(defun opencode-chat--refresh-end ()
  "Called when the current refresh HTTP chain finishes.
Returns non-nil if a retry refresh should be fired (because another
refresh was requested while we were in-flight).

Transitions:
  in-flight         → nil  (return nil, nothing pending)
  in-flight-pending → nil  (return t — caller must re-fire `refresh';
                            the re-fire will transition nil → in-flight)
  other             → nil  (defensive reset)"
  (let ((s (opencode-chat--refresh-state)))
    (cl-assert (memq s '(nil stale in-flight in-flight-pending)) t
               "refresh-state must be nil/stale/in-flight/in-flight-pending")
    (pcase s
      ('in-flight-pending
       (opencode-chat--set-refresh-state nil)
       t)
      (_
       (opencode-chat--set-refresh-state nil)
       nil))))

(defun opencode-chat--force-clear-refresh-guard ()
  "Force-clear the refresh state machine to `nil'.
Call this in terminal event handlers (session.idle, session.error,
session.compacted, server.instance.disposed) so that the canonical
refresh they trigger is never blocked by a stale in-flight guard.
Without this, a lost or slow async callback can permanently lock
out all future refreshes."
  (opencode-chat--set-refresh-state nil))

;;; --- Public buffer-local hooks ---
;;
;; Each hook runs with a single argument: the SSE event plist.
;; These are buffer-local hooks — add with (add-hook 'HOOK FN nil t).

(defvar-local opencode-chat-on-session-updated-hook nil
  "Hook run after a `session.updated' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.updated\"
   :properties (:info (:id SESSION-ID :title TITLE :summary ... :time ...)))")

(defvar-local opencode-chat-on-message-updated-hook nil
  "Hook run after a `message.updated' event is processed.
Called with one argument EVENT, a plist:
  (:type \"message.updated\"
   :properties (:info (:id MSG-ID :sessionID SID :role ROLE
                       :parentID PARENT-MSG-ID
                       :modelID MODEL :providerID PROVIDER
                       :agent AGENT :time (:created MS :completed MS)
                       :cost FLOAT :tokens (:total N :input N :output N
                                            :cache (:read N :write N))
                       :finish \"stop\")))")

(defvar-local opencode-chat-on-message-removed-hook nil
  "Hook run after a `message.removed' event is processed.
Called with one argument EVENT, a plist:
  (:type \"message.removed\"
   :properties (:info (:id MSG-ID :sessionID SID)))")

(defvar-local opencode-chat-on-session-diff-hook nil
  "Hook run after a `session.diff' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.diff\"
   :properties (:sessionID SID :diff ...))")

(defvar-local opencode-chat-on-session-status-hook nil
  "Hook run after a `session.status' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.status\"
   :properties (:sessionID SID :status (:type \"busy\"|\"idle\"|\"retry\")))")

(defvar-local opencode-chat-on-session-idle-hook nil
  "Hook run after a `session.idle' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.idle\"
   :properties (:sessionID SID))")

(defvar-local opencode-chat-on-session-compacted-hook nil
  "Hook run after a `session.compacted' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.compacted\"
   :properties (:sessionID SID))")

(defvar-local opencode-chat-on-server-instance-disposed-hook nil
  "Hook run after a `server.instance.disposed' event is processed.
Called with one argument EVENT, a plist:
  (:type \"server.instance.disposed\"
   :properties ())")

(defvar-local opencode-chat-on-session-deleted-hook nil
  "Hook run after a `session.deleted' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.deleted\"
   :properties (:info (:id SESSION-ID)))")

(defvar-local opencode-chat-on-session-error-hook nil
  "Hook run after a `session.error' event is processed.
Called with one argument EVENT, a plist:
  (:type \"session.error\"
   :properties (:sessionID SID
                :error (:name ERROR-NAME :data ERROR-DATA)))")

(defvar-local opencode-chat-on-installation-update-available-hook nil
  "Hook run after an `installation.update-available' event is processed.
Called with one argument EVENT, a plist:
  (:type \"installation.update-available\"
   :properties (:current VERSION-STRING :latest VERSION-STRING))")

(defvar-local opencode-chat-on-todo-updated-hook nil
  "Hook run after a `todo.updated' event is processed.
Called with one argument EVENT, a plist:
  (:type \"todo.updated\"
   :properties (:sessionID SID :todos VECTOR-OF-PLISTS))")

(defvar-local opencode-chat-on-part-updated-hook nil
  "Hook run after a `message.part.updated' event is processed.
Called with one argument EVENT, a plist:
  (:type \"message.part.updated\"
   :properties (:part (:id PART-ID :sessionID SID :messageID MSG-ID
                       :type \"text\"|\"reasoning\"|\"tool\"
                             |\"step-start\"|\"step-finish\"
                       :text TEXT :tool TOOL-NAME
                       :state (:status STATUS-STR
                               :input (...) :output STRING)
                       :time (:start MS :end MS))
                :delta DELTA-STRING-OR-NIL))")

(defvar-local opencode-chat-on-refresh-hook nil
  "Hook run after a chat buffer refresh completes.
Called with one argument, a plist:
  (:messages MESSAGES :session SESSION)
where MESSAGES is the vector from GET /session/:id/message
and SESSION is the plist from GET /session/:id.
Use this to update derived state like the footer token display.")

(declare-function opencode-session-get "opencode-session.el")

(defun opencode-chat--child-session-p ()
  "Return non-nil if the buffer-local session has a parent session.
Uses the struct's cached session plist."
  (plist-get (opencode-chat--session) :parentID))

(defun opencode-chat--parent-session-id ()
  "Return the parent session ID from the buffer-local session.
Returns nil if the session has no parent."
  (plist-get (opencode-chat--session) :parentID))

(defun opencode-chat--child-sessions (session-id)
  "Return child sessions of SESSION-ID from the server.
Uses the official /session/:id/children endpoint."
  (condition-case err
      (let ((result (opencode-api-get-sync
                     (format "/session/%s/children" session-id))))
        (if (vectorp result) (append result nil) result))
    (error
     (opencode--debug "opencode-chat: children fetch failed: %s"
                      (error-message-string err))
     nil)))

(defun opencode-chat--session-parent-id (session-id)
  "Return the :parentID of SESSION-ID from server session data.
Uses `opencode-session-get' to fetch fresh session information."
  (plist-get (opencode-session-get session-id) :parentID))

;;; --- Buffer naming ---

(defun opencode-chat--buffer-name (session)
  "Return the buffer name for SESSION.
Format: *opencode: <project>/<title>*"
  (let ((project (opencode-session--project-name session))
        (title (opencode-session--title session)))
    (format "*opencode: %s/%s*" project title)))

;;; --- Chat mode ---

(defvar-keymap opencode-chat-mode-map
  :doc "Keymap for `opencode-chat-mode'."
  "C-c C-c" #'opencode-chat--send
  "C-c C-k" #'opencode-chat-abort
  "C-c C-a" #'opencode-chat--attach
  "C-p" #'opencode-command-select
  "C-t" #'opencode-chat--cycle-variant
  "C-c g" #'opencode-chat--refresh
  "TAB" #'opencode-chat--cycle-agent
  "S-TAB" #'opencode-chat--cycle-agent-backward
  "<backtab>" #'opencode-chat--cycle-agent-backward
  "M-p" #'opencode-chat--prev-message
  "M-n" #'opencode-chat--next-message
  "DEL" #'opencode-chat--chip-backspace
  "C-c C-v" #'opencode-chat--paste-image)

(defun opencode-chat-goto-parent ()
  "Navigate to the parent session, replacing the current buffer in the same window."
  (interactive)
  (if-let* ((parent-id (opencode-chat--parent-session-id)))
      (opencode-chat-open parent-id
                         (plist-get (opencode-chat--session) :directory)
                         'replace)
    (user-error "No parent session")))

(defun opencode-chat--quit-or-goto-parent ()
  "In child sessions, go to parent; otherwise `quit-window'."
  (interactive)
  (if (opencode-chat--child-session-p)
      (opencode-chat-goto-parent)
    (quit-window)))

(defun opencode-chat--render-child-indicator ()
  "Render the sub-agent indicator line below the input area.
Shows a read-only label and a [Parent] button for navigation."
  (let* ((parent-id (opencode-chat--parent-session-id))
         (directory (plist-get (opencode-chat--session) :directory))
         (inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize " Sub-agent session  "
                        'face 'font-lock-comment-face
                        'read-only t
                        'front-sticky '(read-only)))
    (insert-text-button "[Parent]"
                        'action (lambda (_btn)
                                  (opencode-chat-open parent-id directory 'replace))
                        'follow-link t
                        'read-only t
                        'front-sticky '(read-only)
                        'help-echo "Return to parent session")
    (insert (propertize "\n" 'read-only t))))

(defvar-keymap opencode-chat-message-map
  :doc "Keymap for the read-only message area (applied via text property)."
  "g" #'opencode-chat--refresh
  "G" #'opencode-chat--goto-latest
  "q" #'opencode-chat--quit-or-goto-parent
  "C-p" #'opencode-command-select
  "C-t" #'opencode-chat--cycle-variant
  "TAB" #'opencode-ui--toggle-section)

(define-derived-mode opencode-chat-mode nil "OpenCode Chat"
  "Major mode for OpenCode chat conversations.
Does NOT derive from `special-mode' because the input area must allow
\"self-insert-command\" for typing.
Read-only protection is via text properties.

\\{opencode-chat-mode-map}"
  :group 'opencode-chat
  (setq truncate-lines nil
        word-wrap t
        buffer-read-only nil)  ; We use text-property 'read-only instead
  (add-to-invisibility-spec 'opencode-section)
  (add-to-invisibility-spec 'opencode-md)
  ;; Register our CAPFs with negative depth so they run BEFORE any
  ;; other completion backends (e.g. dabbrev, cape, corfu) that might
  ;; intercept @-mention or /slash completions.
  (add-hook 'completion-at-point-functions #'opencode-chat--mention-capf -100 t)
  (add-hook 'completion-at-point-functions #'opencode-chat--slash-capf -100 t)
  ;; Ensure pasted/yanked text in the input area inherits the input keymap
  (add-hook 'after-change-functions #'opencode-chat--input-after-change nil t)
  ;; @-mention completion uses a custom fuzzy matcher built into the
  ;; completion table (see `opencode-chat--mention-completion-table').
  ;; It handles path-segment skipping (e.g. this/file.txt →
  ;; this/is/a/longlongpath/file.txt) and scattered substrings
  ;; (e.g. ochat → opencode-chat.el) regardless of the user's
  ;; `completion-styles' setting.  We still set basic+flex as a
  ;; fallback for edge cases and /slash-command completion.
  (setq-local completion-category-overrides
              '((opencode-mention (styles basic partial-completion flex))))
  (when (fboundp 'company-mode) (company-mode 1))
  ;; Lazy-refresh: when a stale chat buffer becomes visible, refresh it.
  ;; add-hook is idempotent so this is safe to call from every mode init.
  (add-hook 'window-buffer-change-functions #'opencode-chat--on-window-buffer-change)
  ;; Optimistic busy/queued on send — chat.el owns state transitions
  (add-hook 'opencode-chat-on-message-sent-hook #'opencode-chat--on-message-sent nil t)
  (visual-line-mode 1)
  (cursor-intangible-mode 1)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (and (opencode-chat--session-id)
                        (fboundp 'opencode--deregister-chat-buffer))
                (opencode--deregister-chat-buffer (opencode-chat--session-id))))
            nil t))

;;; --- Header line (sticky, via header-line-format) ---

(defun opencode-chat--header-line ()
  "Return a list for `header-line-format'.
Shows session title on the left; status on the right.
Session details (model, agent, tokens) moved to footer above input area.
Uses (space :align-to) display property for right-alignment."
  (let* ((session (opencode-chat--session))
         (title (if session (opencode-session--title session) "OpenCode"))
         (status (if (opencode-chat--busy) "busy" "idle"))
         (status-face (if (opencode-chat--busy) 'opencode-tool-running
                        'opencode-session-idle)))
    (list
     ;; Left: Session title
     (propertize (format " %s" title) 'face 'opencode-header)
     ;; Right: Status (right-aligned)
     (propertize " " 'display '(space :align-to (- right 10)))
     (propertize status 'face status-face))))

;;; --- Queued indicator (owned by chat.el, not chat-message.el) ---

(defun opencode-chat--show-queued-indicator ()
  "Insert a QUEUED badge after the last message (at messages-end).
Inserts AFTER messages-end without advancing the marker, so the badge
is not included in message-area captures.  Uses an overlay for clean
removal.  Idempotent."
  (when-let* ((end-marker (opencode-chat-message-messages-end)))
    (when (and (marker-position end-marker)
               (not (opencode-chat--queued-overlay)))
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        ;; Temporarily switch to nil insertion type so messages-end
        ;; does NOT advance past the QUEUED badge text
        (set-marker-insertion-type end-marker nil)
        (save-excursion
          (goto-char end-marker)
          (let ((start (point)))
            (insert (propertize "  QUEUED\n" 'face 'opencode-tool-running
                                'read-only t))
            (let ((ov (make-overlay start (point))))
              (overlay-put ov 'opencode-queued t)
              (overlay-put ov 'evaporate t)
              (opencode-chat--set-queued-overlay ov))))
        ;; Restore insertion type
        (set-marker-insertion-type end-marker t)))))

(defun opencode-chat--hide-queued-indicator ()
  "Remove the QUEUED badge if currently shown."
  (when-let* ((ov (opencode-chat--queued-overlay)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
      (when (and (overlay-start ov) (overlay-end ov))
        (delete-region (overlay-start ov) (overlay-end ov)))
      (delete-overlay ov)
      (opencode-chat--set-queued-overlay nil))))

(defun opencode-chat--clear-queued-state ()
  "Clear all queued state: flag, pending IDs, and overlay."
  (opencode-chat--set-queued nil)
  (opencode-chat--clear-pending-msg-ids)
  (opencode-chat--hide-queued-indicator))

;;; --- Retry indicator (owned by chat.el) ---

(defun opencode-chat--show-retry-indicator (attempt error-msg secs)
  "Insert a retry error badge after the last message.
ATTEMPT is the retry attempt number, ERROR-MSG is the server error string,
SECS is seconds until the next retry (or nil).
Each call replaces the previous retry badge."
  (opencode-chat--hide-retry-indicator)
  (when-let* ((end-marker (opencode-chat-message-messages-end)))
    (when (marker-position end-marker)
      (let ((inhibit-read-only t)
            (buffer-undo-list t)
            (text (format "  ⚠ %s (attempt %s%s)\n"
                          (or error-msg "unknown error")
                          (or attempt "?")
                          (if secs (format ", retry in %ds" secs) ""))))
        (set-marker-insertion-type end-marker nil)
        (save-excursion
          (goto-char end-marker)
          (let ((start (point)))
            (insert (propertize text 'face 'opencode-tool-error
                                'read-only t))
            (let ((ov (make-overlay start (point))))
              (overlay-put ov 'opencode-retry t)
              (overlay-put ov 'evaporate t)
              (opencode-chat--set-retry-overlay ov))))
        (set-marker-insertion-type end-marker t)))))

(defun opencode-chat--hide-retry-indicator ()
  "Remove the retry error badge if currently shown."
  (when-let* ((ov (opencode-chat--retry-overlay)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
      (when (and (overlay-start ov) (overlay-end ov))
        (delete-region (overlay-start ov) (overlay-end ov)))
      (delete-overlay ov)
      (opencode-chat--set-retry-overlay nil))))

(defun opencode-chat--on-message-sent (info)
  "Handle optimistic busy/queued state after a message is sent.
INFO is a plist with :message-id, :session-id, etc.
Called via `opencode-chat-on-message-sent-hook'."
  (let ((msg-id (plist-get info :message-id)))
    (opencode-chat--set-busy t)
    (opencode-chat--set-queued t)
    (opencode-chat--add-pending-msg-id msg-id)
    (opencode-chat--show-queued-indicator)))

(defun opencode-chat--maybe-clear-queued-for-msg (msg-id)
  "Clear the pending entry for MSG-ID if it is acknowledged.
A server message with ID >= a pending ID means that pending message
has been acknowledged.  When all pending IDs are cleared, removes
the QUEUED indicator."
  (when (opencode-chat--queued)
    (let ((pending (opencode-chat--pending-msg-ids))
          (cleared nil))
      (dolist (pid pending)
        (when (not (string> pid msg-id))
          (opencode-chat--remove-pending-msg-id pid)
          (setq cleared t)))
      (when (and cleared (null (opencode-chat--pending-msg-ids)))
        (opencode-chat--set-queued nil)
        (opencode-chat--hide-queued-indicator)))))

;;; --- Token and context calculation ---

(defun opencode-chat--extract-tokens-from-info (info)
  "Extract a normalized token plist from message INFO.
Returns plist with :total, :input, :output, :reasoning,
:cache-read, :cache-write, or nil if no token data.

Note: the server's :total field is *cumulative* across the session
\(all tokens consumed up to and including this message), while
:input, :output, :reasoning, and :cache are per-message values.

An aborted assistant message arrives with a fully-zero `:tokens'
field (no usage recorded before abort).  We treat that as \"no data\"
and return nil so callers don't overwrite a previously-cached
meaningful cumulative total with zeros."
  (when-let* ((tokens (plist-get info :tokens)))
    (let* ((cache (plist-get tokens :cache))
           (input (or (plist-get tokens :input) 0))
           (output (or (plist-get tokens :output) 0))
           (reasoning (or (plist-get tokens :reasoning) 0))
           (cache-read (or (when cache (plist-get cache :read)) 0))
           (cache-write (or (when cache (plist-get cache :write)) 0))
           ;; :total from server is cumulative; keep it as-is for
           ;; session-level display.  Fall back to per-message sum
           ;; only when the server omits it.
           (total (or (plist-get tokens :total)
                      (+ input output cache-read))))
      (when (> (+ total input output reasoning cache-read cache-write) 0)
        (list :total total
              :input input
              :output output
              :reasoning reasoning
              :cache-read cache-read
              :cache-write cache-write)))))

(defun opencode-chat--recompute-cached-tokens-from-store ()
  "Recompute tokens in `opencode-chat--state' from the message store.

All token fields from the server are cumulative (session-level totals
up to and including that message), so we simply take the values from
the last assistant message — no summing needed.

Cost: O(N) in number of messages (walks to find the last assistant).
This is meant for cold-start refresh (after `render-messages'
populates the store from a full /message fetch), not for live
per-event updates.  The SSE path uses
`opencode-chat--update-cached-tokens-from-event' which is O(1)."
  (opencode-chat--state-ensure)
  (let ((last-tok nil))
    (dolist (msg-id (opencode-chat-message-sorted-ids))
      (when-let* ((info (opencode-chat-message-info msg-id))
                  ((equal (plist-get info :role) "assistant"))
                  (tok (opencode-chat--extract-tokens-from-info info)))
        ;; Messages are sorted chronologically — keep overwriting so
        ;; we end up with the last assistant message's tokens.
        (setq last-tok tok)))
    (when last-tok
      (opencode-chat--set-tokens last-tok))))

(defun opencode-chat--update-cached-tokens-from-event (info)
  "Update cached tokens from a finalized assistant message INFO.
Called from the `message.updated' SSE handler when a completed assistant
message arrives.

All token fields are cumulative (session-level), so we simply
replace the cached value with the new message's data."
  (when-let* ((new-tok (opencode-chat--extract-tokens-from-info info)))
    (opencode-chat--set-tokens new-tok)
    ;; Refresh the footer to show updated tokens
    (opencode-chat--refresh-footer)))

;;; --- Pending popup fetch on refresh ---

(defun opencode-chat--fetch-pending-popups (buf)
  "Fetch pending questions and permissions from the server.
BUF is the chat buffer to merge results into (buffer-local queues).
Fires two async GET requests in parallel; each callback filters items
by session-id, merges into the buffer-local queues (deduplicating by
:id), and calls `opencode-chat--drain-popup-queue' in BUF."
  (opencode--debug "opencode-chat: fetching pending popups")
    (let ((sid (with-current-buffer buf (opencode-chat--session-id))))
    ;; Fetch pending questions
    (opencode-api-get
     "/question"
     (lambda (response)
       (when (and (buffer-live-p buf)
                  (plist-get response :body))
         (let ((body (plist-get response :body)))
           (when (length> body 0)
             (let ((matching (seq-filter
                              (lambda (item)
                                (equal (plist-get item :sessionID) sid))
                              body)))
               (when matching
                 (opencode--debug "opencode-chat: got %d pending questions for %s"
                                  (length matching) sid)
                 (with-current-buffer buf
                   (opencode-chat--merge-pending-popups
                    'opencode-question--pending matching)
                   (opencode-chat--drain-popup-queue)))))))))
    ;; Fetch pending permissions
    (opencode-api-get
     "/permission"
     (lambda (response)
       (when (and (buffer-live-p buf)
                  (plist-get response :body))
         (let ((body (plist-get response :body)))
           (when (length> body 0)
             (let ((matching (seq-filter
                              (lambda (item)
                                (equal (plist-get item :sessionID) sid))
                              body)))
               (when matching
                 (opencode--debug "opencode-chat: got %d pending permissions for %s"
                                  (length matching) sid)
                 (with-current-buffer buf
                   (opencode-chat--merge-pending-popups
                    'opencode-permission--pending matching)
                   (opencode-chat--drain-popup-queue)))))))))))

(defun opencode-chat--merge-pending-popups (queue-sym new-items)
  "Merge NEW-ITEMS into the buffer-local pending queue QUEUE-SYM.
Deduplicates by :id.  NEW-ITEMS is a vector or list of request plists."
  (let ((existing-ids (mapcar (lambda (r) (plist-get r :id))
                              (symbol-value queue-sym))))
    (seq-doseq (item new-items)
      (unless (member (plist-get item :id) existing-ids)
        (set queue-sym
             (append (symbol-value queue-sym) (list item)))))))

;;; --- Message rendering ---

(defun opencode-chat--drain-popup-queue ()
  "Show queued permission/question popups in this chat buffer.
Called at the end of `opencode-chat--render-messages' when no popup
was already active, and from `opencode-chat--on-session-idle'.
Pending queues are buffer-local, so no session-id filtering is needed."
  (opencode-popup--drain-queue))


(defun opencode-chat--save-render-state ()
  "Capture pre-render cursor/input/popup/window state.
Returns a plist consumed by the `--restore-*' helpers after rendering.
Keys: :saved-input :had-input-area :in-input-p :saved-input-offset
:saved-msg-position :in-footer-p :saved-window-start :saved-popup-perm
:saved-popup-ques."
  (let* ((saved-input (opencode-chat--input-text))
         (had-input-area (opencode-chat--input-start))
         (in-input-p (and had-input-area (opencode-chat--in-input-area-p)))
         (saved-input-offset
          (when (and in-input-p (opencode-chat--input-content-start))
            (max 0 (- (point) (opencode-chat--input-content-start)))))
         (saved-msg-position
          (unless in-input-p
            (when had-input-area
              (let ((msg-ov (seq-find
                             (lambda (ov)
                               (let ((sec (overlay-get ov 'opencode-section)))
                                 (and sec (eq (plist-get sec :type) 'message))))
                             (overlays-at (point)))))
                (when msg-ov
                  (cons (plist-get (overlay-get msg-ov 'opencode-section) :id)
                        (- (point) (overlay-start msg-ov))))))))
         (in-footer-p (and had-input-area
                           (not in-input-p)
                           (>= (point) (marker-position (opencode-chat--input-start)))))
         (saved-window-start (when (get-buffer-window (current-buffer))
                               (window-start (get-buffer-window (current-buffer))))))
    (list :saved-input saved-input
          :had-input-area had-input-area
          :in-input-p in-input-p
          :saved-input-offset saved-input-offset
          :saved-msg-position saved-msg-position
          :in-footer-p in-footer-p
          :saved-window-start saved-window-start
          :saved-popup-perm opencode-permission--current
          :saved-popup-ques opencode-question--current)))

(defun opencode-chat--clear-for-rerender ()
  "Wipe buffer and reset state that must not carry across a rerender.
Nils the input-start marker BEFORE rendering messages: after
`erase-buffer' it collapses to point-min, and the buffer-local
`after-change-functions' hook would otherwise force the whole new
message area into the input keymap, clobbering edit-tool file-path
and message-map bindings."
  (erase-buffer)
  (opencode-chat-message-clear-all)
  (when (opencode-chat--input-start)
    (set-marker (opencode-chat--input-start) nil)
    (opencode-chat--set-input-start nil))
  ;; Clear `stale' bit — this IS the refresh.  If we're mid-refresh
  ;; (state = in-flight), refresh-end handles it; this only matters
  ;; when render-messages is called directly (scenario tests, sync).
  (when (eq (opencode-chat--refresh-state) 'stale)
    (opencode-chat--set-refresh-state nil))
  (when (overlayp opencode-popup--overlay)
    (delete-overlay opencode-popup--overlay))
  (setq opencode-popup--inline-p nil
        opencode-popup--overlay nil)
  ;; :eval header-line updates dynamically on session.updated.
  (setq header-line-format '(:eval (opencode-chat--header-line))))

(defun opencode-chat--restore-cursor (pre)
  "Restore cursor position after a rerender.
PRE is the plist returned by `--save-render-state'."
  (let ((had-input-area   (plist-get pre :had-input-area))
        (in-input-p       (plist-get pre :in-input-p))
        (in-footer-p      (plist-get pre :in-footer-p))
        (saved-input      (plist-get pre :saved-input))
        (saved-offset     (plist-get pre :saved-input-offset))
        (saved-msg-pos    (plist-get pre :saved-msg-position)))
    (cond
     ((not had-input-area) (opencode-chat--goto-latest))
     (in-footer-p          (opencode-chat--goto-latest))
     ((and in-input-p saved-input (not (string-empty-p saved-input))
           saved-offset (opencode-chat--input-start))
      (let* ((content-start (opencode-chat--input-content-start))
             (content-end (opencode-chat--input-content-end))
             (target (when content-start
                       (+ content-start
                          (min saved-offset
                               (max 0 (1- (- content-end content-start))))))))
        (if target (goto-char target) (opencode-chat--goto-latest))))
     (in-input-p (opencode-chat--goto-latest))
     (saved-msg-pos
      (let* ((msg-id (car saved-msg-pos))
             (offset (cdr saved-msg-pos))
             (ov (opencode-chat--store-find-overlay msg-id)))
        (if ov
            (goto-char (min (+ (overlay-start ov) offset) (overlay-end ov)))
          (opencode-chat--goto-latest))))
     (t (opencode-chat--goto-latest)))))

(defun opencode-chat--restore-window-position (pre)
  "Sync window-point / window-start after a rerender.
PRE is the plist returned by `--save-render-state'.

When `render-messages' runs inside an async HTTP callback (process
filter), the preceding `goto-char' only updates buffer-point.  Stale
window-point and window-start (from the pre-refresh, larger buffer)
then drag buffer-point forward on the next redisplay — users see it
as \"cursor jumps to the end after refresh\".  Fixes:
  1. `set-window-point' to restored buffer-point.
  2. Clamp window-start to <= (point); if stale, `recenter -1' to
     reveal recent content above point (chat-UI convention).

Batch tests don't reproduce this (headless Emacs auto-syncs
window-point with buffer-point); the guard lives in
`opencode-scenario-cursor-window-point-desync' as intent docs."
  (when-let* ((win (get-buffer-window (current-buffer))))
    (set-window-point win (point))
    (when (plist-get pre :had-input-area)
      (let ((saved-start (plist-get pre :saved-window-start)))
        (if (and saved-start
                 (<= saved-start (point))
                 (<= saved-start (point-max)))
            (set-window-start win saved-start)
          (with-selected-window win (recenter -1)))))))

(defun opencode-chat--restore-popup-or-drain (pre)
  "Re-show the pre-render inline popup, or drain the popup queue.
PRE is the plist returned by `--save-render-state'.  Errors during
re-show fall back to draining the queue so a broken popup doesn't
block subsequent ones."
  (condition-case err
      (cond
       ((plist-get pre :saved-popup-perm)
        (opencode-popup--save-input)
        (opencode-permission--render-inline (plist-get pre :saved-popup-perm)))
       ((plist-get pre :saved-popup-ques)
        (opencode-popup--save-input)
        (opencode-question--render-inline))
       (t
        (opencode-chat--drain-popup-queue)))
    (error
     (opencode--debug "opencode-chat: popup re-show error: %S" err)
     (setq opencode-popup--inline-p nil)
     (opencode-chat--drain-popup-queue))))

(defun opencode-chat--render-messages (&optional messages)
  "Render MESSAGES in the chat buffer.
MESSAGES is a vector of message plists from the API.
When nil, renders an empty buffer (cold start or re-render without data).
Preserves user input text, cursor position, window scroll, and any
active inline popup across re-renders — see the `--save-render-state'
/ `--restore-*' helper family for the details."
  (let ((inhibit-read-only t)
        (inhibit-redisplay t)
        (buffer-undo-list t)
        (pre (opencode-chat--save-render-state)))
    (opencode-chat--clear-for-rerender)
    ;; Messages
    (opencode-chat-message-render-all messages)
    ;; Make the message area read-only with navigation keymap.
    (when (> (point) (point-min))
      (opencode-chat--apply-message-props (point-min) (point)))
    ;; Input area (editable) — same for all sessions
    (opencode-chat--render-input-area)
    ;; Child sessions: append sub-agent indicator below the input area
    (when (opencode-chat--child-session-p)
      (opencode-chat--render-child-indicator))
    ;; Now switch messages-end to insert-after semantics
    (set-marker-insertion-type (opencode-chat-message-messages-end) t)
    ;; Restore user input
    (when-let* ((saved-input (plist-get pre :saved-input))
                ((not (string-empty-p saved-input))))
      (opencode-chat--replace-input saved-input))
    (opencode-chat--restore-cursor pre)
    (opencode-chat--restore-window-position pre)
    (opencode-chat--restore-popup-or-drain pre)
    (opencode-chat--input-history-seed)))

;;; --- Input area ---

;;; --- Debounced refresh ---

(defun opencode-chat--schedule-refresh ()
  "Schedule a debounced refresh (`opencode-chat-refresh-delay' seconds)."
  (opencode--debounce (cons #'opencode-chat--refresh-timer
                            #'opencode-chat--set-refresh-timer)
                      opencode-chat-refresh-delay
                      #'opencode-chat--refresh))

;;; --- SSE event handling ---

(defun opencode-chat--session-id-from-event (event)
  "Extract session-id from SSE EVENT properties.
Tries flat :sessionID, nested :info :id, then :part
:sessionID."
  (let ((props (plist-get event :properties)))
    (or (plist-get props :sessionID)
        (plist-get (plist-get props :info) :id)
        (plist-get (plist-get props :part) :sessionID))))

(defun opencode-chat--on-session-updated (event)
  "Handle a `session.updated' SSE EVENT.
Updates session data and renames the buffer if the title changed."
  (let* ((props (plist-get event :properties))
         (info (plist-get props :info)))
    (opencode--debug "opencode-chat: on-session-updated id=%s" (when info (plist-get info :id)))
    (opencode-chat--set-session info)
    ;; Keep session cache fresh for stale-on-timeout fallback
    (when info
      (opencode-api-cache-put-session (opencode-chat--session-id) info))
    ;; Rename buffer to reflect the (possibly new) title
    (when info
      (let ((new-name (opencode-chat--buffer-name info)))
        (unless (or (string= (buffer-name) new-name)
                    (get-buffer new-name))
          (rename-buffer new-name))))
    (run-hook-with-args 'opencode-chat-on-session-updated-hook event)))

(defun opencode-chat--on-message-updated (event)
  "Handle a `message.updated' SSE EVENT.
Caches assistant message info for streaming bootstrap.  For new assistant
messages (not yet in the buffer), immediately bootstraps an empty message
so subsequent part.updated events (step-start, tool, text delta) can find
the message overlay and insert at the correct position.  Without this,
parts arriving before the first text delta would fallback to messages-end
and appear outside the message section.

For messages that already exist in the buffer (optimistic user messages,
or assistant messages receiving completion info), updates the header and
footer in-place via `opencode-chat-message-update'."
  (let* ((props (plist-get event :properties))
         (info (plist-get props :info))
         (role (plist-get info :role))
         (msg-id (plist-get info :id))
         (time-data (plist-get info :time))
         (completed (when time-data (plist-get time-data :completed))))
    (opencode--debug "opencode-chat: on-message-updated msg=%s role=%s completed=%s"
             msg-id role (and completed t))
    (cond
     ;; New assistant message (not yet completed) — bootstrap
     ((and (equal role "assistant") (not completed))
      (when msg-id
        (opencode-chat--maybe-clear-queued-for-msg msg-id))
      (opencode-chat--set-streaming-assistant-info info)
      (when (and msg-id
                 (opencode-chat-message-messages-end)
                 (not (opencode-chat-message-exists-p msg-id)))
        (opencode-chat-message-upsert msg-id info)))
     ;; Optimistic user message → delete and let server rebuild
     ((and (equal role "user")
           (opencode-chat--optimistic-msg-id)
           (opencode-chat-message-exists-p (opencode-chat--optimistic-msg-id)))
      (opencode-chat--hide-queued-indicator)
      (opencode-chat-message-delete (opencode-chat--optimistic-msg-id))
      (opencode-chat--set-optimistic-msg-id nil)
      (opencode-chat-message-upsert msg-id info))
     ;; New user message (SSE-only, no prior optimistic send)
     ((and (equal role "user")
           msg-id
           (not (opencode-chat--optimistic-msg-id))
           (opencode-chat-message-messages-end)
           (not (opencode-chat-message-exists-p msg-id)))
      (opencode-chat-message-upsert msg-id info))
     ;; Existing message — update header/footer
     ((and msg-id (opencode-chat-message-exists-p msg-id))
      (opencode-chat-message-upsert msg-id info)))
    ;; Cache tokens from finalized assistant messages (has :completed + :tokens)
    (when (and (equal role "assistant") completed (plist-get info :tokens))
      (opencode-chat--update-cached-tokens-from-event info))
    ;; Update state agent/model from assistant messages
    ;; (matches TUI: local.agent.set(msg.agent) on every message return)
    (when (equal role "assistant")
      (when-let* ((a (plist-get info :agent)))
        (opencode-chat--set-agent a)
        (opencode-chat--set-agent-color
         (plist-get (opencode-agent--find-by-name a) :color)))
      (when-let* ((m (plist-get info :modelID)))
        (opencode-chat--set-model-id m))
      (when-let* ((p (plist-get info :providerID)))
        (opencode-chat--set-provider-id p)))
    (run-hook-with-args 'opencode-chat-on-message-updated-hook event)))

(defun opencode-chat--on-message-removed (event)
  "Handle a `message.removed' SSE EVENT."
  (opencode--debug "opencode-chat: on-message-removed")
  (opencode-chat--schedule-refresh)
  (run-hook-with-args 'opencode-chat-on-message-removed-hook event))

(defun opencode-chat--on-session-diff (event)
  "Handle a `session.diff' SSE EVENT.
Invalidates the diff cache and pre-fetches fresh diffs asynchronously."
  (opencode--debug "opencode-chat: on-session-diff session=%s" (opencode-chat--session-id))
  (opencode-chat-message-invalidate-diffs)
  (condition-case nil
      (opencode-chat-message-prefetch-diffs (opencode-chat--session-id))
    (error nil))
  (opencode-chat--schedule-refresh)
  (run-hook-with-args 'opencode-chat-on-session-diff-hook event))

(defun opencode-chat--on-session-status (event)
  "Handle a `session.status' SSE EVENT.
\"retry\" keeps the session busy (server is still working on it) and
surfaces the attempt/error message via the echo area so the user
knows why the session appears stuck."
  (let* ((props (plist-get event :properties))
         (status (plist-get props :status))
         (status-type (when status (plist-get status :type))))
    (opencode--debug "opencode-chat: on-session-status type=%s" status-type)
    (cond
     ((equal status-type "retry")
      ;; Session is still busy while retrying — don't clear the busy flag.
      (opencode-chat--set-busy t)
      (let* ((attempt (plist-get status :attempt))
             (msg (plist-get status :message))
             (next (plist-get status :next))
             ;; `:next' is a unix timestamp in milliseconds.
             (now-ms (truncate (* 1000 (float-time))))
             (secs (when (and next (numberp next))
                     (max 0 (/ (- next now-ms) 1000)))))
        (opencode-chat--show-retry-indicator attempt msg secs)
        (message "Opencode session retrying (attempt %s)%s: %s"
                 (or attempt "?")
                 (if secs (format " in %ds" secs) "")
                 (or msg "unknown error"))))
     (t
      (opencode-chat--set-busy (equal status-type "busy"))
      (opencode-chat--hide-retry-indicator)))
    (run-hook-with-args 'opencode-chat-on-session-status-hook event)))

(defun opencode-chat--on-session-idle (event)
  "Handle a `session.idle' SSE EVENT.
Clears busy state, queued state, and streaming state, triggers full refresh.
Force-clears the refresh-in-flight guard because `session.idle' is the
authoritative \"all done\" signal — any previously in-flight refresh is
irrelevant (its callback may have been lost or is about to land with
stale data that this refresh will supersede)."
  (opencode--debug "opencode-chat: on-session-idle session=%s" (opencode-chat--session-id))
  (opencode-chat-message-clear-streaming)
  (opencode-chat--set-busy nil)
  (opencode-chat--hide-retry-indicator)
  (opencode-chat--clear-queued-state)
  (opencode-chat--force-clear-refresh-guard)
  ;; Snap cursor to the input area when point is past the prompt but
  ;; not in the editable input — streaming often leaves it at
  ;; `point-max' or in the footer/help region.  The async `--refresh'
  ;; below eventually lands via `render-messages' cursor-restore (same
  ;; `--goto-latest' fallback), but the HTTP gap would leave the cursor
  ;; visibly stuck.
  ;; Leave point alone when inside editable input (user typing) or
  ;; before `input-start' (inside a message overlay — render-messages
  ;; restores that position by msg-id + offset).
  (when (and (opencode-chat--input-start)
             (marker-position (opencode-chat--input-start))
             (>= (point) (marker-position (opencode-chat--input-start)))
             (not (opencode-chat--in-input-area-p)))
    (opencode-chat--goto-latest))
  (opencode-chat--refresh)
  (opencode-chat--drain-popup-queue)
  (run-hook-with-args 'opencode-chat-on-session-idle-hook event))

(defun opencode-chat--on-session-compacted (event)
  "Handle a `session.compacted' SSE EVENT.
Compaction rewrites message history — clear streaming state and re-fetch."
  (opencode--debug "opencode-chat: on-session-compacted session=%s" (opencode-chat--session-id))
  (opencode-chat-message-clear-streaming)
  (opencode-chat-message-invalidate-diffs)
  (when opencode-chat--state
    (opencode-chat--set-tokens nil))
  (opencode-chat--force-clear-refresh-guard)
  (opencode-chat--refresh)
  (run-hook-with-args 'opencode-chat-on-session-compacted-hook event))

(defun opencode-chat--on-server-instance-disposed (event)
  "Handle a `server.instance.disposed' SSE EVENT.
Broadcast event — applies to all chat buffers.  Clears streaming state.
Defers refresh if idle (lets the server restart); marks stale if busy or hidden."
  (opencode--debug "opencode-chat: on-server-instance-disposed session=%s" (opencode-chat--session-id))
  (let ((was-busy (opencode-chat--busy)))
    (opencode-chat-message-clear-streaming)
    (opencode-chat-message-invalidate-diffs)
    (opencode-chat--clear-queued-state)
    (when opencode-chat--state
      (opencode-chat--set-tokens nil))
    (opencode-chat--force-clear-refresh-guard)
    (cond
     (was-busy
      (opencode-chat--mark-stale))
     ((get-buffer-window (current-buffer))
      (opencode--debounce (cons #'opencode-chat--disposed-refresh-timer
                                #'opencode-chat--set-disposed-refresh-timer)
                          2.0
                          #'opencode-chat--refresh))
     (t
      (opencode-chat--mark-stale))))
  (run-hook-with-args 'opencode-chat-on-server-instance-disposed-hook event))

(defun opencode-chat--on-window-buffer-change (frame)
  "Refresh stale chat buffers that become visible in FRAME.
Registered on `window-buffer-change-functions' by `opencode-chat-mode'."
  (dolist (win (window-list frame 'no-minibuffer))
    (let ((buf (window-buffer win)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (eq major-mode 'opencode-chat-mode)
                     (opencode-chat--stale-p))
            (opencode--debug "opencode-chat: refreshing stale buffer %s" (buffer-name))
            ;; refresh-begin will transition stale → in-flight.
            (opencode-chat--refresh)))))))

(defun opencode-chat--on-session-deleted (event)
  "Handle a `session.deleted' SSE EVENT."
  (opencode--debug "opencode-chat: on-session-deleted session=%s" (opencode-chat--session-id))
  (opencode-chat--set-busy nil)
  (message "Session %s was deleted" (opencode-chat--session-id))
  (when (opencode-chat--input-start)
    (let ((inhibit-read-only t))
      (add-text-properties (marker-position (opencode-chat--input-start))
                           (point-max)
                           '(read-only t face font-lock-comment-face))))
  (run-hook-with-args 'opencode-chat-on-session-deleted-hook event))

(defun opencode-chat--on-session-error (event)
  "Handle a `session.error' SSE EVENT.
Skips MessageAbortedError (normal abort, not a real error)."
  (let* ((props (plist-get event :properties))
         (error-obj (plist-get props :error))
         (error-name (when error-obj (plist-get error-obj :name)))
         (error-data (when error-obj (plist-get error-obj :data))))
    (opencode--debug "opencode-chat: on-session-error name=%s data=%s" error-name error-data)
    (opencode-chat--clear-queued-state)
    (opencode-chat--hide-retry-indicator)
    (opencode-chat--force-clear-refresh-guard)
    (unless (equal error-name "MessageAbortedError")
      (opencode-chat--set-busy nil)
      (message "Session error: %s%s"
               error-name
               (if error-data (format " - %s" error-data) ""))))
  (run-hook-with-args 'opencode-chat-on-session-error-hook event))

(defun opencode-chat--on-installation-update-available (event)
  "Handle an `installation.update-available' SSE EVENT.
Stores the update info in buffer-local var.  The notification appears
on the next natural re-render (session.idle, manual refresh, etc.).
No immediate HTTP fetch is needed for a cosmetic footer line."
  (let* ((props (plist-get event :properties))
         (current (plist-get props :current))
         (latest (plist-get props :latest)))
    (opencode--debug "opencode-chat: installation.update-available current=%s latest=%s"
             current latest)
    (opencode-chat--set-update-available (list :current current :latest latest))
    (run-hook-with-args 'opencode-chat-on-installation-update-available-hook event)))

(defun opencode-chat--on-todo-updated (event)
  "Handle a `todo.updated' SSE EVENT.
Updates the inline todo list in the chat footer.  The todos vector
from the event is stored in `(opencode-chat--inline-todos)' and the
inline todo section is re-rendered cheaply."
  (let* ((props (plist-get event :properties))
         (todos (plist-get props :todos)))
    (opencode--debug "opencode-chat: on-todo-updated session=%s count=%d"
             (opencode-chat--session-id) (length todos))
    (opencode-chat--set-inline-todos todos)
    (opencode-chat--refresh-inline-todos todos)
    (run-hook-with-args 'opencode-chat-on-todo-updated-hook event)))


(defun opencode-chat--on-part-updated (event)
  "Handle a `message.part.updated' or `message.part.delta' SSE EVENT.
Normalizes both SSE formats, delegates to `opencode-chat-message-update-part',
and handles chat-level side effects based on the return value."
  (let* ((props (plist-get event :properties))
         (part  (plist-get props :part))
         ;; Normalize both SSE formats
         (part-id   (or (plist-get part :id) (plist-get props :partID)))
         (msg-id    (or (plist-get part :messageID) (plist-get props :messageID)))
         (part-type (plist-get part :type))
         (delta     (plist-get props :delta)))
    (opencode--debug "opencode-chat: on-part-updated part=%s type=%s delta=%s"
                     part-id part-type (and delta t))
    (pcase (opencode-chat-message-update-part msg-id part-id part-type part delta)
      (:streamed
       (when-let* ((timer (opencode-chat--refresh-timer)))
         (cancel-timer timer)
         (opencode-chat--set-refresh-timer nil))
       (opencode-chat--schedule-streaming-fontify))
      (:need-msg
       (when-let* ((timer (opencode-chat--refresh-timer)))
         (cancel-timer timer)
         (opencode-chat--set-refresh-timer nil))
       ;; Bootstrap message then retry
       (when (opencode-chat-message-messages-end)
         (let* ((info (or (opencode-chat--streaming-assistant-info)
                         (list :role "assistant"
                               :id msg-id
                               :agent (opencode-chat--effective-agent)
                               :modelID (plist-get (opencode-chat--effective-model) :modelID)
                               :time (list :created (* (float-time) 1000))))))
           (opencode-chat-message-upsert msg-id info)
           ;; Retry now that message exists
           (when (eq :streamed
                     (opencode-chat-message-update-part
                      msg-id part-id part-type part delta))
             (opencode-chat--schedule-streaming-fontify)))))
      (:upserted nil)
      (:rendered nil)
      ('nil nil)  ; finalized part — no-op
      (_ (opencode-chat--schedule-refresh)))
    (run-hook-with-args 'opencode-chat-on-part-updated-hook event)))

(defun opencode-chat--prev-message ()
  "Move to the previous message."
  (interactive)
  (opencode-ui--prev-section))

(defun opencode-chat--next-message ()
  "Move to the next message."
  (interactive)
  (opencode-ui--next-section))

(defun opencode-chat--fetch-inline-todos ()
  "Fetch todos for the current session asynchronously.
Updates `(opencode-chat--inline-todos)' and refreshes the inline todo section."
  (when-let* ((session-id (opencode-chat--session-id)))
    (let ((buf (current-buffer)))
      (opencode-api-get
       (format "/session/%s/todo" session-id)
       (lambda (response)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (opencode-chat--debug-cursor-trace "todo-cb-enter")
             (when-let* ((body (plist-get response :body)))
               (opencode-chat--set-inline-todos body)
               (opencode-chat--refresh-inline-todos body))
             (opencode-chat--debug-cursor-trace "todo-cb-exit"))))))))


(defun opencode-chat--refresh (&optional initial)
  "Refresh chat from the server (async).
When INITIAL is non-nil, passes fetched messages to `opencode-chat--state-init'
so it can extract agent/model from the last assistant message (first open).
When nil (live re-refresh), state-init preserves existing state set by SSE.

Fetches messages and session data without blocking Emacs.
Skips the fetch when the session is busy (streaming/tool calls) to avoid
slow /message responses that freeze Emacs; marks the buffer stale so the
next `session.idle' event triggers the refresh.
Uses the refresh state machine (see `opencode-chat--refresh-begin'):
busy → `stale' (no HTTP); in-flight → `in-flight-pending' (coalesced);
otherwise → `in-flight' (HTTP fetch chain).  When the in-flight chain
completes, it checks for a pending request and fires exactly one more
refresh.  This ensures at most two overlapping request chains."
  (interactive)
  (when (opencode-chat--session-id)
    (cond
     ;; Busy guard: skip refresh during streaming — /message is too slow.
     ((opencode-chat--busy)
      (opencode--debug "opencode-chat: refresh skipped (busy) sid=%s"
                       (opencode-chat--session-id))
      (opencode-chat--mark-stale))
     ;; State machine: coalesce if already in-flight, else proceed.
     ((not (opencode-chat--refresh-begin))
      (opencode--debug "opencode-chat: refresh coalesced (state=%S) sid=%s"
                       (opencode-chat--refresh-state)
                       (opencode-chat--session-id)))
     (t
      (opencode--debug "opencode-chat: refreshing sid=%s" (opencode-chat--session-id))
      (let ((session-id (opencode-chat--session-id))
            (buf (current-buffer)))
        ;; Fetch pending popups in parallel (fire-and-forget).
        ;; Merges into buffer-local queues; drain-popup-queue at the
        ;; end of render-messages (or the callback itself) picks them up.
        (opencode-chat--fetch-pending-popups buf)
        ;; Fetch messages asynchronously
        (opencode-api-get
         (format "/session/%s/message" session-id)
         (lambda (response)
           (opencode--debug "opencode-chat: refresh messages status=%s msg-count=%s"
                    (plist-get response :status)
                    (and (plist-get response :body)
                         (length (plist-get response :body))))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((messages (plist-get response :body)))
                 ;; Also refresh session info (with stale-on-timeout fallback)
                 (opencode-api-cache-get-session
                  session-id
                  (lambda (session-data)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (when session-data
                          (opencode-chat--set-session session-data))
                        ;; Re-initialize state struct (picks up model context limit etc.)
                        (opencode-chat--state-init (when initial messages))
                        ;; Render messages (populates store), then extract tokens
                        (opencode-chat--render-messages messages)
                        (opencode-chat--debug-cursor-trace "after-render")
                        (opencode-chat--recompute-cached-tokens-from-store)
                        (opencode-chat--debug-cursor-trace "after-recompute-tokens")
                        ;; Footer was already rendered by render-messages
                        ;; with nil tokens; refresh now that tokens are set.
                        (opencode-chat--refresh-footer)
                        (opencode-chat--debug-cursor-trace "after-refresh-footer")
                        ;; Fetch todos asynchronously for inline display
                        (opencode-chat--fetch-inline-todos)
                        (opencode-chat--debug-cursor-trace "after-fetch-todos")
                        ;; Run post-refresh hook
                        (run-hook-with-args 'opencode-chat-on-refresh-hook
                                            (list :messages messages
                                                  :session (opencode-chat--session)))
                        (opencode-chat--debug-cursor-trace "after-hook")
                        ;; State machine: transition out of in-flight.
                        ;; If another refresh was requested during this one,
                        ;; refresh-end returns t and we fire exactly one retry.
                        (when (opencode-chat--refresh-end)
                          (opencode--debug "opencode-chat: re-firing pending refresh sid=%s"
                                           (opencode-chat--session-id))
                          (opencode-chat--refresh))))))))))
         (list (cons "limit" (number-to-string opencode-chat-message-limit)))))))))

(defun opencode-chat--debug-cursor-trace (label)
  "Log a single-line cursor-state snapshot tagged with LABEL."
  (let ((win (get-buffer-window (current-buffer))))
    (opencode--debug
     "opencode-chat: TRACE %s point=%d win-pt=%s win-start=%s input-start=%s content-start=%s point-max=%d in-input=%s at-max=%s"
     label
     (point)
     (and win (window-point win))
     (and win (window-start win))
     (and (opencode-chat--input-start)
          (marker-position (opencode-chat--input-start)))
     (ignore-errors (opencode-chat--input-content-start))
     (point-max)
     (ignore-errors (opencode-chat--in-input-area-p))
     (= (point) (point-max)))))

(defun opencode-chat--refresh-sync (&optional initial)
  "Refresh chat from the server (synchronous).
INITIAL has the same meaning as in `opencode-chat--refresh'.
Use only for initial load or testing; prefer `opencode-chat--refresh'."
  (when (opencode-chat--session-id)
    (condition-case err
        (let ((messages (opencode-api-get-sync
                        (format "/session/%s/message" (opencode-chat--session-id)))))
          (opencode-chat--set-session
           (opencode-api-get-sync
            (format "/session/%s" (opencode-chat--session-id))))
          (opencode-chat--state-init (when initial messages))
          (opencode-chat--render-messages messages)
          (opencode-chat--recompute-cached-tokens-from-store)
          (opencode-chat--refresh-footer)
          (run-hook-with-args 'opencode-chat-on-refresh-hook
                              (list :messages messages
                                    :session (opencode-chat--session))))
      (error (message "Refresh failed: %s" (error-message-string err))))))

;;; --- Open chat buffer ---

(defun opencode-chat-open (session-id &optional directory _display-action)
  "Open a chat buffer for SESSION-ID.
Fetches session data asynchronously -- the buffer appears immediately
with a loading indicator, then populates when data arrives.
DIRECTORY, if non-nil, pins the X-OpenCode-Directory header so that
API calls use the correct project even for cross-project sessions.
The buffer is always displayed in the current window via
`display-buffer-same-window'.  The third argument is accepted for
backward compatibility and ignored."
  (interactive "sSession ID: ")
  ;; Check for existing buffer first
  (let ((existing (opencode-chat--find-buffer session-id)))
    (if existing
        (progn
          (pop-to-buffer existing '(display-buffer-same-window))
          (with-current-buffer existing
            (opencode-chat--refresh)))
      ;; Create a temporary buffer name, then rename after session loads
      (let* ((tmp-name (format "*opencode: loading %s...*"
                                (string-limit session-id 12)))
             (buf (get-buffer-create tmp-name)))
        (with-current-buffer buf
          (unless (eq major-mode 'opencode-chat-mode)
            (opencode-chat-mode))
           (opencode-chat--set-session-id session-id)
          (opencode--register-chat-buffer session-id (current-buffer))
          ;; Pin directory header IMMEDIATELY so the initial GET
          ;; /session/:id AND subsequent prompt_async use the correct
          ;; X-OpenCode-Directory.  Callers that know the project
          ;; directory pass it explicitly; without it the header
          ;; falls through to `default-directory' (inherited from
          ;; whichever buffer was current at buffer-creation time),
          ;; which may belong to a different project — causing the
          ;; server to silently drop requests.
          (when-let ((dir (or directory
                              (bound-and-true-p opencode-default-directory))))
            (setq-local opencode-api-directory (directory-file-name (expand-file-name dir)))
            (setq default-directory (file-name-as-directory (expand-file-name dir))))
          ;; Show loading state (read-only so user doesn't type into it)
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
            (erase-buffer)
            (insert (propertize "Loading session...\n"
                                'face 'font-lock-comment-face
                                'read-only t)))
          ;; Note: SSE hooks are registered at module load time (see line ~2150)
          )
        (pop-to-buffer buf '(display-buffer-same-window))
        ;; Retry cache load if it failed during startup
        (opencode-api-cache-ensure-loaded)
        ;; Fetch session info async, then rename buffer and load messages
        (opencode-api-get
         (format "/session/%s" session-id)
         (lambda (response)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((session (plist-get response :body)))
                 (when session
                    (opencode-chat--set-session session)
                   ;; Pin API directory from session's authoritative data.
                   ;; The server stores the correct project directory;
                   ;; opencode-default-directory may differ (e.g. $HOME).
                   (when-let ((dir (plist-get session :directory)))
                     (setq-local opencode-api-directory (directory-file-name dir))
                     (setq default-directory (file-name-as-directory dir)))
                   ;; Rename buffer to proper name
                   (let ((proper-name (opencode-chat--buffer-name session)))
                     (unless (get-buffer proper-name)
                       (rename-buffer proper-name)))))
               (opencode-chat--refresh t)))))))))  ;; initial open

;;; --- Buffer lookup ---

(defun opencode-chat--find-buffer (session-id)
  "Find the chat buffer for SESSION-ID, or nil.
Tries the buffer registry for O(1) lookup first, then
falls back to scanning `buffer-list'."
  (or (and (fboundp 'opencode--chat-buffer-for-session)
           (opencode--chat-buffer-for-session session-id))
      (seq-find
       (lambda (buf)
         (with-current-buffer buf
           (and (eq major-mode 'opencode-chat-mode)
                (string= (opencode-chat--session-id) session-id))))
       (buffer-list))))

(provide 'opencode-chat)
;;; opencode-chat.el ends here
