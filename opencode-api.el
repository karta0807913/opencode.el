;;; opencode-api.el --- HTTP client layer for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Async and sync HTTP client for the OpenCode REST API.
;; Uses built-in `url.el' for all HTTP operations.
;; JSON serialization via native `json-parse-string' / `json-serialize' (Emacs 30).
;;
;; All JSON objects are parsed as plists (:object-type 'plist).
;; All JSON arrays are parsed as vectors (:array-type 'array).

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)
(require 'json)
(require 'opencode-log)
(require 'opencode-util)
(require 'opencode-api-cache)

;; the var from url-http.el
(defvar url-http-end-of-headers)

(declare-function opencode-server-url "opencode-server" (&optional path))
(declare-function opencode-server--url "opencode-server" (&optional path))
(declare-function opencode-server-connected-p "opencode-server" ())
(declare-function opencode-server--connected-p "opencode-server" ())
(declare-function opencode-server-auth-headers "opencode-server" ())

(defvar opencode-default-directory)
(defgroup opencode-api nil
  "OpenCode HTTP API client."
  :group 'opencode
  :prefix "opencode-api-")

;;; --- Customization ---

(defcustom opencode-api-directory nil
  "Override project directory for the X-OpenCode-Directory header.
When nil, uses `opencode-default-directory' (set by `opencode-start')
or falls back to `default-directory'."
  :type '(choice (const :tag "Use project directory" nil)
                 (directory :tag "Fixed directory"))
  :group 'opencode-api)

(defcustom opencode-api-timeout 30
  "HTTP request timeout in seconds."
  :type 'integer
  :group 'opencode-api)

;;; --- Error condition ---

(define-error 'opencode-api-error "OpenCode API error")

(defun opencode-api--signal-error (status name message)
  "Signal an `opencode-api-error' with STATUS, NAME, and MESSAGE."
  (signal 'opencode-api-error (list :status status :name name :message message)))

;;; --- JSON helpers ---

(defun opencode-api--json-parse (string)
  "Parse JSON STRING to a plist.
Returns nil if STRING is empty or nil."
  (when (and string (not (string-empty-p (string-trim string))))
    (opencode--json-parse string)))

(defsubst opencode-api--to-unibyte (string)
  "Return STRING as a unibyte UTF-8 byte sequence.
`url.el' rejects HTTP requests whose concatenated header+body is a
multibyte string (Bug#23750 in `url-http-create-request').  Any string
that will end up inside `url-request-data' or
`url-request-extra-headers' must therefore be unibyte before it
reaches url.el.  This is a single pass over STRING; unibyte input is
returned as-is by `encode-coding-string' so the call is cheap."
  (if (multibyte-string-p string)
      (encode-coding-string string 'utf-8 t)
    string))

(defun opencode-api--json-serialize (object)
  "Serialize OBJECT to an all-ASCII JSON string.
Non-ASCII characters are escaped as \\\\uXXXX (BMP) or surrogate pairs
\(supplementary planes) so the body contains only bytes 0x00–0x7F.

Why not raw UTF-8?  `url-http-create-request' concatenates header
strings with the body.  In some Emacs builds the header literals are
multibyte; when `concat' promotes a unibyte body whose bytes include
0x80–0xFF the bytes become eight-bit characters and the Bug#23750
guard `(unless (= (string-bytes req) (length req)) (error ...))' fires.
Keeping the body pure ASCII sidesteps the issue entirely."
  (let* ((raw (json-serialize object))
         ;; json-serialize returns unibyte UTF-8.  Decode so we can
         ;; iterate over Unicode code-points rather than raw bytes.
         (str (decode-coding-string raw 'utf-8))
         (escaped
          (replace-regexp-in-string
           "[^\x00-\x7f]"
           (lambda (match)
             (let ((cp (aref match 0)))
               (if (< cp #x10000)
                   (format "\\u%04x" cp)
                 ;; Supplementary plane → JSON surrogate pair.
                 (let* ((v  (- cp #x10000))
                        (hi (+ #xD800 (ash v -10)))
                        (lo (+ #xDC00 (logand v #x3FF))))
                   (format "\\u%04x\\u%04x" hi lo)))))
           str t t)))
    ;; Result is pure ASCII → encode-coding-string is a no-op but
    ;; guarantees the returned string object is unibyte.
    (encode-coding-string escaped 'utf-8)))

;;; --- URL construction ---

(defun opencode-api--build-url (path &optional query-params)
  "Build a full URL from PATH and optional QUERY-PARAMS.
PATH is appended to the server base URL.
QUERY-PARAMS is an alist of (KEY . VALUE) pairs."
  (let ((base (opencode-server--url path)))
    (if query-params
        (concat base
                (if (string-search "?" base) "&" "?")
                (url-build-query-string
                 (mapcar (lambda (pair)
                           (list (car pair) (cdr pair)))
                         query-params)))
      base)))

;;; --- Header construction ---

(defun opencode-api--build-headers (&optional extra-headers)
  "Build HTTP request headers.
Always includes Content-Type and Accept as JSON.
Includes X-OpenCode-Directory header.
EXTRA-HEADERS is an alist of additional headers.

Every header value is normalised to a unibyte UTF-8 byte sequence so
that `url-http-create-request' can concat them with the request body
without tripping Bug#23750.  Callers may therefore pass multibyte
strings (e.g. file paths containing Unicode) freely."
  (cl-flet ((cell (name value)
              (cons name (opencode-api--to-unibyte value))))
    (let ((headers (list (cell "Content-Type" "application/json")
                         (cell "Accept" "application/json"))))
      ;; Add directory header - ensure we use absolute path
      (when-let* ((dir (or opencode-api-directory
                           (and (boundp 'opencode-default-directory)
                                opencode-default-directory)
                           default-directory))
                  (absolute-dir (directory-file-name (expand-file-name dir))))
        (push (cell "X-OpenCode-Directory" absolute-dir) headers)
        (opencode--debug "opencode-api: using X-OpenCode-Directory=%s" absolute-dir))
      ;; Add basic auth header if configured
      (when-let ((auth (opencode-server-auth-headers)))
        (dolist (h auth)
          (push (cell (car h) (cdr h)) headers)))
      ;; Merge extra headers
      (dolist (h extra-headers)
        (push (cell (car h) (cdr h)) headers))
      headers)))

;;; --- Response parsing ---

(defun opencode-api--parse-response-buffer ()
  "Parse HTTP response from current `url.el' response buffer.
Returns a plist (:status STATUS :headers HEADERS :body BODY).
BODY is the parsed JSON, or nil if empty/unparseable.
When `url-http-end-of-headers' is nil (incomplete response or
buffer renamed under concurrency), returns status 0 with an error
plist instead of signaling."
  (if (not (bound-and-true-p url-http-end-of-headers))
      ;; Guard: url-http-parse-response will throw if headers weren't parsed.
      ;; This happens under high async concurrency when url.el renames the
      ;; response buffer (e.g.  *http host*-NNNNN) and the sentinel fires
      ;; before HTTP parsing completed.
      (progn
        (opencode--debug "opencode-api: parse-response-buffer called with nil url-http-end-of-headers in %s"
                         (buffer-name))
        (list :status 0 :headers nil :body nil
              :error (list 'error 'http
                           (format "Incomplete HTTP response in %s"
                                   (buffer-name)))))
    (goto-char (point-min))
    (let ((status (url-http-parse-response))
          (headers nil)
          (body nil))
      ;; Parse headers
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^\\([^:]+\\): \\(.+\\)$" url-http-end-of-headers t)
          (push (cons (downcase (match-string 1)) (match-string 2)) headers)))
      ;; Parse body
      (goto-char url-http-end-of-headers)
      (let ((body-str (string-trim
                       (buffer-substring-no-properties (point) (point-max)))))
        (condition-case nil
            (setq body (opencode-api--json-parse body-str))
          (error
           ;; If JSON parse fails, keep raw string if non-empty
           (unless (string-empty-p body-str)
             (setq body body-str)))))
      (list :status status :headers (nreverse headers) :body body))))

;;; --- Error handling ---

(defun opencode-api--handle-error (response)
  "Check RESPONSE for errors and signal if found.
RESPONSE is a plist from `opencode-api--parse-response-buffer'.
OpenCode errors have format: {:name \"ErrorName\" :data {:name ... :message ...}}"
  (let ((status (plist-get response :status))
        (body (plist-get response :body)))
    (when (and status (>= status 400))
      (opencode--debug "opencode-api: !!! ERROR status=%d raw-body=%S" status body)
      (let ((err-name "UnknownError")
            (err-message (format "HTTP %d" status)))
        ;; Try to extract OpenCode NamedError
        (when (and (listp body) (plist-get body :name))
          (setq err-name (plist-get body :name))
          (let ((data (plist-get body :data)))
            (when (and (listp data) (plist-get data :message))
              (setq err-message (plist-get data :message)))))
        (opencode--debug "opencode-api: !!! signaling error name=%s message=%s" err-name err-message)
        (opencode-api--signal-error status err-name err-message)))))

(defun opencode-api--debug-body (url body)
  "Format BODY for debug logging, omitting large responses.
Omits body for /session/<id>/message and /agent endpoints
whose responses are too large for useful debug output."
  (if (and url (or (string-match-p "/session/[^/]+/message" url)
                   (string-match-p "/agent\\(?:\\?\\|$\\)" url)
                   (string-match-p "/session/[^/]+/diff" url)))
      "[omitted]"
    (format "%S" body)))


;;; --- Core request functions ---

(defun opencode-api--request (method path &optional body callback headers query-params)
  "Make an HTTP request to the OpenCode API.
METHOD is \"GET\", \"POST\", \"PATCH\", or \"DELETE\".
PATH is the API path (e.g., \"/session\").
BODY is an optional plist to serialize as JSON.
CALLBACK is called with the parsed response plist (:status :headers :body).
  If nil, the request is synchronous and returns the response.
HEADERS is an optional alist of extra headers.
QUERY-PARAMS is an optional alist of (KEY . VALUE) pairs for URL query string."
   (let* ((is-mutating (member method '("POST" "PATCH" "DELETE")))
         (serialized-body (when is-mutating
                            (opencode-api--to-unibyte
                             (if body
                                 (opencode-api--json-serialize body)
                               "{}"))))
         (url-request-method method)
         (url-request-extra-headers (opencode-api--build-headers headers))
         (url-request-data serialized-body)
         (full-url (opencode-api--build-url path query-params)))
     (opencode--debug "opencode-api: >>> %s %s dir=%s\nBody: %s"
              method full-url
              (cdr (assoc "X-OpenCode-Directory" url-request-extra-headers))
              (or serialized-body "nil"))
    (opencode--debug "opencode-api: >>> HEADERS: %S" url-request-extra-headers)
    (if callback
        ;; Async — with timeout guard
        (let* ((url-buf nil)
               (timeout-timer
                (run-with-timer
                 opencode-api-timeout nil
                 (lambda ()
                   (opencode--debug "opencode-api: <<< ASYNC TIMEOUT %s" full-url)
                   (when (and url-buf (buffer-live-p url-buf))
                     (with-current-buffer url-buf
                       ;; Kill the connection to trigger the callback with error
                       (when-let ((proc (get-buffer-process (current-buffer))))
                         (delete-process proc))))))))
          (setq url-buf
                (url-retrieve
                 full-url
                  (lambda (status cb url tmr)
                    (cancel-timer tmr)
                    (if (plist-get status :error)
                        (let ((err (plist-get status :error)))
                          (opencode--debug "opencode-api: <<< ASYNC ERROR %s -> %S" url err)
                          (let ((buf (current-buffer)))
                            (funcall cb (list :status 0
                                              :headers nil
                                              :body nil
                                              :error err
                                              :url url))
                            (when (buffer-live-p buf)
                              (kill-buffer buf))))
                      (condition-case err
                          (let ((response (opencode-api--parse-response-buffer)))
                            (opencode--debug "opencode-api: <<< ASYNC %s -> status=%d body=%s"
                                             url (plist-get response :status)
                                             (opencode-api--debug-body url (plist-get response :body)))
                            (let ((buf (current-buffer)))
                              (funcall cb response)
                              (when (buffer-live-p buf)
                                (kill-buffer buf))))
                        (error
                         (opencode--debug "opencode-api: <<< ASYNC PARSE ERROR %s -> %S" url err)
                         (let ((buf (current-buffer)))
                           (funcall cb (list :status 0
                                             :headers nil
                                             :body nil
                                             :error (cdr err)
                                             :url url))
                           (when (buffer-live-p buf)
                             (kill-buffer buf)))))))
                 (list callback full-url timeout-timer)
                 t
                 nil)))
      ;; Sync
      (let ((buf (url-retrieve-synchronously
                  full-url t nil opencode-api-timeout)))
        (if buf
            (unwind-protect
                (with-current-buffer buf
                  (let ((response (opencode-api--parse-response-buffer)))
                    (opencode--debug "opencode-api: <<< SYNC %s -> status=%d body=%s"
                             full-url (plist-get response :status)
                             (opencode-api--debug-body full-url (plist-get response :body)))
                    (opencode-api--handle-error response)
                    response))
              (kill-buffer buf))
          (opencode-api--signal-error 0 "ConnectionError"
                                      (format "No response from %s" full-url)))))))

;;; --- Convenience wrappers (async, callback-based) ---

(defun opencode-api-get (path callback &optional query-params)
  "GET PATH with optional QUERY-PARAMS, call CALLBACK with response."
  (opencode-api--request "GET" path nil callback nil query-params))

(defun opencode-api-post (path body callback)
  "POST BODY to PATH, call CALLBACK with response."
  (opencode-api--request "POST" path body callback))

(defun opencode-api-patch (path body callback)
  "PATCH BODY to PATH, call CALLBACK with response."
  (opencode-api--request "PATCH" path body callback))

(defun opencode-api-delete (path callback)
  "DELETE PATH, call CALLBACK with response."
  (opencode-api--request "DELETE" path nil callback))

;;; --- Synchronous convenience wrappers ---

(defun opencode-api-get-sync (path &optional query-params)
  "Synchronous GET PATH with optional QUERY-PARAMS.
Returns the response body (parsed JSON)."
  (plist-get (opencode-api--request "GET" path nil nil nil query-params) :body))

(defun opencode-api-post-sync (path &optional body)
  "Synchronous POST BODY to PATH.
Returns the response body (parsed JSON)."
  (plist-get (opencode-api--request "POST" path body) :body))

;;; --- Agent/model state for prompt_async ---

(declare-function opencode-agent--find-by-name "opencode-agent" (name))
(declare-function opencode-agent--primary-agents "opencode-agent" ())

(defun opencode-api--fetch-agent-info ()
  "Pre-warm agent and config caches asynchronously.
Delegates to `opencode-api-cache-prewarm'."
  (opencode-api-cache-prewarm))

(defun opencode-api--valid-agent-p (agent-name)
  "Return non-nil if AGENT-NAME is a valid agent known to the server.
Delegates to `opencode-api-cache-valid-agent-p'."
  (opencode-api-cache-valid-agent-p agent-name))

(defun opencode-api--prompt-body (text &optional agent model-id provider-id
                                       variant mentions images message-id context)
  "Build the POST body for /session/:id/prompt_async.
TEXT is the user's message text.
AGENT, MODEL-ID, PROVIDER-ID, VARIANT are optional overrides.
When nil, uses global defaults from opencode-api--*.
MENTIONS is an optional list of mention plists, each with :type, :name,
:path (for files), :start, and :end (positions in TEXT).
When MENTIONS is non-nil, additional file/agent parts are included.
When VARIANT is non-nil, includes :variant in output plist.
IMAGES is an optional list of image plists, each with :data-url, :mime,
and :filename.  When non-nil, file parts with data: URLs are appended
after text and mention parts.
MESSAGE-ID is the optional parent message ID.
CONTEXT is an optional plist with :filename and :selection.
Returns a plist with :parts, :agent, :model, :variant, :messageID, :context."
  (let* ((text-part (list :type "text" :text text :id (opencode-util--generate-id "prt")))
         (mention-parts
          (when mentions
            (mapcar
             (lambda (m)
               (let ((mtype (plist-get m :type))
                     (mname (plist-get m :name))
                     (mpath (plist-get m :path))
                     (mstart (plist-get m :start))
                     (mend (plist-get m :end)))
                 (pcase mtype
                   ('file
                    (list :type "file"
                          :id (opencode-util--generate-id "prt")
                          :mime "text/plain"
                          :url (concat "file://" mpath)
                          :filename mname
                          :source (list :type "file"
                                        :text (list :value (substring text mstart mend)
                                                    :start mstart :end mend)
                                        :path mpath)))
                   ('agent
                    (list :type "agent"
                          :id (opencode-util--generate-id "prt")
                          :name mname
                          :source (list :value (substring text mstart mend)
                                        :start mstart :end mend))))))
             mentions)))
         (image-parts (when images
                        (mapcar
                         (lambda (img)
                           (list :type "file"
                                 :id (opencode-util--generate-id "prt")
                                 :mime (plist-get img :mime)
                                 :url (plist-get img :data-url)
                                 :filename (plist-get img :filename)))
                         images)))
         (all-parts (apply #'vector (cons text-part (append (or mention-parts nil) (or image-parts nil)))))
         (body (list :parts all-parts)))
    ;; Agent: caller must provide (via opencode-chat--effective-agent)
    (when agent
      (setq body (plist-put body :agent agent)))
    ;; Model: caller must provide (via opencode-chat--effective-model)
    (when (and model-id provider-id)
      (setq body (plist-put body :model
                             (list :modelID model-id
                                   :providerID provider-id))))
    ;; Include variant only if non-nil
    (when variant
      (setq body (plist-put body :variant variant)))
    ;; Include messageID (parent) only if non-nil
    (when message-id
      (setq body (plist-put body :messageID message-id)))
    ;; Include context only if non-nil
    (when context
      (setq body (plist-put body :context context)))
    body))

(provide 'opencode-api)
;;; opencode-api.el ends here
