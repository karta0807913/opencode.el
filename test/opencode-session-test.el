;;; opencode-session-test.el --- Tests for opencode-session.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for session management helpers.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-session)

;;; --- Data helpers ---

(ert-deftest opencode-session-title-returns-title ()
  "Verify explicit titles are returned unchanged.
Session pickers and chat headers need stable title display."
  (should (string= (opencode-session--title '(:title "Fix auth bug"))
                    "Fix auth bug")))

(ert-deftest opencode-session-title-returns-untitled ()
  "Verify missing titles render as a fallback string.
Without this, untitled sessions would show nil in user-facing UI."
  (should (string= (opencode-session--title '(:title nil))
                    "(untitled)")))

(ert-deftest opencode-session-project-name-extracts ()
  "Verify project names are extracted from session directories.
Session completion labels depend on readable project names."
  (should (string= (opencode-session--project-name
                     '(:directory "/home/user/projects/my-app"))
                    "my-app")))

(ert-deftest opencode-session-project-name-default ()
  "Verify sessions without directories get a stable project fallback.
This prevents nil text in completion labels for incomplete server data."
  (should (string= (opencode-session--project-name '(:directory nil))
                    "default")))

(provide 'opencode-session-test)
;;; opencode-session-test.el ends here
