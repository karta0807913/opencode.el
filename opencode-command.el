;;; opencode-command.el --- Command selection for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Interactive command selection and execution for OpenCode.
;; Provides a `completing-read' interface to select and execute
;; slash commands from the OpenCode server.
;;
;; Commands are fetched from `GET /command' and executed via
;; `POST /session/:id/command'.
;;
;; Keybinding: C-p in `opencode-chat-mode'.

;;; Code:

(require 'opencode-chat-state)
(require 'opencode-session)
(require 'opencode-config)
(require 'opencode-log)

(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))
(declare-function opencode-chat--refresh-footer "opencode-chat-input" ())
(declare-function opencode-chat--recompute-cached-tokens-from-store "opencode-chat" ())

;;; --- Variables ---


(defconst opencode-command--local-commands
  (vector
   (list :name "compact" :description "Compact/summarize the current session"
         :callback (lambda ()
                     (let* ((model (opencode-chat--effective-model))
                            (model-id (plist-get model :modelID))
                            (provider-id (plist-get model :providerID)))
                        (unless (and model-id provider-id)
                          (user-error "No model configured for compaction"))
                         (opencode-session-compact (opencode-chat--session-id) model-id provider-id))))
   (list :name "model" :description "Select a different model"
         :callback #'opencode-command-select-model)
   (list :name "rename" :description "Rename the current session"
         :callback (lambda ()
                     (let ((title (read-string "New title: ")))
                       (opencode-session-rename (opencode-chat--session-id) title))))
   (list :name "fork" :description "Fork the current session"
         :callback (lambda ()
                     (let ((new-session (opencode-session-fork (opencode-chat--session-id))))
                       (when new-session
                         (opencode-chat-open (plist-get new-session :id)
                                            (plist-get new-session :directory))))))
   (list :name "share" :description "Create a shareable URL for this session"
         :callback (lambda ()
                     (let ((res (opencode-session-share (opencode-chat--session-id))))
                       (when-let* ((share (plist-get (plist-get res :body) :share))
                                   (url (plist-get share :url)))
                         (kill-new url)
                         (message "Share URL copied to clipboard: %s" url)))))
   (list :name "unshare" :description "Delete the share link for this session"
         :callback (lambda ()
                     (opencode-session-unshare (opencode-chat--session-id))
                     (message "Session unshared")))
   (list :name "undo" :description "Undo the last user message"
         :callback (lambda ()
                     (let ((last-user-id
                            (seq-find
                             (lambda (id)
                               (when-let* ((info (opencode-chat-message-info id)))
                                 (equal (plist-get info :role) "user")))
                             (reverse (opencode-chat-message-sorted-ids)))))
                       (if last-user-id
                           (progn
                             (opencode-session-revert (opencode-chat--session-id) last-user-id)
                             (message "Undid last message"))
                         (user-error "No user message found to undo")))))
   (list :name "redo" :description "Redo the last undone message"
         :callback (lambda ()
                     (opencode-session-unrevert (opencode-chat--session-id))
                     (message "Redo executed"))))
  "List of local client-side commands.")

;;; --- Command selection ---

(defun opencode-command--format-candidate (cmd)
  "Format command CMD as a completion candidate string.
Returns \"name - description\" or just \"name\" if no description."
  (let ((name (plist-get cmd :name))
        (desc (plist-get cmd :description)))
    (if (and desc (not (string-empty-p desc)))
        (format "%s - %s" name desc)
      name)))

(defun opencode-command--parse-candidate (candidate)
  "Extract command name from CANDIDATE string.
CANDIDATE may be \"name - description\" or just \"name\"."
  (if (string-match "\\`\\([^ ]+\\)" candidate)
      (match-string 1 candidate)
    candidate))

(defun opencode-command--build-completion-table (commands)
  "Build a completion table from COMMANDS vector.
Returns an alist of (candidate . command-plist) for annotation."
  (let ((table (make-hash-table :test 'equal)))
    (seq-doseq (cmd commands)
      (let ((candidate (opencode-command--format-candidate cmd)))
        (puthash candidate cmd table)))
    table))

(defun opencode-command--annotator (table)
  "Return an annotation function for completion TABLE.
Shows command hints and whether it's an MCP command."
  (lambda (candidate)
    (when-let* ((cmd (gethash candidate table)))
      (let ((hints (plist-get cmd :hints))
            (mcp (plist-get cmd :mcp))
            (agent (plist-get cmd :agent))
            (parts nil))
        (when (and hints (> (length hints) 0))
          (push (propertize (format " %s" (mapconcat #'identity hints " "))
                            'face 'font-lock-variable-name-face)
                parts))
        (when agent
          (push (propertize (format " [%s]" agent)
                            'face 'font-lock-type-face)
                parts))
        (when (eq mcp t)
          (push (propertize " [MCP]" 'face 'font-lock-keyword-face)
                parts))
        (when parts
          (apply #'concat (nreverse parts)))))))

(defun opencode-command--read-arguments (cmd)
  "Prompt for arguments for command CMD if it has hints.
Returns the arguments string, or empty string if no hints."
  (let ((hints (plist-get cmd :hints))
        (name (plist-get cmd :name)))
    (if (and hints (> (length hints) 0))
        (read-string (format "/%s arguments (%s): "
                             name
                             (mapconcat #'identity hints " ")))
      "")))

(defun opencode-command-select-model ()
  "Interactively select a model from connected providers.
Presents all available models via `completing-read' and updates
the buffer-local state.  Resets variant (variants are model-specific)."
  (interactive)
  (let ((models (opencode-config--all-models)))
    (unless models
      (user-error "No models available (providers not connected)"))
    (let* ((current (opencode-chat--effective-model))
           (current-label (when (and (plist-get current :providerID)
                                     (plist-get current :modelID))
                            (format "%s/%s"
                                    (plist-get current :providerID)
                                    (plist-get current :modelID))))
           ;; Build completion table: display string -> model plist
           (table (make-hash-table :test 'equal))
           (_ (dolist (m models)
                (let* ((label (plist-get m :label))
                       (name (plist-get m :name))
                       (display (if name
                                    (format "%s - %s" label name)
                                  label)))
                  (puthash display m table))))
           (candidates (hash-table-keys table))
           ;; Sort with current model first
           (sorted (if current-label
                       (sort candidates
                             (lambda (a b)
                               (cond
                                ((string-prefix-p current-label a) t)
                                ((string-prefix-p current-label b) nil)
                                (t (string< a b)))))
                     (sort candidates #'string<)))
           (selected (completing-read
                      (format "Model%s: "
                              (if current-label
                                  (format " (current: %s)" current-label)
                                ""))
                      sorted nil t)))
      (when (and selected (not (string-empty-p selected)))
        (let* ((entry (gethash selected table))
               (new-provider-id (plist-get entry :provider-id))
               (new-model-id (plist-get entry :model-id)))
          (opencode-chat--set-model-id new-model-id)
          (opencode-chat--set-provider-id new-provider-id)
          (opencode-chat--set-context-limit
           (opencode-config--model-context-limit new-provider-id new-model-id))
          ;; Reset variant — variants are model-specific
          (opencode-chat--set-variant nil)
          ;; Recompute tokens from the store — the context bar
          ;; percentage must reflect the new model's context limit.
          (opencode-chat--recompute-cached-tokens-from-store)
          (opencode-chat--refresh-footer)
          (message "Model: %s/%s" new-provider-id new-model-id))))))

;;;###autoload
(defun opencode-command-select ()
  "Select and execute an OpenCode local command via `completing-read'.
Presents a list of client-side built-in commands (e.g. /compact, /rename)
and executes the selected one.

Must be called from an `opencode-chat-mode' buffer."
  (interactive)
  (unless (derived-mode-p 'opencode-chat-mode)
    (user-error "Must be in an opencode-chat buffer"))
  (unless (opencode-chat--session-id)
    (user-error "No active session"))
  (let* ((commands opencode-command--local-commands)
         (table (opencode-command--build-completion-table commands))
         (candidates (hash-table-keys table))
         (selected (completing-read "Command: " candidates nil t)))
    (when (and selected (not (string-empty-p selected)))
      (let* ((name (opencode-command--parse-candidate selected))
             (cmd (gethash selected table))
             (callback (plist-get cmd :callback)))
        (when callback
          (opencode--debug "opencode-command: executing local /%s" name)
          (funcall callback)
          (message "Executed /%s" name))))))

;;;###autoload
(defun opencode-command-select-global ()
  "Select and execute an OpenCode command, creating a session if needed.
If not in a chat buffer, creates a new session first."
  (interactive)
  (if (and (derived-mode-p 'opencode-chat-mode)
           (opencode-chat--session-id))
      (opencode-command-select)
    ;; Not in a chat buffer - need to create/select a session first
    (user-error "Please open a chat session first (C-c o c)")))

(provide 'opencode-command)
;;; opencode-command.el ends here
