;;; opencode-event.el --- Canonical backend event routing -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Centralised canonical backend-event routing.  OpenCode SSE and Pi RPC both
;; enter here through `opencode-event-dispatch'.  Existing chat/popup/sidebar
;; handlers still receive OpenCode-shaped legacy event plists during this
;; migration, but canonical `opencode-backend-event' plists are now the sole
;; internal routing seam.
;;
;; Two invariants the old code established and this module preserves
;; explicitly:
;;
;;  1. No route hook installation.  `opencode-event-route' records routes only;
;;     `opencode-event-dispatch' reads this table.  Stale hook functions from
;;     the previous hook-installed design are removed at load time so reloading
;;     during development does not double-dispatch.
;;
;;  2. Introspectable routing table.  The scenario replay framework
;;     (test/opencode-scenario-test.el) needs to discover the
;;     event-type → handler mapping at replay time without subscribing
;;     to hooks.  It currently reads an alist named
;;     `opencode--sse-chat-dispatch-specs'; the shim below re-exports
;;     that name so the test contract keeps working.
;;
;; Four dispatch strategies, chosen per-route:
;;
;;   chat     — Look up chat buffer by session-id (registry), run
;;              handler there.  Fallback: broadcast to all chat buffers.
;;   popup    — Like chat, but ALSO dispatch to the root-parent buffer
;;              on a child session so the popup appears in both places.
;;              Falls back to async HTTP walk on cache miss.
;;   sidebar  — Dispatch to the single global sidebar buffer.
;;   global   — Run the handler directly (no buffer lookup).
;;
;; Routes are declared inline via `opencode-event-route'.  Each call records
;; the entry in `opencode-event-routes' for dispatch and introspection.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'opencode-log)
(require 'opencode-domain)
(require 'opencode-backend-core)

;; Forward declarations.  opencode.el `require's this module during its
;; top-level load; by the time the event routes fire at runtime, every
;; referenced symbol below is defined.  These declares keep the
;; byte-compiler quiet without introducing circular requires.
(declare-function opencode--chat-buffer-for-session "opencode" (session-id))
(declare-function opencode--all-chat-buffers "opencode" ())
(declare-function opencode--sidebar-buffer-for-project "opencode" ())
(declare-function opencode-chat--session-id-from-event "opencode-chat" (event))
(declare-function opencode-sse--hook-for-type "opencode-sse" (type))
(declare-function opencode-sse--global-hook-for-type "opencode-sse" (type))
(defvar opencode-sse-after-dispatch-hook-global nil)

(defvar opencode-backend-event-hook nil
  "Hook run with each canonical backend event before internal routing.
Each function receives two arguments: the canonical backend event and the
legacy OpenCode-shaped event that current handlers consume.")

;;; --- Routing table ---

(defvar opencode-event-routes nil
  "Alist of (EVENT-TYPE HOOK HANDLER STRATEGY) for every declared route.
Populated by `opencode-event-route'.  Introspected by tests and by the
scenario replay framework to discover the event→handler mapping.

EVENT-TYPE is the string as it appears in the SSE payload (\"message.updated\").
HOOK is the `opencode-sse-*-hook' symbol that fires for this event.
HANDLER is the actual handler function receiving the event plist.
STRATEGY is one of `chat', `popup', `sidebar', `global'.")

(defun opencode-event--route-type (route)
  "Return ROUTE's canonical event type without any suffix route marker."
  (let ((event-type (car route)))
    (or (seq-some
         (lambda (suffix)
           (and (string-suffix-p suffix event-type)
                (substring event-type 0 (- (length event-type)
                                           (length suffix)))))
         '(".sidebar" ".global"))
        event-type)))

(defun opencode-event--route-matches-p (route event-type)
  "Return non-nil when ROUTE applies to canonical EVENT-TYPE."
  (equal (opencode-event--route-type route) event-type))

(defun opencode-event--put-route (event-type hook handler strategy)
  "Insert or replace the route entry for EVENT-TYPE.
Idempotent under reload: a second registration for the same EVENT-TYPE
overwrites the first.  HOOK, HANDLER, STRATEGY are stored verbatim."
  (let ((entry (list event-type hook handler strategy)))
    (setq opencode-event-routes
          (cons entry
                (seq-remove (lambda (e) (equal (car e) event-type))
                            opencode-event-routes)))))

;;; --- Dispatch strategies ---

(defun opencode-event--hook-for-event (event)
  "Return the global SSE hook symbol for EVENT, or nil if unknown."
  (when-let* ((event-type (plist-get event :type)))
    (or (and (fboundp 'opencode-sse--hook-for-type)
             (opencode-sse--hook-for-type event-type))
        (when-let* ((entry (seq-find (lambda (route)
                                        (opencode-event--route-matches-p
                                         route event-type))
                                      opencode-event-routes)))
          (nth 1 entry)))))

(defun opencode-event--local-hook-functions (hook)
  "Return non-nil when HOOK has local listeners in the current buffer."
  (and hook (local-variable-p hook (current-buffer))))

(defun opencode-event--run-local-sse-hook (event)
  "Run buffer-local SSE hook listeners for EVENT.
This is the chat-buffer-local bridge for users who add SSE hooks with
LOCAL non-nil."
  (dolist (hook (delq nil (delete-dups
                           (list 'opencode-sse-event-hook
                                 (opencode-event--hook-for-event event)))))
    (when (opencode-event--local-hook-functions hook)
      (condition-case err
          (run-hook-with-args hook event)
        (error
         (opencode--debug "opencode-event: local hook error in %s: %S"
                          (buffer-name) err))))))

(defun opencode-event--dispatch-chat-buffer (buf handler event)
  "Run HANDLER for EVENT inside chat BUF."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (condition-case err
          (funcall handler event)
        (error
         (opencode--debug "opencode-event: handler error in %s: %S"
                          (buffer-name) err))))))

(defun opencode-event--dispatch-chat (handler event)
  "Run HANDLER for EVENT against the chat buffer registered for the session.
When the event has no session-id, broadcast to every live chat buffer.
Uses O(1) registry lookup."
  (let ((sid (opencode-chat--session-id-from-event event)))
    (cond
     (sid
       (opencode-event--dispatch-chat-buffer
        (opencode--chat-buffer-for-session sid) handler event))
     (t
       (dolist (buf (opencode--all-chat-buffers))
         (opencode-event--dispatch-chat-buffer buf handler event))))))

(defun opencode-event--dispatch-to-buffer (buf handler event)
  "Run HANDLER for EVENT inside BUF, guarded by `condition-case'."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (condition-case err
          (funcall handler event)
        (error
         (opencode--debug "opencode-event: handler error in %s: %S"
                          (buffer-name) err))))))

(defun opencode-event--dispatch-local-to-buffer (buf event)
  "Run only EVENT's buffer-local SSE hook listeners inside BUF."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (opencode-event--run-local-sse-hook event))))

(defun opencode-event--forward-local (event)
  "Forward EVENT to matching chat-buffer-local SSE hook listeners.
If EVENT has a session-id, dispatch to that session's buffer and its root
parent buffer when known.  If EVENT has no session-id, broadcast to all
registered chat buffers."
  (let* ((sid (opencode-chat--session-id-from-event event))
         (buf (when sid (opencode--chat-buffer-for-session sid))))
    (cond
     (sid
      (opencode-event--dispatch-local-to-buffer buf event)
      (let* ((root-id (opencode-domain-find-root-session sid))
             (root-buf (when (and root-id (not (equal root-id sid)))
                         (opencode--chat-buffer-for-session root-id))))
        (opencode-event--dispatch-local-to-buffer root-buf event)))
     (t
      (dolist (chat-buf (opencode--all-chat-buffers))
        (opencode-event--dispatch-local-to-buffer chat-buf event))))))

(defconst opencode-event--popup-max-walk 8
  "Maximum number of /session/:id lookups the popup walk will chain.
Each lookup discovers one more parent level.  A depth greater than this
is almost certainly a cycle or corrupted server metadata; the walk
bails silently rather than recurse further.")

(defun opencode-event--dispatch-popup (handler event &optional depth)
  "Run HANDLER for popup EVENT against originating + root-parent buffers.
When the event targets a child session, dispatch to BOTH the child's
buffer (if open) AND the root ancestor's buffer so the popup appears in
both places and is dismissed together.  Falls back to async HTTP walk
on cache miss; DEPTH is the internal retry counter (nil at entry)."
  (let* ((depth (or depth 0))
         (sid (opencode-chat--session-id-from-event event))
         (buf (when sid (opencode--chat-buffer-for-session sid))))
    (cond
      ;; Direct buffer — dispatch here AND at root parent (if different)
      (buf
       (opencode-event--dispatch-to-buffer buf handler event)
       (let* ((root-id (opencode-domain-find-root-session sid))
              (root-buf (when (and root-id (not (equal root-id sid)))
                          (opencode--chat-buffer-for-session root-id))))
         (opencode-event--dispatch-to-buffer root-buf handler event)))
     ;; Depth cap — bail rather than loop
     ((>= depth opencode-event--popup-max-walk)
      (opencode--debug
       "opencode-event: popup dispatch bailed at depth %d (sid=%s) — cycle or overflow"
       depth sid))
     ;; No direct buffer — walk cache, dispatch at furthest ancestor or fetch one level up
     (sid
      (let* ((root-id (opencode-domain-find-root-session sid))
             (root-buf (opencode--chat-buffer-for-session root-id)))
        (if root-buf
            (opencode-event--dispatch-to-buffer root-buf handler event)
          ;; Fetch parentID of the furthest known ancestor and retry.
          (opencode-backend-get-session
           root-id
           (lambda (response)
             (when-let* ((parent-id (plist-get response :parentID))
                         ;; Defend against server-returned self-parent.
                         ((not (equal parent-id root-id))))
               (opencode-domain-child-parent-put root-id parent-id)
               (opencode-event--dispatch-popup handler event (1+ depth))))))))
      ;; No session-id — broadcast
      (t
       (dolist (buf (opencode--all-chat-buffers))
         (opencode-event--dispatch-to-buffer buf handler event))))))

(defun opencode-event--dispatch-sidebar (handler event)
  "Run HANDLER for EVENT inside the global sidebar buffer, if any."
  (opencode-event--dispatch-to-buffer
   (opencode--sidebar-buffer-for-project) handler event))

(defun opencode-event--dispatch-global (handler event)
  "Run HANDLER for EVENT directly, no buffer context."
  (condition-case err
      (funcall handler event)
    (error
     (opencode--debug "opencode-event: global handler error: %S" err))))

;;; --- Route registration ---

(defun opencode-event--dispatcher-symbol (event-type)
  "Return the old interned add-hook target symbol for EVENT-TYPE.
Kept so load/reload can remove stale hook-installed dispatchers left by
older versions of `opencode-event-route'."
  (intern (format "opencode-event--fire-%s"
                  (replace-regexp-in-string "\\." "-" event-type))))

(defun opencode-event--remove-stale-route-hook (event-type hook)
  "Remove old hook-installed route dispatcher for EVENT-TYPE from HOOK."
  (let* ((sym (opencode-event--dispatcher-symbol event-type))
         (global-hook (intern (format "%s-global" (symbol-name hook)))))
    (when (boundp global-hook)
      (remove-hook global-hook sym))
    (when (fboundp sym)
      (fmakunbound sym))))

(defun opencode-event--dispatch-route (route event)
  "Dispatch legacy EVENT through one internal ROUTE."
  (let ((handler (nth 2 route))
        (strat (nth 3 route)))
    (pcase strat
      ('chat    (opencode-event--dispatch-chat handler event))
      ('popup   (opencode-event--dispatch-popup handler event))
      ('sidebar (opencode-event--dispatch-sidebar handler event))
      ('global  (opencode-event--dispatch-global handler event))
      (_ (opencode--debug "opencode-event: unknown strategy %S for %s"
                          strat (car route))))))

(defun opencode-event--canonical-message-info (backend-event)
  "Return OpenCode-shaped :info plist for BACKEND-EVENT's message."
  (let* ((message (plist-get backend-event :message))
         (raw (plist-get message :raw))
         (time (plist-get raw :time)))
    (append
     (list :id (or (plist-get backend-event :message-id)
                   (plist-get message :id)
                   (plist-get raw :id))
           :sessionID (or (plist-get backend-event :session-id)
                          (plist-get message :session-id)
                          (plist-get raw :sessionID))
           :parentID (or (plist-get message :parent-id)
                         (plist-get raw :parentID))
           :role (or (plist-get message :role)
                     (plist-get raw :role)))
     (when (or (plist-get message :agent) (plist-get raw :agent))
       (list :agent (or (plist-get message :agent) (plist-get raw :agent))))
     (when (or (plist-get message :model-id) (plist-get raw :modelID))
       (list :modelID (or (plist-get message :model-id)
                          (plist-get raw :modelID))))
     (when (or (plist-get message :provider-id) (plist-get raw :providerID))
       (list :providerID (or (plist-get message :provider-id)
                             (plist-get raw :providerID))))
     (when (or (plist-get message :tokens) (plist-get raw :tokens))
       (list :tokens (or (plist-get message :tokens) (plist-get raw :tokens))))
     (when (or (plist-get message :cost) (plist-get raw :cost))
       (list :cost (or (plist-get message :cost) (plist-get raw :cost))))
     (when (or (plist-get message :finish) (plist-get raw :finish))
       (list :finish (or (plist-get message :finish) (plist-get raw :finish))))
     (list :time
           (append
            (when-let ((created (or (plist-get message :created-at)
                                    (plist-get time :created))))
              (list :created created))
            (when-let ((completed (or (plist-get message :completed-at)
                                      (plist-get time :completed))))
              (list :completed completed)))))))

(defun opencode-event--canonical-part (backend-event)
  "Return OpenCode-shaped :part plist for BACKEND-EVENT."
  (let* ((part (plist-get backend-event :part))
         (raw (plist-get part :raw)))
    (append
     (list :id (or (plist-get backend-event :part-id)
                   (plist-get part :id)
                   (plist-get raw :id))
           :sessionID (or (plist-get backend-event :session-id)
                          (plist-get part :session-id)
                          (plist-get raw :sessionID))
           :messageID (or (plist-get backend-event :message-id)
                          (plist-get part :message-id)
                          (plist-get raw :messageID))
           :type (or (plist-get part :type) (plist-get raw :type))
           :text (or (plist-get part :text) (plist-get raw :text))
           :time (or (plist-get part :time)
                     (plist-get raw :time)
                     (list :start 0)))
     (when (or (plist-get part :tool) (plist-get raw :tool))
       (list :tool (or (plist-get part :tool) (plist-get raw :tool))))
     (when (or (plist-get part :state) (plist-get raw :state))
       (list :state (or (plist-get part :state) (plist-get raw :state)))))))

(defun opencode-event-canonical->legacy (backend-event)
  "Convert canonical BACKEND-EVENT to current OpenCode-shaped event plist."
  (let* ((type (plist-get backend-event :type))
         (session-id (plist-get backend-event :session-id))
         (props
          (pcase type
            ((or "message.updated" "message.removed")
             (list :info (opencode-event--canonical-message-info backend-event)))
            ((or "message.part.updated" "message.part.removed")
             (append
              (list :part (opencode-event--canonical-part backend-event))
              (when (plist-member backend-event :delta)
                (list :delta (plist-get backend-event :delta)))))
            ;; Newer OpenCode uses a standalone delta shape instead of putting
            ;; optional :delta beside a full :part on `message.part.updated'.
            ;; Preserve that shape for the legacy chat handler: synthesizing a
            ;; partial :part here would blur the two server event contracts.
            ("message.part.delta"
             (list :sessionID session-id
                   :messageID (plist-get backend-event :message-id)
                   :partID (plist-get backend-event :part-id)
                   :field (plist-get backend-event :field)
                   :delta (plist-get backend-event :delta)))
            ("session.updated"
             (list :info (or (plist-get (plist-get backend-event :session)
                                        :raw)
                             (plist-get backend-event :session)
                             (list :id session-id))))
             ("session.status"
              (list :sessionID session-id
                    :status (plist-get backend-event :status)))
             ("session.diff"
              (list :sessionID session-id
                    :diff (plist-get backend-event :diff)))
             ("todo.updated"
              (list :sessionID session-id
                    :todos (plist-get backend-event :todos)))
             ("session.deleted"
              (list :sessionID session-id
                    :info (list :id session-id)))
             ((or "session.idle" "session.compacted")
              (list :sessionID session-id))
             ("session.error"
              (list :sessionID session-id
                    :error (plist-get backend-event :error)))
             ((or "permission.asked" "question.asked")
              (or (copy-tree (plist-get backend-event :request))
                  (list :id (plist-get backend-event :request-id)
                        :sessionID session-id)))
             ((or "permission.replied"
                  "question.replied"
                  "question.rejected")
              (list :requestID (plist-get backend-event :request-id)
                    :sessionID session-id))
             ("installation.update-available"
              (list :current (plist-get backend-event :current)
                    :latest (plist-get backend-event :latest)))
             (_ (append
                 (when session-id (list :sessionID session-id))
                 (when-let ((error (plist-get backend-event :error)))
                  (list :error error)))))))
    (list :type type
          :properties props
          :directory (plist-get backend-event :directory)
          :backend-event backend-event)))

(defun opencode-event-dispatch (backend-event &optional legacy-event)
  "Dispatch canonical BACKEND-EVENT through all internal routes exactly once.
LEGACY-EVENT, when non-nil, is the original OpenCode-shaped event that public
SSE hooks already saw.  Current internal handlers receive the legacy shape
with `:backend-event' attached."
  (let* ((event-type (plist-get backend-event :type))
         (event (or legacy-event
                    (opencode-event-canonical->legacy backend-event))))
    (setq event (plist-put event :backend-event backend-event))
    (condition-case err
        (run-hook-with-args 'opencode-backend-event-hook backend-event event)
      (error
       (opencode--debug "opencode-event: backend hook error: %S" err)))
    (dolist (route (reverse opencode-event-routes))
      (when (opencode-event--route-matches-p route event-type)
        (opencode-event--dispatch-route route event)))
    ;; Buffer-local SSE hooks are an OpenCode transport compatibility surface,
    ;; not the internal event bus.  Pi and future non-SSE backends must not
    ;; masquerade as native SSE producers.
    (when (eq (plist-get backend-event :backend) 'opencode)
      (opencode-event--forward-local event))))

(defun opencode-event-route (event-type hook handler &optional strategy)
  "Record a route for EVENT-TYPE with HOOK metadata and HANDLER.
STRATEGY is one of `chat', `popup', `sidebar', `global' and defaults
to `chat'.

Records the entry in `opencode-event-routes' for test introspection.
Safe to call repeatedly at load time."
  (let ((strat (or strategy 'chat)))
    (opencode-event--remove-stale-route-hook event-type hook)
    (opencode-event--put-route event-type hook handler strat)))

;;; --- Introspection helpers ---

(defun opencode-event-handler-for (event-type &optional strategy)
  "Return the HANDLER registered for EVENT-TYPE, or nil if unknown.
STRATEGY narrows the lookup when the same event type is multiplexed
across strategies (rare; only popup events are currently dual-routed)."
  (when-let* ((entry (seq-find
                      (lambda (e)
                        (and (or (equal (car e) event-type)
                                 (opencode-event--route-matches-p
                                  e event-type))
                              (or (null strategy) (eq (nth 3 e) strategy))))
                      opencode-event-routes)))
    (nth 2 entry)))

(provide 'opencode-event)
;;; opencode-event.el ends here
