;;; opencode-domain.el --- Pure data layer for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Buffer-free domain helpers: parent-session walk, child-parent cache,
;; cycle defense.  No buffer state, no overlays, no markers.
;;
;; This module owns the child→parent session relationship cache that is
;; used by popup dispatch routing.  The cache is populated eagerly by
;; every site that learns of a parent-child pair (session struct install,
;; task tool render, async popup walk) and consulted whenever popup
;; dispatch needs to route an event from a child session to its ancestor.
;;
;; Cycle defense: server-returned session metadata can form cycles
;; (`A.parentID = B`, `B.parentID = A`).  `opencode-domain-find-root-session'
;; caps its walk at `opencode-domain--max-session-depth' hops and breaks
;; the offending link on overflow so callers always terminate.

;;; Code:

(require 'opencode-log)

;;; --- Child → parent session cache ---

(defvar opencode-domain--child-parent-cache (make-hash-table :test 'equal)
  "Global cache of child-session-id → parent-session-id mappings.
Populated eagerly when child sessions are encountered (session struct
install, task tool rendering, async popup walk on cache miss).  Used by
`opencode-event--dispatch-popup' to route child session popups to the
correct parent buffer without synchronous HTTP calls.
Global (not buffer-local) because SSE dispatch runs outside chat buffers.")

(defconst opencode-domain--max-session-depth 8
  "Maximum number of parent hops `opencode-domain-find-root-session' will walk.
Sub-agent nesting is expected to be shallow (typically 0–3 levels); any
chain longer than this is almost certainly a cycle introduced by
corrupted session metadata.  Walking past the cap is treated as a
cycle: the offending link is dropped and the last-known ancestor is
returned so the caller terminates cleanly.")

(defun opencode-domain-child-parent-get (child-session-id)
  "Return immediate parent session ID for CHILD-SESSION-ID from cache, or nil."
  (gethash child-session-id opencode-domain--child-parent-cache))

(defun opencode-domain-child-parent-put (child-session-id parent-session-id)
  "Record that CHILD-SESSION-ID's parent is PARENT-SESSION-ID."
  (when (and child-session-id parent-session-id)
    (puthash child-session-id parent-session-id
             opencode-domain--child-parent-cache)))

(defun opencode-domain-find-root-session (session-id)
  "Walk the child→parent chain to find the root (top-level) session.
Uses path compression: intermediate nodes are updated to point directly
to the root, making subsequent lookups O(1).
Returns SESSION-ID itself if it has no parent in the cache.

Detects cycles in the cache (which should never happen but can arise
from a corrupted or inconsistent server response) by walking at most
`opencode-domain--max-session-depth' hops.  On cycle, breaks the
bad edge and returns the last known node so callers terminate."
  (let ((root session-id)
        (path nil)
        (hops 0))
    ;; Walk up to find root, bounded by max depth.
    (while (and (< hops opencode-domain--max-session-depth)
                (let ((parent (gethash root opencode-domain--child-parent-cache)))
                  (when parent
                    (push root path)
                    (setq root parent)
                    (cl-incf hops)
                    t))))
    ;; If we hit the cap, the chain is cyclic or pathologically deep.
    ;; Break the offending link so the next call terminates cleanly.
    (when (= hops opencode-domain--max-session-depth)
      (opencode--debug
       "opencode-domain: session cycle/overflow at %s; breaking link"
       root)
      (remhash root opencode-domain--child-parent-cache))
    ;; Path compression: point all intermediates directly to root
    (dolist (node path)
      (unless (equal node root)
        (puthash node root opencode-domain--child-parent-cache)))
    root))

(provide 'opencode-domain)
;;; opencode-domain.el ends here
