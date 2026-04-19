;;; opencode-subagent-test.el --- Tests for sub-agent functionality -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for sub-agent (child session) support: helper functions,
;; task tool rendering, session filtering, child buffer behavior,
;; permission bubbling, and navigation.

;;; Code:

(require 'ert)
(require 'opencode-chat)
(require 'opencode-popup)
(require 'opencode-permission)
(require 'opencode-session)
(require 'opencode)
(require 'opencode-scenario-test)
(require 'test-helper)

;;; --- Helper Variables ---
(defvar opencode-question--current nil)
(defvar opencode-permission--current nil)
(defvar opencode-permission--pending nil)
(defvar opencode-question--pending nil)


;;; --- Test Data Helpers ---

(defun opencode-subagent-test--make-session (&optional overrides)
  "Create a test session plist with optional OVERRIDES."
  (let ((session (list :id "ses_parent1"
                       :title "Parent Task"
                       :directory "/home/user/project"
                       :time (list :created 1700000000 :updated 1700000000))))
    (while overrides
      (setq session (plist-put session (pop overrides) (pop overrides))))
    session))

(defun opencode-subagent-test--make-child-session (&optional overrides)
  "Create a test child session plist with :parentID set."
  (opencode-subagent-test--make-session
   (append (list :id "ses_child1" :title "Sub-agent" :parentID "ses_parent1")
           overrides)))

;;; --- Group 1: Helper Functions ---

;;; --- Group 2: Task Tool Rendering ---

;;; --- Group 3: Session Filtering ---

(ert-deftest opencode-subagent-child-sessions-filters-by-parent-id ()
  "Verify child-sessions returns children from /session/:id/children endpoint."
  (let ((child (opencode-subagent-test--make-child-session)))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "GET" "/session/ses_parent1/children" 200
                                   (vector child))
      (let ((children (opencode-chat--child-sessions "ses_parent1")))
        (should (= (length children) 1))
        (should (equal (plist-get (car children) :id) "ses_child1"))))))

;;; --- Group 4: Child Buffer Behavior (Scenario Tests) ---

(ert-deftest opencode-subagent-scenario-streaming ()
  "Subagent streaming: messages render before indicator, buffer is editable."
  (let* ((file (expand-file-name "subagent/streaming-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-subagent-scenario-footer-agent-model ()
  "Subagent footer: state reflects last assistant message's agent/model."
  (let* ((file (expand-file-name "subagent/footer-agent-model-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-subagent-input-area-present ()
  "Child sessions have a working input area and can send messages."
  (opencode-scenario-with-replay
      (concat ":session ses_child_input\n"
              ":parent-id ses_parent_input\n"
              ":directory /tmp/test\n")
    ;; Input area should exist
    (should (markerp (opencode-chat--input-start)))
    ;; Buffer should NOT be read-only
    (should-not buffer-read-only)
    ;; Sub-agent indicator should be present
    (should (save-excursion
              (goto-char (point-min))
              (search-forward "Sub-agent session" nil t)))
    ;; [Parent] button should be present
    (should (save-excursion
              (goto-char (point-min))
              (search-forward "[Parent]" nil t)))))

(ert-deftest opencode-subagent-state-init-agent-default-model ()
  "State-init uses agent's :model field when no message history exists."
  (let ((mock-agents
         [(:name "ultraworker" :mode "primary" :native nil
           :model (:providerID "Gemini" :modelID "gemini-3.1-pro"))]))
    (opencode-scenario-with-replay
        (concat ":session ses_agent_model_test\n"
                ":directory /tmp/test\n")
      ;; Override agent functions to return our mock
      (cl-letf (((symbol-function 'opencode-agent--default-name)
                 (lambda () "ultraworker"))
                ((symbol-function 'opencode-agent--find-by-name)
                 (lambda (name)
                   (when (string= name "ultraworker")
                     (aref mock-agents 0))))
                ;; Agent's model exists on server
                ((symbol-function 'opencode-config--model-info)
                 (lambda (_p _m) '(:name "mock"))))
        ;; Reset state and re-init
        (setq opencode-chat--state nil)
        (opencode-chat--state-init)
        ;; Should resolve to ultraworker's model, not config default
        (should (equal (opencode-chat-state-agent opencode-chat--state) "ultraworker"))
        (should (equal (opencode-chat-state-model-id opencode-chat--state) "gemini-3.1-pro"))
        (should (equal (opencode-chat-state-provider-id opencode-chat--state) "Gemini"))))))

;;; --- Group 4b: State Resolution Fallback Chain ---
;;
;; Resolution priority:
;;   Step 1: message history (last assistant message)
;;   Step 2: agent's default model (:model field on agent definition)
;;   Step 3: config default (opencode-config--current-model)
;;   Step 4: first available provider/model

(ert-deftest opencode-subagent-state-init-messages-param ()
  "Messages parameter: state-init extracts agent/model from last assistant."
  (opencode-scenario-with-replay
      (concat ":session ses_msg_param\n"
              ":directory /tmp/test\n")
    (let ((messages [(:info (:id "m1" :role "user"
                             :time (:created 1700000000)))
                     (:info (:id "m2" :role "assistant"
                             :agent "deep-thinker"
                             :modelID "o3-pro"
                             :providerID "openai"
                             :time (:created 1700000001)))]))
      (setq opencode-chat--state nil)
      (opencode-chat--state-init messages)
      (should (equal (opencode-chat-state-agent opencode-chat--state) "deep-thinker"))
      (should (equal (opencode-chat-state-model-id opencode-chat--state) "o3-pro"))
      (should (equal (opencode-chat-state-provider-id opencode-chat--state) "openai")))))

(ert-deftest opencode-subagent-state-init-step1-existing-state-preserved ()
  "Step 1: existing state (set by SSE handler) is preserved by state-init."
  (opencode-scenario-with-replay
      (concat ":session ses_hist_test\n"
              ":directory /tmp/test\n")
    ;; Simulate SSE handler having set state.agent/model (as on-message-updated does)
    (opencode-chat--state-ensure)
    (opencode-chat--set-agent "deep-thinker")
    (opencode-chat--set-model-id "o3-pro")
    (opencode-chat--set-provider-id "openai")
    ;; Re-init — should preserve the values set above
    (opencode-chat--state-init)
    (should (equal (opencode-chat-state-agent opencode-chat--state) "deep-thinker"))
    (should (equal (opencode-chat-state-model-id opencode-chat--state) "o3-pro"))
    (should (equal (opencode-chat-state-provider-id opencode-chat--state) "openai"))))

(ert-deftest opencode-subagent-state-init-step2-agent-model-wins ()
  "Step 2: agent's :model overrides config default when no messages."
  (opencode-scenario-with-replay
      (concat ":session ses_agent_test\n"
              ":directory /tmp/test\n")
    ;; Agent has :model (Gemini/gemini-3.1-pro).
    ;; Config has anthropic/claude-opus-4-6 (from scenario bootstrap).
    ;; No messages. Agent's model should win over config.
    (cl-letf (((symbol-function 'opencode-agent--default-name)
               (lambda () "ultraworker"))
              ((symbol-function 'opencode-agent--find-by-name)
               (lambda (name)
                 (when (string= name "ultraworker")
                   '(:name "ultraworker" :mode "primary"
                     :model (:providerID "Gemini" :modelID "gemini-3.1-pro")))))
              ;; Agent's model exists on server
              ((symbol-function 'opencode-config--model-info)
               (lambda (_p _m) '(:name "mock"))))
      (setq opencode-chat--state nil)
      (opencode-chat--state-init)
      ;; Agent model wins; config (anthropic/claude-opus-4-6) is NOT used
      (should (equal (opencode-chat-state-agent opencode-chat--state) "ultraworker"))
      (should (equal (opencode-chat-state-model-id opencode-chat--state) "gemini-3.1-pro"))
      (should (equal (opencode-chat-state-provider-id opencode-chat--state) "Gemini")))))

(ert-deftest opencode-subagent-state-init-step3-config-default ()
  "Step 3: config default used when no messages and agent has no :model."
  (opencode-scenario-with-replay
      (concat ":session ses_config_test\n"
              ":directory /tmp/test\n")
    ;; Agent has NO :model field. No messages.
    ;; Config has anthropic/claude-opus-4-6 (from scenario bootstrap).
    (cl-letf (((symbol-function 'opencode-agent--default-name)
               (lambda () "simple-agent"))
              ((symbol-function 'opencode-agent--find-by-name)
               (lambda (name)
                 (when (string= name "simple-agent")
                   '(:name "simple-agent" :mode "primary")))))
      (setq opencode-chat--state nil)
      (opencode-chat--state-init)
      ;; Falls through to config default
      (should (equal (opencode-chat-state-agent opencode-chat--state) "simple-agent"))
      (should (equal (opencode-chat-state-model-id opencode-chat--state) "claude-opus-4-6"))
      (should (equal (opencode-chat-state-provider-id opencode-chat--state) "anthropic")))))

;;; --- Group 4c: Cold-Start Fallback ---
;;
;; state-init cold-start: agent default → agent :model (validated) → config → first

(ert-deftest opencode-subagent-state-init-agent-model-provider-not-found ()
  "Cold start: agent's :model provider not on server — falls to config."
  (opencode-scenario-with-replay
      (concat ":session ses_fb4\n"
              ":directory /tmp/test\n")
    (cl-letf (((symbol-function 'opencode-agent--default-name)
               (lambda () "ultraworker"))
              ((symbol-function 'opencode-agent--find-by-name)
               (lambda (name)
                 (when (string= name "ultraworker")
                   ;; Agent exists but its :model provider is NOT on server
                   '(:name "ultraworker" :mode "primary"
                     :model (:providerID "DeletedProvider"
                             :modelID "deleted-model")))))
              ;; DeletedProvider not on server — model-info returns nil for it
              ((symbol-function 'opencode-config--model-info)
               (lambda (_p _m) nil)))
      (setq opencode-chat--state nil)
      (opencode-chat--state-init)
      ;; Agent: "ultraworker" (found on server)
      ;; Model: agent default invalid → config default
      (should (equal (opencode-chat-state-agent opencode-chat--state) "ultraworker"))
      (should (equal (opencode-chat-state-model-id opencode-chat--state) "claude-opus-4-6"))
      (should (equal (opencode-chat-state-provider-id opencode-chat--state) "anthropic")))))

;;; --- Group 4d: Removed Agent Fallback ---
;;
;; When an agent is removed from the server but still referenced in
;; message history or existing state, state-init should fall back to
;; the default agent rather than keeping the stale name.

(ert-deftest opencode-subagent-state-init-removed-agent-msg-fallback ()
  "Messages with a removed agent should fall back to default agent."
  (opencode-scenario-with-replay
      (concat ":session ses_removed_msg\n"
              ":directory /tmp/test\n")
    ;; Agent cache has only "build" — "Sisyphus (Ultraworker)" was removed
    (let ((opencode-api--agents-cache
           (vector (list :name "build" :description "Default agent"
                         :mode "primary" :hidden :false))))
      (let ((messages [(:info (:id "m1" :role "user"
                               :time (:created 1700000000)))
                       (:info (:id "m2" :role "assistant"
                               :agent "Sisyphus (Ultraworker)"
                               :modelID "gemini-3.1-pro-preview-new"
                               :providerID "Gemini"
                               :time (:created 1700000001)))]))
        (setq opencode-chat--state nil)
        (opencode-chat--state-init messages)
        ;; Should fall back to "build", NOT keep "Sisyphus (Ultraworker)"
        (should (equal (opencode-chat-state-agent opencode-chat--state) "build"))))))

(ert-deftest opencode-subagent-state-init-removed-agent-existing-fallback ()
  "Existing state with a removed agent should fall back to default agent."
  (opencode-scenario-with-replay
      (concat ":session ses_removed_existing\n"
              ":directory /tmp/test\n")
    ;; Agent cache has only "build" — "Sisyphus (Ultraworker)" was removed
    (let ((opencode-api--agents-cache
           (vector (list :name "build" :description "Default agent"
                         :mode "primary" :hidden :false))))
      ;; Simulate SSE handler having previously set the now-removed agent
      (opencode-chat--state-ensure)
      (opencode-chat--set-agent "Sisyphus (Ultraworker)")
      (opencode-chat--set-model-id "gemini-3.1-pro-preview-new")
      (opencode-chat--set-provider-id "Gemini")
      ;; Re-init without messages — should detect stale agent and fall back
      (opencode-chat--state-init)
      ;; Should fall back to "build", NOT keep "Sisyphus (Ultraworker)"
      (should (equal (opencode-chat-state-agent opencode-chat--state) "build")))))

(ert-deftest opencode-subagent-state-init-valid-agent-preserved ()
  "Existing state with a valid agent should be preserved (not reset)."
  (opencode-scenario-with-replay
      (concat ":session ses_valid_agent\n"
              ":directory /tmp/test\n")
    ;; Agent cache has both "build" and "code"
    (let ((opencode-api--agents-cache
           (vector (list :name "build" :description "Default" :mode "primary" :hidden :false)
                   (list :name "code" :description "Coder" :mode "primary" :hidden :false))))
      (opencode-chat--state-ensure)
      (opencode-chat--set-agent "code")
      (opencode-chat--set-model-id "claude-opus-4-6")
      (opencode-chat--set-provider-id "anthropic")
      (opencode-chat--state-init)
      ;; "code" is valid — should be preserved
      (should (equal (opencode-chat-state-agent opencode-chat--state) "code")))))

(ert-deftest opencode-subagent-state-init-nil-cache-trusts-agent ()
  "When agent cache is not yet populated, trust the existing agent name."
  (opencode-scenario-with-replay
      (concat ":session ses_nil_cache\n"
              ":directory /tmp/test\n")
    ;; No agent cache (nil) — startup scenario before prewarm completes
    (let ((opencode-api--agents-cache nil))
      (opencode-chat--state-ensure)
      (opencode-chat--set-agent "deep-thinker")
      (opencode-chat--set-model-id "o3-pro")
      (opencode-chat--set-provider-id "openai")
      (opencode-chat--state-init)
      ;; Can't validate — trust the name
      (should (equal (opencode-chat-state-agent opencode-chat--state) "deep-thinker")))))

;;; --- Group 5: Permission Bubbling ---

(ert-deftest opencode-subagent-union-find-single-level ()
  "find-root-session resolves single child→parent link."
  (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal)))
    (opencode-domain-child-parent-put "ses_child" "ses_root")
    (should (equal (opencode-domain-find-root-session "ses_child") "ses_root"))
    ;; Root returns itself
    (should (equal (opencode-domain-find-root-session "ses_root") "ses_root"))))

(ert-deftest opencode-subagent-union-find-depth3 ()
  "find-root-session walks grandchild→child→root and compresses path."
  (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal)))
    (opencode-domain-child-parent-put "ses_grandchild" "ses_child")
    (opencode-domain-child-parent-put "ses_child" "ses_root")
    ;; Should resolve to root
    (should (equal (opencode-domain-find-root-session "ses_grandchild") "ses_root"))
    ;; Path compression: grandchild now points directly to root
    (should (equal (opencode-domain-child-parent-get "ses_grandchild") "ses_root"))))

(ert-deftest opencode-subagent-union-find-depth4 ()
  "find-root-session handles 4-level chains with full path compression."
  (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal)))
    (opencode-domain-child-parent-put "d" "c")
    (opencode-domain-child-parent-put "c" "b")
    (opencode-domain-child-parent-put "b" "a")
    (should (equal (opencode-domain-find-root-session "d") "a"))
    ;; All intermediates compressed
    (should (equal (opencode-domain-child-parent-get "d") "a"))
    (should (equal (opencode-domain-child-parent-get "c") "a"))
    (should (equal (opencode-domain-child-parent-get "b") "a"))))

(ert-deftest opencode-subagent-depth3-permission-scenario ()
  "Depth-3 permission: grandchild permission routes to root buffer."
  (let* ((file (expand-file-name "subagent/depth3-permission-scenario.txt"
                                 opencode-test--fixtures-dir))
         (results (opencode-scenario-run-file file)))
    (unwind-protect
        (progn
          (should results)
          (dolist (r results)
            (unless (nth 1 r)
              (ert-fail (format "Assertion failed at line %d: %s"
                                (nth 0 r) (nth 2 r))))))
      (when-let* ((buf (get-buffer "*opencode: scenario-replay*")))
        (kill-buffer buf)))))

(ert-deftest opencode-subagent-question-dismiss-no-reshow ()
  "Answering a question purges duplicates from --pending in ALL buffers.
Dual-dispatch queues the same request in both child and root buffers.
Without the purge, cleanup's show-next re-shows the answered question."
  (let ((request '(:id "que_dup_test"
                   :sessionID "ses_dup"
                   :questions [(:question "Pick one"
                                :header "Pick"
                                :options [(:label "A" :description "first")
                                          (:label "B" :description "second")])])))
    ;; Set up: simulate dual-dispatch by putting the request in --pending
    ;; of the CURRENT buffer (the "other" buffer that also got the event)
    (opencode-scenario-with-replay
        (concat ":session ses_dup_root\n"
                ":directory /tmp/dup-test\n"
                ":api POST /question/que_dup_test/reply 200 true\n")
      ;; Manually inject the duplicate into this buffer's pending queue
      ;; (simulates what dual-dispatch does to the "other" buffer)
      (setq opencode-question--pending (list request))
      ;; Now simulate the question being shown and answered in this same buffer
      (setq opencode-question--current request)
      (opencode-question--ensure-selected 2)
      (opencode-question--select-option 1)
      (opencode-question--submit)
      ;; After submit, --current should be nil (dismissed)
      (should-not opencode-question--current)
      ;; --pending should be empty (duplicate purged, NOT re-shown)
      (should-not opencode-question--pending)
      ;; inline popup should NOT be active
      (should-not opencode-popup--inline-p))))

(ert-deftest opencode-subagent-dispatch-popup-event-cycle-guard ()
  "`opencode-event--dispatch-popup' must not infinite-loop on a parent cycle.
When the server returns parentID=A for session A (or A→B→A cycle), the
async retry loop could otherwise recurse forever, growing the stack
and leaking SSE events.  The dispatcher caps depth and bails."
  (let ((dispatch-calls 0))
    (opencode-test-with-mock-api
      ;; Cycle: ses_a → ses_b → ses_a → ...
      (opencode-test-mock-response "GET" "/session/ses_a" 200
                                    (list :id "ses_a" :parentID "ses_b"))
      (opencode-test-mock-response "GET" "/session/ses_b" 200
                                    (list :id "ses_b" :parentID "ses_a"))
      ;; No chat buffer for either session — forces the async walk path.
      ;; Clear the global cache so the walk actually triggers.
      (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal))
            (opencode--chat-registry (make-hash-table :test 'equal)))
        (cl-letf (((symbol-function 'opencode-event--dispatch-to-buffer)
                   (lambda (&rest _) (cl-incf dispatch-calls))))
          ;; This must return quickly without blowing the stack.
          (opencode-event--dispatch-popup
           (lambda (_event) nil)
           (list :type "permission.asked"
                 :properties (list :sessionID "ses_a"
                                   :id "per_cycle_test"))))
        ;; It's fine if it dispatches zero or a bounded number of times;
        ;; the key invariant is that it terminates and does not stack-overflow.
        (should (< dispatch-calls 10))))))

(ert-deftest opencode-subagent-dispatch-popup-event-depth-cap ()
  "`opencode-event--dispatch-popup' caps recursion depth.
Given a deep non-cyclic chain longer than the cap, the walker must
stop before exhausting the stack."
  (opencode-test-with-mock-api
    ;; Build a chain 10 levels deep: ses_0 → ses_1 → ... → ses_9 (no parent).
    (dotimes (i 10)
      (let ((sid (format "ses_%d" i))
            (pid (and (< i 9) (format "ses_%d" (1+ i)))))
        (opencode-test-mock-response
         "GET" (format "/session/%s" sid) 200
         (if pid (list :id sid :parentID pid) (list :id sid)))))
    (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal))
          (opencode--chat-registry (make-hash-table :test 'equal))
          (dispatches 0))
      (cl-letf (((symbol-function 'opencode-event--dispatch-to-buffer)
                 (lambda (&rest _) (cl-incf dispatches))))
        (opencode-event--dispatch-popup
         (lambda (_event) nil)
         (list :type "permission.asked"
               :properties (list :sessionID "ses_0"
                                 :id "per_depth_test"))))
      ;; No chat buffer for any level — nothing should dispatch, and the
      ;; walk must terminate without stack overflow.
      (should (= dispatches 0)))))

(ert-deftest opencode-subagent-set-session-populates-child-parent-cache ()
  "`opencode-chat--set-session' records `:parentID' in the global cache.
Why this matters: before this, the child→parent link was only learned
when a task tool part rendered in the parent buffer.  If the user
opened a child session directly (e.g. via sidebar) and a permission
popup arrived before any task tool part was rendered, dispatch had no
cached parent and fell back to an async HTTP walk."
  (let ((opencode-domain--child-parent-cache (make-hash-table :test 'equal)))
    (opencode-scenario-with-replay
        (concat ":session ses_auto_cache_child\n"
                ":parent-id ses_auto_cache_parent\n"
                ":directory /tmp/auto-cache-test\n")
      ;; Bootstrap sets session with :parentID — auto-populate should fire.
      (should (equal (opencode-domain-child-parent-get
                      "ses_auto_cache_child")
                     "ses_auto_cache_parent")))))

;;; --- Group 6: Navigation ---

(provide 'opencode-subagent-test)

;;; opencode-subagent-test.el ends here
