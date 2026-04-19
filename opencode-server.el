;;; opencode-server.el --- Server subprocess lifecycle for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Manages the OpenCode server subprocess lifecycle:
;; - Spawn `opencode serve --port 0` and parse the dynamically assigned port
;; - Process sentinel for crash detection and auto-restart
;; - Health check with retry and exponential backoff
;; - Graceful shutdown via POST /global/dispose
;; - Connect mode for attaching to an existing server
;; - Per-directory server tracking
;;
;; Emacs 30: Benefits from `fast-read-process-output' (native default
;; process filter) for efficient subprocess stdout/stderr handling.
;;
;; WHY HTTP IS REQUIRED:
;; The TUI avoids HTTP by running Server.App() (Hono) in a Bun Worker thread
;; and calling .fetch() directly via inter-thread RPC.  This is a Bun-specific
;; optimization that Emacs cannot replicate — Emacs has no JavaScript runtime.
;; We must use real HTTP, which matches how `opencode attach` and the Web App
;; work.  See AGENTS.md "Why Emacs Requires HTTP" for details.

;;; Code:

(require 'url)
(require 'url-http)
(require 'opencode-util)

(defvar url-http-end-of-headers)

(defgroup opencode-server nil
  "OpenCode server subprocess management."
  :group 'opencode
  :prefix "opencode-server-")

;;; --- Customization ---

(defcustom opencode-server-command "opencode"
  "Path to the opencode executable."
  :type 'string
  :group 'opencode-server)

(defcustom opencode-server-args '("serve" "--port" "0" "--print-logs")
  "Arguments passed to the opencode server command.
\"--port 0\" makes the OS assign a free port."
  :type '(repeat string)
  :group 'opencode-server)

(defcustom opencode-server-log-level "WARN"
  "Log level for the opencode server subprocess."
  :type '(choice (const "DEBUG") (const "INFO") (const "WARN") (const "ERROR"))
  :group 'opencode-server)

(defcustom opencode-server-auto-restart t
  "When non-nil, automatically restart the server if it crashes."
  :type 'boolean
  :group 'opencode-server)

(defcustom opencode-server-host "127.0.0.1"
  "Hostname for the opencode server."
  :type 'string
  :group 'opencode-server)

(defcustom opencode-server-username "opencode"
  "Username for basic authentication."
  :type 'string
  :group 'opencode-server)

(defcustom opencode-server-password nil
  "Password for basic authentication.
If non-nil, basic authentication will be used."
  :type '(choice (string :tag "Password")
                 (const :tag "None" nil))
  :group 'opencode-server)

(defcustom opencode-server-port nil
  "Fixed port for the opencode server.
When nil (default), uses --port 0 for auto-assignment.
Set to a number to connect to an existing server (no subprocess spawned)."
  :type '(choice (const :tag "Auto-assign (spawn server)" nil)
                 (integer :tag "Fixed port (connect to existing)"))
  :group 'opencode-server)

(defcustom opencode-server-health-retries 5
  "Number of health check retry attempts on startup."
  :type 'integer
  :group 'opencode-server)

(defcustom opencode-server-restart-delay 2
  "Seconds to wait before auto-restarting a crashed server."
  :type 'number
  :group 'opencode-server)

;;; --- Internal state ---

(defvar opencode-server--process nil
  "The opencode server process object, or nil if not running.")

(defvar opencode-server--port nil
  "The port the server is listening on, or nil if not connected.")

(defvar opencode-server--status nil
  "Server connection status.
One of: nil, `starting', `connected', `disconnected', `error'.")

(defvar opencode-server--stdout-buffer nil
  "Internal buffer for accumulating partial stdout from the server process.
Uses an Emacs buffer (gap buffer) instead of string concatenation
for O(1) append and efficient line-by-line scanning.")

(defvar opencode-server--restart-timer nil
  "Timer for auto-restart after crash.")

(defvar opencode-server--log-buffer-name "*opencode: log*"
  "Name of the server log buffer.")

(defvar opencode-server--port-callback nil
  "Callback function invoked when port is parsed from server stdout.
Called with one argument: the port number.")

(defvar opencode-server--managed-p nil
  "Non-nil when we spawned the server (managed mode).
Nil when connecting to an existing server (connect mode).")

(defcustom opencode-server-log-max-lines 5000
  "Maximum number of lines to keep in the server log buffer.
When exceeded, the oldest lines are deleted.  Set to nil to disable truncation."
  :type '(choice (integer :tag "Max lines")
                 (const :tag "Unlimited" nil))
  :group 'opencode-server)

;;; --- Logging ---

(defvar opencode-server--log-line-count 0
  "Approximate number of lines in the server log buffer.
Tracked incrementally to avoid O(n) scanning on every log call.")

(defun opencode-server--log (format-string &rest args)
  "Log a message to the opencode log buffer.
FORMAT-STRING and ARGS are passed to `format'.
Automatically truncates to `opencode-server-log-max-lines'."
  (let ((buf (get-buffer-create opencode-server--log-buffer-name))
        (msg (apply #'format format-string args))
        (timestamp (format-time-string "%H:%M:%S")))
    (with-current-buffer buf
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (insert (format "[%s] %s\n" timestamp msg)))
      (setq opencode-server--log-line-count
            (1+ opencode-server--log-line-count))
      ;; Truncate: delete half at once to amortize cost
      (when (and opencode-server-log-max-lines
                 (> opencode-server--log-line-count
                    opencode-server-log-max-lines))
        (let ((delete-count (/ opencode-server-log-max-lines 2)))
          (save-excursion
            (goto-char (point-min))
            (forward-line delete-count)
            (let ((inhibit-read-only t))
              (delete-region (point-min) (point))))
          (setq opencode-server--log-line-count
                (- opencode-server--log-line-count delete-count)))))))

;;; --- URL construction ---

(defun opencode-server--url (&optional path)
  "Return the base URL for the OpenCode server, optionally with PATH appended.
Does NOT call `opencode-server-ensure' — for internal use.
Signals `user-error' if not connected."
  (unless opencode-server--port
    (user-error "OpenCode server not connected (no port)"))
  (unless (eq opencode-server--status 'connected)
    (user-error "OpenCode server status is `%s', expected `connected'"
                opencode-server--status))
  (let ((base (format "http://%s:%d" opencode-server-host opencode-server--port)))
    (if path
        (concat base (if (string-prefix-p "/" path) path (concat "/" path)))
      base)))

(defun opencode-server-url (&optional path)
  "Return the base URL for the OpenCode server, optionally with PATH appended.
Signals an error if the server is not connected."
  (opencode-server-ensure)
  (opencode-server--url path))

(defun opencode-server-auth-headers ()
  "Return an alist of authentication headers if basic auth is configured.
Otherwise return nil."
  (when opencode-server-password
    `(("Authorization" . ,(concat "Basic "
                                  (base64-encode-string
                                   (format "%s:%s"
                                           opencode-server-username
                                           opencode-server-password)
                                   t))))))

;;; --- Predicates ---

(defun opencode-server--connected-p ()
  "Return non-nil if the server is connected and ready."
  (and opencode-server--port
       (eq opencode-server--status 'connected)))

(defun opencode-server-connected-p ()
  "Return non-nil if the server is connected and ready.
Public API — same as `opencode-server--connected-p'."
  (opencode-server--connected-p))

(defun opencode-server--ensure ()
  "Ensure the server is connected, auto-connecting if possible.
If `opencode-server-port' is set but we haven't connected yet,
automatically connect to the existing server.  Otherwise signal
a `user-error' with actionable instructions."
  (unless (opencode-server-connected-p)
    ;; Try auto-connect if a fixed port is configured
    (when (and opencode-server-port (not opencode-server--port))
      (opencode-server-start))
    ;; Check again after potential auto-connect
    (unless opencode-server--port
      (user-error "OpenCode server not connected.  Either:\n  (setq opencode-server-port 4096)  ; then retry\n  M-x opencode-start               ; to spawn/connect"))
    (unless (eq opencode-server--status 'connected)
      (user-error "OpenCode server status is `%s', expected `connected'"
                  opencode-server--status))))

(defun opencode-server-ensure ()
  "Ensure the server is connected, auto-connecting if possible."
  (opencode-server--ensure))

(defun opencode-server--ensure-stdout-buffer ()
  "Ensure the stdout accumulation buffer exists and return it."
  (or (and opencode-server--stdout-buffer
           (buffer-live-p opencode-server--stdout-buffer)
           opencode-server--stdout-buffer)
      (setq opencode-server--stdout-buffer
            (let ((buf (generate-new-buffer " *opencode-server-stdout*")))
              (with-current-buffer buf
                (set-buffer-multibyte t))
              buf))))

(defun opencode-server--kill-stdout-buffer ()
  "Kill the stdout accumulation buffer if it exists."
  (when (and opencode-server--stdout-buffer
             (buffer-live-p opencode-server--stdout-buffer))
    (kill-buffer opencode-server--stdout-buffer))
  (setq opencode-server--stdout-buffer nil))

;;; --- Process filter ---

(defun opencode-server--process-filter (_process output)
  "Process filter for the opencode server subprocess.
Accumulates partial lines and logs complete ones.
During startup, also scans for the port announcement."
  (let ((accum-buf (opencode-server--ensure-stdout-buffer)))
    (with-current-buffer accum-buf
      (goto-char (point-max))
      (insert output)
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (let* ((nl-pos (point))
               (line-end (1- nl-pos))
               (line (buffer-substring-no-properties (point-min) line-end)))
          (delete-region (point-min) nl-pos)
          (goto-char (point-min))
          (unless (string-empty-p line)
            (opencode-server--log "%s" line)
            (when (eq opencode-server--status 'starting)
              (opencode-server--try-parse-port line))))))))

(defun opencode-server--try-parse-port (line)
  "Try to parse the server port from LINE.
Looks for patterns like \"listening on http://127.0.0.1:PORT\" or
\"http://HOST:PORT\" or just a bare port announcement.
Only parses during startup (when status is `starting')."
  (when (and (eq opencode-server--status 'starting)
             (string-match "\\(?:listening on\\|http://[^:]+:\\)\\([0-9]+\\)" line))
    (let ((port (string-to-number (match-string 1 line))))
      (when (> port 0)
        (setq opencode-server--port port)
        (opencode-server--log "Parsed server port: %d" port)
        (when opencode-server--port-callback
          (funcall opencode-server--port-callback port)
          (setq opencode-server--port-callback nil))))))

;;; --- Process sentinel ---

(defun opencode-server--process-sentinel (_process event)
  "Sentinel for the opencode server process.
_PROCESS is the server process, EVENT describes the status change."
  (let ((event-str (string-trim event)))
    (opencode-server--log "Server process event: %s" event-str)
    (cond
     ;; Process exited normally
     ((string-match-p "finished\\|exited" event-str)
      (setq opencode-server--status 'disconnected)
      (setq opencode-server--process nil)
      (opencode-server--log "Server stopped")
      (run-hooks 'opencode-server-disconnected-hook))
     ;; Process was killed or crashed
     ((string-match-p "\\(?:killed\\|signal\\|abnormal\\|connection broken\\)" event-str)
      (setq opencode-server--status 'error)
      (setq opencode-server--process nil)
      (opencode-server--log "Server crashed: %s" event-str)
      (run-hooks 'opencode-server-disconnected-hook)
      ;; Auto-restart if configured and we were in managed mode
      (when (and opencode-server-auto-restart opencode-server--managed-p)
        (opencode-server--schedule-restart))))))

;;; --- Auto-restart ---

(defun opencode-server--schedule-restart ()
  "Schedule a server restart after `opencode-server-restart-delay' seconds."
  (when opencode-server--restart-timer
    (cancel-timer opencode-server--restart-timer))
  (opencode-server--log "Scheduling restart in %ds..." opencode-server-restart-delay)
  (setq opencode-server--restart-timer
        (run-with-timer opencode-server-restart-delay nil
                        #'opencode-server--do-restart)))

(defun opencode-server--do-restart ()
  "Perform the actual server restart."
  (setq opencode-server--restart-timer nil)
  (opencode-server--log "Attempting restart...")
  (condition-case err
      (opencode-server-start)
    (error
     (opencode-server--log "Restart failed: %s" (error-message-string err)))))

;;; --- Health check ---

(defun opencode-server-health-check (&optional callback)
  "Check server health via GET /global/health.
If CALLBACK is non-nil, call it with the parsed response plist on success,
or nil on failure.  If CALLBACK is nil, return the response synchronously
or signal an error."
  (let ((url (format "http://%s:%d/global/health"
                     opencode-server-host opencode-server--port))
        (url-request-extra-headers (opencode-server-auth-headers)))
    (if callback
        (url-retrieve
         url
         (lambda (status cb)
           (if (plist-get status :error)
               (funcall cb nil)
             (goto-char url-http-end-of-headers)
             (condition-case nil
                (funcall cb (opencode--json-parse
                             (buffer-substring-no-properties (point) (point-max))))
               (error (funcall cb nil)))))
         (list callback)
         t)
      ;; Synchronous
      (let ((buf (url-retrieve-synchronously url t nil 5)))
        (if buf
            (unwind-protect
                (with-current-buffer buf
                  (goto-char url-http-end-of-headers)
                  (opencode--json-parse
                   (buffer-substring-no-properties (point) (point-max))))
              (kill-buffer buf))
          (error "Health check failed: no response"))))))

(defun opencode-server--wait-for-health ()
  "Wait for the server to become healthy.
Retries up to `opencode-server-health-retries' times with exponential backoff."
  (let ((retries opencode-server-health-retries)
        (delay 0.2)
        (healthy nil))
    (while (and (> retries 0) (not healthy))
      (condition-case err
          (let ((resp (opencode-server-health-check)))
            (when (plist-get resp :healthy)
              (setq healthy t)))
        (error (opencode--debug "opencode-server: health check retry error: %S" err)))
      (unless healthy
        (setq retries (1- retries))
        (when (> retries 0)
          (sleep-for delay)
          (setq delay (min (* delay 2) 5.0)))))
    (unless healthy
      (error "Server health check failed after %d retries"
             opencode-server-health-retries))
    (opencode-server--log "Server is healthy")
    t))

;;; --- Start / Stop ---


(defun opencode-server-start (&optional directory)
  "Start or connect to the OpenCode server.
If `opencode-server-port' is set, connect to an existing server (connect mode).
Otherwise, spawn a new `opencode serve' subprocess (managed mode).
Optional DIRECTORY specifies the project directory."
  (interactive)
  (when (opencode-server-connected-p)
    (opencode-server--log "Server already connected on port %d" opencode-server--port)
    (user-error "Server already connected.  Use `opencode-server-stop' first"))
  ;; Reset state
  (opencode-server--kill-stdout-buffer)
  (setq opencode-server--status 'starting)
  (if opencode-server-port
      ;; Connect mode: attach to existing server
      (opencode-server--connect-existing directory)
    ;; Managed mode: spawn subprocess
    (opencode-server--spawn directory)))

(defun opencode-server--connect-existing (&optional _directory)
  "Connect to an existing OpenCode server at the configured port."
  (setq opencode-server--managed-p nil
        opencode-server--port opencode-server-port)
  (opencode-server--log "Connecting to existing server at %s:%d"
                        opencode-server-host opencode-server--port)
  (condition-case err
      (progn
        (opencode-server--wait-for-health)
        (setq opencode-server--status 'connected)
        (opencode-server--log "Connected to server")
        (run-hooks 'opencode-server-connected-hook))
    (error
     (setq opencode-server--status 'error
           opencode-server--port nil)
     (signal (car err) (cdr err)))))

(defun opencode-server--spawn (&optional directory)
  "Spawn a new OpenCode server subprocess.
Optional DIRECTORY is the working directory for the server."
  (setq opencode-server--managed-p t)
  (let* ((default-directory (or directory default-directory))
         (args (append opencode-server-args
                       (list "--log-level" opencode-server-log-level
                             "--hostname" opencode-server-host)))
         (process-environment (copy-sequence process-environment))
         (buf (get-buffer-create opencode-server--log-buffer-name))
         (proc (apply #'start-process
                      "opencode-server" buf
                      opencode-server-command args)))
    (opencode-server--log "Spawning: %s %s (in %s)"
                          opencode-server-command
                          (string-join args " ")
                          default-directory)
    (set-process-filter proc #'opencode-server--process-filter)
    (set-process-sentinel proc #'opencode-server--process-sentinel)
    (set-process-query-on-exit-flag proc nil)
    (setq opencode-server--process proc)
    ;; Wait for port to be parsed (with timeout)
    (let ((deadline (+ (float-time) 15.0)))
      (while (and (not opencode-server--port)
                  (< (float-time) deadline)
                  (process-live-p proc))
        (accept-process-output proc 0.1))
      (unless opencode-server--port
        (when (process-live-p proc)
          (delete-process proc))
        (setq opencode-server--status 'error
              opencode-server--process nil)
        (error "Timed out waiting for server port")))
    ;; Health check
    (condition-case err
        (progn
          (opencode-server--wait-for-health)
          (setq opencode-server--status 'connected)
          (opencode-server--log "Server ready on port %d" opencode-server--port)
          (run-hooks 'opencode-server-connected-hook))
      (error
       (when (process-live-p proc)
         (delete-process proc))
       (setq opencode-server--status 'error
             opencode-server--process nil
             opencode-server--port nil)
       (signal (car err) (cdr err))))))

(defun opencode-server--stop ()
  "Stop the OpenCode server (internal implementation).
In managed mode, sends POST /global/dispose and kills the process.
In connect mode, just disconnects (does not kill the external server)."
  (when opencode-server--restart-timer
    (cancel-timer opencode-server--restart-timer)
    (setq opencode-server--restart-timer nil))
  (when (and opencode-server--port
            (eq opencode-server--status 'connected)
            ;; Only send dispose when we have a real managed process.
            ;; Without this guard, --stop called with port set but no process
            ;; would send POST /global/dispose to whatever is on that port,
            ;; potentially killing an unrelated server.
            opencode-server--managed-p
            opencode-server--process
            (process-live-p opencode-server--process))
    ;; Try graceful dispose
    (condition-case err
        (let* ((url (format "http://%s:%d/global/dispose"
                            opencode-server-host opencode-server--port))
               (url-request-method "POST")
               (url-request-extra-headers (append '(("Content-Type" . "application/json"))
                                                  (opencode-server-auth-headers)))
               (buf (url-retrieve-synchronously url t nil 5)))
          (when buf (kill-buffer buf))
          (opencode-server--log "Sent dispose request"))
      (error (opencode--debug "opencode-server: dispose request error: %S" err))))
  ;; Kill process if managed
  (when (and opencode-server--process (process-live-p opencode-server--process))
    (let ((proc opencode-server--process))
      (set-process-sentinel proc #'ignore)
      (delete-process proc)
      (opencode-server--log "Server process killed")))
  ;; Reset state
  (setq opencode-server--process nil
        opencode-server--port nil
        opencode-server--status 'disconnected
        opencode-server--managed-p nil)
  (opencode-server--kill-stdout-buffer)
  (run-hooks 'opencode-server-disconnected-hook)
  (opencode-server--log "Disconnected"))

(defun opencode-server-stop ()
  "Stop the OpenCode server."
  (interactive)
  (opencode-server--stop))

;;; --- Hooks ---

(defvar opencode-server-connected-hook nil
  "Hook run when the server connection is established.")

(defvar opencode-server-disconnected-hook nil
  "Hook run when the server connection is lost.")

(provide 'opencode-server)
;;; opencode-server.el ends here
