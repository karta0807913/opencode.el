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
  ;; --- Session identity + agent/model overrides ---
  (session-id nil
   :documentation "Session ID string for this chat buffer.")
  (session nil
   :documentation "Cached session plist from the server.")
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

  ;; --- Migrated from chat-message.el (9 slots) ---
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
  (streaming-part-id nil
   :documentation "ID of the part currently receiving streaming deltas, or nil.")
  (streaming-msg-id nil
   :documentation "ID of the message whose part is streaming, or nil.")
  (streaming-fontify-timer nil
   :documentation "Idle timer for deferred markdown fontify of the streaming region.")
  (streaming-region-start nil
   :documentation "Marker at the start of the current streaming region, or nil.")
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

(defun opencode-chat--session-id ()
  "Return the session ID for this chat buffer."
  (and opencode-chat--state
       (opencode-chat-state-session-id opencode-chat--state)))

(defun opencode-chat--session ()
  "Return the cached session plist for this chat buffer."
  (and opencode-chat--state
       (opencode-chat-state-session opencode-chat--state)))

(defun opencode-chat--busy ()
  "Return non-nil when waiting for a response."
  (and opencode-chat--state
       (opencode-chat-state-busy opencode-chat--state)))

(defun opencode-chat--queued ()
  "Return non-nil when a message is queued (sent, awaiting assistant)."
  (and opencode-chat--state
       (opencode-chat-state-queued opencode-chat--state)))

;;; --- Setters ---

(defun opencode-chat--set-session-id (id)
  "Set the session ID to ID."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-session-id opencode-chat--state) id))

(defun opencode-chat--set-session (session)
  "Set the session plist to SESSION.
If SESSION has a `:parentID' we proactively populate the global
child→parent cache so popup dispatch can route events to the root
buffer without needing an HTTP round-trip.  This is cheap insurance:
every set-session call either re-asserts a known link or records a
new one as soon as the buffer learns about it."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-session opencode-chat--state) session)
  (when-let* ((sid (and session (plist-get session :id)))
              (parent-id (plist-get session :parentID)))
    (opencode-domain-child-parent-put sid parent-id)))

(defun opencode-chat--set-busy (busy)
  "Set the busy flag to BUSY."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-busy opencode-chat--state) busy))

(defun opencode-chat--set-queued (queued)
  "Set the queued flag to QUEUED."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-queued opencode-chat--state) queued))

(defun opencode-chat--pending-msg-ids ()
  "Return the list of pending (unacknowledged) message IDs."
  (and opencode-chat--state
       (opencode-chat-state-pending-msg-ids opencode-chat--state)))

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

(defun opencode-chat--set-agent (value)
  "Set the `agent' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-agent opencode-chat--state) value))

(defun opencode-chat--set-agent-color (value)
  "Set the `agent-color' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-agent-color opencode-chat--state) value))

(defun opencode-chat--set-model-id (value)
  "Set the `model-id' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-model-id opencode-chat--state) value))

(defun opencode-chat--set-provider-id (value)
  "Set the `provider-id' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-provider-id opencode-chat--state) value))

(defun opencode-chat--set-variant (value)
  "Set the `variant' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-variant opencode-chat--state) value))

(defun opencode-chat--set-context-limit (value)
  "Set the `context-limit' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-context-limit opencode-chat--state) value))

(defun opencode-chat--set-tokens (value)
  "Set the `tokens' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-tokens opencode-chat--state) value))

(defun opencode-chat--set-update-available (value)
  "Set the `update-available' slot to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-update-available opencode-chat--state) value))

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
    (setq opencode-chat--state (opencode-chat-state-create)))
  (let* ((existing-agent (opencode-chat-state-agent opencode-chat--state))
         (existing-model-id (opencode-chat-state-model-id opencode-chat--state))
         (existing-provider-id (opencode-chat-state-provider-id opencode-chat--state))
         (resolved (opencode-chat--resolve-defaults
                    messages existing-agent existing-model-id existing-provider-id)))
    (opencode-chat--set-agent (plist-get resolved :agent))
    (opencode-chat--set-agent-color (plist-get resolved :agent-color))
    (opencode-chat--set-model-id (plist-get resolved :model-id))
    (opencode-chat--set-provider-id (plist-get resolved :provider-id))
    (opencode-chat--set-context-limit (plist-get resolved :context-limit))))


(defun opencode-chat--state-ensure ()
  "Ensure `opencode-chat--state' is non-nil, creating if needed.
Also lazily initialises the three hash-table slots (`store',
`diff-cache', `diff-shown') so accessor callers never see nil."
  (unless opencode-chat--state
    (opencode-chat--state-init))
  (unless (opencode-chat-state-store opencode-chat--state)
    (setf (opencode-chat-state-store opencode-chat--state)
          (make-hash-table :test 'equal)))
  (unless (opencode-chat-state-diff-cache opencode-chat--state)
    (setf (opencode-chat-state-diff-cache opencode-chat--state)
          (make-hash-table :test 'equal)))
  (unless (opencode-chat-state-diff-shown opencode-chat--state)
    (setf (opencode-chat-state-diff-shown opencode-chat--state)
          (make-hash-table :test 'equal)))
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

(defmacro opencode-chat-state--define-slot (slot)
  "Define reader + writer functions for SLOT of `opencode-chat-state'.
Reader is `opencode-chat--SLOT': returns nil when no state exists yet
so callers that probe (e.g. \"was there a previous render?\") see the
same value they used to see from a nil-initialised `defvar-local'.
Writer is `opencode-chat--set-SLOT': calls `--state-ensure' first so
writes always have somewhere to land."
  (let* ((getter (intern (format "opencode-chat--%s" slot)))
         (setter (intern (format "opencode-chat--set-%s" slot)))
         (struct-accessor (intern (format "opencode-chat-state-%s" slot))))
    `(progn
       (defun ,getter ()
         ,(format "Return the %s slot of `opencode-chat--state', or nil." slot)
         (and opencode-chat--state
              (,struct-accessor opencode-chat--state)))
       (defun ,setter (value)
         ,(format "Set the %s slot of `opencode-chat--state' to VALUE." slot)
         (opencode-chat--state-ensure)
         (setf (,struct-accessor opencode-chat--state) value)))))

;; --- Migrated from chat.el (6 slots) ---
(opencode-chat-state--define-slot refresh-timer)
(opencode-chat-state--define-slot refresh-state)
(opencode-chat-state--define-slot streaming-assistant-info)
(opencode-chat-state--define-slot queued-overlay)
(opencode-chat-state--define-slot retry-overlay)
(opencode-chat-state--define-slot disposed-refresh-timer)

;; --- Migrated from chat-message.el (9 slots) ---
;;
;; `store', `diff-cache', `diff-shown' are hash tables.  Their readers
;; call `--state-ensure' (which auto-allocates the tables on demand) so
;; callers never see nil — matches the pre-migration invariant where
;; the defvar-local defaulted to a fresh hash.
(defun opencode-chat--store ()
  "Return the `store' hash table, auto-allocating it on first access."
  (opencode-chat--state-ensure)
  (opencode-chat-state-store opencode-chat--state))

(defun opencode-chat--set-store (value)
  "Set the `store' slot of `opencode-chat--state' to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-store opencode-chat--state) value))

(defun opencode-chat--diff-cache ()
  "Return the `diff-cache' hash table, auto-allocating it on first access."
  (opencode-chat--state-ensure)
  (opencode-chat-state-diff-cache opencode-chat--state))

(defun opencode-chat--set-diff-cache (value)
  "Set the `diff-cache' slot of `opencode-chat--state' to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-diff-cache opencode-chat--state) value))

(defun opencode-chat--diff-shown ()
  "Return the `diff-shown' hash table, auto-allocating it on first access."
  (opencode-chat--state-ensure)
  (opencode-chat-state-diff-shown opencode-chat--state))

(defun opencode-chat--set-diff-shown (value)
  "Set the `diff-shown' slot of `opencode-chat--state' to VALUE."
  (opencode-chat--state-ensure)
  (setf (opencode-chat-state-diff-shown opencode-chat--state) value))

(opencode-chat-state--define-slot current-message-id)
(opencode-chat-state--define-slot streaming-part-id)
(opencode-chat-state--define-slot streaming-msg-id)
(opencode-chat-state--define-slot streaming-fontify-timer)
(opencode-chat-state--define-slot streaming-region-start)
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
