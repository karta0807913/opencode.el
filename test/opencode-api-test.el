;;; opencode-api-test.el --- Tests for opencode-api.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the HTTP client layer.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-api)

;;; --- JSON helpers ---

(ert-deftest opencode-api-json-parse-plist ()
  "Verify JSON objects parse as plists.
Without this, all API response handling breaks — we rely on plist-get everywhere."
  (let ((result (opencode-api--json-parse "{\"name\": \"test\", \"count\": 42}")))
    (should (plistp result))
    (should (string= (plist-get result :name) "test"))
    (should (= (plist-get result :count) 42))))

(ert-deftest opencode-api-json-parse-array ()
  "Verify JSON arrays parse as vectors.
Without this, session lists and message parts arrays fail — iteration breaks."
  (let ((result (opencode-api--json-parse "[1, 2, 3]")))
    (should (vectorp result))
    (should (length= result 3))
    (should (= (aref result 0) 1))))

(ert-deftest opencode-api-json-parse-nested ()
  "Verify nested JSON objects parse correctly.
Without this, deep structures like session.info.time become inaccessible."
  (let ((result (opencode-api--json-parse
                 "{\"session\": {\"id\": \"ses_abc\", \"title\": \"Test\"}}")))
    (should (plistp result))
    (let ((session (plist-get result :session)))
      (should (string= (plist-get session :id) "ses_abc"))
      (should (string= (plist-get session :title) "Test")))))

(ert-deftest opencode-api-json-parse-null ()
  "Verify JSON null values parse as nil.
Without this, null fields cause surprises in plist-get — expected nil becomes garbage."
  (let ((result (opencode-api--json-parse "{\"value\": null}")))
    (should (null (plist-get result :value)))))

(ert-deftest opencode-api-json-parse-false ()
  "Verify JSON false parses as :false keyword, not nil.
CRITICAL: (not :false) is nil (truthy!). Must use (eq val :false). Wrong handling causes boolean logic bugs throughout."
  (let ((result (opencode-api--json-parse "{\"active\": false}")))
    (should (eq (plist-get result :active) :false))))

(ert-deftest opencode-api-json-parse-empty-string ()
  "Verify empty/whitespace/nil input returns nil without crashing.
Without this, empty server responses or network errors crash the parser."
  (should (null (opencode-api--json-parse "")))
  (should (null (opencode-api--json-parse "  ")))
  (should (null (opencode-api--json-parse nil))))

(ert-deftest opencode-api-json-serialize-plist ()
  "Verify plists serialize to JSON objects.
Without this, POST bodies to server are malformed — prompts fail silently."
  (let ((json (opencode-api--json-serialize '(:name "test" :count 42))))
    (should (stringp json))
    (let ((parsed (opencode-api--json-parse json)))
      (should (string= (plist-get parsed :name) "test"))
      (should (= (plist-get parsed :count) 42)))))

(ert-deftest opencode-api-json-roundtrip ()
  "Verify serialize→parse roundtrip preserves data.
Without this, data integrity is compromised — fields may be lost or corrupted in the JSON pipeline."
  (let* ((original '(:id "ses_abc" :title "Test Session" :version 3))
         (json (opencode-api--json-serialize original))
         (parsed (opencode-api--json-parse json)))
    (should (string= (plist-get parsed :id) "ses_abc"))
    (should (string= (plist-get parsed :title) "Test Session"))
    (should (= (plist-get parsed :version) 3))))

(ert-deftest opencode-api-json-serialize-returns-all-ascii ()
  "Verify serialized body is an all-ASCII unibyte string.
Non-ASCII characters must be \\\\uXXXX-escaped (BMP) or expressed as
surrogate pairs (supplementary planes) so that the body contains only
bytes 0x00–0x7F.  This prevents Bug#23750 in `url-http-create-request'
which errors when `string-bytes' ≠ `length' after concatenating
multibyte header strings with a body containing bytes ≥ 0x80."
  (let* ((original '(:text "a→b😀c" :arrow "parent→child"))
         (json (opencode-api--json-serialize original)))
    ;; Body is unibyte with no bytes ≥ 0x80.
    (should (stringp json))
    (should-not (multibyte-string-p json))
    (should (= (string-bytes json) (length json)))
    ;; No raw high bytes — everything is ASCII.
    (should-not (string-match-p "[\x80-\xff]" json))
    ;; Non-ASCII characters are \\uXXXX-escaped.
    (should (string-match-p "\\\\u2192" json))   ; → U+2192
    (should (string-match-p "\\\\ud83d" json))   ; 😀 high surrogate
    ;; Roundtrip must preserve the original characters.
    (let ((parsed (opencode-api--json-parse json)))
      (should (string= (plist-get parsed :text) "a→b😀c"))
      (should (string= (plist-get parsed :arrow) "parent→child")))))

(ert-deftest opencode-api-to-unibyte-idempotent ()
  "Verify `opencode-api--to-unibyte' leaves unibyte strings unchanged and
encodes multibyte strings to unibyte UTF-8.  This is the single
invariant the HTTP layer relies on to avoid Bug#23750."
  (let ((uni (opencode-api--to-unibyte "plain-ascii")))
    (should-not (multibyte-string-p uni))
    (should (string= uni "plain-ascii")))
  (let ((uni (opencode-api--to-unibyte "/Users/项目/测试")))
    (should-not (multibyte-string-p uni))
    (should (= (string-bytes uni) (length uni)))
    ;; Roundtrip through decode reproduces the original multibyte string.
    (should (string= (decode-coding-string uni 'utf-8)
                     "/Users/项目/测试"))))

(ert-deftest opencode-api-request-survives-url-http-create-request ()
  "End-to-end check against Bug#23750: feed a realistic body containing
non-ASCII text and a multibyte directory header through
`url-http-create-request'.  The serializer \\\\uXXXX-escapes non-ASCII
characters so the body is pure ASCII; `opencode-api--to-unibyte'
normalises header values.  Together they ensure `string-bytes' equals
`length' in the final request string."
  (require 'url-http)
  ;; `url-http-create-request' reads these as dynamic variables.  They must
  ;; be declared `special' for the `let' bindings below to take effect under
  ;; lexical-binding.
  (defvar url-http-target-url)
  (defvar url-http-method)
  (defvar url-http-version)
  (defvar url-http-proxy)
  (defvar url-http-referer)
  (defvar url-http-attempt-keepalives)
  (defvar url-http-extra-headers)
  (defvar url-http-data)
  (let* ((body (opencode-api--json-serialize '(:text "parent→child 你好😀")))
         (dir-header (cons "X-OpenCode-Directory"
                           (opencode-api--to-unibyte "/Users/项目/测试")))
         (url-http-target-url (url-generic-parse-url "http://127.0.0.1:4096/session"))
         (url-http-method "POST")
         (url-http-version "1.1")
         (url-http-proxy nil)
         (url-http-referer nil)
         (url-http-attempt-keepalives t)
         (url-http-extra-headers (list (cons "Content-Type" "application/json")
                                       dir-header))
         (url-http-data body)
         (req (url-http-create-request)))
    (should-not (multibyte-string-p req))
    (should (= (length req) (string-bytes req)))
    ;; Body portion must be all-ASCII (\uXXXX escapes, no raw high bytes).
    (let* ((hdr-end (string-search "\r\n\r\n" req))
           (req-body (substring req (+ hdr-end 4))))
      (should-not (string-match-p "[\x80-\xff]" req-body))
      ;; Roundtrip: the JSON body must still parse to the original text.
      (let ((parsed (json-parse-string req-body :object-type 'plist)))
        (should (string= (plist-get parsed :text) "parent→child 你好😀"))))))

;;; --- Header construction ---

(ert-deftest opencode-api-headers-include-content-type ()
  "Verify Content-Type: application/json header is always present.
Without this, server rejects requests — API contract requires JSON content type."
  (let ((headers (opencode-api--build-headers)))
    (should (assoc "Content-Type" headers))
    (should (string= (cdr (assoc "Content-Type" headers)) "application/json"))))

(ert-deftest opencode-api-headers-include-accept ()
  "Verify Accept: application/json header is always present.
Without this, server returns HTML (SPA fallback) instead of JSON — all responses parse incorrectly."
  (let ((headers (opencode-api--build-headers)))
    (should (assoc "Accept" headers))
    (should (string= (cdr (assoc "Accept" headers)) "application/json"))))

(ert-deftest opencode-api-headers-include-directory ()
  "Verify X-OpenCode-Directory header is included.
Without this, server cannot locate session storage — sessions appear missing or cross-project errors occur."
  (let ((opencode-api-directory "/tmp/test-project"))
    (let ((headers (opencode-api--build-headers)))
      (should (assoc "X-OpenCode-Directory" headers))
      (should (string= (cdr (assoc "X-OpenCode-Directory" headers))
                        (expand-file-name "/tmp/test-project"))))))

(ert-deftest opencode-api-headers-merge-extra ()
  "Verify extra headers merge into the result.
Without this, callers cannot add custom headers for auth tokens or debugging."
  (let ((headers (opencode-api--build-headers
                  '(("X-Custom" . "value")))))
    (should (assoc "X-Custom" headers))
    (should (string= (cdr (assoc "X-Custom" headers)) "value"))))

(ert-deftest opencode-api-headers-values-are-unibyte ()
  "Verify every header value produced by `opencode-api--build-headers'
is a unibyte byte sequence.  Without this, a project directory or a
custom header containing Unicode characters propagates a multibyte
string into `url-http-create-request' and triggers Bug#23750."
  (let ((opencode-api-directory "/Users/项目/测试"))
    (let ((headers (opencode-api--build-headers
                    '(("X-Unicode-Custom" . "hëllo/世界")))))
      (dolist (h headers)
        (should-not (multibyte-string-p (cdr h))))
      ;; The directory value roundtrips to the original multibyte path.
      (should (string= (decode-coding-string
                        (cdr (assoc "X-OpenCode-Directory" headers)) 'utf-8)
                       (expand-file-name "/Users/项目/测试")))
      (should (string= (decode-coding-string
                        (cdr (assoc "X-Unicode-Custom" headers)) 'utf-8)
                       "hëllo/世界")))))

;;; --- URL construction ---

(ert-deftest opencode-api-build-url-basic ()
  "Verify URL construction appends path to server URL.
Without this, API endpoints are malformed — all requests fail to reach correct routes."
  ;; Mock opencode-server--url
  (cl-letf (((symbol-function 'opencode-server--url)
             (lambda (&optional path)
               (concat "http://127.0.0.1:4096" (or path "")))))
    (should (string= (opencode-api--build-url "/session")
                       "http://127.0.0.1:4096/session"))))

(ert-deftest opencode-api-build-url-with-query-params ()
  "Verify query parameters are appended to URL.
Without this, parameterized requests like ?limit=10 fail — session listing and pagination break."
  (cl-letf (((symbol-function 'opencode-server--url)
             (lambda (&optional path)
               (concat "http://127.0.0.1:4096" (or path "")))))
    (let ((url (opencode-api--build-url "/session"
                                        '(("directory" . "/tmp")
                                          ("limit" . "10")))))
      (should (string-search "?" url))
      (should (string-search "directory" url))
      (should (string-search "limit" url)))))

;;; --- Error handling ---

(ert-deftest opencode-api-error-condition-defined ()
  "Verify opencode-api-error condition is defined.
Without this, condition-case cannot catch API errors — error handling code silently fails."
  (should (get 'opencode-api-error 'error-conditions)))

(ert-deftest opencode-api-handle-error-signals-on-4xx ()
  "Verify 4xx status triggers error signal.
Without this, client errors (404 Not Found, 400 Bad Request) are swallowed — users see no feedback."
  (should-error
   (opencode-api--handle-error
    (list :status 404
          :headers nil
          :body '(:name "NotFoundError" :data (:message "Session not found"))))
   :type 'opencode-api-error))

(ert-deftest opencode-api-handle-error-signals-on-5xx ()
  "Verify 5xx status triggers error signal.
Without this, server errors are silently ignored — users don't know the server is failing."
  (should-error
   (opencode-api--handle-error
    (list :status 500
          :headers nil
          :body '(:name "InternalError" :data (:message "Server error"))))
   :type 'opencode-api-error))

(ert-deftest opencode-api-handle-error-ok-on-2xx ()
  "Verify 2xx status does not signal error.
Without this, successful responses incorrectly trigger error handling — normal operations fail."
  (should-not
   (opencode-api--handle-error
    (list :status 200 :headers nil :body '(:ok t)))))

(ert-deftest opencode-api-handle-error-extracts-named-error ()
  "Verify NamedError fields are extracted into condition data.
Without this, UI shows generic 'HTTP 404' instead of rich 'Session not found' messages."
  (condition-case err
      (opencode-api--handle-error
       (list :status 404
             :headers nil
             :body '(:name "NotFoundError"
                     :data (:name "NotFoundError"
                            :message "Session not found"))))
    (opencode-api-error
     (let ((data (cdr err)))
       (should (string= (plist-get data :name) "NotFoundError"))
       (should (string= (plist-get data :message) "Session not found"))
       (should (= (plist-get data :status) 404))))))

;;; --- Mock request flow ---

(ert-deftest opencode-api-request-method-set ()
  "Verify HTTP method is set correctly on request.
Without this, POST vs GET distinction fails — mutations don't work, reads fail."
  (let ((captured-method nil))
    (cl-letf (((symbol-function 'opencode-server--url)
               (lambda (&optional path)
                 (concat "http://127.0.0.1:4096" (or path ""))))
              ((symbol-function 'opencode-server--connected-p)
               (lambda () t))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (_url &rest _args)
                 (setq captured-method url-request-method)
                 ;; Return a fake response buffer
                 (let ((buf (generate-new-buffer " *test-response*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 200 OK\r\n")
                     (insert "Content-Type: application/json\r\n")
                     (insert "\r\n")
                     (insert "{\"ok\": true}")
                     (setq-local url-http-end-of-headers
                                 (save-excursion
                                   (goto-char (point-min))
                                   (re-search-forward "\r?\n\r?\n" nil t)
                                   (point))))
                   buf))))
      (opencode-api--request "POST" "/test")
      (should (string= captured-method "POST")))))

;;; --- Prompt body construction ---

(ert-deftest opencode-api-false-not-hidden ()
  "Verify :false is not treated as truthy.
Guards against (if (plist-get x :hidden) ...) bug — :false is truthy in boolean context."
  (let ((it (list :mode "primary" :hidden :false :native :false
                  :name "Agent"
                  :model (list :providerID "P" :modelID "M"))))
    (should (not (eq (plist-get it :hidden) t)))
    (should (not (eq (plist-get it :native) t)))))

(ert-deftest opencode-api-json-parse-boolean-roundtrip ()
  "Verify :false survives serialize→parse roundtrip.
Without this, boolean fidelity breaks — false becomes nil after JSON pipeline, causing logic errors."
  (let* ((json-str "{\"active\": false, \"enabled\": true}")
         (parsed (opencode-api--json-parse json-str)))
    ;; :false is a keyword symbol, not nil
    (should (eq (plist-get parsed :active) :false))
    (should-not (null :false))
    ;; true parses as t
    (should (eq (plist-get parsed :enabled) t))
    ;; Roundtrip: serialize back and re-parse
    (let* ((re-json (opencode-api--json-serialize parsed))
           (re-parsed (opencode-api--json-parse re-json)))
      (should (eq (plist-get re-parsed :active) :false))
      (should (eq (plist-get re-parsed :enabled) t)))))

(ert-deftest opencode-api-handle-error-plain-body-no-named-error ()
  "Verify non-NamedError response falls back to generic HTTP error.
Without this, unknown error formats crash the handler instead of showing HTTP 400."
  (condition-case err
      (opencode-api--handle-error
       (list :status 400
             :headers nil
             :body '(:error "Bad request body")))
    (opencode-api-error
     (let ((data (cdr err)))
       ;; No :name field in body, so falls back to UnknownError
       (should (string= (plist-get data :name) "UnknownError"))
       (should (string= (plist-get data :message) "HTTP 400"))
       (should (= (plist-get data :status) 400))))))

(ert-deftest opencode-api-prompt-body-basic ()
  "Verify full prompt body matches server format when model/provider passed explicitly.
CRITICAL: Without model field, server returns 204 silently."
  (let ((body (opencode-api--prompt-body "hello world" "build" "claude-opus-4-6" "anthropic")))
    (should (string= (plist-get body :agent) "build"))
    (let ((model (plist-get body :model)))
      (should (string= (plist-get model :modelID) "claude-opus-4-6"))
      (should (string= (plist-get model :providerID) "anthropic")))
    (let* ((parts (plist-get body :parts))
           (part (aref parts 0)))
      (should (vectorp parts))
      (should (length= parts 1))
      (should (string= (plist-get part :type) "text"))
      (should (string= (plist-get part :text) "hello world")))
    (should-not (plist-member body :variant))))

(ert-deftest opencode-api-prompt-body-without-model ()
  "Verify prompt body omits :model when no model/provider provided.
Callers must pass explicit model — there is no global fallback."
  (let ((body (opencode-api--prompt-body "test")))
    (should (plist-get body :parts))
    (should-not (plist-get body :agent))
    (should-not (plist-get body :model))))

(ert-deftest opencode-api-prompt-body-variant ()
  "Verify prompt body includes :variant when provided."
  (let ((body (opencode-api--prompt-body "test" "build" "m" "p" "slash-cmd")))
    (should (string= (plist-get body :variant) "slash-cmd"))))

(ert-deftest opencode-api-prompt-body-with-file-mention ()
  "Verify @file mention produces text + file parts."
  (let ((mentions (list (list :type 'file
                              :name "foo.el"
                              :path "/tmp/foo.el"
                              :start 0 :end 8))))
    (let* ((body (opencode-api--prompt-body "@foo.el hello" "build" "m" "p" nil mentions))
           (parts (plist-get body :parts)))
      (should (length= parts 2))
      (should (string= (plist-get (aref parts 0) :type) "text"))
      (let ((fpart (aref parts 1)))
        (should (string= (plist-get fpart :type) "file"))
        (should (string= (plist-get fpart :filename) "foo.el"))))))

(ert-deftest opencode-api-prompt-body-with-images ()
  "Verify prompt body includes image parts when provided."
  (let* ((images (list (list :data-url "data:image/png;base64,abc"
                             :mime "image/png"
                             :filename "test.png")))
         (body (opencode-api--prompt-body "hello" "build" "m" "p" nil nil images))
         (parts (plist-get body :parts)))
    (should (= (length parts) 2))
    (should (string= (plist-get (aref parts 0) :type) "text"))
    (should (string= (plist-get (aref parts 1) :type) "file"))
    (should (string= (plist-get (aref parts 1) :mime) "image/png"))))

(ert-deftest opencode-api-prompt-body-messageid-included ()
  "Verify :messageID is included in prompt body when message-id is provided."
  (let* ((msg-id "msg_cb28a34c5000breYcI8NbRJr6p")
         (body (opencode-api--prompt-body "hello" nil nil nil nil nil nil msg-id)))
    (should (plist-member body :messageID))
    (should (string= (plist-get body :messageID) msg-id))))

(ert-deftest opencode-api-prompt-body-messageid-absent-when-nil ()
  "Verify :messageID is NOT added to prompt body when message-id is nil."
  (let ((body (opencode-api--prompt-body "hello")))
    (should-not (plist-member body :messageID))))

(ert-deftest opencode-api-prompt-body-part-ids-unique ()
  "Verify every part in the prompt body has a unique :id."
  (let ((mentions (list (list :type 'file
                              :name "foo.el"
                              :path "/tmp/foo.el"
                              :start 0 :end 8))))
    (let* ((body (opencode-api--prompt-body "@foo.el hello" nil nil nil nil mentions))
           (parts (plist-get body :parts))
           (ids (mapcar (lambda (i) (plist-get (aref parts i) :id))
                        (number-sequence 0 (1- (length parts))))))
      (dolist (id ids)
        (should (stringp id))
        (should (> (length id) 0)))
      (should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

(ert-deftest opencode-api-prompt-body-part-id-format ()
  "Verify each part :id starts with 'prt_' prefix matching OpenCode server format."
  (let* ((body (opencode-api--prompt-body "test"))
         (parts (plist-get body :parts))
         (part-id (plist-get (aref parts 0) :id)))
    (should (string-prefix-p "prt_" part-id))))

(ert-deftest opencode-api-prompt-body-messageid-format ()
  "Verify :messageID in the prompt body starts with 'msg_' prefix."
  (let* ((msg-id (opencode-util--generate-id "msg"))
         (body (opencode-api--prompt-body "hello" nil nil nil nil nil nil msg-id)))
    (should (string-prefix-p "msg_" (plist-get body :messageID)))))

;;; --- Response buffer edge cases ---

(ert-deftest opencode-api-parse-response-nil-end-of-headers ()
  "Verify parse-response-buffer returns error plist when url-http-end-of-headers is nil.
Without this guard, `url-http-parse-response' throws 'Trying to parse HTTP response
code in odd buffer' under high async concurrency when url.el renames response buffers."
  (with-temp-buffer
    ;; Simulate a buffer where HTTP parsing never completed
    (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}")
    ;; url-http-end-of-headers is buffer-local and nil by default
    (let ((response (opencode-api--parse-response-buffer)))
      (should (= 0 (plist-get response :status)))
      (should (plist-get response :error)))))

(provide 'opencode-api-test)
;;; opencode-api-test.el ends here
