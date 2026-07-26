;;; opencode-pi-rpc.el --- Pi RPC subprocess transport for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Stdio transport for the Pi coding agent (https://github.com/earendil-works/pi).
;;
;; Pi has NO HTTP server.  Its headless integration surface is `pi --mode rpc',
;; a subprocess that speaks newline-delimited JSON:
;;
;;   - Commands   : JSON objects written to the subprocess stdin, one per line.
;;   - Responses  : JSON objects on stdout with `type:"response"' and a request
;;                  `id' for correlation.
;;   - Events     : JSON objects on stdout (agent/message/tool lifecycle).  No
;;                  `id' field.
;;   - UI requests: JSON objects on stdout with `type:"extension_ui_request"'
;;                  (select/confirm/input/editor).  Answered via an
;;                  `extension_ui_response' written to stdin.
;;
;; ONE subprocess corresponds to ONE Pi session (and one chat buffer).  This
;; module owns only the transport: process lifecycle, JSONL framing, request
;; correlation, and dispatch to caller-provided handlers.  Event/message
;; normalization into opencode.el's canonical shapes lives in `opencode-pi.el'.
;;
;; Framing rules (from Pi's `jsonl.ts'): split on LF (\n) only, strip a trailing
;; \r, never split on U+2028/U+2029 (valid inside JSON strings).
;;
;; CRITICAL (mirrors the `opencode-sse--filter' lesson): collect complete lines
;; first, delete the consumed region from the work buffer, THEN dispatch handlers
;; OUTSIDE the work buffer.  A handler may kill or reset the connection (e.g. a
;; popup answer that aborts the process); holding work-buffer positions across
;; dispatch would make later buffer operations see stale ranges and signal
;; `Args out of range'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'opencode-log)
(require 'opencode-util)

(defgroup opencode-pi nil
  "Pi backend for opencode.el."
  :group 'opencode
  :prefix "opencode-pi-")

(defcustom opencode-pi-program "pi"
  "Executable used to launch the Pi coding agent."
  :type 'string
  :group 'opencode-pi)

(defcustom opencode-pi-request-timeout 10
  "Default seconds to wait for a synchronous Pi RPC response."
  :type 'number
  :group 'opencode-pi)

;;; --- Connection object ---

(cl-defstruct (opencode-pi-conn
               (:constructor opencode-pi-conn--create)
               (:copier nil))
  "A live `pi --mode rpc' connection.

PROCESS is the subprocess.  WORK-BUFFER accumulates raw stdout bytes for
JSONL framing.  PENDING maps request id -> callback for response
correlation.  EVENT-HANDLER receives parsed non-response, non-UI events.
UI-HANDLER receives parsed `extension_ui_request' objects.  EXIT-HANDLER
runs once on process termination.  SESSION-ID identifies the Pi session
this connection serves (set once known via `get_state')."
  process
  work-buffer
  (pending (make-hash-table :test 'equal))
  (id-counter 0)
  event-handler
  ui-handler
  exit-handler
  session-id
  (alive t))

;;; --- Lifecycle ---

(defun opencode-pi-rpc-start (cwd &rest plist)
  "Start a `pi --mode rpc' subprocess in CWD and return an `opencode-pi-conn'.

PLIST keys:
  :args          extra command-line arguments (list of strings) appended
                 after `--mode rpc'.
  :event-handler function called with one parsed event plist per non-response,
                 non-UI stdout line.
  :ui-handler    function called with one parsed `extension_ui_request' plist.
  :exit-handler  function called with no args once the process terminates."
  (let* ((default-directory (file-name-as-directory (expand-file-name cwd)))
         (work-buffer (generate-new-buffer
                       (format " *opencode-pi-rpc:%s*"
                               (file-name-nondirectory
                                (directory-file-name default-directory)))))
         (args (append (list "--mode" "rpc") (plist-get plist :args)))
         (conn (opencode-pi-conn--create
                :work-buffer work-buffer
                :event-handler (plist-get plist :event-handler)
                :ui-handler (plist-get plist :ui-handler)
                :exit-handler (plist-get plist :exit-handler))))
    (with-current-buffer work-buffer
      (set-buffer-multibyte t))
    (let ((process
           (make-process
            :name (format "opencode-pi-rpc:%s"
                          (file-name-nondirectory
                           (directory-file-name default-directory)))
            :command (cons opencode-pi-program args)
            :connection-type 'pipe
            :coding 'utf-8-unix
            :noquery t
            :filter (lambda (_proc output)
                      (opencode-pi-rpc--filter conn output))
            :sentinel (lambda (_proc _event)
                        (opencode-pi-rpc--sentinel conn)))))
      (setf (opencode-pi-conn-process conn) process)
      (opencode--debug "opencode-pi-rpc: started %s %s in %s"
                       opencode-pi-program (string-join args " ")
                       default-directory)
      conn)))

(defun opencode-pi-rpc-alive-p (conn)
  "Return non-nil if CONN's subprocess is live."
  (and conn
       (opencode-pi-conn-alive conn)
       (let ((proc (opencode-pi-conn-process conn)))
         (and proc (process-live-p proc)))))

(defun opencode-pi-rpc-stop (conn)
  "Terminate CONN's subprocess and release its resources."
  (when conn
    (let ((proc (opencode-pi-conn-process conn)))
      (when (and proc (process-live-p proc))
        (delete-process proc)))
    (opencode-pi-rpc--cleanup conn)))

(defun opencode-pi-rpc--cleanup (conn)
  "Mark CONN dead, fail pending requests, and kill its work buffer."
  (when (opencode-pi-conn-alive conn)
    (setf (opencode-pi-conn-alive conn) nil)
    (opencode-pi-rpc--fail-pending conn "connection closed")
    (let ((buf (opencode-pi-conn-work-buffer conn)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun opencode-pi-rpc--sentinel (conn)
  "Handle CONN subprocess termination: fail pending, run exit handler."
  (opencode--debug "opencode-pi-rpc: process exited")
  (let ((exit-handler (opencode-pi-conn-exit-handler conn)))
    (opencode-pi-rpc--cleanup conn)
    (when exit-handler
      (condition-case err
          (funcall exit-handler)
        (error
         (opencode--debug "opencode-pi-rpc: exit-handler error: %s"
                          (error-message-string err)))))))

(defun opencode-pi-rpc--fail-pending (conn reason)
  "Invoke every pending callback in CONN with a synthetic error response.
REASON is a human-readable string."
  (let ((pending (opencode-pi-conn-pending conn)))
    (maphash
     (lambda (_id cb)
       (when cb
         (condition-case err
             (funcall cb (list :type "response" :success :false :error reason))
           (error
            (opencode--debug "opencode-pi-rpc: pending callback error: %s"
                             (error-message-string err))))))
     pending)
    (clrhash pending)))

;;; --- Sending commands ---

(defun opencode-pi-rpc--next-id (conn)
  "Return the next request id string for CONN."
  (format "req-%d" (cl-incf (opencode-pi-conn-id-counter conn))))

(defun opencode-pi-rpc-send (conn command &optional callback)
  "Send COMMAND (a plist) to CONN.  Return the request id.

COMMAND must include a `:type'.  An `:id' is generated and attached unless
already present.  When CALLBACK is non-nil it is invoked with the parsed
response plist whose `id' matches; otherwise the response is discarded.

Signals an error if CONN is not alive."
  (unless (opencode-pi-rpc-alive-p conn)
    (error "Pi RPC connection is not alive"))
  (let* ((id (or (plist-get command :id) (opencode-pi-rpc--next-id conn)))
         (command (plist-put (copy-sequence command) :id id))
         (json (opencode-util--json-serialize command))
         (line (concat (opencode-pi-rpc--to-unibyte json) "\n")))
    (when callback
      (puthash id callback (opencode-pi-conn-pending conn)))
    (opencode--debug "opencode-pi-rpc: >>> %s" json)
    (process-send-string (opencode-pi-conn-process conn) line)
    id))

(defun opencode-pi-rpc-request-sync (conn command &optional timeout)
  "Send COMMAND to CONN and block until its response arrives.
Return the parsed response plist, or a synthetic error response on TIMEOUT
\(default `opencode-pi-request-timeout' seconds)."
  (let* ((result nil)
         (done nil)
         (deadline (+ (float-time) (or timeout opencode-pi-request-timeout))))
    (opencode-pi-rpc-send conn command
                          (lambda (resp) (setq result resp done t)))
    (while (and (not done)
                (opencode-pi-rpc-alive-p conn)
                (< (float-time) deadline))
      (accept-process-output (opencode-pi-conn-process conn) 0.05))
    (or result
        (list :type "response" :success :false
              :error (if (opencode-pi-rpc-alive-p conn)
                         "request timed out"
                       "connection closed")))))

(defun opencode-pi-rpc--to-unibyte (string)
  "Return STRING as a unibyte UTF-8 byte sequence for `process-send-string'."
  (if (multibyte-string-p string)
      (encode-coding-string string 'utf-8 t)
    string))

;;; --- Receiving: JSONL framing + dispatch ---

(defun opencode-pi-rpc--filter (conn output)
  "Process filter for CONN: accumulate OUTPUT, frame JSONL, dispatch.

Collect complete lines, delete the consumed region, THEN dispatch each
line OUTSIDE the work buffer.  Dispatch may kill or reset CONN, so no
work-buffer position may be held across a handler call."
  (let ((work-buffer (opencode-pi-conn-work-buffer conn))
        lines)
    (when (buffer-live-p work-buffer)
      (with-current-buffer work-buffer
        (goto-char (point-max))
        (insert output)
        (when (string-search "\n" output)
          (goto-char (point-min))
          (let ((consumed-end (point-min)))
            (while (search-forward "\n" nil t)
              (let* ((nl-pos (point))
                     (raw-line (buffer-substring-no-properties
                                consumed-end (1- nl-pos))))
                (push (if (and (> (length raw-line) 0)
                               (eq (aref raw-line (1- (length raw-line))) ?\r))
                          (substring raw-line 0 -1)
                        raw-line)
                      lines)
                (setq consumed-end nl-pos)))
            (when (> consumed-end (point-min))
              (delete-region (point-min) consumed-end))))))
    (dolist (line (nreverse lines))
      (unless (string-empty-p (string-trim line))
        (opencode-pi-rpc--dispatch-line conn line)))))

(defun opencode-pi-rpc--dispatch-line (conn line)
  "Parse LINE as JSON and route it for CONN.
Each dispatch is isolated in `condition-case' so one malformed or
mishandled line cannot break the rest of the stream."
  (condition-case err
      (let* ((obj (opencode--json-parse line))
             (type (plist-get obj :type)))
        (opencode--debug "opencode-pi-rpc: <<< %s" line)
        (cond
         ((equal type "response")
          (opencode-pi-rpc--handle-response conn obj))
         ((equal type "extension_ui_request")
          (let ((handler (opencode-pi-conn-ui-handler conn)))
            (when handler (funcall handler obj))))
         (t
          (let ((handler (opencode-pi-conn-event-handler conn)))
            (when handler (funcall handler obj))))))
    (error
     (opencode--debug "opencode-pi-rpc: dispatch error on %s: %s"
                      line (error-message-string err)))))

(defun opencode-pi-rpc--handle-response (conn obj)
  "Resolve the pending callback in CONN for response OBJ by its `id'."
  (let* ((id (plist-get obj :id))
         (pending (opencode-pi-conn-pending conn))
         (cb (and id (gethash id pending))))
    (when id (remhash id pending))
    (when cb
      (condition-case err
          (funcall cb obj)
        (error
         (opencode--debug "opencode-pi-rpc: response callback error: %s"
                          (error-message-string err)))))))

;;; --- Extension UI replies ---

(defun opencode-pi-rpc-ui-reply-value (conn id value)
  "Answer extension UI request ID on CONN with string VALUE."
  (opencode-pi-rpc-send conn (list :type "extension_ui_response"
                                   :id id :value value)))

(defun opencode-pi-rpc-ui-reply-confirm (conn id confirmed)
  "Answer extension UI confirm request ID on CONN with CONFIRMED (t or nil)."
  (opencode-pi-rpc-send conn (list :type "extension_ui_response"
                                   :id id :confirmed (if confirmed t :false))))

(defun opencode-pi-rpc-ui-reply-cancel (conn id)
  "Cancel extension UI request ID on CONN."
  (opencode-pi-rpc-send conn (list :type "extension_ui_response"
                                   :id id :cancelled t)))

(provide 'opencode-pi-rpc)
;;; opencode-pi-rpc.el ends here
