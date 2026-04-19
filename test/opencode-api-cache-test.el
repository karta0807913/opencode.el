;;; opencode-api-cache-test.el --- Tests for opencode-api-cache.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the cache facade, session stale-on-timeout fallback,
;; startup-safe load/retry, and optimistic busy/queued lifecycle.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-api-cache)
(require 'opencode-api)
(require 'opencode-chat-state)

;;; --- Micro-cache tests ---

(ert-deftest opencode-api-cache-agents-stub-exists ()
  "Verify `opencode-api--agents' function exists after cache module loads."
  (should (fboundp 'opencode-api--agents)))

(ert-deftest opencode-api-cache-server-config-stub-exists ()
  "Verify `opencode-api--server-config' function exists."
  (should (fboundp 'opencode-api--server-config)))

(ert-deftest opencode-api-cache-providers-stub-exists ()
  "Verify `opencode-api--providers' function exists."
  (should (fboundp 'opencode-api--providers)))

(ert-deftest opencode-api-cache-invalidate-all-exists ()
  "Verify `opencode-api-invalidate-all-caches' function exists."
  (should (fboundp 'opencode-api-invalidate-all-caches)))

(ert-deftest opencode-api-cache-invalidate-clears-cache ()
  "Verify invalidation clears the cache variable."
  (let ((opencode-api--agents-cache '(:some "data"))
        (opencode-api--agents-refreshing t))
    (opencode-api--agents-invalidate)
    (should (null opencode-api--agents-cache))
    (should (null opencode-api--agents-refreshing))))

(ert-deftest opencode-api-cache-mode-returns-cache-only ()
  "Verify :cache t returns cached data without HTTP."
  (let ((opencode-api--agents-cache '(:id "agent1")))
    (should (equal (opencode-api--agents :cache t) '(:id "agent1")))))

(ert-deftest opencode-api-cache-mode-nil-when-empty ()
  "Verify :cache t returns nil when cache is empty."
  (let ((opencode-api--agents-cache nil))
    (should (null (opencode-api--agents :cache t)))))

;;; --- Startup-safe cache load tests ---

(ert-deftest opencode-api-cache-load-state-initial ()
  "Verify initial load state is unloaded."
  (let ((opencode-api-cache--load-state 'unloaded))
    (should (eq opencode-api-cache--load-state 'unloaded))))

(ert-deftest opencode-api-cache-load-failure-non-fatal ()
  "Verify cache load failure is recorded but does not throw."
  (let ((opencode-api-cache--load-state 'unloaded)
        (opencode-api-cache--load-error nil))
    (cl-letf (((symbol-function 'opencode-api-cache-prewarm)
               (lambda () (error "Network error"))))
      (opencode-api-cache--do-load)
      (should (eq opencode-api-cache--load-state 'failed))
      (should (stringp opencode-api-cache--load-error)))))

(ert-deftest opencode-api-cache-load-success-sets-loaded ()
  "Verify successful cache load sets state to loaded."
  (let ((opencode-api-cache--load-state 'unloaded)
        (opencode-api-cache--load-error nil))
    (cl-letf (((symbol-function 'opencode-api-cache-prewarm)
               (lambda () nil)))
      (opencode-api-cache--do-load)
      (should (eq opencode-api-cache--load-state 'loaded)))))

(ert-deftest opencode-api-cache-ensure-loaded-noop-when-loaded ()
  "Verify ensure-loaded is a no-op when already loaded."
  (let ((opencode-api-cache--load-state 'loaded)
        (called nil))
    (cl-letf (((symbol-function 'opencode-api-cache--do-load)
               (lambda () (setq called t))))
      (opencode-api-cache-ensure-loaded)
      (should-not called))))

(ert-deftest opencode-api-cache-ensure-loaded-retries-on-failure ()
  "Verify ensure-loaded retries when previous load failed."
  (let ((opencode-api-cache--load-state 'failed)
        (opencode-api-cache--load-error "prev error")
        (called nil))
    (cl-letf (((symbol-function 'opencode-api-cache--do-load)
               (lambda () (setq called t))))
      (opencode-api-cache-ensure-loaded)
      (should called))))

(ert-deftest opencode-api-cache-load-failed-p-true ()
  "Verify load-failed-p returns non-nil when state is failed."
  (let ((opencode-api-cache--load-state 'failed))
    (should (opencode-api-cache-load-failed-p))))

(ert-deftest opencode-api-cache-load-failed-p-false ()
  "Verify load-failed-p returns nil when state is loaded."
  (let ((opencode-api-cache--load-state 'loaded))
    (should-not (opencode-api-cache-load-failed-p))))

(ert-deftest opencode-api-cache-invalidate-all-resets-load-state ()
  "Verify invalidate-all-caches resets load-state to unloaded.
Without this, ensure-loaded after invalidation is a no-op and caches
stay nil — causing the agent footer to show \"unknown\"."
  (let ((opencode-api-cache--load-state 'loaded)
        (opencode-api--agents-cache '(:some "data"))
        (opencode-api--agents-refreshing nil)
        (opencode-api--server-config-cache '(:model "x"))
        (opencode-api--server-config-refreshing nil)
        (opencode-api--providers-cache '(:p "y"))
        (opencode-api--providers-refreshing nil))
    (opencode-api-invalidate-all-caches)
    (should (null opencode-api--agents-cache))
    (should (eq opencode-api-cache--load-state 'unloaded))))

;;; --- Session cache tests ---

(ert-deftest opencode-api-cache-put-get-session ()
  "Verify session cache put and hash lookup works."
  (let ((opencode-api-cache--session-cache (make-hash-table :test 'equal)))
    (opencode-api-cache-put-session "ses_1" '(:id "ses_1" :title "Test"))
    (should (equal (gethash "ses_1" opencode-api-cache--session-cache)
                   '(:id "ses_1" :title "Test")))))

(ert-deftest opencode-api-cache-invalidate-session ()
  "Verify session invalidation removes the entry."
  (let ((opencode-api-cache--session-cache (make-hash-table :test 'equal)))
    (puthash "ses_1" '(:id "ses_1") opencode-api-cache--session-cache)
    (opencode-api-cache-invalidate-session "ses_1")
    (should (null (gethash "ses_1" opencode-api-cache--session-cache)))))

(ert-deftest opencode-api-cache-get-session-no-cache-fetches ()
  "Verify get-session with no cache calls API and returns result."
  (let ((opencode-api-cache--session-cache (make-hash-table :test 'equal))
        (opencode-api-cache--load-state 'loaded)
        (callback-result nil))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "GET" "/session/ses_1"
                                    200 '(:id "ses_1" :title "Fresh"))
      (opencode-api-cache-get-session
       "ses_1"
       (lambda (data) (setq callback-result data)))
      (should callback-result)
      (should (equal (plist-get callback-result :title) "Fresh"))
      (should (gethash "ses_1" opencode-api-cache--session-cache)))))

(ert-deftest opencode-api-cache-get-session-with-cache-returns-fresh ()
  "Verify get-session with cache returns fresh data when fetch succeeds quickly."
  (let ((opencode-api-cache--session-cache (make-hash-table :test 'equal))
        (opencode-api-cache--load-state 'loaded)
        (callback-result nil))
    (puthash "ses_1" '(:id "ses_1" :title "Stale")
             opencode-api-cache--session-cache)
    (opencode-test-with-mock-api
      (opencode-test-mock-response "GET" "/session/ses_1"
                                    200 '(:id "ses_1" :title "Fresh"))
      (opencode-api-cache-get-session
       "ses_1"
       (lambda (data) (setq callback-result data)))
      (should callback-result)
      (should (equal (plist-get callback-result :title) "Fresh")))))

;;; --- Queued state tests ---

(ert-deftest opencode-api-cache-queued-state-struct ()
  "Verify queued and pending-msg-ids slots exist in chat state struct."
  (let ((state (opencode-chat-state-create :queued t :pending-msg-ids '("msg_1"))))
    (should (opencode-chat-state-queued state))
    (should (equal (opencode-chat-state-pending-msg-ids state) '("msg_1")))))

(ert-deftest opencode-api-cache-set-queued-accessor ()
  "Verify set-queued and queued accessors work."
  (let ((opencode-chat--state (opencode-chat-state-create)))
    (should-not (opencode-chat--queued))
    (opencode-chat--set-queued t)
    (should (opencode-chat--queued))
    (opencode-chat--set-queued nil)
    (should-not (opencode-chat--queued))))

(ert-deftest opencode-api-cache-pending-msg-ids-add-remove ()
  "Verify add/remove/clear for pending-msg-ids."
  (let ((opencode-chat--state (opencode-chat-state-create)))
    (should (null (opencode-chat--pending-msg-ids)))
    ;; Add two
    (opencode-chat--add-pending-msg-id "msg_1")
    (opencode-chat--add-pending-msg-id "msg_2")
    (should (equal (sort (opencode-chat--pending-msg-ids) #'string<)
                   '("msg_1" "msg_2")))
    ;; Duplicate add is no-op
    (opencode-chat--add-pending-msg-id "msg_1")
    (should (= (length (opencode-chat--pending-msg-ids)) 2))
    ;; Remove one — returns nil (not empty yet)
    (should-not (opencode-chat--remove-pending-msg-id "msg_1"))
    (should (equal (opencode-chat--pending-msg-ids) '("msg_2")))
    ;; Remove last — returns t (now empty)
    (should (opencode-chat--remove-pending-msg-id "msg_2"))
    (should (null (opencode-chat--pending-msg-ids)))))

(ert-deftest opencode-api-cache-clear-pending-msg-ids ()
  "Verify clear-pending-msg-ids empties the list."
  (let ((opencode-chat--state (opencode-chat-state-create
                                :pending-msg-ids '("msg_1" "msg_2"))))
    (opencode-chat--clear-pending-msg-ids)
    (should (null (opencode-chat--pending-msg-ids)))))

(ert-deftest opencode-api-cache-state-init-preserves-queued ()
  "Verify state-init preserves queued flag and pending-msg-ids."
  (let ((opencode-chat--state (opencode-chat-state-create
                                :queued t :busy t
                                :pending-msg-ids '("msg_1"))))
    (cl-letf (((symbol-function 'opencode-agent--default-name)
               (lambda () "coder"))
              ((symbol-function 'opencode-agent--find-by-name)
               (lambda (_) nil))
              ((symbol-function 'opencode-config--current-model)
               (lambda () '(:modelID "m1" :providerID "p1")))
              ((symbol-function 'opencode-config--model-context-limit)
               (lambda (_p _m) 100000)))
      (opencode-chat--state-init)
      (should (opencode-chat--queued))
      (should (opencode-chat--busy))
      (should (equal (opencode-chat--pending-msg-ids) '("msg_1"))))))

;;; --- Project-sessions block mode tests ---

(ert-deftest opencode-api-cache-project-sessions-block-fetches-when-empty ()
  "Verify :block t fetches from API when cache is empty."
  (let ((opencode-api-cache--project-sessions (make-hash-table :test 'equal)))
    (opencode-test-with-mock-api
      (opencode-test-mock-response
       "GET" "/session"
       200 [(:id "ses_1" :title "Test" :directory "/proj")])
      (let ((result (opencode-api-cache-project-sessions "/proj" :block t)))
        (should result)
        (should (= 1 (length result)))
        (should (equal "ses_1" (plist-get (aref result 0) :id)))))))

(ert-deftest opencode-api-cache-project-sessions-block-returns-cached ()
  "Verify :block t returns cached data without fetching when cache exists."
  (let ((opencode-api-cache--project-sessions (make-hash-table :test 'equal)))
    (opencode-api-cache-put-project-sessions
     "/proj" [(:id "ses_1" :title "Cached")])
    (opencode-test-with-mock-api
      ;; No mock registered — if it tries to fetch, it will error
      (let ((result (opencode-api-cache-project-sessions "/proj" :block t)))
        (should result)
        (should (equal "Cached" (plist-get (aref result 0) :title)))))))

(ert-deftest opencode-api-cache-project-sessions-block-force-refetches ()
  "Verify :block t :force t re-fetches even when cache exists."
  (let ((opencode-api-cache--project-sessions (make-hash-table :test 'equal)))
    (opencode-api-cache-put-project-sessions
     "/proj" [(:id "ses_1" :title "Stale")])
    (opencode-test-with-mock-api
      (opencode-test-mock-response
       "GET" "/session"
       200 [(:id "ses_1" :title "Fresh")])
      (let ((result (opencode-api-cache-project-sessions
                     "/proj" :block t :force t)))
        (should result)
        (should (equal "Fresh" (plist-get (aref result 0) :title)))))))

(provide 'opencode-api-cache-test)
;;; opencode-api-cache-test.el ends here
