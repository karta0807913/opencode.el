;;; opencode-log-test.el --- Tests for opencode-log.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the debug logging module.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-log)

;;; --- Helpers ---

(defmacro opencode-log-test-with-fresh-buffer (&rest body)
  "Run BODY with a fresh debug buffer and reset line counter."
  (declare (indent 0))
  `(let ((opencode-debug t)
         (opencode-log--line-count 0))
     (when-let ((buf (get-buffer "*opencode: debug*")))
       (kill-buffer buf))
     (unwind-protect
         (progn ,@body)
       (when-let ((buf (get-buffer "*opencode: debug*")))
         (kill-buffer buf)))))

;;; --- Debug buffer creation ---

(ert-deftest opencode-log-debug-creates-buffer ()
  "Calling `opencode--debug' creates the debug buffer when `opencode-debug' is non-nil."
  (opencode-log-test-with-fresh-buffer
    (opencode--debug "test message")
    (should (get-buffer "*opencode: debug*"))))

;;; --- Timestamped messages ---

(ert-deftest opencode-log-debug-inserts-timestamped-message ()
  "Debug message includes [HH:MM:SS.mmm] timestamp prefix and formatted message."
  (opencode-log-test-with-fresh-buffer
    (opencode--debug "test message")
    (with-current-buffer "*opencode: debug*"
      (let ((content (buffer-string)))
        (should (string-match-p "\\[\\([0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\.[0-9]\\{3\\}\\)\\]" content))
        (should (string-match-p "test message" content))))))

;;; --- Noop when disabled ---

(ert-deftest opencode-log-debug-noop-when-disabled ()
  "When `opencode-debug' is nil, `opencode--debug' does nothing."
  (let ((opencode-debug nil))
    (when-let ((buf (get-buffer "*opencode: debug*")))
      (kill-buffer buf))
    (opencode--debug "should not appear")
    (should-not (get-buffer "*opencode: debug*"))))

;;; --- Format string and args ---

(ert-deftest opencode-log-debug-format-string-args ()
  "Debug message formats string and args correctly."
  (opencode-log-test-with-fresh-buffer
    (opencode--debug "foo %s %d" "bar" 42)
    (with-current-buffer "*opencode: debug*"
      (should (string-match-p "foo bar 42" (buffer-string))))))

;;; --- Truncation ---

(ert-deftest opencode-log-debug-truncates-when-exceeding-max ()
  "Buffer is truncated when line count exceeds `opencode-debug-max-lines'.
Uses delete-half strategy so line count stays bounded but may not equal max exactly."
  (let ((opencode-debug-max-lines 5))
    (opencode-log-test-with-fresh-buffer
      (dotimes (i 10)
        (opencode--debug "message %d" i))
      (with-current-buffer "*opencode: debug*"
        (let ((line-count (count-lines (point-min) (point-max))))
          ;; Should be at most max-lines (bounded)
          (should (<= line-count opencode-debug-max-lines))
          ;; Latest messages should be present
          (let ((content (buffer-string)))
            (should (string-match-p "message 9" content))
            (should (string-match-p "message 8" content))
            ;; Earliest messages should be gone
            (should-not (string-match-p "message 0" content))
            (should-not (string-match-p "message 1" content))))))))

(ert-deftest opencode-log-debug-no-truncate-at-exactly-max ()
  "When buffer has exactly `opencode-debug-max-lines' lines, no truncation occurs."
  (let ((opencode-debug-max-lines 5))
    (opencode-log-test-with-fresh-buffer
      (dotimes (i 5)
        (opencode--debug "message %d" i))
      (with-current-buffer "*opencode: debug*"
        (let ((line-count (count-lines (point-min) (point-max))))
          (should (= line-count 5))
          (let ((content (buffer-string)))
            (should (string-match-p "message 0" content))
            (should (string-match-p "message 4" content))))))))

(ert-deftest opencode-log-debug-counter-resets-on-fresh-buffer ()
  "Line counter resets when the debug buffer is recreated.
Prevents stale counter from triggering premature truncation."
  (let ((opencode-debug-max-lines 5))
    (opencode-log-test-with-fresh-buffer
      ;; Fill and trigger truncation
      (dotimes (i 8)
        (opencode--debug "batch1 %d" i))
      ;; Kill buffer, simulating clear
      (kill-buffer "*opencode: debug*")
      (setq opencode-log--line-count 0)
      ;; Insert fewer than max — should NOT truncate
      (dotimes (i 3)
        (opencode--debug "batch2 %d" i))
      (with-current-buffer "*opencode: debug*"
        (should (= (count-lines (point-min) (point-max)) 3))
        (should (string-match-p "batch2 0" (buffer-string)))))))

;;; --- Format error handling ---

(ert-deftest opencode-log-debug-survives-format-error ()
  "Format error in `opencode--debug' does not crash caller."
  (opencode-log-test-with-fresh-buffer
    ;; This should not raise an error to the caller
    (let ((result (opencode--debug "%s %s" "only-one-arg")))
      (should (stringp result))
      (should (string-match-p "opencode--debug error" result)))))

;;; --- Cursor position preservation ---

(ert-deftest opencode-log-debug-preserves-buffer-point ()
  "Debug logging does not move buffer point when not at end."
  (opencode-log-test-with-fresh-buffer
    (opencode--debug "line one")
    (opencode--debug "line two")
    (opencode--debug "line three")
    (with-current-buffer "*opencode: debug*"
      (goto-char (point-min))
      (let ((saved-point (point)))
        (opencode--debug "line four")
        (opencode--debug "line five")
        (should (= (point) saved-point))))))

(ert-deftest opencode-log-debug-preserves-mid-buffer-point ()
  "Debug logging preserves point in the middle of the buffer."
  (opencode-log-test-with-fresh-buffer
    (dotimes (i 10)
      (opencode--debug "message %d" i))
    (with-current-buffer "*opencode: debug*"
      (goto-char (point-min))
      (forward-line 4)
      (let ((saved-point (point))
            (saved-line-content (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position))))
        (opencode--debug "extra line")
        (should (= (point) saved-point))
        (should (string= (buffer-substring-no-properties
                          (line-beginning-position)
                          (line-end-position))
                         saved-line-content))))))

;;; --- Show debug log errors ---

(ert-deftest opencode-log-show-debug-log-errors-when-no-buffer ()
  "Calling `opencode-show-debug-log' signals error when debug buffer doesn't exist."
  (when-let ((buf (get-buffer "*opencode: debug*")))
    (kill-buffer buf))
  (should-error (opencode-show-debug-log) :type 'user-error))

;;; --- Clear resets counter ---

(ert-deftest opencode-log-clear-resets-counter ()
  "Calling `opencode-clear-debug-log' resets the line counter to zero."
  (opencode-log-test-with-fresh-buffer
    (dotimes (i 5)
      (opencode--debug "msg %d" i))
    (should (= opencode-log--line-count 5))
    (opencode-clear-debug-log)
    (should (= opencode-log--line-count 0))))

(provide 'opencode-log-test)
;;; opencode-log-test.el ends here
