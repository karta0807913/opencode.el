;;; opencode-agent.el --- Agent management for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Agent list, cycle, and display functions.
;; No UI buffer — just functions used by opencode-chat.el.

;;; Code:

(require 'opencode-backend-core)
(require 'seq)

;;; --- Cache (delegated to opencode-api--agents micro-cache) ---

(defun opencode-agent--list (&optional backend)
  "Return cached agent list (possibly nil if not yet fetched).
Uses cache-only mode — never triggers HTTP."
  (opencode-backend-cached-agents backend))

(defun opencode-agent-invalidate (&optional backend)
  "Invalidate the agent cache.
Forces a re-fetch from the server on next access.
Called by `opencode-refresh' and the disposed SSE handler."
  (opencode-backend-invalidate-agents backend))

(defun opencode-agent--primary-agents (&optional backend)
  "Return list of primary, non-hidden agents.
Filters the cached agent list to only include agents where
mode is \"primary\" or \"all\" and hidden is not t."
  (let ((agents (if backend
                    (opencode-agent--list backend)
                  (opencode-agent--list)))
        (result nil))
    (when (vectorp agents)
      (seq-doseq (agent agents)
        (when (and (member (plist-get agent :mode) '("primary" "all"))
                   (not (eq (plist-get agent :hidden) t)))
          (push agent result))))
    (nreverse result)))

(defun opencode-agent--default-name (&optional backend)
  "Return the default agent name from cache.
Computes the first primary, non-hidden agent name on demand."
  (when-let* ((primary (if backend
                           (opencode-agent--primary-agents backend)
                         (opencode-agent--primary-agents)))
              (first (car primary)))
    (plist-get first :name)))

(defun opencode-agent--cycle (&optional current-name delta backend)
  "Cycle through primary agents by DELTA steps and return the new name.
DELTA defaults to 1 (forward).  Negative DELTA cycles backward.
Wraps around at both ends.
CURRENT-NAME specifies the current agent for positioning.
When nil, uses the default agent name from cache.
Does NOT mutate global state; caller is responsible for
storing the result (e.g. as a buffer-local override)."
  (let* ((agents (opencode-agent--primary-agents backend))
         (len (length agents))
         (current (or current-name (opencode-agent--default-name backend)))
         (d (or delta 1))
         (current-index (seq-position agents current
                                      (lambda (agent name)
                                              (string= name (plist-get agent :name)))))
         (new-index (if current-index
                        (mod (+ current-index d) len)
                      0))
         (new-agent (nth new-index agents)))
    (when new-agent (plist-get new-agent :name))))

(defun opencode-agent--find-by-name (name &optional backend)
  "Return agent plist for NAME from cache, or nil.
Searches the cached agent list for an agent whose :name matches NAME."
  (when-let* ((agents (opencode-backend-cached-agents backend)))
    (when (vectorp agents)
      (seq-find (lambda (a) (string= (plist-get a :name) name))
                agents))))

(defun opencode-agent-valid-p (name &optional backend)
  "Return non-nil when NAME is valid for BACKEND.
Trust NAME when backend agent metadata has not loaded yet; absence can only be
authoritative once a vector of agent definitions is available."
  (let ((agents (opencode-backend-cached-agents backend)))
    (or (null agents)
        (and (vectorp agents)
             (seq-find
              (lambda (agent)
                (string= (plist-get agent :name) name))
              agents)))))
(provide 'opencode-agent)
;;; opencode-agent.el ends here
