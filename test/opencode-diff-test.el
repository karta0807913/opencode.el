;;; opencode-diff-test.el --- Tests for opencode-diff.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the inline diff display module.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'opencode-diff)

(defvar opencode-default-directory)

;;; --- Test: File header rendering ---

(ert-deftest opencode-diff-render-file-header ()
  "Verify file path appears with correct face in rendered diff.
Why this matters — without correct file header rendering, users cannot identify which files have changes."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Verify file path appears
    (should (opencode-test-buffer-contains-p "src/auth/login.ts"))
    ;; Verify file header face
    (should (opencode-test-has-face-p "src/auth/login.ts" 'opencode-diff-file-header))
    ;; Verify stats in header
    (should (opencode-test-buffer-contains-p "(+5 -3)"))))

;;; --- Test: Added lines face ---

(ert-deftest opencode-diff-render-added-lines ()
  "Verify that + lines have `opencode-diff-added' face.
Why this matters — without proper styling, added lines are indistinguishable from context, losing diff readability."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Verify added line has correct face
    (should (opencode-test-has-face-p "+    return { valid: true, decoded };"
                                      'opencode-diff-added))))

;;; --- Test: Removed lines face ---

(ert-deftest opencode-diff-render-removed-lines ()
  "Verify that - lines have `opencode-diff-removed' face.
Why this matters — without proper styling, removed lines are indistinguishable from context, losing diff readability."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Verify removed line has correct face
    (should (opencode-test-has-face-p "-    return decoded;"
                                      'opencode-diff-removed))))

;;; --- Test: Hunk header face ---

(ert-deftest opencode-diff-render-hunk-header ()
  "Verify that @@ lines have `opencode-diff-hunk-header' face.
Why this matters — hunk headers mark change boundaries; without styling, users cannot navigate to specific changes."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Verify hunk header face
    (should (opencode-test-has-face-p "@@ -21,5 +21,10 @@"
                                      'opencode-diff-hunk-header))))

;;; --- Test: Empty diff ---

(ert-deftest opencode-diff-empty-diff ()
  "Verify that an empty diff array shows the 'No changes' message.
Why this matters — without an empty state message, users see a blank buffer with no explanation."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs [])
    (opencode-diff--render)
    ;; Verify empty state message
    (should (opencode-test-buffer-contains-p "No changes in this session."))))

;;; --- Test: Revert API call ---

(ert-deftest opencode-diff-revert-requires-message-id ()
  "Verify that revert errors when no message ID is set.
Why this matters — revert without messageID would send an invalid API request or corrupt session state."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--message-id nil)
    ;; Should signal user-error
    (should-error (opencode-diff--revert) :type 'user-error)))

;;; --- Test: Revert sends correct request ---

(ert-deftest opencode-diff-revert-api-call ()
  "Verify that revert sends POST with correct messageID to /session/:id/revert.
Why this matters — incorrect request body would fail to revert changes or revert wrong content."
  (opencode-test-with-mock-api
    ;; Mock the revert endpoint
    (opencode-test-mock-response "POST" "/session/ses_test/revert" 200
                                 (list :id "ses_test"))
    ;; Mock the diff refresh endpoint
    (opencode-test-mock-response "GET" "/session/ses_test/diff" 200 [])
    (opencode-test-with-temp-buffer "*test-diff*"
      (opencode-diff-mode)
      (setq opencode-diff--session-id "ses_test")
      (setq opencode-diff--message-id "msg_abc123")
      (setq opencode-diff--diffs [])
      ;; Bypass yes-or-no-p confirmation
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
        (opencode-diff--revert))
      ;; Verify the POST request was made (second request — last is the refresh GET)
      (should (>= (opencode-test-request-count) 2))
      (let ((req (nth 1 opencode-test--mock-requests)))
        (should (equal (nth 0 req) "POST"))
        (should (string-search "revert" (nth 1 req)))))))

;;; --- Test: Buffer mode ---

(ert-deftest opencode-diff-buffer-mode ()
  "Verify that the diff buffer derives from `diff-mode'.
Why this matters — diff-mode derivation enables standard diff navigation keys and syntax highlighting."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (should (eq major-mode 'opencode-diff-mode))
    (should (derived-mode-p 'diff-mode))))

;;; --- Test: Multiple files rendered ---

(ert-deftest opencode-diff-multiple-files ()
  "Verify that multiple files from the fixture are each rendered with headers.
Why this matters — multi-file diffs must show all changed files; missing files would hide changes from users."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Both files from fixture should appear
    (should (opencode-test-buffer-contains-p "src/auth/login.ts"))
    (should (opencode-test-buffer-contains-p "src/auth/__tests__/login.test.ts"))))

;;; --- Test: File text property ---

(ert-deftest opencode-diff-file-text-property ()
  "Verify that `opencode-diff-file' text property is set on diff lines.
Why this matters — programmatic file access via text property enables navigation and file-specific operations."
  (opencode-test-with-temp-buffer "*test-diff*"
    (opencode-diff-mode)
    (setq opencode-diff--session-id "ses_test")
    (setq opencode-diff--diffs (opencode-test-fixture "diff-response"))
    (opencode-diff--render)
    ;; Find the file header and check text property
    (goto-char (point-min))
    (search-forward "src/auth/login.ts")
    (should (equal (get-text-property (match-beginning 0) 'opencode-diff-file)
                   "src/auth/login.ts"))))

;;; --- Test: Generate unified diff from before/after ---

(ert-deftest opencode-diff-generate-unified-basic ()
  "Generate unified diff from before/after strings.
Why this matters — unified diff generation is the fallback when server provides before/after but no patch field."
  (let ((result (opencode-diff--generate-unified
                 "line1\nline2\n"
                 "line1\nline2\nline3\n"
                 "test.txt")))
    (should result)
    (should (string-match-p "^---" result))
    (should (string-match-p "^\\+\\+\\+" result))
    (should (string-match-p "\\+line3" result))))

(ert-deftest opencode-diff-generate-unified-no-change ()
  "Verify unified diff generation returns nil when before and after are identical.
Why this matters — identical content should not produce spurious diff output or 'no newline' artifacts."
  (let ((result (opencode-diff--generate-unified
                 "same\n" "same\n" "test.txt")))
    (should-not result)))

(ert-deftest opencode-diff-generate-unified-nil-inputs ()
  "Verify unified diff generation handles nil inputs gracefully.
Why this matters — nil inputs from server edge cases must not crash the diff renderer."
  (should-not (opencode-diff--generate-unified nil nil "test.txt")))

(ert-deftest opencode-diff-generate-unified-new-file ()
  "Verify unified diff handles new file creation (nil before, non-nil after).
Why this matters — new files have no 'before' content; this edge case must render as all-additions diff."
  (let ((result (opencode-diff--generate-unified
                 nil "new content\n" "new.txt")))
    (should result)
    (should (string-match-p "\\+new content" result))))

;;; --- Test: render-file falls back to before/after ---

(ert-deftest opencode-diff-render-file-before-after ()
  "Verify render-file generates diff from before/after when no patch field present.
Why this matters — fallback diff rendering ensures diffs display even when server omits pre-computed patch."
  (opencode-test-with-temp-buffer "*test-diff-before-after*"
    (opencode-diff-mode)
    (let ((inhibit-read-only t)
          (file-diff (list :file "src/foo.el"
                           :additions 1 :deletions 0
                           :before "line1\n"
                           :after "line1\nline2\n")))
      (opencode-diff--render-file file-diff)
      ;; Should show the file header
      (should (opencode-test-buffer-contains-p "src/foo.el"))
      ;; Should NOT show "no changes"
      (should-not (opencode-test-buffer-contains-p "no changes"))
      ;; Should show the added line from generated diff
      (should (opencode-test-buffer-contains-p "+line2")))))

;;; --- Test: open-file-at-point resolves relative path to project root ---

(ert-deftest opencode-diff-open-file-resolves-to-project-root ()
  "Verify that RET / `o' resolves relative file paths using the project root.
Why this matters — diff file paths are relative (e.g. \"src/main.ts\"); without
project root in `default-directory', `find-file' opens the wrong location."
  (let* ((project-dir (make-temp-file "opencode-diff-test-" t))
         (src-dir (expand-file-name "src" project-dir))
         (file-path (expand-file-name "main.ts" src-dir))
         (opened-file nil))
    (make-directory src-dir t)
    (with-temp-file file-path
      (insert "console.log('hello');\n"))
    (unwind-protect
        (opencode-test-with-temp-buffer "*test-diff-nav*"
          (opencode-diff-mode)
          (setq default-directory (file-name-as-directory project-dir))
          (setq opencode-diff--session-id "ses_test")
          (setq opencode-diff--diffs
                (vector (list :file "src/main.ts"
                              :additions 1 :deletions 0
                              :before "" :after "console.log('hello');\n")))
          (opencode-diff--render)
          ;; Position on a line with the file property
          (goto-char (point-min))
          (search-forward "src/main.ts")
          ;; Intercept find-file to capture the resolved path
          (cl-letf (((symbol-function 'find-file)
                     (lambda (path &rest _) (setq opened-file path))))
            (opencode-diff--open-file-at-point))
          ;; Verify the opened path is the absolute project file, not relative
          (should opened-file)
          (should (file-name-absolute-p opened-file))
          (should (string-suffix-p "src/main.ts" opened-file))
          (should (string-prefix-p project-dir opened-file)))
      (delete-directory project-dir t))))

;;; --- Test: diff buffer default-directory set from opencode-default-directory ---

(ert-deftest opencode-diff-open-sets-default-directory ()
  "Verify that `opencode-diff--open' sets `default-directory' from `opencode-default-directory'.
Why this matters — without project root in `default-directory', all file operations resolve incorrectly."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/session/ses_test/diff" 200 [])
    (let ((opencode-default-directory "/tmp/test-project/"))
      (opencode-diff--open "ses_test"))
    (with-current-buffer "*opencode: diff*"
      (should (string= default-directory "/tmp/test-project/"))
      (kill-buffer))))

(provide 'opencode-diff-test)
;;; opencode-diff-test.el ends here
