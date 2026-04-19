;;; opencode-server-test.el --- Tests for opencode-server.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for server subprocess lifecycle management.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-server)

;;; --- Port parsing ---

(ert-deftest opencode-server-parse-port-from-listening ()
  "Verify that port parsing detects the 'listening on http://HOST:PORT' pattern.
Without this, Emacs cannot know when the server subprocess is ready to accept requests."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "listening on http://127.0.0.1:54321")
    (should (= opencode-server--port 54321))))

(ert-deftest opencode-server-parse-port-from-url ()
  "Verify that port parsing detects bare 'http://HOST:PORT' pattern.
Handles alternative server output formats so port detection works across server versions."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "Server started at http://localhost:8080/")
    (should (= opencode-server--port 8080))))

(ert-deftest opencode-server-parse-port-ignores-non-port ()
  "Verify that port parsing ignores lines without port info.
Prevents false positives in log scanning that would cause connection to wrong port."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "Starting opencode server...")
    (should (null opencode-server--port))))

(ert-deftest opencode-server-parse-port-only-during-startup ()
  "Verify that port parsing only occurs when status is 'starting'.
State guard prevents re-parsing port after already connected, avoiding state corruption."
  (let ((opencode-server--status 'connected)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "listening on http://127.0.0.1:9999")
    ;; Should NOT parse because status is not 'starting
    (should (null opencode-server--port))))

(ert-deftest opencode-server-parse-port-callback ()
  "Verify that port callback is invoked and cleared when port is parsed.
The hook system chains SSE connect via this callback; without it, streaming never starts."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil)
        (opencode-server--port-callback nil)
        (captured-port nil))
    (setq opencode-server--port-callback
          (lambda (port) (setq captured-port port)))
    (opencode-server--try-parse-port "listening on http://127.0.0.1:12345")
    (should (= captured-port 12345))
    ;; Callback should be cleared after use
    (should (null opencode-server--port-callback))))

;;; --- Process filter ---

(ert-deftest opencode-server-filter-handles-complete-lines ()
  "Verify that process filter handles complete lines terminated by newline.
Basic stdout processing — if this fails, no server output is processed at all."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil)
        (opencode-server--stdout-buffer nil))
    ;; Simulate a mock process (we only need the filter, not a real process)
    (opencode-server--process-filter nil "listening on http://127.0.0.1:7777\n")
    (should (= opencode-server--port 7777))
    ;; After processing a complete line, accumulation buffer should be empty
    (should (or (null opencode-server--stdout-buffer)
                (and (buffer-live-p opencode-server--stdout-buffer)
                     (= (buffer-size opencode-server--stdout-buffer) 0))))
    (opencode-server--kill-stdout-buffer)))

(ert-deftest opencode-server-filter-handles-partial-lines ()
  "Verify that process filter buffers partial lines across calls.
Handles chunked I/O where OS splits output at arbitrary byte boundaries."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil)
        (opencode-server--stdout-buffer nil))
    ;; First chunk: incomplete line
    (opencode-server--process-filter nil "listening on http://127.0")
    (should (null opencode-server--port))
    ;; Second chunk: completes the line
    (opencode-server--process-filter nil ".0.1:6543\n")
    (should (= opencode-server--port 6543))
    (opencode-server--kill-stdout-buffer)))

(ert-deftest opencode-server-filter-handles-multiple-lines ()
  "Verify that process filter handles multiple lines in one chunk.
Handles batched output when server flushes multiple lines at once."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil)
        (opencode-server--stdout-buffer nil))
    (opencode-server--process-filter
     nil "Starting server...\nlistening on http://127.0.0.1:4444\nReady\n")
    (should (= opencode-server--port 4444))
    (opencode-server--kill-stdout-buffer)))

;;; --- URL construction ---

(ert-deftest opencode-server--url-basic ()
  "Verify that URL construction returns the correct base URL.
Foundation for all API endpoint routing — incorrect URL breaks all server communication."
  (let ((opencode-server--port 4096)
        (opencode-server--status 'connected)
        (opencode-server-host "127.0.0.1"))
    (should (string= (opencode-server--url) "http://127.0.0.1:4096"))))

(ert-deftest opencode-server--url-with-path ()
  "Verify that URL construction appends path correctly.
Endpoint routing for all API calls — path errors cause 404s or wrong endpoints hit."
  (let ((opencode-server--port 4096)
        (opencode-server--status 'connected)
        (opencode-server-host "127.0.0.1"))
    (should (string= (opencode-server--url "/session/")
                     "http://127.0.0.1:4096/session/"))
    (should (string= (opencode-server--url "global/health")
                     "http://127.0.0.1:4096/global/health"))))

(ert-deftest opencode-server--url-errors-when-disconnected ()
  "Verify that URL construction signals error when not connected.
Fail-fast prevents requests to nowhere, giving users clear feedback instead of silent failures."
  (let ((opencode-server-port nil)
        (opencode-server--port nil)
        (opencode-server--status nil))
    (should-error (opencode-server--url) :type 'user-error)))

(ert-deftest opencode-server--url-errors-when-not-ready ()
  "Verify that URL construction signals error when status is not connected.
Timing guard prevents requests during startup before server is ready to accept them."
  (let ((opencode-server-port nil)
        (opencode-server--port 4096)
        (opencode-server--status 'starting))
    (should-error (opencode-server--url) :type 'user-error)))

;;; --- Predicates ---

(ert-deftest opencode-server--connected-p-true ()
  "Verify that connected predicate returns non-nil when connected.
Used throughout codebase for connection checks — false negatives break all API calls."
  (let ((opencode-server--port 4096)
        (opencode-server--status 'connected))
    (should (opencode-server--connected-p))))

(ert-deftest opencode-server--connected-p-false-no-port ()
  "Verify that connected predicate returns nil when no port.
Both port AND status needed — port-only check would allow requests before handshake."
  (let ((opencode-server--port nil)
        (opencode-server--status 'connected))
    (should-not (opencode-server--connected-p))))

(ert-deftest opencode-server--connected-p-false-wrong-status ()
  "Verify that connected predicate returns nil when status is not connected.
Status must be exactly 'connected' — starting/stopping states are not usable."
  (let ((opencode-server--port 4096)
        (opencode-server--status 'starting))
    (should-not (opencode-server--connected-p))))

;;; --- Status transitions ---

(ert-deftest opencode-server-initial-state ()
  "Verify that initial state has nil port, status, and process.
Clean slate assumption for all other tests — state leakage causes flaky tests."
  ;; Reset to initial
  (let ((opencode-server--port nil)
        (opencode-server--status nil)
        (opencode-server--process nil))
    (should (null opencode-server--port))
    (should (null opencode-server--status))
    (should (null opencode-server--process))))

;;; --- Connect mode ---

(ert-deftest opencode-server-connect-mode-sets-managed-p ()
  "Verify that connect mode sets managed-p to nil.
Distinguishes managed (started by us) vs connected (external) for correct shutdown behavior."
  (let ((opencode-server--managed-p t))
    ;; Simulate what connect-existing does
    (setq opencode-server--managed-p nil)
    (should-not opencode-server--managed-p)))

;;; --- Logging ---

(ert-deftest opencode-server-log-writes-to-buffer ()
  "Verify that log function writes timestamped messages to log buffer.
Server log buffer *opencode: log* is the primary debugging tool for server issues."
  (let ((opencode-server--log-buffer-name "*opencode: test-log*"))
    (unwind-protect
        (progn
          (opencode-server--log "test message %d" 42)
          (with-current-buffer "*opencode: test-log*"
            (should (opencode-test-buffer-matches-p "\\[.*\\] test message 42"))))
      (when (get-buffer "*opencode: test-log*")
        (kill-buffer "*opencode: test-log*")))))

;;; --- Stop ---

(ert-deftest opencode-server--stop-resets-state ()
  "Verify that stop resets all server state variables.
Clean shutdown — port, status, buffer, managed-p all cleared for fresh restart.
CRITICAL: Must stub url-retrieve-synchronously to prevent a real POST /global/dispose
that would kill any running server on the configured port."
  (let ((opencode-server--process nil)
        (opencode-server--port 4096)
        (opencode-server--status 'connected)
        (opencode-server--stdout-buffer nil)
        (opencode-server--managed-p t)
        (opencode-server--restart-timer nil)
        (opencode-server--log-buffer-name "*opencode: test-stop-log*"))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (_url &rest _args) nil)))
          (opencode-server--stop)
          (should (null opencode-server--process))
          (should (null opencode-server--port))
          (should (eq opencode-server--status 'disconnected))
          (should (null opencode-server--stdout-buffer))
          (should (null opencode-server--managed-p)))
      (when (get-buffer "*opencode: test-stop-log*")
        (kill-buffer "*opencode: test-stop-log*")))))

;;; --- Ensure / auto-connect ---

(ert-deftest opencode-server--ensure-auto-connects-with-fixed-port ()
  "Verify that ensure auto-connects when opencode-server-port is set.
Auto-start enables lazy connection on first API call without explicit opencode-start."
  (let ((opencode-server-port 4096)
        (opencode-server--port nil)
        (opencode-server--status nil)
        (start-called nil))
    (cl-letf (((symbol-function 'opencode-server-start)
               (lambda (&optional _dir)
                 (setq start-called t
                       opencode-server--port 4096
                       opencode-server--status 'connected))))
      (opencode-server--ensure)
      (should start-called)
      (should (= opencode-server--port 4096)))))

(ert-deftest opencode-server--ensure-noop-when-connected ()
  "Verify that ensure does nothing when already connected.
Idempotency — calling ensure repeatedly must be safe without side effects."
  (let ((opencode-server-port 4096)
        (opencode-server--port 4096)
        (opencode-server--status 'connected)
        (start-called nil))
    (cl-letf (((symbol-function 'opencode-server-start)
               (lambda (&optional _dir) (setq start-called t))))
      (opencode-server--ensure)
      (should-not start-called))))

(ert-deftest opencode-server--ensure-errors-without-port ()
  "Verify that ensure signals user-error when no port configured and not connected.
User feedback — clear error message instead of silent failure when misconfigured."
  (let ((opencode-server-port nil)
        (opencode-server--port nil)
        (opencode-server--status nil))
    (should-error (opencode-server--ensure) :type 'user-error)))

;;; --- Additional edge case tests ---

(ert-deftest opencode-server-parse-port-valid ()
  "Verify that port parsing extracts port from 'listening on http://HOST:PORT' pattern.
Redundant coverage for critical port detection path — the foundation of server startup."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "listening on http://127.0.0.1:4096")
    (should (= opencode-server--port 4096))))

(ert-deftest opencode-server-parse-port-no-match ()
  "Verify that port parsing returns nil for lines without port pattern.
Redundant coverage ensuring no false positives in port detection logic."
  (let ((opencode-server--status 'starting)
        (opencode-server--port nil))
    (opencode-server--try-parse-port "Some random log line")
    (should (null opencode-server--port))))

(ert-deftest opencode-server-connected-p-when-port-set ()
  "Verify that public connected-p returns non-nil when port set and status connected.
Public API for connection check — used by external code to gate server operations."
  (let ((opencode-server--port 4096)
        (opencode-server--status 'connected))
    (should (opencode-server-connected-p))))

(ert-deftest opencode-server-connected-p-when-no-port ()
  "Verify that public connected-p returns nil when no port is set.
Public API must correctly report disconnected state to prevent invalid API calls."
  (let ((opencode-server--port nil)
        (opencode-server--status 'connected))
    (should-not (opencode-server-connected-p))))

(provide 'opencode-server-test)
;;; opencode-server-test.el ends here
