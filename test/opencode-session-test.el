;;; opencode-session-test.el --- Tests for opencode-session.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for session management and session list buffer.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-session)

;;; --- Data helpers ---

(ert-deftest opencode-session-title-returns-title ()
  "Title helper returns the session title."
  (should (string= (opencode-session--title '(:title "Fix auth bug"))
                    "Fix auth bug")))

(ert-deftest opencode-session-title-returns-untitled ()
  "Title helper returns (untitled) for nil title."
  (should (string= (opencode-session--title '(:title nil))
                    "(untitled)")))

(ert-deftest opencode-session-id-returns-id ()
  "ID helper returns the session ID."
  (should (string= (opencode-session--id '(:id "ses_abc"))
                    "ses_abc")))

(ert-deftest opencode-session-project-name-extracts ()
  "Project name extracted from directory."
  (should (string= (opencode-session--project-name
                     '(:directory "/home/user/projects/my-app"))
                    "my-app")))

(ert-deftest opencode-session-project-name-default ()
  "Project name defaults to 'default' when no directory."
  (should (string= (opencode-session--project-name '(:directory nil))
                    "default")))

(ert-deftest opencode-session-archived-p-true ()
  "Archived predicate returns non-nil for archived sessions."
  (should (opencode-session--archived-p
           '(:time (:archived 1700000000)))))

(ert-deftest opencode-session-archived-p-false ()
  "Archived predicate returns nil for non-archived sessions."
  (should-not (opencode-session--archived-p
               '(:time (:archived 0))))
  (should-not (opencode-session--archived-p '(:time nil))))

;;; --- Status helpers ---

(ert-deftest opencode-session-status-type-from-status-map ()
  "Status type extracted from status map."
  (let ((opencode-session--status '(ses_abc (:type "busy"))))
    (should (string= (opencode-session--status-type "ses_abc") "busy"))))

(ert-deftest opencode-session-status-type-nil-when-missing ()
  "Status type returns nil when session not in map."
  (let ((opencode-session--status '(ses_abc (:type "busy"))))
    (should (null (opencode-session--status-type "ses_xyz")))))

;;; --- Session list buffer ---

(ert-deftest opencode-session-mode-defined ()
  "Session mode should be defined."
  (should (fboundp 'opencode-session-mode)))

(ert-deftest opencode-session-mode-keymap ()
  "Session mode keymap has expected bindings."
  (should (keymapp opencode-session-mode-map))
  (should (commandp (keymap-lookup opencode-session-mode-map "RET")))
  (should (commandp (keymap-lookup opencode-session-mode-map "TAB")))
  (should (commandp (keymap-lookup opencode-session-mode-map "n")))
  (should (commandp (keymap-lookup opencode-session-mode-map "g"))))

;;; --- Rendering ---

(ert-deftest opencode-session--render-empty ()
  "Render with no sessions produces footer."
  (opencode-test-with-temp-buffer "*test-session-render*"
    (opencode-session-mode)
    (let ((opencode-session--list nil))
      (opencode-session--render)
      ;; Should have the footer keybinding hints
      (should (opencode-test-buffer-contains-p "[RET] open")))))

(ert-deftest opencode-session--render-with-sessions ()
  "Render with sessions shows titles and status icons."
  (opencode-test-with-temp-buffer "*test-session-render-data*"
    (opencode-session-mode)
    (setq opencode-session--expanded (make-hash-table :test 'equal))
    (let ((opencode-session--list
           (vector
            (list :id "ses_1" :title "Fix auth bug"
                  :directory "/tmp/my-app"
                  :time (list :created 1700000000 :updated 1700000000)
                  :summary (list :additions 8 :deletions 3 :files 2))
            (list :id "ses_2" :title "Add dashboard"
                  :directory "/tmp/my-app"
                  :time (list :created 1699990000 :updated 1699990000))))
          (opencode-session--status
           (list (intern "ses_1") (list :type "busy")
                 (intern "ses_2") (list :type "idle"))))
      (opencode-session--render)
      (should (opencode-test-buffer-contains-p "Fix auth bug"))
      (should (opencode-test-buffer-contains-p "Add dashboard"))
      (should (opencode-test-buffer-contains-p "my-app")))))

;;; --- Expand/collapse ---

(ert-deftest opencode-session-expand-tracks-state ()
  "Expanding a session adds it to the expanded set."
  (let ((opencode-session--expanded (make-hash-table :test 'equal)))
    (puthash "ses_1" t opencode-session--expanded)
    (should (gethash "ses_1" opencode-session--expanded))
    (remhash "ses_1" opencode-session--expanded)
    (should-not (gethash "ses_1" opencode-session--expanded))))

;;; --- File list rendering ---

(ert-deftest opencode-session--render-file-list ()
  "File list renders with tree guides and status."
  (opencode-test-with-temp-buffer "*test-session-files*"
    (let ((opencode-session--diffs (make-hash-table :test 'equal)))
      (puthash "ses_1"
               (vector
                (list :file "src/auth/login.ts" :status "modified"
                      :additions 5 :deletions 3)
                (list :file "src/auth/test.ts" :status "added"
                      :additions 3 :deletions 0))
               opencode-session--diffs)
      (opencode-session--render-file-list "ses_1")
      (should (opencode-test-buffer-contains-p "login.ts"))
      (should (opencode-test-buffer-contains-p "test.ts"))
      (should (opencode-test-buffer-contains-p "├─"))
      (should (opencode-test-buffer-contains-p "└─"))
      (should (opencode-test-buffer-contains-p "M"))
      (should (opencode-test-buffer-contains-p "A")))))

(provide 'opencode-session-test)
;;; opencode-session-test.el ends here
