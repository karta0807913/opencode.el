;;; opencode-event.el --- SSE event routing for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Centralised SSE-event routing.  Takes the place of the hand-written
;; opencode--sse-dispatch-* wrappers and the ad-hoc add-hook block that
;; used to live directly in opencode.el.
;;
;; Two invariants the old code established and this module preserves
;; explicitly:
;;
;;  1. Named symbol registration.  Every `add-hook' target is a stable
;;     `defalias'-defined symbol (not a fresh closure), so reloading
;;     opencode.el does not accumulate duplicate handlers.  See the
;;     comment in the original opencode.el:661-665 that named this
;;     concern.
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
;; Routes are declared inline via `opencode-event-route'.  Each call
;; both registers the named dispatcher with `add-hook' AND records the
;; entry in `opencode-event-routes' for introspection.

;;; Code:

(require 'cl-lib)
(require 'opencode-log)
(require 'opencode-domain)

;; Forward declarations.  opencode.el `require's this module during its
;; top-level load; by the time the event routes fire at runtime, every
;; referenced symbol below is defined.  These declares keep the
;; byte-compiler quiet without introducing circular requires.
(declare-function opencode--chat-buffer-for-session "opencode" (session-id))
(declare-function opencode--dispatch-to-chat-buffer "opencode" (session-id handler event))
(declare-function opencode--dispatch-to-all-chat-buffers "opencode" (handler event))
(declare-function opencode--sidebar-buffer-for-project "opencode" ())
(declare-function opencode-chat--session-id-from-event "opencode-chat" (event))
(declare-function opencode-api-get "opencode-api" (path callback &optional query-params))

;;; --- Routing table ---

(defvar opencode-event-routes nil
  "Alist of (EVENT-TYPE HOOK HANDLER STRATEGY) for every declared route.
Populated by `opencode-event-route'.  Introspected by tests and by the
scenario replay framework to discover the event→handler mapping.

EVENT-TYPE is the string as it appears in the SSE payload (\"message.updated\").
HOOK is the `opencode-sse-*-hook' symbol that fires for this event.
HANDLER is the actual handler function receiving the event plist.
STRATEGY is one of `chat', `popup', `sidebar', `global'.")

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

(defun opencode-event--dispatch-chat (handler event)
  "Run HANDLER for EVENT against the chat buffer registered for the session.
When the event has no session-id, broadcast to every live chat buffer.
Uses O(1) registry lookup."
  (let ((sid (opencode-chat--session-id-from-event event)))
    (cond
     (sid
      (when (opencode--chat-buffer-for-session sid)
        (opencode--dispatch-to-chat-buffer sid handler event)))
     (t
      (opencode--dispatch-to-all-chat-buffers handler event)))))

(defun opencode-event--dispatch-to-buffer (buf handler event)
  "Run HANDLER for EVENT inside BUF, guarded by `condition-case'."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (condition-case err
          (funcall handler event)
        (error
         (opencode--debug "opencode-event: handler error in %s: %S"
                          (buffer-name) err))))))

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
          (opencode-api-get
           (format "/session/%s" root-id)
           (lambda (response)
             (when-let* ((body (plist-get response :body))
                         (parent-id (plist-get body :parentID))
                         ;; Defend against server-returned self-parent.
                         ((not (equal parent-id root-id))))
               (opencode-domain-child-parent-put root-id parent-id)
               (opencode-event--dispatch-popup handler event (1+ depth))))))))
     ;; No session-id — broadcast
     (t
      (opencode--dispatch-to-all-chat-buffers handler event)))))

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
  "Return the interned symbol used as the add-hook target for EVENT-TYPE.
Always returns the same symbol for the same EVENT-TYPE so reloading
opencode-event.el does not accumulate duplicate handlers on the hook."
  (intern (format "opencode-event--fire-%s"
                  (replace-regexp-in-string "\\." "-" event-type))))

(defun opencode-event-route (event-type hook handler &optional strategy)
  "Register a named dispatcher for EVENT-TYPE on HOOK with HANDLER.
STRATEGY is one of `chat', `popup', `sidebar', `global' and defaults
to `chat'.

Creates a stable named symbol via `defalias' so `add-hook' deduplicates
on reload.  Records the entry in `opencode-event-routes' for test
introspection.  Safe to call repeatedly at load time."
  (let ((strat (or strategy 'chat))
        (sym (opencode-event--dispatcher-symbol event-type)))
    ;; Install a named dispatcher that invokes the chosen strategy.
    ;; Using `defalias' with a freshly-defined lambda: reload replaces
    ;; the binding but keeps the symbol, so add-hook sees the same
    ;; function identity across reloads.
    (defalias sym
      (pcase strat
        ('chat    (lambda (event) (opencode-event--dispatch-chat handler event)))
        ('popup   (lambda (event) (opencode-event--dispatch-popup handler event)))
        ('sidebar (lambda (event) (opencode-event--dispatch-sidebar handler event)))
        ('global  (lambda (event) (opencode-event--dispatch-global handler event)))
        (_ (error "opencode-event-route: unknown strategy %S" strat))))
    (add-hook hook sym)
    (opencode-event--put-route event-type hook handler strat)))

;;; --- Introspection helpers ---

(defun opencode-event-handler-for (event-type &optional strategy)
  "Return the HANDLER registered for EVENT-TYPE, or nil if unknown.
STRATEGY narrows the lookup when the same event type is multiplexed
across strategies (rare; only popup events are currently dual-routed)."
  (when-let* ((entry (seq-find
                      (lambda (e)
                        (and (equal (car e) event-type)
                             (or (null strategy) (eq (nth 3 e) strategy))))
                      opencode-event-routes)))
    (nth 2 entry)))

(provide 'opencode-event)
;;; opencode-event.el ends here
