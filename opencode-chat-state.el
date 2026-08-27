;;; opencode-chat-state.el --- Chat buffer state struct -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Consolidated buffer-local state for OpenCode chat buffers.
;; Owns the `opencode-chat-state' cl-defstruct and all session
;; display state: session identity, agent/model overrides, token
;; usage, context info, and update notification.
;;
;; This module sits at the bottom of the chat dependency tree —
;; chat.el, chat-input.el, chat-message.el, and command.el all
;; require it.  It must NOT require any of those modules.

;;; Code:

(require 'cl-lib)
(require 'opencode-agent)
(require 'opencode-chat-resolve)
(require 'opencode-domain)

;;; --- State struct ---

(cl-defstruct (opencode-chat-state (:constructor opencode-chat-state-create)
                                    (:copier nil))
  "Consolidated buffer-local display state for a chat session.
Holds session identity, agent/model overrides, token usage,
context info, update notification, and — after the Step 5
struct migration — all per-buffer rendering / refresh / input
state that used to live in scattered `defvar-local's.

Slots are grouped by the module that originally owned them."
  ;; --- Ownership ---
  (buffer nil
   :documentation "The chat buffer this state describes.
Set once at `opencode-chat--state-init'.  The state is buffer-local, so
this is redundant as storage and load-bearing as a check: every accessor
reads the state of whatever buffer happens to be current, an invisible
precondition that ten modules depend on.  Recording the buffer lets
`--state-ensure' verify it instead of trusting it.")
  ;; --- Session identity + agent/model overrides ---
  (session-id nil
   :documentation "Session ID string for this chat buffer.")
  (session nil
   :documentation "Cached session plist from the server.")
  (backend nil
   :documentation "Backend name symbol for this chat buffer.")
  (agent nil
   :documentation "Effective agent name (string or nil).")
  (agent-color nil
   :documentation "Hex color for the effective agent (string or nil).")
  (model-id nil
   :documentation "Effective model ID (string or nil).
Resolved from config during `opencode-chat--state-init'.")
  (provider-id nil
   :documentation "Effective provider ID (string or nil).
Resolved from config during `opencode-chat--state-init'.")
  (variant nil
   :documentation "Effective variant override (e.g. \"max\"), or nil.")
  (context-limit nil
   :documentation "Model context window size (integer or nil).
Cached from provider data; refreshed on agent/model change.")
  (tokens nil
   :documentation "Normalized token plist or nil.
Plist keys: :total :input :output :reasoning :cache-read :cache-write.")
  (update-available nil
   :documentation "Update info plist (:current VERSION :latest VERSION) or nil.")
  (busy nil
   :documentation "Non-nil when waiting for a response.")
  (queued nil
   :documentation "Non-nil when a message has been sent but no assistant activity yet.
Set optimistically on send, cleared when a server message with ID >=
`pending-msg-id' arrives, or on idle, abort, or error.")
  (pending-msg-ids nil
   :documentation "List of sent-but-unacknowledged message IDs.
Each send adds an ID; acknowledged when a server message with
ID >= the pending ID arrives.  QUEUED clears when this list empties.")

  ;; --- Migrated from chat.el (6 slots) ---
  (refresh-timer nil
   :documentation "Debounce timer for `opencode-chat--refresh'.")
  (refresh-state nil
   :documentation "Refresh state machine.  One of nil / `stale' / `in-flight' /
`in-flight-pending'.  Mutate ONLY through `--mark-stale',
`--refresh-begin', `--refresh-end', `--force-clear-refresh-guard'.")
  (streaming-assistant-info nil
   :documentation "Info plist of the currently-streaming assistant message, or nil.
Cached by `on-message-updated' (which always precedes `on-part-updated')
so Case 2 bootstrap in `on-part-updated' has agent/model to construct
a minimal placeholder.")
  (queued-overlay nil
   :documentation "Overlay showing the QUEUED badge after messages-end, or nil.")
  (retry-overlay nil
   :documentation "Overlay showing a RETRY badge on the last user message, or nil.")
  (disposed-refresh-timer nil
   :documentation "Debounce timer for post-`server.instance.disposed' refresh.")

  ;; --- Migrated from chat-message.el (6 slots) ---
  (store nil
   :documentation "Hash table msg-id → plist (:msg MSG :overlay OV :parts PARTS :state STATE).
Lazily initialised by `--state-ensure'.")
  (current-message-id nil
   :documentation "ID of the message currently being rendered, or nil.
Used by `render-part' to attribute parts to their owning message.")
  (diff-cache nil
   :documentation "Hash table messageID → diff data.
Lazily initialised by `--state-ensure'.")
  (diff-shown nil
   :documentation "Hash table partID → t when inline diff is expanded.
Lazily initialised by `--state-ensure'.")
  (collapse-overrides nil
   :documentation "Hash table section id → non-nil when the user collapsed it.
Records explicit TAB choices, which a section overlay cannot: the
overlay dies with the text it covers, and the transcript is redrawn
whenever a tool advances or the session goes idle.
Lazily initialised by `--state-ensure'.")
  (messages-end nil
   :documentation "Marker at the end of messages, before the input area.")

  ;; --- Migrated from chat-input.el (8 slots) ---
  (optimistic-msg-id nil
   :documentation "ID of the optimistically-rendered user message that is not
yet confirmed by a `message.updated' SSE event, or nil.")
  (input-start nil
   :documentation "Marker at the start of the editable input region.")
  (input-history nil
   :documentation "Ring of previously-sent message texts.")
  (input-history-index nil
   :documentation "Current index into `input-history' (nil when not browsing).")
  (input-history-saved nil
   :documentation "Input text saved when history browsing began, for restore.")
  (mention-cache nil
   :documentation "Cached @-mention candidate list.")
  (inline-todos nil
   :documentation "Cached todos list for inline footer display, or nil.")
  (inline-todos-ov nil
   :documentation "Overlay showing inline todos in the input-area footer, or nil."))

;;; --- Buffer-local instance ---

(defvar-local opencode-chat--state nil
  "Buffer-local `opencode-chat-state' struct for this chat buffer.")

;;; --- Accessors (struct is the sole source of truth) ---

;;; --- Setters ---

(defun opencode-chat--pending-msg-ids (&optional state)
  "Return the list of pending (unacknowledged) message IDs.
STATE defaults to the current buffer's state."
  (when-let* ((s (or state opencode-chat--state)))
    (opencode-chat-state-pending-msg-ids s)))

(defun opencode-chat--add-pending-msg-id (id)
  "Add ID to the pending message IDs set."
  (opencode-chat--state-ensure)
  (let ((current (opencode-chat-state-pending-msg-ids opencode-chat--state)))
    (unless (member id current)
      (setf (opencode-chat-state-pending-msg-ids opencode-chat--state)
            (cons id current)))))

(defun opencode-chat--remove-pending-msg-id (id)
  "Remove ID from the pending message IDs set.
Returns non-nil if the set is now empty."
  (opencode-chat--state-ensure)
  (let ((remaining (delete id (opencode-chat-state-pending-msg-ids opencode-chat--state))))
    (setf (opencode-chat-state-pending-msg-ids opencode-chat--state) remaining)
    (null remaining)))

(defun opencode-chat--clear-pending-msg-ids ()
  "Clear all pending message IDs."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-pending-msg-ids opencode-chat--state) nil))

;;; --- Setters for the 8 session-identity slots ---
;;
;; These slots predate the Step 5 `--define-slot' migration and never
;; got wrapper setters; call sites reached directly into the struct
;; via `setf (opencode-chat-state-<slot> ...)'.  Adding the wrappers
;; here makes every state mutation go through a named setter that
;; calls `--state-ensure' first.  Reads stay on the existing
;; `--effective-*' accessors and the cl-defstruct auto-getters.

;;; --- Initialization ---

(defun opencode-chat--state-init (&optional messages)
  "Initialize `opencode-chat--state' and apply resolved defaults.

Creates the struct if absent, reads any existing agent/model/provider
values, delegates the 5-step priority cascade to
`opencode-chat--resolve-defaults' (in opencode-chat-resolve.el), then
applies the result via the setter API.  The 23 slots migrated in Step
5 (store, input-start, refresh-state, etc.) are preserved by leaving
their slots alone — this is an in-place update."
  (unless opencode-chat--state
    (setq opencode-chat--state (opencode-chat-state-create
                                :buffer (current-buffer))))
  (let* ((existing-agent (opencode-chat-state-agent opencode-chat--state))
         (existing-model-id (opencode-chat-state-model-id opencode-chat--state))
         (existing-provider-id (opencode-chat-state-provider-id opencode-chat--state))
         (existing-variant (opencode-chat-state-variant opencode-chat--state))
         (resolved (opencode-chat--resolve-defaults
                      messages existing-agent existing-model-id
                      existing-provider-id existing-variant
                      (opencode-chat-state-backend opencode-chat--state))))
    (opencode-chat--set-agent (plist-get resolved :agent))
    (opencode-chat--set-agent-color (plist-get resolved :agent-color))
    (opencode-chat--set-model-id (plist-get resolved :model-id))
    (opencode-chat--set-provider-id (plist-get resolved :provider-id))
    (opencode-chat--set-variant (plist-get resolved :variant))
    (opencode-chat--set-context-limit (plist-get resolved :context-limit))))


(defun opencode-chat--state-ensure ()
  "Ensure `opencode-chat--state' is non-nil, creating if needed.
The hash-table slots allocate themselves on first read --- see the
`:lazy' key of `opencode-chat-state--define-slot' --- so they are no
longer initialised here."
  (unless opencode-chat--state
    (opencode-chat--state-init))
  ;; Writing through an accessor while the wrong buffer is current used to
  ;; land silently in that buffer's state --- or lazily create one for it.
  ;; The state knows which buffer it describes, so say so.
  (cl-assert (or (null (opencode-chat-state-buffer opencode-chat--state))
                 (eq (current-buffer)
                     (opencode-chat-state-buffer opencode-chat--state)))
             t "chat state written from a buffer it does not describe")

  ;; Invariant: every setter and accessor calls this, so post-condition
  ;; must be: state exists.  If this ever fires we have a setf that
  ;; nil'd the struct mid-operation.
  (cl-assert opencode-chat--state t "state-ensure failed to allocate struct"))

;;; --- Effective config accessors ---

(defun opencode-chat--effective-agent ()
  "Return the effective agent name for this buffer."
  (opencode-chat--state-ensure)
  (or (opencode-chat-state-agent opencode-chat--state)
      (opencode-agent--default-name)))

(defun opencode-chat--effective-model ()
  "Return the effective model as a plist (:providerID ... :modelID ...).
Reads directly from state (resolved during `opencode-chat--state-init')."
  (opencode-chat--state-ensure)
  (list :providerID (opencode-chat-state-provider-id opencode-chat--state)
        :modelID (opencode-chat-state-model-id opencode-chat--state)))

(defun opencode-chat--effective-variant ()
  "Return the effective variant for this buffer, or nil."
  (opencode-chat--state-ensure)
  (opencode-chat-state-variant opencode-chat--state))

;;; --- Token formatting ---

(defun opencode-chat--format-token-count (n)
  "Format token count N with thousands separator."
  (let ((str (number-to-string n))
        (result ""))
    (let ((len (length str)))
      (dotimes (i len)
        (when (and (> i 0) (zerop (mod (- len i) 3)))
          (setq result (concat result ",")))
        (setq result (concat result (substring str i (1+ i)))))
      result)))

;;; --- Accessors / setters for migrated slots ---
;;
;; Each of the 23 slots migrated from chat.el / chat-message.el /
;; chat-input.el gets a getter `(opencode-chat--FOO)' and a setter
;; `(opencode-chat--set-FOO VALUE)'.  Reads return the struct slot;
;; writes go through `--state-ensure' first so the struct is
;; allocated on demand.
;;
;; Call-site migration is "add a pair of parens":
;;   (gethash k opencode-chat--store)
;;     → (gethash k (opencode-chat--store))
;;   (setq opencode-chat--store nil)
;;     → (opencode-chat--set-store nil)
;;
;; During the migration window (commits 3-6) the old `defvar-local's
;; still exist; the new accessors read/write the struct only, so the
;; two storage locations co-exist.  When every call site has migrated
;; and the `defvar-local' is deleted, the struct becomes sole truth.

(defmacro opencode-chat-state--define-slot (slot &rest keys)
  "Define reader + writer functions for SLOT of `opencode-chat-state'.
Reader is `opencode-chat--SLOT', writer is `opencode-chat--set-SLOT'.

Both take an optional STATE.  Without it they read and write the
current buffer's state, which is the historical behaviour and carries an
invisible precondition: the right buffer must be current.  With it, the
state is addressed directly and the precondition disappears.

KEYS may contain:

  :doc NOUN     describe the slot as NOUN in the generated docstrings,
                instead of naming the slot.
  :default FORM value the reader returns when the slot is nil.
  :lazy FORM    allocate FORM into the slot on first read.  For the
                hash-table slots, which callers expect to exist.
  :after FORM   run FORM after a write, with VALUE bound.  For the one
                slot whose setter has a real side effect rather than
                boilerplate, so it does not have to be the exception
                that gets missed next time this macro changes.

Every accessor comes from here.  Nine used to be written out by hand in
the same shapes, which meant a change to this macro silently missed
them --- including `--session-id', the one nearly every module calls."
  (let* ((getter (intern (format "opencode-chat--%s" slot)))
         (setter (intern (format "opencode-chat--set-%s" slot)))
         (struct-accessor (intern (format "opencode-chat-state-%s" slot)))
         (noun (or (plist-get keys :doc) (format "`%s' slot" slot)))
         (default (plist-get keys :default))
         (lazy (plist-get keys :lazy))
         (after (plist-get keys :after))
         (read-body
          (cond
           (lazy `(let ((s (or state
                               (progn (opencode-chat--state-ensure)
                                      opencode-chat--state))))
                    (or (,struct-accessor s)
                        (setf (,struct-accessor s) ,lazy))))
           (default `(or (when-let* ((s (or state opencode-chat--state)))
                           (,struct-accessor s))
                         ,default))
           (t `(when-let* ((s (or state opencode-chat--state)))
                 (,struct-accessor s))))))
    `(progn
       (defun ,getter (&optional state)
         ,(format "Return the %s.
STATE defaults to the current buffer's state." noun)
         ,read-body)
       (defun ,setter (value &optional state)
         ,(format "Set the %s to VALUE.
STATE defaults to the current buffer's state, which is created if
absent.  Passing it explicitly lets a caller holding a chat state
operate on it without first making its buffer current." noun)
         (let ((s (or state
                      (progn (opencode-chat--state-ensure)
                             opencode-chat--state))))
           (setf (,struct-accessor s) value)
           ,@(when after (list after))
           value)))))

;; --- Migrated from chat.el (6 slots) ---
(opencode-chat-state--define-slot session-id :doc "session ID for this chat")
(opencode-chat-state--define-slot session :doc "cached session plist for this chat"
  ;; Proactively record the child->parent link so popup dispatch can route
  ;; events to the root buffer without an HTTP round-trip.  Every write
  ;; either re-asserts a known link or records a new one as soon as the
  ;; buffer learns about it.
  :after (when-let* ((sid (and value (plist-get value :id)))
                     (parent-id (plist-get value :parentID)))
           (opencode-domain-child-parent-put sid parent-id)))
(opencode-chat-state--define-slot backend :doc "backend name for this chat"
                                  :default 'opencode)
(opencode-chat-state--define-slot busy :doc "busy flag, non-nil while awaiting a response")
(opencode-chat-state--define-slot queued :doc "queued flag, non-nil once a message awaits an assistant")
(opencode-chat-state--define-slot store :doc "message store hash table"
                                  :lazy (make-hash-table :test 'equal))
(opencode-chat-state--define-slot diff-cache :doc "diff cache hash table"
                                  :lazy (make-hash-table :test 'equal))
(opencode-chat-state--define-slot diff-shown :doc "shown-diffs hash table"
                                  :lazy (make-hash-table :test 'equal))
(opencode-chat-state--define-slot collapse-overrides
                                  :doc "user collapse-choice hash table"
                                  :lazy (make-hash-table :test 'equal))
(opencode-chat-state--define-slot agent)
(opencode-chat-state--define-slot agent-color)
(opencode-chat-state--define-slot model-id)
(opencode-chat-state--define-slot provider-id)
(opencode-chat-state--define-slot variant)
(opencode-chat-state--define-slot context-limit)
(opencode-chat-state--define-slot tokens)
(opencode-chat-state--define-slot update-available)
(opencode-chat-state--define-slot refresh-timer)
(opencode-chat-state--define-slot refresh-state)
(opencode-chat-state--define-slot streaming-assistant-info)
(opencode-chat-state--define-slot queued-overlay)
(opencode-chat-state--define-slot retry-overlay)
(opencode-chat-state--define-slot disposed-refresh-timer)

;; --- Migrated from chat-message.el (6 slots) ---
;;
;; `store', `diff-cache', `diff-shown' are hash tables.  Their readers
;; call `--state-ensure' (which auto-allocates the tables on demand) so
;; callers never see nil — matches the pre-migration invariant where
;; the defvar-local defaulted to a fresh hash.
(opencode-chat-state--define-slot current-message-id)
(opencode-chat-state--define-slot messages-end)

;; --- Migrated from chat-input.el (8 slots) ---
(opencode-chat-state--define-slot optimistic-msg-id)
(opencode-chat-state--define-slot input-start)
(opencode-chat-state--define-slot input-history)
(opencode-chat-state--define-slot input-history-index)
(opencode-chat-state--define-slot input-history-saved)
(opencode-chat-state--define-slot mention-cache)
(opencode-chat-state--define-slot inline-todos)
(opencode-chat-state--define-slot inline-todos-ov)

(provide 'opencode-chat-state)
;;; opencode-chat-state.el ends here
