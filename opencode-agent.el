;;; opencode-agent.el --- Agent management for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Agent list, cycle, and display functions.
;; No UI buffer — just functions used by opencode-chat.el.

;;; Code:

(require 'opencode-api)
(require 'seq)

;;; --- Cache (delegated to opencode-api--agents micro-cache) ---

(defun opencode-agent--list ()
  "Return cached agent list (possibly nil if not yet fetched).
Uses cache-only mode — never triggers HTTP."
  (opencode-api--agents :cache t))

(defun opencode-agent-invalidate ()
  "Invalidate the agent cache.
Forces a re-fetch from the server on next access.
Called by `opencode-refresh' and the disposed SSE handler."
  (opencode-api--agents-invalidate))

(defun opencode-agent--primary-agents ()
  "Return list of primary, non-hidden agents.
Filters the cached agent list to only include agents where
mode is \"primary\" or \"all\" and hidden is not t."
  (let ((agents (opencode-agent--list))
        (result nil))
    (when (vectorp agents)
      (seq-doseq (agent agents)
        (when (and (member (plist-get agent :mode) '("primary" "all"))
                   (not (eq (plist-get agent :hidden) t)))
          (push agent result))))
    (nreverse result)))

(defun opencode-agent--default-name ()
  "Return the default agent name from cache.
Computes the first primary, non-hidden agent name on demand."
  (when-let* ((primary (opencode-agent--primary-agents))
              (first (car primary)))
    (plist-get first :name)))

(defun opencode-agent--cycle (&optional current-name delta)
  "Cycle through primary agents by DELTA steps and return the new name.
DELTA defaults to 1 (forward).  Negative DELTA cycles backward.
Wraps around at both ends.
CURRENT-NAME specifies the current agent for positioning.
When nil, uses the default agent name from cache.
Does NOT mutate global state; caller is responsible for
storing the result (e.g. as a buffer-local override)."
  (let* ((agents (opencode-agent--primary-agents))
         (len (length agents))
         (current (or current-name (opencode-agent--default-name)))
         (d (or delta 1))
         (current-index (seq-position agents current
                                      (lambda (agent name)
                                              (string= name (plist-get agent :name)))))
         (new-index (if current-index
                        (mod (+ current-index d) len)
                      0))
         (new-agent (nth new-index agents)))
    (when new-agent (plist-get new-agent :name))))

(defun opencode-agent--find-by-name (name)
  "Return agent plist for NAME from cache, or nil.
Searches the cached agent list for an agent whose :name matches NAME."
  (when-let* ((agents (opencode-api--agents :cache t)))
    (when (vectorp agents)
      (seq-find (lambda (a) (string= (plist-get a :name) name))
               agents))))
(provide 'opencode-agent)
;;; opencode-agent.el ends here
