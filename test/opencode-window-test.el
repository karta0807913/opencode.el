;;; opencode-window-test.el --- Tests for opencode-window.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for window and frame management.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-window)
(require 'opencode-sidebar)
(require 'opencode-session)

(defvar opencode-window-test-project-dir "/home/user/project"
  "Default project directory for window tests.")

;;; --- Display actions ---

(ert-deftest opencode-window-side-action-structure ()
  "Verify side action returns correct display-buffer alist structure.
Side window display depends on correct alist keys (side, width, category) —
wrong structure breaks window positioning and classification."
  (let ((opencode-window-side 'right)
        (opencode-window-width 80)
        (opencode-window-persistent t))
    (let ((action (opencode-window--side-action)))
      (should (listp action))
      ;; First element is function list
      (should (memq 'display-buffer-in-side-window (car action)))
      ;; Check alist entries
      (let ((alist (cdr action)))
        (should (eq (alist-get 'side alist) 'right))
        (should (= (alist-get 'window-width alist) 80))
        (should (eq (alist-get 'category alist) 'opencode))))))

(ert-deftest opencode-window-side-action-left ()
  "Verify side action respects `opencode-window-side' set to left.
Users who prefer left-side panels need the alist to reflect their setting —
ignoring this breaks left-side window placement."
  (let ((opencode-window-side 'left)
        (opencode-window-width 60)
        (opencode-window-persistent nil))
    (let* ((action (opencode-window--side-action))
           (alist (cdr action)))
      (should (eq (alist-get 'side alist) 'left))
      (should (= (alist-get 'window-width alist) 60)))))

(ert-deftest opencode-window-float-action-structure ()
  "Verify float action uses pop-up-frame with frame-alist parameters.
Floating windows require display-buffer-pop-up-frame and proper frame params —
wrong action type prevents opencode buffers from appearing in separate frames."
  (let ((opencode-float-frame-alist '((width . 100) (height . 50))))
    (let* ((action (opencode-window--float-action))
           (alist (cdr action)))
      (should (memq 'display-buffer-pop-up-frame (car action)))
      (should (alist-get 'pop-up-frame-parameters alist))
      (should (eq (alist-get 'category alist) 'opencode)))))

(ert-deftest opencode-window-split-action-structure ()
  "Verify split action uses display-buffer-in-direction.
Split display mode needs correct direction-based action —
wrong structure breaks side-by-side window splitting."
  (let* ((action (opencode-window--split-action))
         (alist (cdr action)))
    (should (memq 'display-buffer-in-direction (car action)))
    (should (eq (alist-get 'direction alist) 'right))))

(ert-deftest opencode-window-full-action-structure ()
  "Verify full action uses display-buffer-full-frame.
Full-frame display mode requires the dedicated action —
wrong action prevents opencode from taking over the entire frame."
  (let* ((action (opencode-window--full-action))
         (alist (cdr action)))
    (should (memq 'display-buffer-full-frame (car action)))))

;;; --- Window finding ---

(ert-deftest opencode-window-find-window-returns-nil ()
  "Verify find-window returns nil when no opencode windows exist.
Callers must handle nil gracefully when no opencode windows are open —
returning stale or wrong windows causes display corruption."
  ;; In batch mode, there are no opencode windows
  (should (null (opencode-window--find-window))))

;;; --- Buffer finding ---

(ert-deftest opencode-window-find-buffer-prefers-chat ()
  "Verify find-buffer prefers chat buffers over session list buffers.
Chat buffers are the primary UI; users expect them to be selected first —
wrong priority causes session list to steal focus from active chats."
  (let* ((session-name (opencode-session--buffer-name opencode-window-test-project-dir))
         (chat-buf (get-buffer-create "*opencode: test/Chat*"))
         (session-buf (get-buffer-create session-name)))
    (unwind-protect
        (let ((found (opencode-window--find-buffer)))
          (should found)
          (should (string= (buffer-name found) "*opencode: test/Chat*")))
      (kill-buffer chat-buf)
      (kill-buffer session-buf))))

(ert-deftest opencode-window-find-buffer-falls-back-to-sessions ()
  "Verify find-buffer falls back to session list when no chat buffer exists.
When no chat is open, session list is the next best opencode buffer —
returning nil when sessions exist breaks window navigation commands."
  (let* ((session-name (opencode-session--buffer-name opencode-window-test-project-dir))
         (session-buf (get-buffer-create session-name)))
    (unwind-protect
        (let ((found (opencode-window--find-buffer)))
          (should found)
          (should (string= (buffer-name found) session-name)))
      (kill-buffer session-buf))))

(ert-deftest opencode-window-find-buffer-skips-log ()
  "Verify find-buffer excludes the log buffer from results.
Log buffer is internal infrastructure, not a user-facing UI buffer —
including it in results causes navigation to land on debug output."
  (let ((log-buf (get-buffer-create "*opencode: log*")))
    (unwind-protect
        (let ((found (opencode-window--find-buffer)))
          ;; Should not return the log buffer (may return nil or sessions)
          (when found
            (should-not (string= (buffer-name found) "*opencode: log*"))))
      (kill-buffer log-buf))))

(ert-deftest opencode-window-find-buffer-skips-debug ()
  "Verify find-buffer excludes the debug buffer from results.
Debug buffer is internal infrastructure, not a user-facing UI buffer —
including it in results causes navigation to land on debug output."
  (let ((debug-buf (get-buffer-create "*opencode: debug*")))
    (unwind-protect
        (let ((found (opencode-window--find-buffer)))
          ;; Should not return the debug buffer (may return nil or sessions)
          (when found
            (should-not (string= (buffer-name found) "*opencode: debug*"))))
      (kill-buffer debug-buf))))

;;; --- Persistent side window ---

(ert-deftest opencode-window-persistent-parameter ()
  "Verify side action includes no-delete-other-windows when persistent=t.
Persistent side windows must survive `delete-other-windows' commands —
missing window-parameter allows C-x 1 to accidentally close the sidebar."
  (let ((opencode-window-persistent t)
        (opencode-window-side 'right)
        (opencode-window-width 80))
    (let* ((action (opencode-window--side-action))
           (alist (cdr action))
           (win-params (alist-get 'window-parameters alist)))
      (should win-params)
      (should (alist-get 'no-delete-other-windows win-params)))))

(ert-deftest opencode-window-non-persistent-parameter ()
  "Verify side action omits no-delete-other-windows when persistent=nil.
Non-persistent windows should be deletable by standard window commands —
including the parameter breaks users who expect C-x 1 to close everything."
  (let ((opencode-window-persistent nil)
        (opencode-window-side 'right)
        (opencode-window-width 80))
    (let* ((action (opencode-window--side-action))
           (alist (cdr action))
           (win-params (alist-get 'window-parameters alist)))
      (should-not (alist-get 'no-delete-other-windows win-params)))))

;;; --- Display rules ---

(ert-deftest opencode-window--setup-display-rules-adds-entry ()
  "Verify setup installs display-buffer-alist entry matching *opencode:*.
The alist entry routes opencode buffers to the configured display action —
missing entry causes buffers to appear in random windows."
  (let ((display-buffer-alist nil))
    (opencode-window--setup-display-rules)
    (should (length= display-buffer-alist 1))
    (should (string= (caar display-buffer-alist) "\\*opencode:"))))

;;; --- Toggle sidebar ---

(ert-deftest opencode-window-toggle-sidebar-width-45 ()
  "Verify toggle-sidebar uses width 45 for the side window."
  (let ((display-alist nil)
        (sidebar-name opencode-sidebar--buffer-name))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _)
                 (cons 'transient opencode-window-test-project-dir)))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'opencode-server-connected-p)
               (lambda () t))
              ((symbol-function 'opencode-sidebar--ensure-buffer)
               (lambda (_dir) (get-buffer-create sidebar-name)))
              ((symbol-function 'display-buffer-in-side-window)
               (lambda (_buf alist)
                 (setq display-alist alist)
                 nil)))
      (unwind-protect
          (progn
            (opencode-window-toggle-sidebar)
            (should display-alist)
            (should (= (alist-get 'window-width display-alist) 45)))
        (when-let ((buf (get-buffer sidebar-name)))
          (kill-buffer buf))))))

(ert-deftest opencode-window-toggle-sidebar-selects-window ()
  "Verify toggle-sidebar focuses the newly opened sidebar window."
  (let ((selected-win nil)
        (sidebar-name opencode-sidebar--buffer-name))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _)
                 (cons 'transient opencode-window-test-project-dir)))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'opencode-server-connected-p)
               (lambda () t))
              ((symbol-function 'opencode-sidebar--ensure-buffer)
               (lambda (_dir) (get-buffer-create sidebar-name)))
              ((symbol-function 'display-buffer-in-side-window)
               (lambda (_buf _alist) 'mock-window))
              ((symbol-function 'select-window)
               (lambda (win) (setq selected-win win))))
      (unwind-protect
          (progn
            (opencode-window-toggle-sidebar)
            (should (eq selected-win 'mock-window)))
        (when-let ((buf (get-buffer sidebar-name)))
          (kill-buffer buf))))))

(ert-deftest opencode-window-toggle-sidebar-reshow-selects-window ()
  "Verify re-showing existing sidebar buffer also focuses the window."
  (let ((selected-win nil)
        (sidebar-name opencode-sidebar--buffer-name))
    (unwind-protect
        (progn
          ;; Pre-create sidebar buffer with primary-project-dir set
          ;; so toggle doesn't try to refresh (no server in tests)
          (let ((buf (get-buffer-create sidebar-name)))
            (with-current-buffer buf
              (setq-local opencode-sidebar--primary-project-dir
                          (directory-file-name (expand-file-name default-directory)))))
          (cl-letf (((symbol-function 'display-buffer-in-side-window)
                     (lambda (_buf _alist) 'mock-window2))
                    ((symbol-function 'select-window)
                     (lambda (win) (setq selected-win win))))
            (opencode-window-toggle-sidebar)
            (should (eq selected-win 'mock-window2))))
      (when-let ((buf (get-buffer sidebar-name)))
        (kill-buffer buf)))))

(ert-deftest opencode-window-toggle-sidebar-reshow-width-45 ()
  "Verify re-showing existing sidebar buffer uses width 45."
  (let ((display-alist nil)
        (sidebar-name opencode-sidebar--buffer-name))
    (unwind-protect
        (progn
          (let ((buf (get-buffer-create sidebar-name)))
            (with-current-buffer buf
              (setq-local opencode-sidebar--primary-project-dir
                          (directory-file-name (expand-file-name default-directory)))))
          (cl-letf (((symbol-function 'display-buffer-in-side-window)
                     (lambda (_buf alist)
                       (setq display-alist alist)
                       nil)))
            (opencode-window-toggle-sidebar)
            (should display-alist)
            (should (= (alist-get 'window-width display-alist) 45))))
      (when-let ((buf (get-buffer sidebar-name)))
        (kill-buffer buf)))))

(provide 'opencode-window-test)
;;; opencode-window-test.el ends here
