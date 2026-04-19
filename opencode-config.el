;;; opencode-config.el --- Config & provider data for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Cached access to the OpenCode server's config, provider, and command data.
;; Functions-only module — no UI buffer.
;; Follows the same cache+TTL pattern as opencode-agent.el.

;;; Code:

(require 'opencode-api)
(require 'opencode-log)

;;; --- Config cache (delegated to opencode-api--server-config micro-cache) ---

(defcustom opencode-config-cache-ttl 30
  "Seconds before config/provider cache expires."
  :type 'integer
  :group 'opencode)

(defun opencode-config--get ()
  "Return cached server config (possibly nil if not yet fetched).
Uses cache-only mode — never triggers HTTP."
  (opencode-api--server-config :cache t))

;;; --- Provider cache (delegated to opencode-api--providers micro-cache) ---

(defun opencode-config--ensure-providers-cache ()
  "Ensure provider cache is populated.
Delegates to `opencode-api--providers'."
  (opencode-api--providers))

(defun opencode-config--providers ()
  "Return cached provider data (possibly nil if not yet fetched).
Uses cache-only mode — never triggers HTTP."
  (opencode-api--providers :cache t))

;;; --- Commands cache (GET /command) ---

(defvar opencode-config--commands-cache nil
  "Cached command list from GET /command.")

(defvar opencode-config--commands-cache-time 0
  "Float-time when commands cache was last populated.")

(defvar opencode-config--commands-refreshing nil
  "Non-nil while an async refresh of commands is in flight.")

(defun opencode-config--refresh-commands-async ()
  "Fetch commands asynchronously and update the cache.
Does nothing if a refresh is already in flight."
  (unless opencode-config--commands-refreshing
    (setq opencode-config--commands-refreshing t)
    (opencode-api-get
     "/command"
     (lambda (response)
       (setq opencode-config--commands-refreshing nil)
       (when-let* ((body (plist-get response :body)))
         (setq opencode-config--commands-cache body
                 opencode-config--commands-cache-time (float-time)))))))
(defun opencode-config--ensure-commands-cache ()
  "Ensure commands cache is being populated, never blocks.
If the cache is nil or expired and no refresh is in flight,
kicks off an async fetch.  Always returns immediately.
Callers get whatever is in the cache (possibly nil on first call
before the async response arrives)."
  (let ((now (float-time)))
    (when (and (not opencode-config--commands-refreshing)
              (or (null opencode-config--commands-cache)
                  (> (- now opencode-config--commands-cache-time)
                     opencode-config-cache-ttl)))
      (opencode-config--refresh-commands-async))))

(defun opencode-config--commands ()
  "Return cached command list (vector of plists).
Each command has :name, :description, :agent, :hints, :subtask, :mcp.
Returns stale cache immediately if a refresh is in progress.
Ensures cache is populated first."
  (opencode-config--ensure-commands-cache)
  opencode-config--commands-cache)

(defun opencode-config--command-names ()
  "Return list of command name strings for completion.
Extracts :name from each command in the cache."
  (let ((commands (opencode-config--commands)))
    (when (vectorp commands)
      (mapcar (lambda (cmd) (plist-get cmd :name))
              (seq-into commands 'list)))))

(defun opencode-config--find-command (name)
  "Find a command plist by NAME from the commands cache.
Returns the command plist (with :name, :agent, etc.) or nil.
NAME is the command name string without leading slash."
  (let ((commands (opencode-config--commands)))
    (when (vectorp commands)
      (seq-find (lambda (cmd) (string= (plist-get cmd :name) name))
                commands))))

;;; --- Accessors ---

(defun opencode-config--connected-providers ()
  "Return the list of connected provider IDs.
Fetches from GET /provider/ and returns the :connected field."
  (let ((data (opencode-config--providers)))
    (when data
      (plist-get data :connected))))

(defun opencode-config--current-model ()
  "Extract current model from config as a plist.
Returns (:providerID PROVIDER :modelID MODEL).
Handles both string format (\"provider/model-id\") and
plist format (:providerID ... :modelID ...)."
  (let ((model (plist-get (opencode-config--get) :model)))
    (cond
     ;; String format: "anthropic/claude-opus-4-6"
     ((and (stringp model)
           (string-match "\\`\\(.+\\)/\\(.+\\)\\'" model))
      (list :providerID (match-string 1 model)
            :modelID (match-string 2 model)))
     ;; Plist format: already has :providerID and :modelID
     ((and model (plist-get model :providerID))
      model)
     (t nil))))

(defun opencode-config--current-agent ()
  "Return the default agent name from config.
Returns the :default_agent field."
  (plist-get (opencode-config--get) :default_agent))

(defun opencode-config--model-info (provider-id model-id)
  "Look up model info for PROVIDER-ID and MODEL-ID.
Searches the provider cache's :all list for the matching provider
\(using `downcase' for comparison), then finds the model in its
:models map.  Returns the model info plist, or nil if not found."
  (let* ((data (opencode-config--providers))
         (all (when data (plist-get data :all)))
         (provider nil)
         (model-info nil))
    ;; Find matching provider in :all vector
    (when (vectorp all)
      (seq-doseq (p all)
        (when (and (null provider)
                   (string= (downcase (or (plist-get p :id) ""))
                            (downcase (or provider-id ""))))
          (setq provider p))))
    ;; Find model in provider's :models plist
    (when provider
      (let ((models (plist-get provider :models)))
        (when models
          (let ((key (intern (concat ":" model-id))))
            (setq model-info (plist-get models key))))))
    model-info))

(defun opencode-config--model-variants (provider-id model-id)
  "Look up model variants for PROVIDER-ID and MODEL-ID.
Searches the provider cache's :all list for the matching provider
\(using `downcase' for comparison), then finds the model in its
:models map.  Returns the :variants plist, or nil if not found."
  (plist-get (opencode-config--model-info provider-id model-id) :variants))

(defun opencode-config--model-context-limit (provider-id model-id)
  "Return the context window size for PROVIDER-ID and MODEL-ID.
Looks up the :limit :context field from the provider cache.
Returns an integer (number of tokens), or nil if not available."
  (when-let* ((info (opencode-config--model-info provider-id model-id))
              (limit (plist-get info :limit)))
    (plist-get limit :context)))

(defun opencode-config--variant-keys (provider-id model-id)
  "Return list of variant key strings for PROVIDER-ID and MODEL-ID.
Calls `opencode-config--model-variants' and extracts just the keys.
Returns nil if no variants found."
  (when-let* ((variants (opencode-config--model-variants provider-id model-id)))
      ;; variants is a plist: (:low (...) :medium (...) ...)
       ;; Extract keys (every other element starting from 0)
       (let ((keys nil)
             (rest variants))
         (while rest
           (push (substring (symbol-name (car rest)) 1) keys)
           (setq rest (cddr rest)))
         (nreverse keys))))

;;; --- Model enumeration ---

(defun opencode-config--all-models ()
  "Return a list of all models from connected providers.
Each element is a plist with :provider-id, :model-id, :name, :label.
Only models from connected providers are included.
Returns nil if provider data is not available."
  (let* ((data (opencode-config--providers))
         (all (when data (plist-get data :all)))
         (connected (when data (plist-get data :connected)))
         (result nil))
    (when (and (vectorp all) (vectorp connected))
      (seq-doseq (provider all)
        (let ((pid (plist-get provider :id)))
          (when (seq-contains-p connected pid
                                (lambda (a b) (string= (downcase a) (downcase b))))
            (let ((models (plist-get provider :models))
                  (rest nil))
              (when models
                (setq rest models)
                (while rest
                  (let* ((key (car rest))
                         (info (cadr rest))
                         (model-id (substring (symbol-name key) 1))
                         (name (and (listp info) (plist-get info :name))))
                    (push (list :provider-id pid
                                :model-id model-id
                                :name name
                                :label (format "%s/%s" pid model-id))
                          result))
                  (setq rest (cddr rest)))))))))
    (nreverse result)))

;;; --- Command execution ---

(defun opencode-config-execute-command (session-id command &optional arguments agent model variant)
  "Execute slash COMMAND in SESSION-ID.
Sends POST /session/:id/command with body.
ARGUMENTS is the command arguments string (empty string if none).
AGENT is the agent name string.
MODEL is the model string in \"provider/model-id\" format.
VARIANT is the variant string (e.g. \"max\").
Calls callback on response (async)."
  (let ((body (list :command command
                    :arguments (or arguments "")
                    :parts [])))
    (when agent (setq body (plist-put body :agent agent)))
    (when model (setq body (plist-put body :model model)))
    (when variant (setq body (plist-put body :variant variant)))
    (opencode--debug "opencode-config: executing command /%s body=%S" command body)
    (opencode-api-post
     (format "/session/%s/command" session-id)
     body
     (lambda (response)
       (let ((status (plist-get response :status)))
         (if (and status (>= status 400))
             (message "opencode-config: command /%s failed with status %d"
                      command status)
           (opencode--debug "opencode-config: command /%s executed" command)))))))

;;; --- Cache management ---

(defun opencode-config-invalidate ()
  "Invalidate all config, provider, and command caches.
Forces fresh data on next access."
  (opencode-api--server-config-invalidate)
  (opencode-api--providers-invalidate)
  (setq opencode-config--commands-cache nil
        opencode-config--commands-cache-time 0
        opencode-config--commands-refreshing nil))


(defun opencode-config-prewarm ()
  "Pre-warm caches asynchronously.
Call from the server-connected hook so slash command completion
and model context/variant data are ready before the user needs them."
  (opencode-config--refresh-commands-async)
  (opencode-config--ensure-providers-cache))

(provide 'opencode-config)
;;; opencode-config.el ends here
