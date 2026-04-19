;;; opencode-agent-test.el --- Tests for opencode-agent.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the agent management module.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-agent)

;;; --- Cache and list tests ---

(ert-deftest opencode-agent-list-returns-cache ()
  "Agent list returns cached agents."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    (let ((agents (opencode-agent--list)))
      (should (vectorp agents))
      (should (length= agents 3))
      (should (string= (plist-get (aref agents 0) :name) "build"))
      (should (string= (plist-get (aref agents 1) :name) "plan"))
      (should (string= (plist-get (aref agents 2) :name) "Prometheus (Plan Builder)")))))

(ert-deftest opencode-agent-primary-filters ()
  "Primary agent filter returns primary and all-mode agents, excludes hidden and subagent."
  (let ((opencode-api--agents-cache (vector
                                (list :name "build" :mode "primary" :hidden :false)
                                (list :name "plan" :mode "primary" :hidden :false)
                                (list :name "hidden-agent" :mode "primary" :hidden t)
                                (list :name "explore" :mode "subagent" :hidden :false)
                                (list :name "Prometheus (Plan Builder)" :mode "all" :hidden :false))))
    (let ((primary (opencode-agent--primary-agents)))
      (should (length= primary 3))
      (should (string= (plist-get (nth 0 primary) :name) "build"))
      (should (string= (plist-get (nth 1 primary) :name) "plan"))
      (should (string= (plist-get (nth 2 primary) :name) "Prometheus (Plan Builder)")))))

(ert-deftest opencode-agent-cycle-wraps ()
  "Agent cycle advances through primary agents and wraps.
Without this, TAB cycling in the chat buffer breaks — agents either
don't advance or skip entries."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    ;; Cycle from "build" to "plan"
    (should (string= (opencode-agent--cycle "build") "plan"))
    ;; Cycle from "plan" to "Prometheus (Plan Builder)"
    (should (string= (opencode-agent--cycle "plan") "Prometheus (Plan Builder)"))
    ;; Cycle again, should wrap to "build"
    (should (string= (opencode-agent--cycle "Prometheus (Plan Builder)") "build"))))

(ert-deftest opencode-agent-default-name-returns-first-primary ()
  "Default agent name returns the first primary agent from cache.
Without this, new chat buffers with no override get nil agent."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    (should (string= (opencode-agent--default-name) "build")))
  (let ((opencode-api--agents-cache (vector (list :name "plan" :mode "primary" :hidden :false))))
    (should (string= (opencode-agent--default-name) "plan"))))

(ert-deftest opencode-agent-primary-includes-mode-all ()
  "Primary agents include agents with mode=all (e.g. Prometheus (Plan Builder))."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    (let ((primary (opencode-agent--primary-agents)))
      ;; Prometheus (Plan Builder) has mode "all" and should be included
      (should (seq-find (lambda (a) (string= (plist-get a :name) "Prometheus (Plan Builder)"))
                        primary)))))

(ert-deftest opencode-agent-cycle-with-current-name ()
  "Agent cycle respects optional CURRENT-NAME override.
Without this, caller-provided position is ignored and cycle starts
from the wrong agent."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    ;; Cycle from "plan" (override)
    (should (string= (opencode-agent--cycle "plan") "Prometheus (Plan Builder)"))
    ;; Cycle from "Prometheus (Plan Builder)" (override)
    (should (string= (opencode-agent--cycle "Prometheus (Plan Builder)") "build"))))

(ert-deftest opencode-agent-find-by-name ()
  "Find agent by name from cache."
  (let ((opencode-api--agents-cache (opencode-test-fixture "agent-list")))
    (let ((agent (opencode-agent--find-by-name "build")))
      (should agent)
      (should (string= (plist-get agent :name) "build"))
      (should (string= (plist-get agent :color) "#34d399")))
    (let ((agent (opencode-agent--find-by-name "Prometheus (Plan Builder)")))
      (should agent)
      (should (string= (plist-get agent :name) "Prometheus (Plan Builder)")))
    ;; Non-existent
    (should-not (opencode-agent--find-by-name "nonexistent"))
    ;; Direct plist-get for color — no wrapper needed
    (should (string= "#a78bfa" (plist-get (opencode-agent--find-by-name "plan") :color)))
    (should-not (plist-get (opencode-agent--find-by-name "nonexistent") :color))))

(ert-deftest opencode-agent-invalidate-clears-cache ()
  "Invalidate nils out the cache so next access re-fetches."
  (let ((opencode-api--agents-cache (vector (list :name "build"))))
    (opencode-agent-invalidate)
    (should-not opencode-api--agents-cache)))

(provide 'opencode-agent-test)
;;; opencode-agent-test.el ends here
