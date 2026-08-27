;;; opencode-permission-test.el --- Tests for opencode-permission.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the opencode-permission module.

;;; Code:

(require 'ert)
(require 'opencode-backend-opencode)
(require 'opencode-permission)
(require 'opencode-chat)
(require 'opencode-session)
(require 'test-helper)

;;; --- Test fixtures ---

(defun opencode-permission-test--make-request (&optional id)
  "Create a mock permission request plist with optional ID override."
  (list :id (or id "perm_abc123")
        :sessionID "ses_a1b2c3"
        :permission "file.write"
        :patterns ["src/**/*.ts"]
        :always ["src/**/*.ts"]
        :metadata nil))

(defun opencode-permission-test--make-event (&optional id)
  "Create a mock SSE permission.asked event with optional ID override."
  (list :type "permission.asked"
        :properties (opencode-permission-test--make-request id)))

;;; --- Test: Allow once reply ---

(ert-deftest opencode-permission-allow-once-reply ()
  "Verify that allow-once sends the correct POST body."
  (unwind-protect
      (opencode-test-with-mock-api
        (opencode-test-mock-response "POST" "/permission/perm_abc123/reply" 200 t)
        (setq opencode-permission--current
              (opencode-permission-test--make-request)
              opencode-permission--pending nil)
        ;; Show the popup so there's a buffer to kill
        (opencode-permission--show opencode-permission--current)
        (opencode-permission--allow-once)
        ;; Verify the POST was made
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (string= (nth 0 req) "POST"))
          (should (string= (nth 1 req) "/permission/perm_abc123/reply"))
          (should (equal (plist-get (nth 3 req) :reply) "once"))))
    ;; Cleanup
    (when-let ((buf (get-buffer opencode-permission--buffer-name)))
      (kill-buffer buf))
    (setq opencode-permission--current nil
          opencode-permission--pending nil)))

;;; --- Test: Allow always reply ---

(ert-deftest opencode-permission-allow-always-reply ()
  "Verify that allow-always sends the correct POST body with always-pattern message."
  (unwind-protect
      (opencode-test-with-mock-api
        (opencode-test-mock-response "POST" "/permission/perm_abc123/reply" 200 t)
        (setq opencode-permission--current
              ;; Request with :always patterns different from :patterns
              (list :id "perm_abc123"
                    :sessionID "ses_a1b2c3"
                    :permission "bash"
                    :patterns ["grep -rn \"busy\\|idle\" /path"]
                    :always ["grep*"]
                    :metadata nil)
              opencode-permission--pending nil)
        (opencode-permission--show opencode-permission--current)
        (opencode-permission--allow-always)
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (string= (nth 0 req) "POST"))
          (should (string= (nth 1 req) "/permission/perm_abc123/reply"))
          (should (equal (plist-get (nth 3 req) :reply) "always"))
          ;; Message should use :always patterns, not :patterns
          (should (equal (plist-get (nth 3 req) :message) "grep*"))))
    ;; Cleanup
    (when-let ((buf (get-buffer opencode-permission--buffer-name)))
      (kill-buffer buf))
    (setq opencode-permission--current nil
          opencode-permission--pending nil)))

;;; --- Test: Reject reply ---

(ert-deftest opencode-permission-reject-reply ()
  "Verify that reject sends the correct POST body."
  (unwind-protect
      (opencode-test-with-mock-api
        (opencode-test-mock-response "POST" "/permission/perm_abc123/reply" 200 t)
        (setq opencode-permission--current
              (opencode-permission-test--make-request)
              opencode-permission--pending nil)
        (opencode-permission--show opencode-permission--current)
        (opencode-permission--reject)
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (string= (nth 0 req) "POST"))
          (should (string= (nth 1 req) "/permission/perm_abc123/reply"))
          (should (equal (plist-get (nth 3 req) :reply) "reject"))))
    ;; Cleanup
    (when-let ((buf (get-buffer opencode-permission--buffer-name)))
      (kill-buffer buf))
    (setq opencode-permission--current nil
          opencode-permission--pending nil)))

;;; --- Test: Reject with message ---

(ert-deftest opencode-permission-reject-with-message ()
  "Verify that reject-with-message includes the message in POST body."
  (unwind-protect
      (opencode-test-with-mock-api
        (opencode-test-mock-response "POST" "/permission/perm_abc123/reply" 200 t)
        (setq opencode-permission--current
              (opencode-permission-test--make-request)
              opencode-permission--pending nil)
        (opencode-permission--show opencode-permission--current)
        ;; Mock read-string to return a fixed message
        (cl-letf (((symbol-function 'read-string)
                   (lambda (_prompt &rest _) "Not safe to write here")))
          (opencode-permission--reject-with-message))
        (let ((req (opencode-test-last-request)))
          (should req)
          (should (string= (nth 0 req) "POST"))
          (should (string= (nth 1 req) "/permission/perm_abc123/reply"))
          (should (equal (plist-get (nth 3 req) :reply) "reject"))
          (should (equal (plist-get (nth 3 req) :message) "Not safe to write here"))))
    ;; Cleanup
    (when-let ((buf (get-buffer opencode-permission--buffer-name)))
      (kill-buffer buf))
    (setq opencode-permission--current nil
          opencode-permission--pending nil)))

;;; --- Test: SSE handler populates pending ---

(ert-deftest opencode-permission-sse-handler ()
  "Verify that the SSE handler queues when no chat buffer is available."
  (unwind-protect
      (progn
        (setq opencode-permission--pending nil)
        ;; Deliver SSE event (no matching chat buffer → pushed back to queue)
        (let ((event (opencode-permission-test--make-event "perm_new")))
          (opencode-permission--on-asked event))
        ;; No chat buffer — request stays queued
        (should (length= opencode-permission--pending 1))
        (should (string= (plist-get (car opencode-permission--pending) :id)
                          "perm_new")))
    ;; Cleanup
    (when-let ((buf (get-buffer opencode-permission--buffer-name)))
      (kill-buffer buf))
    (setq opencode-permission--current nil
          opencode-permission--pending nil)))

;;; --- Test: Pattern truncation helper ---

(ert-deftest opencode-permission-truncate-pattern-helper ()
  "Verify opencode--truncate-string works correctly for permission patterns."
  ;; Short pattern - no truncation
  (should (string= (opencode--truncate-string "emacs *" 20)
                    "emacs *"))
  ;; Exactly at limit - no truncation
  (should (string= (opencode--truncate-string "12345678901234567890" 20)
                    "12345678901234567890"))
  ;; Over limit - truncated with ellipsis
  (should (string= (opencode--truncate-string "123456789012345678901" 20)
                    "1234567890123456789…")))

;;; --- Test: Format patterns short helper ---

(ert-deftest opencode-permission-format-patterns-short ()
  "Verify opencode-permission--format-patterns-short works correctly."
  ;; Single short pattern
  (should (string= (opencode-permission--format-patterns-short
                    :patterns ["emacs *"] :permission "bash")
                   "emacs *"))
  ;; Multiple patterns joined with "; "
  (should (string= (opencode-permission--format-patterns-short
                    :patterns ["emacs *" "tee *"] :permission "bash")
                   "emacs *; tee *"))
  ;; Empty patterns falls back to permission
  (should (string= (opencode-permission--format-patterns-short
                    :patterns [] :permission "bash")
                   "bash"))
  ;; Nil patterns falls back to permission
  (should (string= (opencode-permission--format-patterns-short
                    :patterns nil :permission "file.write")
                   "file.write")))

(ert-deftest opencode-permission-public-reply-can-select-id ()
  "Verify hook users can reply to a chosen permission id via public API.
This guards user code that handles `opencode-sse-permission-asked-hook' and
answers a request without using the built-in popup state."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "POST" "/permission/perm_selected/reply" 200 t)
    (opencode-permission-reply :id "perm_selected" :choice "once")
    (let ((req (opencode-test-last-request)))
      (should (equal (nth 1 req) "/permission/perm_selected/reply"))
      (should (equal (plist-get (nth 3 req) :reply) "once")))))

(ert-deftest opencode-permission-popup-reply-uses-chat-backend ()
  "Built-in popup replies use the backend stored in the chat buffer."
  (opencode-test-with-temp-buffer "*opencode: permission-backend*"
    (opencode-chat-mode)
    (opencode-chat--set-backend 'pi)
    (setq opencode-permission--current
          '(:id "perm_pi" :sessionID "ses_pi"))
    (let ((captured nil))
      (cl-letf (((symbol-function 'opencode-backend-reply-permission)
                 (lambda (id choice message &optional backend)
                   (setq captured (list id choice message backend))))
                ((symbol-function 'opencode-popup--purge-pending-by-id)
                 #'ignore)
                ((symbol-function 'opencode-popup--cleanup)
                 #'ignore))
        (opencode-permission--reply :choice "once")
        (should (equal captured '("perm_pi" "once" nil pi)))))))

;;; --- Test: show returns nil for child sessions (no input area) ---

;;; --- Test: show recovers from render error ---

(provide 'opencode-permission-test)
;;; opencode-permission-test.el ends here
