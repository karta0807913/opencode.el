;;; opencode-sidebar-test.el --- Tests for opencode-sidebar.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for global treemacs-based sidebar panel.
;; Old per-project sidebar tests removed; replaced with group/status tests.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-sidebar)
(require 'opencode-api-cache)
(require 'opencode-pipeline)

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

(ert-deftest opencode-sidebar-project-name-never-empty ()
  "Project display names must never be empty.
The OpenCode `global' project has \"/\" as its worktree, whose basename
is empty.  Treemacs puts the `button' property on the label text alone,
so an empty label yields a node with no button: it cannot be selected
or expanded."
  (should (equal "(global)" (opencode-sidebar--project-name "/")))
  (should (equal "myproject" (opencode-sidebar--project-name "/tmp/myproject/")))
  (should-not (string-empty-p (opencode-sidebar--project-name nil)))
  (should-not (string-empty-p (opencode-sidebar--project-name ""))))

(ert-deftest opencode-sidebar-group-label-root-worktree ()
  "The global project group renders a non-empty, selectable label."
  (let ((item (list :group-name ""
                    :group-type 'project
                    :project-dir "/")))
    (should (equal "(global)" (substring-no-properties
                               (opencode-sidebar--group-label item))))))

(ert-deftest opencode-sidebar-session-label-root-worktree-prefix ()
  "Opened sessions in the global project get a non-empty project prefix."
  (let* ((item (list :title "Global task" :opened t :project-dir "/"))
         (label (substring-no-properties (opencode-sidebar--session-label item))))
    (should (string-match-p "\\[(global)\\]" label))
    (should-not (string-match-p "\\[\\]" label))))

;;; --- Pipeline view tests ---

(defun opencode-sidebar-test--file-string (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file
                                            (file-name-directory
                                             (locate-library "opencode-sidebar"))))
    (buffer-string)))

(ert-deftest opencode-sidebar-boundary-no-direct-chat-registry ()
  "Sidebar production code must use public chat registry accessors."
  (let ((src (opencode-sidebar-test--file-string "opencode-sidebar.el")))
    (should-not (string-match-p "opencode--chat-registry" src))))

(ert-deftest opencode-sidebar-boundary-no-mutable-pipeline-execution-items ()
  "Sidebar items/views must not carry mutable pipeline execution structs."
  (let ((src (opencode-sidebar-test--file-string "opencode-sidebar.el")))
    (should-not (string-match-p ":pipeline-execution\\_>" src))))

(defvar opencode-sidebar-test-pipeline-entry nil)
(defvar opencode-sidebar-test-pipeline-next nil)

(defun opencode-sidebar-test--install-pipeline ()
  "Install a small pipeline for sidebar tests."
  (let* ((next
          (opencode-pipeline-template
           :title "opencode-sidebar-test-pipeline-next"
           :prompt "Verify"))
         (entry
          (opencode-pipeline-template
           :title "opencode-sidebar-test-pipeline-entry"
           :session-id "ses_pipeline_entry"
           :prompt "Implement"
           :next next)))
    (setq opencode-sidebar-test-pipeline-entry entry
          opencode-sidebar-test-pipeline-next next)))

(defun opencode-sidebar-test--pipeline-execution ()
  "Return a runtime execution for sidebar pipeline tests."
  (let ((execution
         (opencode-pipeline-execution--create
          :id "plrun_sidebar"
          :entry-template opencode-sidebar-test-pipeline-entry
          :title "Sidebar Pipeline"
          :directory "/project/"
          :status 'running)))
    (opencode-pipeline--instantiate-nodes execution)
    (let* ((entry-symbol
            (gethash opencode-sidebar-test-pipeline-entry
                     (opencode-pipeline-execution-template-index execution)))
           (next-symbol
            (gethash opencode-sidebar-test-pipeline-next
                     (opencode-pipeline-execution-template-index execution)))
           (entry
            (opencode-pipeline-execution-node execution entry-symbol)))
      (setf (opencode-pipeline-execution-current execution) next-symbol)
      (setf (opencode-pipeline-node-status entry) 'completed
            (opencode-pipeline-node-visit-count entry) 1
            (opencode-pipeline-node-invocation-count entry) 1))
    execution))

(ert-deftest opencode-sidebar-pipeline-execution-items-read-registry ()
  "Pipeline execution rows carry immutable views, not runtime structs."
  (let ((opencode-pipeline--executions (make-hash-table :test 'equal)))
    (opencode-sidebar-test--install-pipeline)
    (let ((execution (opencode-sidebar-test--pipeline-execution)))
      (puthash "plrun_sidebar" execution
               opencode-pipeline--executions)
      (let ((items (opencode-sidebar--pipeline-execution-items)))
        (should (= 1 (length items)))
        (should-not (plist-member (car items) :pipeline-execution))
        (should (equal "plrun_sidebar"
                       (plist-get (car items) :pipeline-execution-id)))
        (should (equal "plrun_sidebar"
                       (plist-get (plist-get (car items) :pipeline-view) :id)))
        (should
         (string-match-p
            "\\[project\\].*Sidebar Pipeline.*running"
            (opencode-sidebar--pipeline-execution-label (car items))))))))

(ert-deftest opencode-sidebar-pipeline-node-items-include-lazy-node ()
  "Pipeline children include both bound and not-yet-created sessions."
  (opencode-sidebar-test--install-pipeline)
  (let* ((execution (opencode-sidebar-test--pipeline-execution))
         (view (opencode-pipeline-view-execution execution))
         (items (opencode-sidebar--pipeline-node-items view)))
    (should (= 2 (length items)))
    (should-not (plist-member (car items) :pipeline-execution))
    (should (equal "ses_pipeline_entry"
                   (plist-get (car items) :session-id)))
    (should-not (plist-get (cadr items) :session-id))
    (should
     (equal "opencode-sidebar-test-pipeline-next"
            (symbol-name (plist-get (cadr items) :pipeline-node))))))

(ert-deftest opencode-sidebar-pipeline-node-keys-include-execution ()
  "Pipeline child keys remain unique across executions of one template."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution-a (opencode-sidebar-test--pipeline-execution))
        (execution-b (opencode-sidebar-test--pipeline-execution)))
    (setf (opencode-pipeline-execution-id execution-b) "plrun_sidebar_b")
    (should-not
     (equal (mapcar (lambda (item) (plist-get item :key))
                    (opencode-sidebar--pipeline-node-items
                     (opencode-pipeline-view-execution execution-a)))
            (mapcar (lambda (item) (plist-get item :key))
                    (opencode-sidebar--pipeline-node-items
                     (opencode-pipeline-view-execution execution-b)))))))

(ert-deftest opencode-sidebar-ret-on-pipeline-opens-status-buffer ()
  "RET on a pipeline execution opens its SVG/text status buffer."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution (opencode-sidebar-test--pipeline-execution))
        (opencode-pipeline--executions (make-hash-table :test 'equal))
        described)
    (puthash "plrun_sidebar" execution opencode-pipeline--executions)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node property)
                 (when (eq property :item)
                    (list :pipeline-view
                          (opencode-pipeline-view-execution execution)
                          :pipeline-execution-id "plrun_sidebar"))))
              ((symbol-function 'opencode-sidebar--find-main-window)
               (lambda () (selected-window)))
              ((symbol-function 'opencode-pipeline-describe)
               (lambda (value) (setq described value))))
      (opencode-sidebar--ret-action)
      (should (eq execution described)))))

(ert-deftest opencode-sidebar-ret-on-pipeline-session-opens-chat ()
  "RET on a bound pipeline node reuses normal session opening."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution (opencode-sidebar-test--pipeline-execution))
        opened described)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node property)
                 (when (eq property :item)
                     (list :pipeline-view
                           (opencode-pipeline-view-execution execution)
                           :pipeline-node 'node
                           :session-id "ses_pipeline"
                          :project-dir "/project"
                          :backend 'opencode))))
              ((symbol-function 'opencode-sidebar--find-main-window)
               (lambda () (selected-window)))
              ((symbol-function 'opencode-pipeline-describe)
               (lambda (&rest _) (setq described t)))
              ((symbol-function 'opencode-chat-open)
               (lambda (session-id directory display-action backend)
                 (setq opened
                       (list session-id directory display-action backend)))))
      (opencode-sidebar--ret-action)
      (should
       (equal '("ses_pipeline" "/project" nil opencode) opened))
      (should-not described))))

(ert-deftest opencode-sidebar-delete-pipeline-execution-resets-only-run ()
  "The `d' command removes a terminal pipeline execution."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution (opencode-sidebar-test--pipeline-execution))
        (opencode-pipeline--executions (make-hash-table :test 'equal))
        reset rerendered)
    (setf (opencode-pipeline-execution-status execution) 'failed)
    (puthash "plrun_sidebar" execution opencode-pipeline--executions)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node property)
                 (when (eq property :item)
                    (list :pipeline-view
                          (opencode-pipeline-view-execution execution)
                          :pipeline-execution-id "plrun_sidebar"))))
              ((symbol-function 'opencode-pipeline-reset)
               (lambda (value) (setq reset value)))
              ((symbol-function 'opencode-sidebar--rerender)
               (lambda () (setq rerendered t))))
      (opencode-sidebar--delete-or-close)
      (should (eq execution reset))
      (should rerendered))))

(ert-deftest opencode-sidebar-delete-running-pipeline-refuses ()
  "The `d' command refuses to hide a running pipeline."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution (opencode-sidebar-test--pipeline-execution))
        (opencode-pipeline--executions (make-hash-table :test 'equal))
        reset)
    (puthash "plrun_sidebar" execution opencode-pipeline--executions)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node property)
                 (when (eq property :item)
                    (list :pipeline-view
                          (opencode-pipeline-view-execution execution)
                          :pipeline-execution-id "plrun_sidebar"))))
              ((symbol-function 'opencode-pipeline-reset)
               (lambda (value) (setq reset value))))
      (should-error (opencode-sidebar--delete-or-close)
                    :type 'user-error)
      (should-not reset))))

(ert-deftest opencode-sidebar-delete-pipeline-child-is-noop ()
  "The `d' command on a pipeline child never deletes its session."
  (opencode-sidebar-test--install-pipeline)
  (let ((execution (opencode-sidebar-test--pipeline-execution))
        deleted killed reset)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node property)
                 (when (eq property :item)
                     (list :pipeline-view
                           (opencode-pipeline-view-execution execution)
                           :pipeline-node 'verify
                           :session-id "ses_verify"))))
              ((symbol-function 'opencode-pipeline-reset)
               (lambda (&rest _) (setq reset t)))
              ((symbol-function 'opencode-sidebar--delete-session-impl)
               (lambda (_item) (setq deleted t)))
              ((symbol-function 'kill-buffer)
               (lambda (&rest _) (setq killed t))))
      (opencode-sidebar--delete-or-close)
      (should-not deleted)
      (should-not killed)
      (should-not reset))))

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

;;; --- Create session tests ---

(ert-deftest opencode-sidebar-project-candidates-use-worktree ()
  "Project completion candidates consume canonical backend projects."
  (let ((candidates
         (opencode-sidebar--project-candidates
          [(:id "prj_a" :name "Project A" :directory "/tmp/project-a")
           (:id "prj_b" :directory "/tmp/project-b")
           (:id "prj_duplicate" :directory "/tmp/project-a")
           (:id "prj_missing")])))
    (should (= 2 (length candidates)))
    (should (equal "/tmp/project-a" (cdar candidates)))
    (should (string-match-p "Project A.*prj_a" (caar candidates)))
    (should (equal "/tmp/project-b" (cdadr candidates)))))

(ert-deftest opencode-sidebar-read-project-returns-selected-worktree ()
  "Project picker uses backend projects and returns the selected directory."
  (let (requested-backend)
    (cl-letf (((symbol-function 'opencode-backend-supports-p)
               (lambda (operation backend)
                 (and (eq operation 'list-projects)
                      (eq backend 'opencode))))
              ((symbol-function 'opencode-backend-list-projects)
               (lambda (&optional backend)
                 (setq requested-backend backend)
                 [(:id "prj_a" :directory "/tmp/project-a")
                  (:id "prj_b" :directory "/tmp/project-b")]))
              ((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (car (rassoc "/tmp/project-b" candidates)))))
      (should (equal "/tmp/project-b" (opencode-sidebar--read-project)))
      (should (eq 'opencode requested-backend)))))

(ert-deftest opencode-sidebar-read-project-errors-when-empty ()
  "Project picker reports when the server has no usable projects."
  (cl-letf (((symbol-function 'opencode-backend-supports-p)
             (lambda (&rest _) t))
            ((symbol-function 'opencode-backend-list-projects)
             (lambda (&rest _) [])))
    (should-error (opencode-sidebar--read-project) :type 'user-error)))

(ert-deftest opencode-sidebar-new-session-reuses-project-helper ()
  "Lowercase `c' delegates its node project to the shared creation helper."
  (let (created-in)
    (cl-letf (((symbol-function 'opencode-sidebar--node-at-point)
               (lambda () 'node))
              ((symbol-function 'button-get)
               (lambda (_node _property)
                 '(:project-dir "/tmp/project-a")))
              ((symbol-function 'opencode-sidebar--new-session-in-project)
               (lambda (dir) (setq created-in dir))))
      (opencode-sidebar--new-session)
      (should (equal "/tmp/project-a" created-in)))))

(ert-deftest opencode-sidebar-new-session-in-project-preserves-title-flow ()
  "Shared creation helper binds the project and treats an empty title as nil."
  (let (created-title created-dir created-backend
        opened-id opened-dir opened-backend invalidated-dir sidebar-buf)
    (save-window-excursion
      (with-temp-buffer
        (setq sidebar-buf (current-buffer))
        (setq-local opencode-sidebar--known-project-dirs nil)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) ""))
                  ((symbol-function 'opencode--ensure-ready) #'ignore)
                  ((symbol-function 'opencode-session-create)
                   (lambda (&optional title _parent-id backend)
                     (setq created-title title
                           created-dir opencode-default-directory
                           created-backend backend)
                     '(:id "ses_new")))
                  ((symbol-function
                    'opencode-backend-invalidate-project-sessions)
                   (lambda (dir &optional backend)
                     (should (eq backend 'opencode))
                     (setq invalidated-dir dir)))
                  ((symbol-function 'opencode-sidebar--find-main-window)
                   (lambda () (selected-window)))
                  ((symbol-function 'opencode-chat-open)
                   (lambda (session-id &optional directory
                                       _display-action backend)
                     (setq opened-id session-id
                           opened-dir directory
                           opened-backend backend)))
                  ((symbol-function 'opencode-sidebar--rerender) #'ignore))
          (opencode-sidebar--new-session-in-project
           "/tmp/project-a/" 'opencode)
          (should-not created-title)
          (should (equal "/tmp/project-a" created-dir))
          (should (eq 'opencode created-backend))
          (should (equal "ses_new" opened-id))
          (should (equal "/tmp/project-a" opened-dir))
          (should (eq 'opencode opened-backend))
          (should (equal "/tmp/project-a" invalidated-dir))
          (with-current-buffer sidebar-buf
            (should (member "/tmp/project-a"
                            opencode-sidebar--known-project-dirs))))))))

(ert-deftest opencode-sidebar-chat-choose-project-delegates ()
  "Uppercase `C' runs the project chat picker in the main window."
  (save-window-excursion
    (let ((sidebar-buf (generate-new-buffer " *opencode-test-sidebar*"))
          (main-buf (generate-new-buffer " *opencode-test-main*"))
          (chat-buf (generate-new-buffer " *opencode-test-chat*"))
          (ready-count 0)
          picker-args
          picker-window)
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer main-buf)
            (let ((main-win (selected-window))
                  (sidebar-win (split-window-right)))
              (select-window sidebar-win)
              (switch-to-buffer sidebar-buf)
              (setq-local opencode-sidebar--last-main-window main-win)
              (cl-letf (((symbol-function 'opencode--ensure-ready)
                         (lambda () (cl-incf ready-count)))
                        ((symbol-function 'opencode-sidebar--read-project)
                         (lambda ()
                           (should (= ready-count 1))
                           "/tmp/project-b"))
                        ((symbol-function 'opencode--open-chat-picker)
                         (lambda (&optional session-id backend directory)
                           (setq picker-args
                                 (list session-id backend directory)
                                 picker-window (selected-window))
                           (switch-to-buffer chat-buf))))
                (opencode-sidebar--chat-choose-project))
              (should (= ready-count 1))
              (should (equal picker-args
                             '(nil opencode "/tmp/project-b")))
              (should (eq picker-window main-win))
              (should (eq (window-buffer main-win) chat-buf))
              (should (eq (window-buffer sidebar-win) sidebar-buf))))
        (dolist (buf (list sidebar-buf main-buf chat-buf))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest opencode-sidebar-chat-choose-project-quit-restores-sidebar ()
  "Cancelling the project chat picker restores focus to the sidebar."
  (save-window-excursion
    (let ((sidebar-buf (generate-new-buffer " *opencode-test-sidebar*"))
          (main-buf (generate-new-buffer " *opencode-test-main*")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer main-buf)
            (let ((main-win (selected-window))
                  (sidebar-win (split-window-right)))
              (select-window sidebar-win)
              (switch-to-buffer sidebar-buf)
              (setq-local opencode-sidebar--last-main-window main-win)
              (let ((quit-signaled nil))
                (cl-letf (((symbol-function 'opencode--ensure-ready) #'ignore)
                          ((symbol-function 'opencode-sidebar--read-project)
                           (lambda () "/tmp/project-b"))
                          ((symbol-function 'opencode--open-chat-picker)
                           (lambda (&rest _) (signal 'quit nil))))
                  (condition-case nil
                      (opencode-sidebar--chat-choose-project)
                    (quit (setq quit-signaled t))))
                (should quit-signaled))
              (should (eq (selected-window) sidebar-win))
              (should (eq (window-buffer main-win) main-buf))
              (should (eq (window-buffer sidebar-win) sidebar-buf))))
        (dolist (buf (list sidebar-buf main-buf))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest opencode-sidebar-keymap-binds-project-session-command ()
  "Uppercase `C' opens the choose-project chat picker flow."
  (should
   (eq (keymap-lookup opencode-sidebar--extra-map "C")
       #'opencode-sidebar--chat-choose-project)))

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
  (let ((sessions
         [(:id "ses_parent" :title "Parent" :directory "/proj")
          (:id "ses_child1" :title "Child 1" :parentID "ses_parent"
           :directory "/proj")
          (:id "ses_child2" :title "Child 2" :parentID "ses_parent"
           :directory "/proj")
          (:id "ses_other_child" :title "Other Child" :parentID "ses_other"
           :directory "/proj")]))
    (cl-letf (((symbol-function 'opencode-backend-cached-project-sessions)
               (lambda (project-dir &optional backend)
                 (should (equal project-dir "/proj"))
                 (should (eq backend 'opencode))
                 sessions)))
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

(ert-deftest opencode-sidebar-find-main-window-prefers-remembered-window ()
  "RET from the sidebar must open in the window that invoked the sidebar.
Without the remembered main window, Emacs picks the leftmost non-sidebar
window and opens chats in the wrong pane when multiple main windows exist."
  (save-window-excursion
    (let ((sidebar-buf (get-buffer-create opencode-sidebar--buffer-name))
          (main-a (generate-new-buffer "*opencode-test-main-a*"))
          (main-b (generate-new-buffer "*opencode-test-main-b*")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer sidebar-buf)
            (split-window-right)
            (other-window 1)
            (switch-to-buffer main-a)
            (split-window-right)
            (other-window 1)
            (switch-to-buffer main-b)
            (let ((target (selected-window)))
              (with-current-buffer sidebar-buf
                (setq opencode-sidebar--last-main-window target)
                (should (eq (opencode-sidebar--find-main-window) target)))))
        (when (buffer-live-p sidebar-buf) (kill-buffer sidebar-buf))
        (when (buffer-live-p main-a) (kill-buffer main-a))
        (when (buffer-live-p main-b) (kill-buffer main-b))))))

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
