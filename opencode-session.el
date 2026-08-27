;;; opencode-session.el --- Session management for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Session CRUD operations.

;;; Code:

(require 'subr-x)
(require 'opencode-log)
(require 'opencode-backend-core)

(defgroup opencode-session nil
  "OpenCode session management."
  :group 'opencode
  :prefix "opencode-session-")

;;; --- API functions ---

(defun opencode-session--list (&optional query-params)
  "Fetch the session list from the server (internal).
QUERY-PARAMS is an optional alist of query parameters.
Returns a vector of session plists."
  (opencode-backend-list-sessions query-params))

(defun opencode-session-list (&optional query-params)
  "Fetch the session list from the server.
QUERY-PARAMS is an optional alist of query parameters.
Returns a vector of session plists."
  (opencode-session--list query-params))

(defun opencode-session-get (session-id)
  "Fetch a single session by SESSION-ID.
Returns a session plist."
  (opencode-backend-get-session-sync session-id))

(defun opencode-session-create (&optional title parent-id backend)
  "Create a new session with optional TITLE, PARENT-ID, and BACKEND.
Returns the created session plist."
  (opencode--debug "opencode-session: creating session title=%S parent=%S" title parent-id)
  (opencode-backend-create-session :title title :parent-id parent-id :backend backend))

(defun opencode-session-rename (session-id title &optional backend)
  "Rename session SESSION-ID to TITLE in BACKEND.
Uses PATCH /session/:sessionID to update session metadata.
Returns the updated session plist."
  (opencode-backend-rename-session session-id title backend))

(defun opencode-session-delete (session-id &optional backend)
  "Delete session SESSION-ID from BACKEND."
  (opencode-backend-delete-session session-id backend))

(defun opencode-session-abort (session-id &optional backend)
  "Abort the active prompt in session SESSION-ID on BACKEND."
  (opencode--debug "opencode-session: aborting session %s" session-id)
  (opencode-backend-abort-session session-id backend))

(defun opencode-session-compact
    (session-id &optional model-id provider-id backend)
  "Compact (summarize) session SESSION-ID on BACKEND.
Requires MODEL-ID and PROVIDER-ID for the summarization model.
Triggers a summarization of the session history on the server."
  (opencode-backend-compact-session
   session-id model-id provider-id backend))

(defun opencode-session-fork (session-id &optional message-id backend)
  "Fork session SESSION-ID at MESSAGE-ID in BACKEND.
Returns the new session plist."
  (opencode-backend-fork-session session-id message-id backend))

(defun opencode-session-share (session-id &optional backend)
  "Create a share link for session SESSION-ID in BACKEND."
  (opencode-backend-share-session session-id backend))

(defun opencode-session-unshare (session-id &optional backend)
  "Delete the share link for session SESSION-ID in BACKEND."
  (opencode-backend-unshare-session session-id backend))

(defun opencode-session-revert (session-id message-id &optional backend)
  "Revert session SESSION-ID in BACKEND to state before MESSAGE-ID.
This effectively \='undoes\=' the conversation back to that point."
  (opencode-backend-revert-session session-id message-id backend))

(defun opencode-session-unrevert (session-id &optional backend)
  "Un-revert (redo) session SESSION-ID in BACKEND to its latest state."
  (opencode-backend-unrevert-session session-id backend))

(defun opencode-session-status-all ()
  "Fetch status of all active sessions.
Returns a plist mapping session IDs to status plists."
  (opencode-backend-session-status-all))

(defun opencode-session-diff (session-id &optional message-id backend)
  "Fetch file diffs for SESSION-ID in BACKEND, optionally for MESSAGE-ID."
  (opencode-backend-get-diff-sync session-id message-id backend))

;;; --- Session data helpers ---

(defun opencode-session--title (session)
  "Return the title of SESSION plist."
  (or (plist-get session :title) "(untitled)"))

(defun opencode-session--project-name (session)
  "Return the project name for SESSION, extracted from directory."
  (let ((dir (plist-get session :directory)))
    (if dir
        (file-name-nondirectory (directory-file-name dir))
      "default")))

(provide 'opencode-session)
;;; opencode-session.el ends here
