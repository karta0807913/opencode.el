;;; opencode-popup.el --- Shared popup infrastructure for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Shared infrastructure for inline popup modules (permission, question).
;; Both popup types follow the same pattern: replace the chat buffer's
;; input area with interactive content, queue multiple requests, and
;; restore the original input after the user responds.
;;
;; This module provides:
;; - Buffer-local state variables for inline popup regions
;; - `opencode-popup--find-chat-buffer' — locate chat buffer for a request
;; - `opencode-popup--restore-input' — restore input area after popup dismissal
;; - `opencode-popup--cleanup' — full cleanup: restore inline, kill standalone, show next
;; - `opencode-popup--show-next' — dequeue and display next pending popup
;; - `opencode-popup--show-matching' — find+pop matching request and display it

;;; Code:
(require 'seq)
(require 'opencode-domain)

;; Cross-module references — avoid circular requires
(declare-function opencode-chat--find-buffer "opencode-chat" (session-id))
(declare-function opencode-chat--render-input-area "opencode-chat-input" ())
(declare-function opencode-chat--input-text "opencode-chat-input" ())
(declare-function opencode-chat--replace-input "opencode-chat-input" (text))
(declare-function opencode-chat--goto-latest "opencode-chat-input" ())
(declare-function opencode-chat-message-messages-end "opencode-chat-message" ())


;;; --- Buffer-local state (inline mode) ---

(defvar-local opencode-popup--saved-input nil
  "Saved user input text before popup was shown inline.")

(defvar-local opencode-popup--inline-p nil
  "Non-nil when this buffer is displaying an inline popup.")

(defvar-local opencode-popup--overlay nil
  "Overlay covering the inline popup region, or nil.
The overlay carries the popup's `keymap' property so the popup keys
shadow the underlying chat-buffer text-property keymap.  Its
`overlay-start' / `overlay-end' bounds also replace the two separate
`region-start' / `region-end' markers used before 2026-04-18.")

;;; --- Chat buffer lookup ---

(defun opencode-popup--find-chat-buffer (request)
  "Find the chat buffer for REQUEST, preferring `current-buffer'.

When `--show' is called from `--show-next' or `--drain-queue', the
current buffer IS the target chat buffer (popup events are dispatched
to each buffer individually, and the pending queue is buffer-local).
Re-doing a session-id lookup would find the CHILD buffer for a
child-session event even when the popup was dispatched to the parent
buffer — causing the popup to render in the wrong buffer or silently
fail if the child buffer is busy/invalid.

Resolution order:
  1. `current-buffer' if it is a chat buffer with `opencode-chat--state'.
  2. Exact session-id match via `opencode-chat--find-buffer'.
  3. Root parent via child→parent cache walk (no sync HTTP).

Never makes synchronous HTTP calls — if the cache misses, returns nil
so the popup stays queued until the async dispatch populates the cache."
  (or
   ;; Prefer current buffer when it's a chat buffer — this is the
   ;; buffer where the event was dispatched and the request was queued.
   (and (boundp 'opencode-chat--state)
        opencode-chat--state
        (current-buffer))
   ;; Fallback: look up by session-id (standalone show, tests, etc.)
   (when-let* ((session-id (plist-get request :sessionID)))
     (or (opencode-chat--find-buffer session-id)
         ;; Child session: walk cache to root parent (no sync HTTP)
         (when-let* ((root-id (opencode-domain-find-root-session session-id))
                     ((not (equal root-id session-id))))
           (opencode-chat--find-buffer root-id))))))

(defun opencode-popup--input-area-valid-p (&optional buffer)
  "Return non-nil if BUFFER (or current buffer) has a valid input area.
Checks that `(opencode-chat--input-start)' is a marker with a valid position.
Child sessions and buffers still loading have no input area."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((marker (opencode-chat--input-start)))
          (and marker (markerp marker) (marker-position marker)))))))

;;; --- Input save/restore ---

(defun opencode-popup--save-input ()
  "Save the current chat buffer input text and mark as inline.
Must be called from within the chat buffer."
  (setq opencode-popup--saved-input (opencode-chat--input-text))
  (setq opencode-popup--inline-p t))

(defun opencode-popup--restore-input ()
  "Restore the chat buffer input area with previously saved text.
Deletes everything from messages-end (popup replaced the entire input
area including separator and prompt), re-renders via `render-input-area',
and restores any saved user text.  Must be called from within
the chat buffer where the popup was displayed."
  (let ((inhibit-read-only t)
        (saved opencode-popup--saved-input)
        (me (opencode-chat-message-messages-end)))
    ;; Delete from messages-end to end of buffer (popup + any residual)
    (when me
      (delete-region (marker-position me) (point-max)))
    ;; Re-render the full input area (separator + prompt + footer)
    (goto-char (marker-position me))
    (opencode-chat--render-input-area)
    ;; Restore saved text if any
    (when (and saved (not (string-empty-p saved)))
      (opencode-chat--replace-input saved))
    ;; Clear inline state — overlay was inside the deleted region, but
    ;; detach it explicitly so the struct never holds a stale overlay.
    (when (overlayp opencode-popup--overlay)
      (delete-overlay opencode-popup--overlay))
    (setq opencode-popup--saved-input nil
          opencode-popup--inline-p nil
          opencode-popup--overlay nil)
    ;; Move cursor to the input area so the user can type immediately.
    (opencode-chat--goto-latest)))

;;; --- Dual-dispatch deduplication ---

;; `opencode-event--dispatch-popup' sends the same request to MORE than
;; one chat buffer (the originating session's buffer AND its root
;; parent's buffer, for nested sub-agents).  This means a popup request
;; can sit in `--pending' queues in several buffers simultaneously AND
;; be displayed in multiple buffers at once.  When the user answers in
;; one buffer, we must purge the duplicates from every OTHER buffer's
;; queue AND dismiss any duplicate overlays — otherwise `--show-next'
;; in cleanup happily re-displays the already-answered request.
;;
;; Two helpers below are the ONLY supported way to do this purge:
;;   * `opencode-popup--purge-pending-by-id' — remove from pending queues.
;;   * `opencode-popup--dismiss-by-id'       — walk buffers, find the
;;     overlay tagged with the matching request-id, run cleanup there.
;;
;; The dismissal walk uses the overlay tag (`opencode-popup-request-id')
;; set by `--with-inline-region' instead of peeking at per-popup-type
;; `--current' buffer-locals.  One walker handles both permission and
;; question popups.
;;
;; Do NOT re-roll hand-written `(dolist (buf (buffer-list)) ...)' loops
;; in permission.el or question.el — they drift and rot.

(defun opencode-popup--purge-pending-by-id (pending-sym request-id)
  "Remove any request whose :id equals REQUEST-ID from PENDING-SYM in every buffer.
PENDING-SYM is a symbol naming a buffer-local list variable (e.g.
`opencode-permission--pending' or `opencode-question--pending').
REQUEST-ID is the request's :id string.

No-op if REQUEST-ID is nil.  Pending items have no overlay yet (they're
not rendered), so this iterates buffer-local queues.  Callers that want
to also dismiss a displayed popup should call `--dismiss-by-id' as well."
  (when request-id
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (local-variable-p pending-sym)
            (let ((queue (symbol-value pending-sym)))
              (when queue
                (set pending-sym
                     (seq-remove (lambda (req)
                                   (equal (plist-get req :id) request-id))
                                 queue))))))))))

(defun opencode-popup--dismiss-by-id (request-id cleanup-fn)
  "Dismiss any displayed popup tagged with REQUEST-ID, in every buffer.
Walks `buffer-list' and, in each live buffer, looks for an overlay
carrying `opencode-popup-request-id' equal to REQUEST-ID.  When found,
CLEANUP-FN is called with no arguments inside that buffer — it is
responsible for clearing per-popup-type state (`--current' variables,
etc.) and for running the standard popup cleanup that drains the next
queued popup.

Replaces the previous `--dismiss-current-in-all-buffers' helper which
needed a `current-sym' argument for each popup type.  The overlay tag
is set uniformly by `--with-inline-region', so one walker handles both
permission and question popups.

No-op if REQUEST-ID is nil."
  (when request-id
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (seq-find
                 (lambda (ov)
                   (equal (overlay-get ov 'opencode-popup-request-id)
                          request-id))
                 (overlays-in (point-min) (point-max)))
            (funcall cleanup-fn)))))))

;;; --- Queue management ---

(defun opencode-popup--show-next (pending-sym show-fn)
  "Pop the next pending request and try to display it.
PENDING-SYM is the symbol of the pending queue variable.
SHOW-FN is called with the request; it must return non-nil on success
or nil if the target buffer is busy (already showing a popup).
On failure the request is pushed back to the front of the queue."
  (when (symbol-value pending-sym)
    (let ((next (pop (symbol-value pending-sym))))
      (unless (funcall show-fn next)
        ;; Target buffer busy — push back
        (push next (symbol-value pending-sym))))))

(defun opencode-popup--show-matching (pending-sym predicate show-fn)
  "Find the first request in PENDING-SYM matching PREDICATE and show it.
PENDING-SYM is the symbol of the pending queue variable.
PREDICATE is called with each request; returns non-nil for a match.
SHOW-FN is called with the matched request; must return non-nil on success.
On failure the request is pushed back to its original position.
Returns non-nil if a matching request was found (regardless of show success)."
  (when-let* ((queue (symbol-value pending-sym))
              (match (seq-find predicate queue)))
    ;; Remove the matched item from queue
    (set pending-sym (delq match (symbol-value pending-sym)))
    (unless (funcall show-fn match)
      ;; Show failed (buffer busy) — push back to front
      (push match (symbol-value pending-sym)))
    t))

;;; --- Cleanup ---

(defun opencode-popup--cleanup (_request buffer-name show-next-fn)
  "Clean up after responding to a popup.
Must be called from within the chat buffer that hosts the popup — both
the direct keymap-dispatched commands (`question--submit',
`permission--reply') and the SSE `on-replied'/`on-rejected' handlers
wrap their cleanup calls in `with-current-buffer', so `current-buffer'
is guaranteed to be the right one.  Relying on `current-buffer' (instead
of a global tracker) is what makes concurrent popups in different chat
buffers safe: each cleanup only touches its own buffer.
BUFFER-NAME is the standalone fallback buffer name to kill.
SHOW-NEXT-FN is called with no arguments to display the next queued
popup of the same type.  After that, `opencode-popup--drain-queue' is
called to try other popup types (e.g. question after permission dismiss)."
  ;; Restore inline in the buffer that actually has the popup.
  ;; `current-buffer' is always that buffer — see docstring.
  (let ((chat-buf (current-buffer)))
    (when (and chat-buf (buffer-live-p chat-buf))
      (when opencode-popup--inline-p
        (opencode-popup--restore-input)))
    ;; Kill standalone buffer if it exists
    (when-let ((buf (get-buffer buffer-name)))
      (let ((win (get-buffer-window buf t)))
        (when win
          (delete-window win)))
      (kill-buffer buf))
    ;; Show next of same type if queued
    (funcall show-next-fn)
    ;; Also try other popup types in the chat buffer (queues are buffer-local)
    (when (and chat-buf (buffer-live-p chat-buf))
      (with-current-buffer chat-buf
        (unless opencode-popup--inline-p
          (opencode-popup--drain-queue))))))

;;; --- Inline region macro ---

(defmacro opencode-popup--with-inline-region (keymap prop &rest body)
  "Execute BODY to render inline popup content, wrapped in region setup.
KEYMAP is attached to the popup region via an overlay `keymap' property,
so it shadows the underlying chat-buffer text-property keymap
\(`opencode-chat-message-map') that covers the pre-input area.
PROP is a symbol (e.g. `opencode-permission' or `opencode-question')
used both as an identifying text property and, via the ID encoded in
a secondary `opencode-popup-request-id' overlay property when the
caller sets one, for cross-buffer dismissal walks.

This macro handles the boilerplate shared by permission and question popups:
1. Validate input-start marker (guards against child sessions / loading)
2. Delete the input area
3. Position at input-start
4. Execute BODY (caller inserts content)
5. Install an overlay covering the inserted region carrying KEYMAP
6. Apply read-only + PROP text properties to the region
7. Move cursor to region start

Signals an error if `(opencode-chat--input-start)' is nil or has no position,
so callers can catch and recover gracefully."
  (declare (indent 2) (debug t))
  `(progn
     (unless (opencode-popup--input-area-valid-p)
       (error "Popup: input-start marker is nil or invalid, cannot render inline"))
     (let ((inhibit-read-only t)
           (me (opencode-chat-message-messages-end)))
       ;; Delete the entire input area (separator + prompt + footer)
       ;; from messages-end, not input-start, to avoid leaving a
       ;; residual "> " prompt line.
       (delete-region (marker-position me) (point-max))
       ;; Switch messages-end to nil insertion type so it stays at
       ;; the popup start (not pushed to the end by popup content).
       ;; restore-input relies on messages-end pointing BEFORE the
       ;; popup region so it can delete-region from there.
       (set-marker-insertion-type me nil)
       ;; Insert content at messages-end
       (goto-char (marker-position me))
       (let ((region-start (point)))
         ;; Execute body — caller inserts popup content
         ,@body
         ;; Read-only + kind-identifying property stay as text properties.
         (add-text-properties region-start (point)
                              (list 'read-only t
                                    ',prop t))
         ;; Keymap moves to an overlay so it wins against any
         ;; text-property keymap from the underlying chat buffer.
         (let ((ov (make-overlay region-start (point))))
           (overlay-put ov 'keymap ,keymap)
           (overlay-put ov 'priority 100)
           (overlay-put ov 'opencode-popup-kind ',prop)
           (setq opencode-popup--overlay ov))
         ;; Place cursor at start of region
         (goto-char region-start)))))


;;; --- Popup queue draining ---

(defvar opencode-permission--pending)
(defvar opencode-question--pending)
(declare-function opencode-permission--show "opencode-permission" (request))
(declare-function opencode-question--show "opencode-question" (request))

(defun opencode-popup--drain-queue ()
  "Show the next queued permission or question popup in the current buffer.
Called at the end of message rendering when no popup is already active,
and from session-idle handlers.
Pending queues are buffer-local, so no session-id filtering is needed."
  (unless opencode-popup--inline-p
    ;; Permission queue first
    (unless (opencode-popup--show-next
             'opencode-permission--pending
             #'opencode-permission--show)
      ;; No permission — try question queue
      (opencode-popup--show-next
       'opencode-question--pending
       #'opencode-question--show))))

(provide 'opencode-popup)
;;; opencode-popup.el ends here
