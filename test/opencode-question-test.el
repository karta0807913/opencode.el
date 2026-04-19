;;; opencode-question-test.el --- Tests for opencode-question.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the opencode-question module.

;;; Code:

(require 'ert)
(require 'opencode-question)
(require 'opencode-chat)
(require 'test-helper)

;;; --- Test fixtures ---

(defun opencode-question-test--make-request (&optional overrides)
  "Create a question request plist with optional OVERRIDES.
Returns a plist matching the `question.asked' SSE event properties."
  (let ((base (list :id "question_xyz789"
                    :sessionID "ses_a1b2c3"
                    :questions (vector
                                (list :header "Database Choice"
                                      :question "Which database should I use?"
                                      :options (vector
                                                (list :label "PostgreSQL"
                                                      :description "Full-featured relational database")
                                                (list :label "SQLite"
                                                      :description "Lightweight embedded database")
                                                (list :label "MySQL"
                                                      :description "Popular open-source relational database"))
                                      :multiple :false
                                      :custom t)))))
    (if overrides
        (let ((result (copy-sequence base)))
          (while overrides
            (plist-put result (pop overrides) (pop overrides)))
          result)
      base)))

(defun opencode-question-test--make-multi-request ()
  "Create a multi-question request plist."
  (list :id "question_multi"
        :sessionID "ses_multi"
        :questions (vector
                    (list :header "Database Choice"
                          :question "Which database?"
                          :options (vector
                                    (list :label "PostgreSQL"
                                          :description "Relational")
                                    (list :label "SQLite"
                                          :description "Embedded"))
                          :multiple :false
                          :custom :false)
                    (list :header "Cache Choice"
                          :question "Which cache?"
                          :options (vector
                                    (list :label "Redis"
                                          :description "In-memory store")
                                    (list :label "Memcached"
                                          :description "Distributed cache"))
                          :multiple :false
                          :custom :false))))

;;; --- Test: Popup renders ---

(ert-deftest opencode-question-popup-renders ()
  "Verify that the question popup renders header, question, and options."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Verify header
      (should (opencode-test-buffer-contains-p "Database Choice"))
      ;; Verify question text
      (should (opencode-test-buffer-contains-p "Which database should I use?"))
      ;; Verify options
      (should (opencode-test-buffer-contains-p "PostgreSQL"))
      (should (opencode-test-buffer-contains-p "SQLite"))
      (should (opencode-test-buffer-contains-p "MySQL"))
      ;; Verify descriptions
      (should (opencode-test-buffer-contains-p "Full-featured relational database"))
      ;; Verify key hints
      (should (opencode-test-buffer-contains-p "Submit"))
      (should (opencode-test-buffer-contains-p "Reject")))))

;;; --- Test: Single select ---

(ert-deftest opencode-question-single-select ()
  "Verify that single-select mode deselects previous when selecting new."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Select option 1
      (opencode-question--select-option 1)
      (should (eq (aref opencode-question--selected 0) t))
      ;; Select option 2 — should deselect option 1
      (opencode-question--select-option 2)
      (should (eq (aref opencode-question--selected 0) nil))
      (should (eq (aref opencode-question--selected 1) t))
      ;; Verify rendered indicator
      (should (opencode-test-buffer-contains-p "●"))
      (should (opencode-test-buffer-contains-p "○")))))

;;; --- Test: Multi select ---

(ert-deftest opencode-question-multi-select ()
  "Verify that multi-select mode allows toggling multiple options."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      ;; Create a multi-select question
      (setq opencode-question--current
            (list :id "question_multi"
                  :sessionID "ses_test"
                  :questions (vector
                              (list :header "Features"
                                    :question "Select features"
                                    :options (vector
                                              (list :label "Auth" :description "Authentication")
                                              (list :label "API" :description "REST API")
                                              (list :label "DB" :description "Database"))
                                    :multiple t
                                    :custom :false))))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Select options 1 and 3
      (opencode-question--select-option 1)
      (opencode-question--select-option 3)
      (should (eq (aref opencode-question--selected 0) t))
      (should (eq (aref opencode-question--selected 1) nil))
      (should (eq (aref opencode-question--selected 2) t))
      ;; Toggle option 1 off
      (opencode-question--select-option 1)
      (should (eq (aref opencode-question--selected 0) nil))
      (should (eq (aref opencode-question--selected 2) t)))))

;;; --- Test: Custom answer ---

(ert-deftest opencode-question-custom-answer ()
  "Verify that custom answer is stored and deselects options."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Select option 1 first
      (opencode-question--select-option 1)
      (should (eq (aref opencode-question--selected 0) t))
      ;; Now enter custom answer (mock read-string)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &rest _) "MongoDB")))
        (opencode-question--select-custom))
      ;; Custom text should be set
      (should (equal opencode-question--custom-text "MongoDB"))
      ;; Options should be deselected
      (should (eq (aref opencode-question--selected 0) nil))
      (should (eq (aref opencode-question--selected 1) nil))
      ;; Buffer should show custom text
      (should (opencode-test-buffer-contains-p "Custom: MongoDB")))))

;;; --- Test: Reply format ---

(ert-deftest opencode-question-reply-format ()
  "Verify that submit sends correct reply format to the API."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "POST" "/question/question_xyz789/reply" 200 t)
      (opencode-test-with-temp-buffer "*opencode: question*"
        (opencode-question-mode)
        (setq opencode-question--current (opencode-question-test--make-request))
        (setq opencode-question--question-idx 0)
        (setq opencode-question--answers nil)
        (opencode-question--render-question)
        ;; Select PostgreSQL
        (opencode-question--select-option 1)
        ;; Submit
        (opencode-question--submit)
        ;; Verify the POST was made
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (equal (nth 0 req) "POST"))
          (should (equal (nth 1 req) "/question/question_xyz789/reply"))
          ;; Verify body contains answers
          (let ((body (nth 3 req)))
            (should body)
            (should (equal (plist-get body :answers)
                            [["PostgreSQL"]]))))))))


;;; --- Test: Reject ---

(ert-deftest opencode-question-reject ()
  "Verify that reject sends POST to /question/:id/reject."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "POST" "/question/question_xyz789/reject" 200 t)
      (opencode-test-with-temp-buffer "*opencode: question*"
        (opencode-question-mode)
        (setq opencode-question--current (opencode-question-test--make-request))
        (setq opencode-question--question-idx 0)
        (setq opencode-question--answers nil)
        (opencode-question--render-question)
        ;; Reject
        (opencode-question--reject)
        ;; Verify the POST was made
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (equal (nth 0 req) "POST"))
          (should (equal (nth 1 req) "/question/question_xyz789/reject")))
        ;; Current should be cleared
        (should (null opencode-question--current))))))

;;; --- Test: Reject with message ---

(ert-deftest opencode-question-reject-with-message ()
  "Verify that reject-with-message sends POST with :message body."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "POST" "/question/question_xyz789/reject" 200 t)
      (opencode-test-with-temp-buffer "*opencode: question*"
        (opencode-question-mode)
        (setq opencode-question--current (opencode-question-test--make-request))
        (setq opencode-question--question-idx 0)
        (setq opencode-question--answers nil)
        (opencode-question--render-question)
        ;; Reject with message (mock read-string)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt &rest _) "Not relevant to my project")))
          (opencode-question--reject-with-message))
        ;; Verify the POST was made with message body
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (equal (nth 0 req) "POST"))
          (should (equal (nth 1 req) "/question/question_xyz789/reject"))
          (let ((body (nth 3 req)))
            (should body)
            (should (equal (plist-get body :message) "Not relevant to my project"))))
        ;; Current should be cleared
        (should (null opencode-question--current))))))

;;; --- Test: Multi-question stepping ---

(ert-deftest opencode-question-multi-question-step ()
  "Verify stepping through multiple questions and combined reply."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-mock-api
      (opencode-test-mock-response "POST" "/question/question_multi/reply" 200 t)
      (opencode-test-with-temp-buffer "*opencode: question*"
        (opencode-question-mode)
        (setq opencode-question--current (opencode-question-test--make-multi-request))
        (setq opencode-question--question-idx 0)
        (setq opencode-question--answers nil)
        (opencode-question--render-question)
        ;; Verify Q1 is shown
        (should (opencode-test-buffer-contains-p "Database Choice"))
        (should (opencode-test-buffer-contains-p "Question 1 of 2"))
        ;; Answer Q1: select PostgreSQL
        (opencode-question--select-option 1)
        (opencode-question--submit)
        ;; Verify Q2 is now shown
        (should (opencode-test-buffer-contains-p "Cache Choice"))
        (should (opencode-test-buffer-contains-p "Which cache?"))
        ;; Answer Q2: select Redis
        (opencode-question--select-option 1)
        (opencode-question--submit)
        ;; Verify combined reply was sent
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (equal (nth 0 req) "POST"))
          (should (equal (nth 1 req) "/question/question_multi/reply"))
          (let ((body (nth 3 req)))
            (should (equal (plist-get body :answers)
                            [["PostgreSQL"] ["Redis"]]))))))))


;;; --- Test: show returns nil for child sessions (no input area) ---

;;; --- Test: show recovers from render error ---

;;; --- Test: Go back to previous question ---

(ert-deftest opencode-question-go-back-restores-previous ()
  "Verify that BACKSPACE returns to the previous question and restores its answer.
Without this, users who answer Q1 incorrectly in a multi-question flow
would have to reject the entire question and start over."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-multi-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Answer Q1: select PostgreSQL
      (opencode-question--select-option 1)
      (opencode-question--submit)
      ;; Now on Q2
      (should (= opencode-question--question-idx 1))
      (should (opencode-test-buffer-contains-p "Cache Choice"))
      ;; Go back to Q1
      (opencode-question--go-back)
      ;; Should be on Q1 again with PostgreSQL pre-selected
      (should (= opencode-question--question-idx 0))
      (should (opencode-test-buffer-contains-p "Database Choice"))
      (should (eq (aref opencode-question--selected 0) t))  ; PostgreSQL
      (should (eq (aref opencode-question--selected 1) nil)) ; SQLite
      ;; Answers should have the last entry popped
      (should (null opencode-question--answers)))))

(ert-deftest opencode-question-go-back-noop-on-first ()
  "Verify that BACKSPACE does nothing on the first question.
Prevents index-underflow and ensures the popup stays stable."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-multi-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Try going back from Q1 — should do nothing
      (opencode-question--go-back)
      (should (= opencode-question--question-idx 0))
      (should (opencode-test-buffer-contains-p "Database Choice")))))

(ert-deftest opencode-question-go-back-restores-custom-answer ()
  "Verify that going back restores a custom answer from the previous question.
If a user typed a custom answer on Q1 and then went forward, going back
should restore their typed text rather than selecting an option."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current
            (list :id "question_custom_back"
                  :sessionID "ses_test"
                  :questions (vector
                              (list :header "DB Choice"
                                    :question "Which DB?"
                                    :options (vector
                                              (list :label "PostgreSQL" :description "")
                                              (list :label "SQLite" :description ""))
                                    :multiple :false
                                    :custom t)
                              (list :header "Cache Choice"
                                    :question "Which cache?"
                                    :options (vector
                                              (list :label "Redis" :description "")
                                              (list :label "Memcached" :description ""))
                                    :multiple :false
                                    :custom :false))))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Answer Q1 with custom text
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &rest _) "MongoDB")))
        (opencode-question--select-custom))
      (opencode-question--submit)
      ;; Now on Q2
      (should (= opencode-question--question-idx 1))
      ;; Go back
      (opencode-question--go-back)
      ;; Should have custom text restored
      (should (= opencode-question--question-idx 0))
      (should (equal opencode-question--custom-text "MongoDB"))
      ;; No options should be selected
      (should (eq (aref opencode-question--selected 0) nil))
      (should (eq (aref opencode-question--selected 1) nil)))))

(ert-deftest opencode-question-go-back-shows-back-hint ()
  "Verify that the Back hint appears in footer only on question 2+.
On Q1 there's no previous question to go back to, so the hint is hidden."
  (let ((opencode-question--current nil)
        (opencode-question--pending nil))
    (opencode-test-with-temp-buffer "*opencode: question*"
      (opencode-question-mode)
      (setq opencode-question--current (opencode-question-test--make-multi-request))
      (setq opencode-question--question-idx 0)
      (setq opencode-question--answers nil)
      (opencode-question--render-question)
      ;; Q1: no Back hint
      (should-not (opencode-test-buffer-contains-p "Back"))
      ;; Answer Q1 and advance
      (opencode-question--select-option 1)
      (opencode-question--submit)
      ;; Q2: Back hint visible
      (should (opencode-test-buffer-contains-p "Back")))))

(provide 'opencode-question-test)
;;; opencode-question-test.el ends here
