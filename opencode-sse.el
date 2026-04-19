;;; opencode-sse.el --- SSE event stream consumer for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Server-Sent Events (SSE) consumer for the OpenCode event stream.
;; Connects to GET /event (or /global/event), parses SSE format,
;; and dispatches events to hook variables.
;;
;; SSE format:
;;   event: <type>
;;   data: <json>
;;   id: <id>
;;   (empty line = dispatch)
;;
;; Emacs 30: Benefits from `fast-read-process-output' for efficient
;; process filter handling of the long-lived SSE connection.

;;; Code:

(require 'json)
(require 'opencode-log)
(require 'opencode-util)
(require 'map)

(declare-function opencode-server-url "opencode-server" (&optional path))
(declare-function opencode-server--connected-p "opencode-server" ())
(declare-function opencode-server-auth-headers "opencode-server" ())

(defvar opencode-server-host)
(defvar opencode-server--port)

(defgroup opencode-sse nil
  "OpenCode SSE event stream."
  :group 'opencode
  :prefix "opencode-sse-")

;;; --- Customization ---

(defcustom opencode-sse-heartbeat-timeout 60
  "Seconds without any event before assuming connection lost.
OpenCode sends heartbeats every ~30s."
  :type 'integer
  :group 'opencode-sse)

(defcustom opencode-sse-max-reconnect-delay 30
  "Maximum seconds between reconnect attempts."
  :type 'integer
  :group 'opencode-sse)

(defcustom opencode-sse-auto-reconnect t
  "When non-nil, automatically reconnect on connection loss."
  :type 'boolean
  :group 'opencode-sse)

;;; --- Hook variables ---

(defvar opencode-sse-event-hook nil
  "Hook run for ALL SSE events.
Each function receives one argument: the event plist
with :type, :properties, and optionally :directory.")

(defvar opencode-sse-server-connected-hook nil
  "Hook run when `server.connected' event is received.")

(defvar opencode-sse-server-heartbeat-hook nil
  "Hook run when `server.heartbeat' event is received.")

(defvar opencode-sse-session-updated-hook nil
  "Hook run when `session.updated' event is received.
Functions receive the event plist with :properties containing :sessionID.")

(defvar opencode-sse-message-updated-hook nil
  "Hook run when `message.updated' event is received.
Functions receive the event plist.")

(defvar opencode-sse-message-part-updated-hook nil
  "Hook run when `message.part.updated' event is received.
This is the core streaming event.  Functions receive the event plist
with :properties containing :sessionID, :messageID, and :part.")

(defvar opencode-sse-message-part-removed-hook nil
  "Hook run when `message.part.removed' event is received.")

(defvar opencode-sse-message-removed-hook nil
  "Hook run when `message.removed' event is received.")

(defvar opencode-sse-session-status-hook nil
  "Hook run when `session.status' event is received.
Functions receive event plist with :sessionID and :status.")

(defvar opencode-sse-session-idle-hook nil
  "Hook run when `session.idle' event is received.
Functions receive the event plist with :properties containing :sessionID.")

(defvar opencode-sse-session-diff-hook nil
  "Hook run when `session.diff' event is received.")

(defvar opencode-sse-question-asked-hook nil
  "Hook run when `question.asked' event is received.")

(defvar opencode-sse-permission-asked-hook nil
  "Hook run when `permission.asked' event is received.")

(defvar opencode-sse-global-disposed-hook nil
  "Hook run when `global.disposed' event is received.")

(defvar opencode-sse-server-instance-disposed-hook nil
  "Hook run when `server.instance.disposed' event is received.
The server disposes instances when files change or the project reloads.
This is informational only — the global SSE connection remains alive.")

(defvar opencode-sse-session-deleted-hook nil
  "Hook run when `session.deleted' event is received.")

(defvar opencode-sse-session-error-hook nil
  "Hook run when `session.error' event is received.")

(defvar opencode-sse-session-compacted-hook nil
  "Hook run when `session.compacted' event is received.")

(defvar opencode-sse-session-created-hook nil
  "Hook run when `session.created' event is received.")

(defvar opencode-sse-todo-updated-hook nil
  "Hook run when `todo.updated' event is received.")

(defvar opencode-sse-permission-replied-hook nil
  "Hook run when `permission.replied' event is received.")

(defvar opencode-sse-question-replied-hook nil
  "Hook run when `question.replied' event is received.")

(defvar opencode-sse-question-rejected-hook nil
  "Hook run when `question.rejected' event is received.")

(defvar opencode-sse-installation-update-available-hook nil
  "Hook run when `installation.update-available' event is received.")

(defvar opencode-sse-tui-toast-show-hook nil
  "Hook run when `tui.toast.show' event is received.
Functions receive the event plist with :properties containing :message.")
;;; --- Internal state ---

(defvar opencode-sse--process nil
  "The network process for the SSE connection.")

(defvar opencode-sse--buffer nil
  "Internal buffer for accumulating partial SSE data.
Uses an Emacs buffer (gap buffer) instead of string concatenation
for O(1) append and efficient line-by-line scanning.")

(defvar opencode-sse--current-event nil
  "Plist for the SSE event currently being built.
Keys: :event-type, :data, :id.")

(defvar opencode-sse--last-event-id nil
  "The ID of the last received SSE event.")

(defvar opencode-sse--reconnect-timer nil
  "Timer for reconnect attempts.")

(defvar opencode-sse--reconnect-delay 1
  "Current reconnect delay in seconds (exponential backoff).")

(defvar opencode-sse--heartbeat-timer nil
  "Timer for heartbeat monitoring.")

(defvar opencode-sse--last-event-time nil
  "Timestamp of the last received event (float-time).")

(defvar opencode-sse--url nil
  "The SSE endpoint URL, stored for reconnection.")

(defvar opencode-sse--response-buffer nil
  "The url.el response buffer for the SSE connection.")

;;; --- Predicates ---

(defun opencode-sse--connected-p ()
  "Return non-nil if the SSE stream is connected."
  (and opencode-sse--process
       (process-live-p opencode-sse--process)))

(defun opencode-sse-connected-p ()
  "Return non-nil if the SSE stream is connected.
Public API."
  (opencode-sse--connected-p))

;;; --- State management ---

(defun opencode-sse--ensure-buffer ()
  "Ensure the SSE accumulation buffer exists and return it."
  (or (and opencode-sse--buffer
           (buffer-live-p opencode-sse--buffer)
           opencode-sse--buffer)
      (setq opencode-sse--buffer
            (let ((buf (generate-new-buffer " *opencode-sse-accum*")))
              (with-current-buffer buf
                (set-buffer-multibyte t))
              buf))))

(defun opencode-sse--kill-buffer ()
  "Kill the SSE accumulation buffer if it exists."
  (when (and opencode-sse--buffer (buffer-live-p opencode-sse--buffer))
    (kill-buffer opencode-sse--buffer))
  (setq opencode-sse--buffer nil))

(defun opencode-sse--reset-state ()
  "Reset all SSE internal state."
  (opencode-sse--kill-buffer)
  (setq opencode-sse--current-event nil
        opencode-sse--last-event-time nil))

;;; --- SSE line parser ---

(defun opencode-sse--process-line (line)
  "Process a single SSE LINE.
Accumulates event data and dispatches on empty lines."
  (cond
   ;; Empty line → dispatch accumulated event
   ((string-empty-p line)
    (when opencode-sse--current-event
      (let ((event-type (or (plist-get opencode-sse--current-event :event-type)
                            "message"))
            (data (plist-get opencode-sse--current-event :data))
            (id (plist-get opencode-sse--current-event :id)))
        (when data
          (opencode-sse--dispatch-event event-type data id)))
      (setq opencode-sse--current-event nil)))
   ;; Comment line (starts with :)
   ((string-prefix-p ":" line)
    nil)
   ;; event: <type>
   ((string-match "^event: ?\\(.*\\)" line)
    (setq opencode-sse--current-event
          (plist-put (or opencode-sse--current-event '())
                     :event-type (match-string 1 line))))
   ;; data: <json>
   ((string-match "^data: ?\\(.*\\)" line)
    (let ((existing-data (plist-get opencode-sse--current-event :data)))
      (setq opencode-sse--current-event
            (plist-put (or opencode-sse--current-event '()) :data
                       (if existing-data
                           (concat existing-data "\n" (match-string 1 line))
                         (match-string 1 line))))))
   ;; id: <id>
   ((string-match "^id: ?\\(.*\\)" line)
    (setq opencode-sse--current-event
          (plist-put (or opencode-sse--current-event '())
                     :id (match-string 1 line)))
    (setq opencode-sse--last-event-id (match-string 1 line)))
   ;; Unknown field — ignore per spec
   (t nil)))

;;; --- Event dispatch ---

(defun opencode-sse--dispatch-event (event-type data-string &optional id)
  "Dispatch an SSE event.
EVENT-TYPE is the event type string.
DATA-STRING is the raw data (JSON string).
ID is the optional event ID.
Skips sync-envelope events, which the server re-publishes as bus
events for backwards compatibility — processing both would double
every handler run."
  (opencode--debug "opencode-sse: raw event: type=%s data=%s"
           event-type
           data-string)
  (setq opencode-sse--last-event-time (float-time))
  ;; Reset reconnect backoff on successful event
  (setq opencode-sse--reconnect-delay 1)
  (condition-case err
      (let ((event (opencode-sse--parse-event event-type data-string id)))
        (when event
          (opencode-sse--run-hooks event)))
    (error
     (opencode--debug "opencode-sse: Error dispatching event %s: %s"
              event-type (error-message-string err)))))

(defun opencode-sse--parse-event (event-type data-string id)
  "Parse DATA-STRING into a normalized event plist, or nil to skip.
Handles two envelope formats:
  - Global:   {directory, payload: {type, properties}}
  - Instance: {type, properties}
Sync envelopes ({payload: {type: \"sync\", syncEvent: {...}}}) return
nil: the server re-publishes every sync event as a bus event for
backwards compatibility, so processing both duplicates handler calls."
  (let* ((json-data (opencode--json-parse data-string))
         (payload (plist-get json-data :payload)))
    (cond
     ;; Sync envelope — drop; the same event arrives as a bus event too
     ((and payload (equal (plist-get payload :type) "sync"))
      nil)
     ;; Global event format
     (payload
      (list :type (or (plist-get payload :type) event-type)
            :properties (plist-get payload :properties)
            :directory (plist-get json-data :directory)
            :id id))
     ;; Instance event format
     ((plist-get json-data :type)
      (list :type (plist-get json-data :type)
            :properties (plist-get json-data :properties)
            :id id))
     ;; Fallback: use the SSE event-type field
     (t (list :type event-type
              :properties json-data
              :id id)))))

(defun opencode-sse--run-hooks (event)
  "Run the catch-all and type-specific hooks for EVENT."
  (let ((type (plist-get event :type)))
    (opencode--debug "opencode-sse: [%s] dir=%s props-keys=%S"
             type
             (plist-get event :directory)
             (and (plist-get event :properties)
                  (map-keys (plist-get event :properties))))
    (run-hook-with-args 'opencode-sse-event-hook event)
    (when-let* ((hook (opencode-sse--hook-for-type type)))
      (opencode--debug "opencode-sse: dispatching to %s (%d listeners)"
               hook (length (symbol-value hook)))
      (run-hook-with-args hook event))))

(defconst opencode-sse--type->hook
  '(("server.connected"              . opencode-sse-server-connected-hook)
    ("server.heartbeat"               . opencode-sse-server-heartbeat-hook)
    ("session.updated"                . opencode-sse-session-updated-hook)
    ("message.updated"                . opencode-sse-message-updated-hook)
    ("message.part.updated"           . opencode-sse-message-part-updated-hook)
    ;; part.delta is an alias for part.updated — both fire the same hook.
    ("message.part.delta"             . opencode-sse-message-part-updated-hook)
    ("message.part.removed"           . opencode-sse-message-part-removed-hook)
    ("message.removed"                . opencode-sse-message-removed-hook)
    ("session.status"                 . opencode-sse-session-status-hook)
    ("session.idle"                   . opencode-sse-session-idle-hook)
    ("session.diff"                   . opencode-sse-session-diff-hook)
    ("question.asked"                 . opencode-sse-question-asked-hook)
    ("permission.asked"               . opencode-sse-permission-asked-hook)
    ("global.disposed"                . opencode-sse-global-disposed-hook)
    ("server.instance.disposed"       . opencode-sse-server-instance-disposed-hook)
    ("session.deleted"                . opencode-sse-session-deleted-hook)
    ("session.error"                  . opencode-sse-session-error-hook)
    ("session.compacted"              . opencode-sse-session-compacted-hook)
    ("session.created"                . opencode-sse-session-created-hook)
    ("todo.updated"                   . opencode-sse-todo-updated-hook)
    ("permission.replied"             . opencode-sse-permission-replied-hook)
    ("question.replied"               . opencode-sse-question-replied-hook)
    ("question.rejected"              . opencode-sse-question-rejected-hook)
    ("installation.update-available"  . opencode-sse-installation-update-available-hook)
    ("tui.toast.show"                 . opencode-sse-tui-toast-show-hook))
  "Map SSE event TYPE string → hook variable symbol.")

(defun opencode-sse--hook-for-type (type)
  "Return the hook variable for event TYPE string, or nil."
  (cdr (assoc type opencode-sse--type->hook)))

;;; --- Process filter ---

(defun opencode-sse--filter (_process output)
  "Process filter for the SSE connection.
_PROCESS is the network process.  OUTPUT is new data received.
Uses an internal Emacs buffer as accumulator for O(1) append.

Two key optimizations:
1. Skip scan when the new chunk has no newline — the existing
   buffer content has no complete lines (they were consumed by
   previous calls), so only new data can introduce a newline.
2. Bulk delete — scan all lines first, then delete the consumed
   region once.  Per-line delete-region is O(remaining-size) each,
   giving O(k*n) for k lines; one bulk delete is O(n) total."
  (let ((accum-buf (opencode-sse--ensure-buffer))
        (has-nl (string-search "\n" output)))
    (with-current-buffer accum-buf
      ;; O(1) append — gap buffer moves gap to end
      (goto-char (point-max))
      (insert output)
      (when has-nl
        (goto-char (point-min))
        (let ((line-count 0)
              (consumed-end (point-min)))
          ;; Scan forward collecting lines — don't delete yet.
          (while (search-forward "\n" nil t)
            (let* ((nl-pos (point))
                   (raw-line (buffer-substring-no-properties
                              consumed-end (1- nl-pos)))
                   (line (if (and (> (length raw-line) 0)
                                 (eq (aref raw-line (1- (length raw-line))) ?\r))
                             (substring raw-line 0 -1)
                           raw-line)))
              (setq consumed-end nl-pos)
              (setq line-count (1+ line-count))
              (opencode-sse--process-line line)))
          ;; Single bulk delete of all consumed data
          (when (> consumed-end (point-min))
            (delete-region (point-min) consumed-end))
          (when (> line-count 0)
            (opencode--debug "opencode-sse: processed %d lines, %d bytes remaining"
                             line-count (- (point-max) (point-min)))))))))

;;; --- Sentinel ---

(defun opencode-sse--sentinel (_process event)
  "Sentinel for the SSE connection process.
Handles disconnection and triggers reconnect."
  (let ((event-str (string-trim event)))
    (opencode--debug "opencode-sse: sentinel event: %s" event-str)
    (unless (string-match-p "\\`open" event-str)
      ;; Connection lost
      (opencode--debug "opencode-sse: connection lost, will reconnect=%s" opencode-sse-auto-reconnect)
      (setq opencode-sse--process nil)
      (opencode-sse--stop-heartbeat)
      (when opencode-sse-auto-reconnect
        (opencode-sse--schedule-reconnect)))))

;;; --- Connect / Disconnect ---

(defun opencode-sse-connect (&optional _url)
  "Connect to the SSE event stream via curl subprocess.
Uses `curl --no-buffer' for true streaming (url.el buffers responses).
Connects to /global/event which does NOT need X-OpenCode-Directory."
  (when (opencode-sse-connected-p)
    (opencode-sse-disconnect))
  (opencode-sse--reset-state)
  (let* ((process-adaptive-read-buffering nil)
         (host opencode-server-host)
         (port opencode-server--port)
         (sse-url (format "http://%s:%d/global/event" host port))
         (auth-headers (opencode-server-auth-headers))
         (curl-args (append (list "-s" "-N"
                                  "-H" "Accept: text/event-stream"
                                  "-H" "Cache-Control: no-cache")
                            (when auth-headers
                              (list "-H" (format "Authorization: %s" (cdr (assoc "Authorization" auth-headers)))))
                            (list sse-url))))
    (setq opencode-sse--url sse-url)
    (opencode--debug "opencode-sse: connecting via curl to %s" sse-url)
    (opencode--debug "opencode-sse: curl args: %S" curl-args)
    (let ((proc (apply #'start-process
                       "opencode-sse" nil
                       (opencode-sse--curl-path) curl-args)))
      (when proc
        (setq opencode-sse--process proc)
        (set-process-filter proc #'opencode-sse--filter)
        (set-process-sentinel proc #'opencode-sse--sentinel)
        (set-process-query-on-exit-flag proc nil)
        ;; Force unix EOL — plain 'utf-8 uses auto-detection which can
        ;; buffer data until it sees the first line ending, starving
        ;; the filter when the first newline is megabytes into a large
        ;; SSE payload.
        (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
        ;; Disable adaptive read buffering for the SSE process.
        ;; The default (t) makes Emacs coalesce small reads with
        ;; increasing delay, which destroys streaming latency —
        ;; deltas arrive seconds to tens of seconds late after a
        ;; long session.
        (when (fboundp 'set-process-adaptive-read-buffering)
          (set-process-adaptive-read-buffering proc nil))
        (opencode-sse--start-heartbeat)
        (opencode--debug "opencode-sse: curl process started, pid=%s"
                 (process-id proc))))))

(defun opencode-sse-disconnect ()
  "Disconnect from the SSE event stream."
  (opencode--debug "opencode-sse: disconnecting")
  (when opencode-sse--reconnect-timer
    (cancel-timer opencode-sse--reconnect-timer)
    (setq opencode-sse--reconnect-timer nil))
  (opencode-sse--stop-heartbeat)
  (when (and opencode-sse--process (process-live-p opencode-sse--process))
    (set-process-sentinel opencode-sse--process #'ignore)
    (delete-process opencode-sse--process))
  (when (and opencode-sse--response-buffer
             (buffer-live-p opencode-sse--response-buffer))
    (kill-buffer opencode-sse--response-buffer))
  (setq opencode-sse--process nil
        opencode-sse--response-buffer nil)
  (opencode-sse--reset-state))

;;; --- Reconnect ---

(defun opencode-sse--schedule-reconnect ()
  "Schedule a reconnect attempt with exponential backoff."
  (when opencode-sse--reconnect-timer
    (cancel-timer opencode-sse--reconnect-timer))
  (setq opencode-sse--reconnect-timer
        (run-with-timer opencode-sse--reconnect-delay nil
                        #'opencode-sse--do-reconnect))
  ;; Increase backoff
  (setq opencode-sse--reconnect-delay
        (min (* opencode-sse--reconnect-delay 2)
             opencode-sse-max-reconnect-delay)))

(defun opencode-sse--do-reconnect ()
  "Attempt to reconnect to the SSE stream.
Only reconnects if the server is still connected."
  (setq opencode-sse--reconnect-timer nil)
  (condition-case err
      (when (and opencode-sse--url
                 (opencode-server--connected-p))
        (opencode-sse--connect))
    (error
     (opencode--debug "opencode-sse: Reconnect failed: %s" (error-message-string err))
     (when opencode-sse-auto-reconnect
       (opencode-sse--schedule-reconnect)))))

;;; --- Heartbeat monitoring ---

(defun opencode-sse--start-heartbeat ()
  "Start heartbeat monitoring."
  (opencode-sse--stop-heartbeat)
  (setq opencode-sse--last-event-time (float-time))
  (setq opencode-sse--heartbeat-timer
        (run-with-timer opencode-sse-heartbeat-timeout
                        opencode-sse-heartbeat-timeout
                        #'opencode-sse--check-heartbeat)))

(defun opencode-sse--stop-heartbeat ()
  "Stop heartbeat monitoring."
  (when opencode-sse--heartbeat-timer
    (cancel-timer opencode-sse--heartbeat-timer)
    (setq opencode-sse--heartbeat-timer nil)))

(defun opencode-sse--check-heartbeat ()
  "Check if we've received events within the heartbeat timeout."
  (when (and opencode-sse--last-event-time
             (> (- (float-time) opencode-sse--last-event-time)
                opencode-sse-heartbeat-timeout))
    ;; Heartbeat timeout — assume connection lost
    (opencode--debug "opencode-sse: Heartbeat timeout, reconnecting...")
    (opencode-sse-disconnect)
    (when opencode-sse-auto-reconnect
      (opencode-sse--schedule-reconnect))))

;;; --- Curl transport ---

(defvar opencode-sse--curl-path-cache nil
  "Cached path to curl executable.")

(defun opencode-sse--curl-path ()
  "Return the path to curl, caching the result."
  (or opencode-sse--curl-path-cache
      (setq opencode-sse--curl-path-cache
            (or (executable-find "curl")
                (error "curl not found in PATH")))))

;;; --- Internal connect/disconnect ---

(defun opencode-sse--connect ()
  "Internal connect function used by reconnect logic."
  (opencode-sse-connect))

(defun opencode-sse--disconnect ()
  "Internal disconnect — same as `opencode-sse-disconnect'."
  (opencode-sse-disconnect))

(provide 'opencode-sse)
;;; opencode-sse.el ends here
