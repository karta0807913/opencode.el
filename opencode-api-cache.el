;;; opencode-api-cache.el --- Cache facade for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Public cache facade for the OpenCode API layer.
;; Owns micro-cache definitions, invalidation, pre-warming, and
;; startup-resilient load/retry logic.
;;
;; All cache reads go through this module.  `opencode-api.el' delegates
;; here instead of owning cache state directly.
;;
;; Startup resilience: cache-load failures are non-fatal.  When the
;; initial load fails, the failure is recorded and retried on the next
;; chat/sidebar open via `opencode-api-cache-ensure-loaded'.
;;
;; Session read fallback: when stale cached data exists, session reads
;; use a 0.5s timeout before falling back to the cached value.  When
;; no cached data exists, the read blocks until fresh data arrives.

;;; Code:

(require 'cl-lib)
(require 'opencode-log)

(declare-function opencode-api-get "opencode-api" (path callback &optional query-params))
(declare-function opencode-api-get-sync "opencode-api" (path &optional query-params))
(declare-function opencode-agent--find-by-name "opencode-agent" (name))
(declare-function opencode-agent--default-name "opencode-agent" ())

;;; --- Customization ---

(defgroup opencode-api-cache nil
  "OpenCode API cache layer."
  :group 'opencode
  :prefix "opencode-api-cache-")

(defcustom opencode-api-cache-session-timeout 0.5
  "Timeout in seconds for session reads when stale cache exists.
When cached session data is available and a fresh fetch exceeds this
timeout, the stale cached value is returned immediately."
  :type 'number
  :group 'opencode-api-cache)

;;; --- Cache load state ---

(defvar opencode-api-cache--load-state 'unloaded
  "Cache load state: `unloaded', `loaded', or `failed'.
When `failed', the next `opencode-api-cache-ensure-loaded' call
retries the load.")

(defvar opencode-api-cache--load-error nil
  "Error from the last failed cache load attempt, or nil.")

;;; --- Micro-cache (async-first, with :block/:cache/:callback) ---

;; `opencode--define-micro-cache' generates a cl-defun accessor, an
;; invalidator, and two internal defvars for any GET endpoint.
;;
;; Default behavior: return cache if available, kick off async refresh
;; if empty.  Callers that need guaranteed-fresh data use :block t
;; (sync HTTP) or :callback fn (async, fn called with result).
;; Callers that never want HTTP use :cache t (returns cache or nil).

(defmacro opencode--define-micro-cache (name endpoint doc-noun)
  "Define an async micro-cache for ENDPOINT.
NAME is a short identifier used to derive symbols (e.g. \"agents\").
ENDPOINT is the API path string (e.g. \"/agent\").
DOC-NOUN is a description for docstrings (e.g. \"agent list\").

Generated symbols:
  opencode-api--%s-cache       (defvar)
  opencode-api--%s-refreshing  (defvar)
  opencode-api--%s             (cl-defun &key block cache callback)
  opencode-api--%s-invalidate  (defun)"
  (let ((cache-var (intern (format "opencode-api--%s-cache" name)))
        (refreshing-var (intern (format "opencode-api--%s-refreshing" name)))
        (fn-name (intern (format "opencode-api--%s" name)))
        (invalidate-fn (intern (format "opencode-api--%s-invalidate" name))))
    `(progn
       (defvar ,cache-var nil
         ,(format "Cached %s from GET %s." doc-noun endpoint))
       (defvar ,refreshing-var nil
         ,(format "Non-nil while an async %s fetch is in flight." doc-noun))

       (cl-defun ,fn-name (&key block cache callback)
         ,(format "Return cached %s, optionally fetching from the server.

Modes (mutually exclusive — first match wins):

  :cache t    — Return cache immediately.  Never HTTP.  May return nil.
  :block t    — Synchronous HTTP if cache is nil.  Blocks Emacs.
  :callback FN — Async HTTP if cache is nil.  FN called with result.
                  Also returns current cache immediately.
  (default)   — Return cache.  Kick off background refresh if nil.

The cache is invalidated by `%s'." doc-noun invalidate-fn)
         (cond
          (cache
           ,cache-var)
          (block
           (or ,cache-var
               (condition-case err
                   (let ((data (opencode-api-get-sync ,endpoint)))
                     (setq ,cache-var data))
                 (error
                  (opencode--debug ,(format "opencode-api-cache: %s sync fetch failed: %%s" name)
                                   (error-message-string err))
                  nil))))
           (callback
            (if ,cache-var
                (funcall callback ,cache-var)
              (unless ,refreshing-var
                (setq ,refreshing-var t)
                (condition-case err
                    (opencode-api-get
                     ,endpoint
                     (lambda (response)
                       (setq ,refreshing-var nil)
                       (let ((body (plist-get response :body))
                             (status (plist-get response :status))
                             (req-err (plist-get response :error)))
                         (cond
                          (req-err
                           (opencode--debug ,(format "opencode-api-cache: %s async fetch error: %%S" name) req-err))
                          ((and status (>= status 400))
                           (opencode--debug ,(format "opencode-api-cache: %s async fetch HTTP %%d" name) status))
                          (body
                           (setq ,cache-var body))))
                       (funcall callback ,cache-var)))
                  (error
                   (setq ,refreshing-var nil)
                   (opencode--debug ,(format "opencode-api-cache: %s fetch threw: %%s" name)
                                    (error-message-string err))))))
            ,cache-var)
           (t
            (unless (or ,cache-var ,refreshing-var)
              (setq ,refreshing-var t)
              (condition-case err
                  (opencode-api-get
                   ,endpoint
                   (lambda (response)
                     (setq ,refreshing-var nil)
                     (let ((body (plist-get response :body))
                           (status (plist-get response :status))
                           (req-err (plist-get response :error)))
                       (cond
                        (req-err
                         (opencode--debug ,(format "opencode-api-cache: %s async fetch error: %%S" name) req-err))
                        ((and status (>= status 400))
                         (opencode--debug ,(format "opencode-api-cache: %s async fetch HTTP %%d" name) status))
                        (body
                         (setq ,cache-var body))))))
                (error
                 (setq ,refreshing-var nil)
                 (opencode--debug ,(format "opencode-api-cache: %s fetch threw: %%s" name)
                                  (error-message-string err)))))
            ,cache-var)))

       (defun ,invalidate-fn ()
         ,(format "Clear the %s cache.  Next access re-fetches from server." doc-noun)
         (setq ,cache-var nil
               ,refreshing-var nil)))))

(opencode--define-micro-cache "agents" "/agent" "agent list")
(opencode--define-micro-cache "server-config" "/config" "server config")
(opencode--define-micro-cache "providers" "/provider" "provider data")

;;; --- Cache invalidation ---

(defun opencode-api-invalidate-all-caches ()
  "Invalidate all micro-caches.  Next access re-fetches from server.
Called on server connect to ensure fresh data.
Also resets load-state so `opencode-api-cache-ensure-loaded' will
re-fetch instead of being a no-op."
  (opencode-api--agents-invalidate)
  (opencode-api--server-config-invalidate)
  (opencode-api--providers-invalidate)
  (clrhash opencode-api-cache--project-sessions)
  (setq opencode-api-cache--load-state 'unloaded))

;;; --- Pre-warming ---

(defun opencode-api-cache-prewarm ()
  "Pre-warm agent and config caches asynchronously.
Kicks off async fetches for both /agent and /config so that
`opencode-config--current-model' and agent lookups are ready
when chat buffers initialize.  Never blocks Emacs."
  (opencode--debug "opencode-api-cache: pre-warming caches (async)...")
  (opencode-api--agents)
  (opencode-api--server-config))

;;; --- Startup-safe cache load ---

(defun opencode-api-cache-ensure-loaded ()
  "Ensure caches are loaded, retrying if a previous load failed.
Non-blocking: kicks off async fetches.  Safe to call multiple times.
When `opencode-api-cache--load-state' is `failed', resets it and
retries.  When `loaded', this is a no-op.

Called from chat/sidebar open paths to provide lazy retry after
startup cache failures."
  (pcase opencode-api-cache--load-state
    ('loaded
     (opencode--debug "opencode-api-cache: ensure-loaded — already loaded"))
    ('failed
     (opencode--debug "opencode-api-cache: ensure-loaded — retrying after failure: %s"
                      opencode-api-cache--load-error)
     (setq opencode-api-cache--load-state 'unloaded
           opencode-api-cache--load-error nil)
     (opencode-api-cache--do-load))
    ('unloaded
     (opencode-api-cache--do-load))))

(defun opencode-api-cache--do-load ()
  "Perform the actual cache load.  Internal use only.
Wraps pre-warming in condition-case so failures are non-fatal."
  (condition-case err
      (progn
        (opencode-api-cache-prewarm)
        (setq opencode-api-cache--load-state 'loaded))
    (error
     (setq opencode-api-cache--load-state 'failed
           opencode-api-cache--load-error (error-message-string err))
     (opencode--debug "opencode-api-cache: load failed (non-fatal): %s"
                      (error-message-string err)))))

(defun opencode-api-cache-load-failed-p ()
  "Return non-nil if the last cache load attempt failed."
  (eq opencode-api-cache--load-state 'failed))

;;; --- Session read with stale-on-timeout fallback ---

(defvar opencode-api-cache--session-cache (make-hash-table :test 'equal)
  "Hash table mapping session-id to cached session plist.
Used for stale-on-timeout fallback during session reads.")

(defun opencode-api-cache-get-session (session-id callback)
  "Fetch session SESSION-ID, falling back to cache on timeout.
When a cached value exists, starts a fetch with a
`opencode-api-cache-session-timeout' timeout.  If the fetch completes
in time, CALLBACK receives the fresh result and cache is updated.
If it times out, CALLBACK receives the stale cached value.

When no cached value exists, the fetch blocks until a result arrives
\(no timeout applied) and CALLBACK receives the result.

CALLBACK is called with the session plist (or nil on error).
Automatically retries cache load if a previous load failed."
  (opencode-api-cache-ensure-loaded)
  (let ((cached (gethash session-id opencode-api-cache--session-cache)))
    (if cached
        ;; Have cache: fetch with timeout, fallback to stale
        (let* ((completed nil)
               (timeout-timer nil)
               (timeout-secs opencode-api-cache-session-timeout))
          (setq timeout-timer
                (run-with-timer
                 timeout-secs nil
                 (lambda ()
                   (unless completed
                     (setq completed t)
                     (opencode--debug "opencode-api-cache: session %s fetch timed out, using stale cache"
                                      session-id)
                     (funcall callback cached)))))
          (opencode-api-get
           (format "/session/%s" session-id)
           (lambda (response)
             (cancel-timer timeout-timer)
             (unless completed
               (setq completed t)
               (let ((body (plist-get response :body)))
                 (when body
                   (puthash session-id body opencode-api-cache--session-cache))
                 (funcall callback (or body cached)))))))
      ;; No cache: fetch without timeout (block until result)
      (opencode-api-get
       (format "/session/%s" session-id)
       (lambda (response)
         (let ((body (plist-get response :body)))
           (when body
             (puthash session-id body opencode-api-cache--session-cache))
           (funcall callback body)))))))

(defun opencode-api-cache-put-session (session-id session)
  "Update the session cache for SESSION-ID with SESSION plist.
Called when session data is received from SSE events to keep cache fresh."
  (when (and session-id session)
    (puthash session-id session opencode-api-cache--session-cache)))

(defun opencode-api-cache-invalidate-session (session-id)
  "Remove SESSION-ID from the session cache."
  (remhash session-id opencode-api-cache--session-cache))

;;; --- Per-project session list cache ---

;; Each entry is a plist: (:sessions VECTOR :refreshing BOOL :callbacks LIST)
;; :sessions   — cached session vector (or nil if never fetched)
;; :refreshing — non-nil when an async fetch is in-flight
;; :callbacks  — list of pending callback functions queued during in-flight fetch

(defvar opencode-api-cache--project-sessions (make-hash-table :test 'equal)
  "Hash table: project-dir (string) → plist (:sessions :refreshing :callbacks).
Single source of truth for per-project session lists.")

(defun opencode-api-cache--ps-entry (project-dir)
  "Return or create the cache entry plist for PROJECT-DIR."
  (or (gethash project-dir opencode-api-cache--project-sessions)
      (let ((entry (list :sessions nil :refreshing nil :callbacks nil)))
        (puthash project-dir entry opencode-api-cache--project-sessions)
        entry)))

(cl-defun opencode-api-cache-project-sessions (project-dir &key block cache callback force)
  "Access per-project session list cache.
PROJECT-DIR is the project directory to fetch sessions for.
:cache t     — return cached value or nil (never HTTP).
:block t     — synchronous HTTP fetch, return result directly.
:callback fn — async: call fn with result.  If cached, calls
                immediately.  Queues fn if a fetch is in-flight.
:force t     - force refresh the cache. priority is lower than cache.
Default      — return cache if available, kick off async refresh if empty."
  (let* ((entry (opencode-api-cache--ps-entry project-dir))
         (cached (plist-get entry :sessions))
         (refreshing (plist-get entry :refreshing))
         (params (list (cons "directory" project-dir)
                       (cons "limit" "100"))))
    (cond
     (cache cached)
     (block
      (if (and cached (not force))
          cached
        (let ((result (opencode-api-get-sync "/session" params)))
          (when result
            (plist-put entry :sessions result))
          (or result cached))))
     (callback
      (if (and cached (not force))
          (funcall callback cached)
        ;; Queue the callback
        (plist-put entry :callbacks
                   (append (plist-get entry :callbacks) (list callback)))
        ;; Start fetch if not already in-flight
        (unless refreshing
          (plist-put entry :refreshing t)
          (opencode-api-get
           "/session"
           (lambda (response)
             (let ((body (plist-get response :body))
                   (cbs (plist-get entry :callbacks)))
               (when body
                 (plist-put entry :sessions body))
               (plist-put entry :refreshing nil)
               (plist-put entry :callbacks nil)
               ;; Drain all queued callbacks
               (dolist (cb cbs)
                 (funcall cb body))))
           params))))
     ;; Default: return cache, sync refresh if empty
     (t
      (unless (or cached refreshing force)
        (plist-put entry :refreshing t)
        (opencode-api-cache-project-sessions project-dir :block t :force force)
        (plist-put entry :refreshing nil))
      cached))))

(defun opencode-api-cache-put-project-sessions (project-dir sessions)
  "Update the cached sessions for PROJECT-DIR."
  (when (and project-dir sessions)
    (plist-put (opencode-api-cache--ps-entry project-dir) :sessions sessions)))

(defun opencode-api-cache-invalidate-project-sessions (project-dir)
  "Remove PROJECT-DIR from the session list cache."
  (remhash project-dir opencode-api-cache--project-sessions))

(defun opencode-api-cache-project-sessions-refreshing-p (project-dir)
  "Return non-nil if PROJECT-DIR session list fetch is in-flight."
  (plist-get (opencode-api-cache--ps-entry project-dir) :refreshing))

;;; --- Agent validation (convenience) ---

(defun opencode-api-cache-valid-agent-p (agent-name)
  "Return non-nil if AGENT-NAME is a valid agent known to the server.
Checks against the agent cache.  When the cache has not been populated
yet (nil), returns non-nil — we cannot validate so we trust the name."
  (let ((agents (opencode-api--agents :cache t)))
    (or (null agents)                   ; cache not yet populated
        (and (vectorp agents)
             (seq-find (lambda (a) (string= (plist-get a :name) agent-name))
                       agents)))))

(provide 'opencode-api-cache)
;;; opencode-api-cache.el ends here
