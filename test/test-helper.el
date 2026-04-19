;;; test-helper.el --- Test infrastructure for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Shared test fixtures, mock HTTP server, mock SSE stream, and assertion
;; helpers for the opencode.el ERT test suite.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)

;;; --- Treemacs stubs for batch mode ---

;; `opencode-sidebar.el' requires treemacs, treemacs-treelib, and
;; treemacs-mouse-interface.  Those packages are available in the user's
;; interactive Emacs but not in `emacs --batch -Q'.  Provide minimal stubs
;; so that `(require 'opencode)' succeeds without pulling in the real
;; treemacs tree.  Only the symbols referenced at *load time* by
;; opencode-sidebar.el need to exist; runtime-only symbols can stay void
;; because no test exercises the actual sidebar rendering.

(unless (featurep 'treemacs)
  ;; Faces referenced at load time (used in label-building functions that
  ;; are defined at top level inside opencode-sidebar.el).
  (dolist (face '(treemacs-directory-face
                  treemacs-file-face
                  treemacs-git-added-face
                  treemacs-git-conflict-face
                  treemacs-git-ignored-face
                  treemacs-git-modified-face
                  treemacs-git-renamed-face))
    (unless (facep face)
      (make-face face)))

  ;; Variables read at load time.
  (defvar treemacs--width-is-locked nil)
  (defvar treemacs-space-between-root-nodes nil)
  (defvar treemacs--buffer-name-prefix " *Treemacs-")

  ;; Runtime functions — stub just enough to avoid void-function during load.
  (dolist (fn '(treemacs-node-at-point
                treemacs-current-button
                treemacs-button-get
                treemacs-toggle-node
                treemacs-goto-node
                treemacs-update-node
                treemacs-update-async-node
                treemacs-initialize
                treemacs-RET-action))
    (unless (fboundp fn)
      (defalias fn #'ignore)))

  ;; Macros called at top level to define node types.
  (unless (fboundp 'treemacs-define-expandable-node-type)
    (defmacro treemacs-define-expandable-node-type (_name &rest _args)
      "Stub: no-op in test environment."
      nil))
  (unless (fboundp 'treemacs-define-variadic-entry-node-type)
    (defmacro treemacs-define-variadic-entry-node-type (_name &rest _args)
      "Stub: no-op in test environment."
      nil))

  (provide 'treemacs)
  (provide 'treemacs-treelib)
  (provide 'treemacs-mouse-interface))

;;; --- Mock HTTP infrastructure ---

(defvar opencode-test--mock-responses (make-hash-table :test 'equal)
  "Map of (METHOD . URL-PATH) to (STATUS-CODE HEADERS BODY) for mock HTTP.
BODY is either a string (raw) or a Lisp object (will be JSON-serialized).")

(defvar opencode-test--mock-requests nil
  "List of (METHOD URL-PATH HEADERS BODY) for requests made during test.
Most recent request is first.")

(defun opencode-test-mock-response (method url-path status body &optional headers)
  "Register a mock HTTP response.
METHOD is \"GET\", \"POST\", etc.  URL-PATH is the path (e.g., \"/session/\").
STATUS is the HTTP status code.  BODY is a plist or vector (JSON-serialized)
or a string (raw).  HEADERS is an optional alist of response headers."
  (puthash (cons method url-path)
           (list status (or headers '()) body)
           opencode-test--mock-responses))

(defun opencode-test--find-mock (method url-path)
  "Find mock response for METHOD and URL-PATH.
Tries exact match first, then prefix matches for parameterized routes."
  (or (gethash (cons method url-path) opencode-test--mock-responses)
      ;; Try stripping query params
      (let ((path-only (car (split-string url-path "?"))))
        (gethash (cons method path-only) opencode-test--mock-responses))
      ;; Try prefix match for parameterized routes like /session/:id
      (let ((found nil))
        (maphash (lambda (key val)
                   (when (and (not found)
                              (string= (car key) method)
                              (string-prefix-p (cdr key) url-path))
                     (setq found val)))
                 opencode-test--mock-responses)
        found)))

(defun opencode-test--mock-api-request (method path &optional body callback &rest _args)
  "Mock implementation of `opencode-api--request'.
Records the request and returns the registered mock response.
Callback receives a plist (:status :headers :body) matching production."
  (push (list method path nil body) opencode-test--mock-requests)
  (let ((mock (opencode-test--find-mock method path)))
    (if mock
        (let* ((status (nth 0 mock))
               (headers (nth 1 mock))
               (response-body (nth 2 mock))
               (parsed-body (if (stringp response-body)
                                (condition-case nil
                                    (opencode-api--json-parse response-body)
                                  (error response-body))
                              response-body))
               (response (list :status status :headers headers :body parsed-body)))
          (if callback
              (funcall callback response)
            response))
      (error "No mock registered for %s %s" method path))))

(defmacro opencode-test-with-mock-api (&rest body)
  "Execute BODY with HTTP calls intercepted by mock responses.
Clears mock state before and after."
  (declare (indent 0) (debug t))
  `(let ((opencode-test--mock-responses (make-hash-table :test 'equal))
         (opencode-test--mock-requests nil))
     (cl-letf (((symbol-function 'opencode-api--request)
                #'opencode-test--mock-api-request))
       ,@body)))

(defun opencode-test-last-request ()
  "Return the most recent mock request as (METHOD PATH HEADERS BODY)."
  (car opencode-test--mock-requests))

(defun opencode-test-request-count ()
  "Return the number of mock requests made."
  (length opencode-test--mock-requests))

;;; --- Mock SSE infrastructure ---

(defvar opencode-test--sse-handlers nil
  "Alist of (EVENT-TYPE . HANDLER-FUNCTION) for mock SSE dispatch.")

(defun opencode-test-deliver-sse-event (event)
  "Deliver a mock SSE EVENT to registered handlers.
EVENT is a plist with at least :type and :properties."
  (let* ((event-type (plist-get event :type))
         (handler (cdr (assoc event-type opencode-test--sse-handlers))))
    (when handler
      (funcall handler event))
    ;; Also call the catch-all handler if any
    (let ((catch-all (cdr (assoc t opencode-test--sse-handlers))))
      (when catch-all
        (funcall catch-all event)))))

(defmacro opencode-test-with-sse-events (events &rest body)
  "Execute BODY, then deliver each SSE event in EVENTS list sequentially."
  (declare (indent 1) (debug t))
  `(progn
     ,@body
     (dolist (event ,events)
       (opencode-test-deliver-sse-event event))))

;;; --- Test fixtures ---

(defvar opencode-test--fixtures-dir
  (expand-file-name "fixtures" (file-name-directory (or load-file-name
                                                         buffer-file-name
                                                         default-directory)))
  "Directory containing test fixture files.")

(defun opencode-test-fixture (name)
  "Load test fixture NAME from test/fixtures/ as parsed JSON.
NAME should be without extension (e.g., \"session-list\").
Returns a plist (for objects) or vector (for arrays)."
  (let ((file (expand-file-name (concat name ".json") opencode-test--fixtures-dir)))
    (if (file-exists-p file)
        (json-parse-string
         (with-temp-buffer
           (insert-file-contents file)
           (buffer-string))
         :object-type 'plist
         :array-type 'array
         :null-object nil
         :false-object :false)
      (error "Fixture file not found: %s" file))))

(defun opencode-test-fixture-raw (name)
  "Load test fixture NAME as raw string.
NAME should include extension (e.g., \"sse-events.txt\")."
  (let ((file (expand-file-name name opencode-test--fixtures-dir)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string))
      (error "Fixture file not found: %s" file))))

;;; --- Buffer test helpers ---

(defmacro opencode-test-with-temp-buffer (name &rest body)
  "Execute BODY in a temporary buffer named NAME.
Buffer is killed after BODY completes."
  (declare (indent 1) (debug t))
  `(let ((buf (get-buffer-create ,name)))
     (unwind-protect
         (with-current-buffer buf
           ,@body)
       (when (buffer-live-p buf)
         (kill-buffer buf)))))

(defun opencode-test-buffer-contains-p (text &optional buffer)
  "Return non-nil if BUFFER (or current buffer) contains TEXT."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (search-forward text nil t))))

(defun opencode-test-buffer-matches-p (regexp &optional buffer)
  "Return non-nil if BUFFER (or current buffer) matches REGEXP."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward regexp nil t))))

;;; --- Face assertion helpers ---

(defun opencode-test-face-at (text &optional buffer)
  "Return the face at the first occurrence of TEXT in BUFFER.
Returns nil if TEXT not found."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (when (search-forward text nil t)
        (get-text-property (match-beginning 0) 'face)))))

(defun opencode-test-has-face-p (text face &optional buffer)
  "Return non-nil if TEXT in BUFFER has FACE applied.
FACE can be a symbol or a list of faces."
  (let ((actual (opencode-test-face-at text buffer)))
    (cond
     ((null actual) nil)
     ((symbolp actual) (eq actual face))
     ((listp actual) (if (symbolp face)
                         (memq face actual)
                       (equal actual face)))
     (t nil))))

;;; --- JSON assertion helpers ---

(defun opencode-test-plist-equal-p (a b)
  "Return non-nil if plists A and B have the same key-value pairs.
Compares recursively for nested plists."
  (cond
   ((and (null a) (null b)) t)
   ((or (null a) (null b)) nil)
   ((and (consp a) (consp b)
         (keywordp (car a)) (keywordp (car b)))
    (let ((keys-a (cl-loop for (k _v) on a by #'cddr collect k))
          (keys-b (cl-loop for (k _v) on b by #'cddr collect k)))
      (and (null (cl-set-difference keys-a keys-b))
           (null (cl-set-difference keys-b keys-a))
           (cl-every (lambda (k)
                       (opencode-test-plist-equal-p
                        (plist-get a k)
                        (plist-get b k)))
                     keys-a))))
   ((and (stringp a) (stringp b)) (string= a b))
   ((and (numberp a) (numberp b)) (= a b))
   ((and (vectorp a) (vectorp b))
    (and (= (length a) (length b))
         (cl-every #'opencode-test-plist-equal-p
                   (append a nil) (append b nil))))
   (t (equal a b))))

;;; --- Process mock helpers ---

(defvar opencode-test--mock-process-output nil
  "Pending output to deliver via mock process filter.")

(defun opencode-test-mock-process-output (process string)
  "Simulate PROCESS receiving STRING as output.
Calls the process filter if one is set."
  (let ((filter (process-filter process)))
    (when (and filter (not (eq filter 'internal-default-process-filter)))
      (funcall filter process string))))

;;; --- Server state helpers ---

(defvar opencode-test--server-port 19876
  "Fixed port for test server mocks.")

(defmacro opencode-test-with-server-state (&rest body)
  "Set up mock server state for testing.
Binds `opencode-server--port' and related variables."
  (declare (indent 0) (debug t))
  `(let ((opencode-server--port opencode-test--server-port)
         (opencode-server--process nil)
         (opencode-server--status 'connected))
     ,@body))

;;; --- Cleanup ---

(defun opencode-test-cleanup ()
  "Kill all opencode-related buffers."
  (dolist (buf (buffer-list))
    (when (string-prefix-p "*opencode:" (buffer-name buf))
      (kill-buffer buf))))

(add-hook 'ert-runner-reporter-run-ended-functions
          (lambda (&rest _) (opencode-test-cleanup)))

(provide 'test-helper)
;;; test-helper.el ends here
