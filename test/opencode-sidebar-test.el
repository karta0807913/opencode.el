;;; opencode-sidebar-test.el --- Tests for opencode-sidebar.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for global treemacs-based sidebar panel.
;; Old per-project sidebar tests removed; replaced with group/status tests.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-sidebar)
(require 'opencode-api-cache)

;; Ensure `opencode-default-directory' is a special (dynamically-bound) variable
(defvar opencode-default-directory nil)

;;; --- Status store tests ---

(ert-deftest opencode-sidebar-status-store-default-idle ()
  "Default status for unknown session is idle."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (should (eq 'idle (opencode-sidebar--session-status "ses_unknown")))))

(ert-deftest opencode-sidebar-status-store-busy ()
  "Status store returns busy after being set."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'busy opencode-sidebar--status-store)
    (should (eq 'busy (opencode-sidebar--session-status "ses_1")))))

(ert-deftest opencode-sidebar-status-store-question ()
  "Status store returns question after being set."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'question opencode-sidebar--status-store)
    (should (eq 'question (opencode-sidebar--session-status "ses_1")))))

(ert-deftest opencode-sidebar-status-store-permission ()
  "Status store returns permission after being set."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'permission opencode-sidebar--status-store)
    (should (eq 'permission (opencode-sidebar--session-status "ses_1")))))

;;; --- Session icon tests ---

(ert-deftest opencode-sidebar-icon-opened-idle ()
  "Opened session with idle status shows ○ icon."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (let ((item (list :session-id "ses_1" :opened t)))
      (should (string-match-p "○" (opencode-sidebar--session-icon item nil))))))

(ert-deftest opencode-sidebar-icon-opened-busy ()
  "Opened session with busy status shows ⬤ icon."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'busy opencode-sidebar--status-store)
    (let ((item (list :session-id "ses_1" :opened t)))
      (should (string-match-p "⬤" (opencode-sidebar--session-icon item nil))))))

(ert-deftest opencode-sidebar-icon-opened-question ()
  "Opened session with question status shows ? icon."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'question opencode-sidebar--status-store)
    (let ((item (list :session-id "ses_1" :opened t)))
      (should (string-match-p "\\?" (opencode-sidebar--session-icon item nil))))))

(ert-deftest opencode-sidebar-icon-opened-permission ()
  "Opened session with permission status shows ! icon."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (puthash "ses_1" 'permission opencode-sidebar--status-store)
    (let ((item (list :session-id "ses_1" :opened t)))
      (should (string-match-p "!" (opencode-sidebar--session-icon item nil))))))

(ert-deftest opencode-sidebar-icon-not-opened-collapsed ()
  "Non-opened session shows ▸ when collapsed."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (let ((item (list :session-id "ses_1")))
      (should (string-match-p "▸" (opencode-sidebar--session-icon item nil))))))

(ert-deftest opencode-sidebar-icon-not-opened-expanded ()
  "Non-opened session shows ▾ when expanded."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (let ((item (list :session-id "ses_1")))
      (should (string-match-p "▾" (opencode-sidebar--session-icon item t))))))

;;; --- Label tests ---

(ert-deftest opencode-sidebar-session-label-with-summary ()
  "Session label includes title, diff stats, and time."
  (let ((item (list :title "My Task"
                    :summary (list :additions 5 :deletions 2 :files 1)
                    :time (list :updated (* (float-time) 1000)))))
    (let ((label (opencode-sidebar--session-label item)))
      (should (string-match-p "My Task" label))
      (should (string-match-p "\\+5" label))
      (should (string-match-p "-2" label)))))


(ert-deftest opencode-sidebar-group-label-normal ()
  "Group label shows name without refreshing indicator."
  (let ((item (list :group-name "myproject" :project-dir "/proj")))
    ;; No refreshing state
    (should (string-match-p "myproject" (opencode-sidebar--group-label item)))))

;;; --- SSE event handler tests ---

(ert-deftest opencode-sidebar-sse-status-busy ()
  "SSE session.status(busy) updates the status store."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs nil)
    (setq-local opencode-sidebar--refresh-timer nil)
    ;; Stub debounce to avoid timer issues in tests
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "session.status"
             :properties (list :sessionID "ses_1"
                               :status (list :type "busy"))
             :directory "/proj")))
    (should (eq 'busy (gethash "ses_1" opencode-sidebar--status-store)))))

(ert-deftest opencode-sidebar-sse-question-asked ()
  "SSE question.asked updates the status store to question."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs nil)
    (setq-local opencode-sidebar--refresh-timer nil)
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "question.asked"
             :properties (list :sessionID "ses_1")
             :directory "/proj")))
    (should (eq 'question (gethash "ses_1" opencode-sidebar--status-store)))))

(ert-deftest opencode-sidebar-sse-permission-asked ()
  "SSE permission.asked updates the status store to permission."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs nil)
    (setq-local opencode-sidebar--refresh-timer nil)
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "permission.asked"
             :properties (list :sessionID "ses_1")
             :directory "/proj")))
    (should (eq 'permission (gethash "ses_1" opencode-sidebar--status-store)))))

(ert-deftest opencode-sidebar-sse-question-replied-back-to-busy ()
  "SSE question.replied sets status back to busy."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs nil)
    (setq-local opencode-sidebar--refresh-timer nil)
    (puthash "ses_1" 'question opencode-sidebar--status-store)
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "question.replied"
             :properties (list :sessionID "ses_1")
             :directory "/proj")))
    (should (eq 'busy (gethash "ses_1" opencode-sidebar--status-store)))))

(ert-deftest opencode-sidebar-sse-idle ()
  "SSE session.idle sets status to idle."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs nil)
    (setq-local opencode-sidebar--refresh-timer nil)
    (puthash "ses_1" 'busy opencode-sidebar--status-store)
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "session.idle"
             :properties (list :sessionID "ses_1")
             :directory "/proj")))
    (should (eq 'idle (gethash "ses_1" opencode-sidebar--status-store)))))

(ert-deftest opencode-sidebar-sse-discovers-new-project ()
  "SSE event from unknown directory adds it to known project dirs."
  (with-temp-buffer
    (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
    (setq-local opencode-sidebar--known-project-dirs '("/proj"))
    (setq-local opencode-sidebar--refresh-timer nil)
    (cl-letf (((symbol-function 'opencode--debounce) #'ignore)
              ((symbol-function 'opencode-api-cache-project-sessions) (lambda (&rest _) nil)))
      (opencode-sidebar--on-session-event
       (list :type "session.updated"
             :properties (list :info (list :id "ses_2"))
             :directory "/other-proj")))
    (should (member "/other-proj" opencode-sidebar--known-project-dirs))))

;;; --- Project session cache tests ---

(ert-deftest opencode-sidebar-cache-get-put ()
  "Can put and get project sessions in the cache."
  (let ((opencode-api-cache--project-sessions (make-hash-table :test 'equal)))
    (should-not (opencode-api-cache-project-sessions "/proj" :cache t))
    (opencode-api-cache-put-project-sessions "/proj" [(:id "ses_1")])
    (should (opencode-api-cache-project-sessions "/proj" :cache t))
    (opencode-api-cache-invalidate-project-sessions "/proj")
    (should-not (opencode-api-cache-project-sessions "/proj" :cache t))))

;;; --- Build helpers tests ---

(ert-deftest opencode-sidebar-build-file-children ()
  "Builds file children from diff entries."
  (let ((children (opencode-sidebar--build-file-children
                   "ses_1"
                   (list (list :file "foo.el" :additions 5 :deletions 2 :status "modified")
                         (list :file "bar.el" :additions 10 :deletions 0 :status "added")))))
    (should (= 2 (length children)))
    (should (equal "ses_1/foo.el" (plist-get (car children) :key)))
    (should (equal "foo.el" (plist-get (car children) :file-path)))
    (should (equal "modified" (plist-get (car children) :status)))))


;;; --- Subagent children tests ---

(ert-deftest opencode-sidebar-build-subagent-children-filters-by-parent ()
  "Subagent children builder returns only sessions matching parentID."
  (let ((opencode-api-cache--project-sessions (make-hash-table :test 'equal)))
    (opencode-api-cache-put-project-sessions
     "/proj"
     [(:id "ses_parent" :title "Parent" :directory "/proj")
      (:id "ses_child1" :title "Child 1" :parentID "ses_parent" :directory "/proj")
      (:id "ses_child2" :title "Child 2" :parentID "ses_parent" :directory "/proj")
      (:id "ses_other_child" :title "Other Child" :parentID "ses_other" :directory "/proj")])
    (cl-letf (((symbol-function 'opencode-api-get-sync)
               (lambda (_path &optional _params)
                 (opencode-api-cache-project-sessions "/proj" :cache t))))
      (let ((children (opencode-sidebar--build-subagent-children "ses_parent" "/proj")))
        (should (= 2 (length children)))
        (should (equal "ses_child1" (plist-get (car children) :session-id)))
        (should (equal "ses_child2" (plist-get (cadr children) :session-id)))))))


;;; --- next-buffer / previous-buffer cycling ---

(ert-deftest opencode-sidebar-buffer-name-is-internal ()
  "The sidebar buffer name must start with a space.
Buffers whose name starts with a space are internal and Emacs's
`next-buffer'/`previous-buffer' commands skip them automatically.
This is the same trick treemacs uses (treemacs--buffer-name-prefix
is \" *Treemacs-\")."
  (should (eq ?\s (aref opencode-sidebar--buffer-name 0))))

(ert-deftest opencode-sidebar-next-buffer-skips-sidebar ()
  "`next-buffer'/`previous-buffer' must never land on the sidebar buffer."
  (let* ((sidebar  (get-buffer-create opencode-sidebar--buffer-name))
         (normal-a (generate-new-buffer "*opencode-test-normal-a*"))
         (normal-b (generate-new-buffer "*opencode-test-normal-b*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer normal-a)
          ;; Make sidebar part of this window's prev-buffers history so it
          ;; would be a candidate for cycling if it weren't internal.
          (switch-to-buffer sidebar)
          (switch-to-buffer normal-b)
          (dotimes (_ 6)
            (previous-buffer)
            (should-not (eq (current-buffer) sidebar)))
          (dotimes (_ 6)
            (next-buffer)
            (should-not (eq (current-buffer) sidebar))))
      (kill-buffer normal-a)
      (kill-buffer normal-b)
      (when (buffer-live-p sidebar) (kill-buffer sidebar)))))

;;; --- Split-window session open ---

(ert-deftest opencode-sidebar-open-in-split-right ()
  "`opencode-sidebar-open-vsplit' splits the main window to the right
and opens the session in the new split.
Why this matters: users compare two sessions side-by-side via `o v';
the new window must be created as a child of the main window (not the
sidebar), and the session must open in the new child."
  (let ((opened-session nil)
        (opened-dir nil))
    ;; Stub opencode-chat-open so we don't actually hit the server.
    (cl-letf (((symbol-function 'opencode-chat-open)
               (lambda (session-id &optional directory &rest _)
                 (setq opened-session session-id opened-dir directory)
                 ;; Simulate switching to a chat buffer in the current window.
                 (switch-to-buffer (get-buffer-create
                                    (format "*opencode: chat %s*" session-id)))))
              ;; Stub node-at-point to return an item plist.
              ((symbol-function 'opencode-sidebar--node-at-point)
               (lambda ()
                 (let ((node (make-marker)))
                   (set-marker node (point))
                   ;; button-get needs a fake button; use text properties.
                   (put-text-property
                    (point) (point-max) :item
                    (list :session-id "ses_split_test"
                          :title "Split Test"
                          :project-dir "/tmp/split-test"))
                   node)))
              ((symbol-function 'button-get)
               (lambda (_btn _key)
                 (list :session-id "ses_split_test"
                       :title "Split Test"
                       :project-dir "/tmp/split-test"))))
      (save-window-excursion
        (let ((chat-buf (get-buffer-create "*opencode-test-split-chat*"))
              (side-buf (get-buffer-create "*opencode-test-split-sidebar*")))
          (unwind-protect
              (progn
                ;; Lay out: chat | sidebar
                (delete-other-windows)
                (switch-to-buffer chat-buf)
                (split-window-right)
                (other-window 1)
                (switch-to-buffer side-buf)
                ;; Precondition: 2 windows.
                (should (= 2 (length (window-list nil 'no-minibuffer))))
                ;; Invoke the split-open from the sidebar window.
                (opencode-sidebar-open-vsplit)
                ;; Post: 3 windows (chat | chat-split | sidebar).
                (should (= 3 (length (window-list nil 'no-minibuffer))))
                ;; The session was opened with the right ID and directory.
                (should (equal opened-session "ses_split_test"))
                (should (equal opened-dir "/tmp/split-test")))
            (when (buffer-live-p chat-buf) (kill-buffer chat-buf))
            (when (buffer-live-p side-buf) (kill-buffer side-buf))
            (when-let ((b (get-buffer "*opencode: chat ses_split_test*")))
              (kill-buffer b))))))))

(provide 'opencode-sidebar-test)
;;; opencode-sidebar-test.el ends here
