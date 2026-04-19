;;; opencode-popup-test.el --- Tests for opencode-popup.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the opencode-popup module (shared popup infrastructure).

;;; Code:

(require 'ert)
(require 'opencode-popup)
(require 'opencode-chat)
(require 'test-helper)

;;; --- Test: find-chat-buffer exact match ---

;;; --- Test: find-chat-buffer returns nil for non-matching session ---

(ert-deftest opencode-popup-find-chat-buffer-nil-when-no-chat-buffers ()
  "Returns nil when no opencode-chat-mode buffers exist."
  ;; Create a non-chat buffer
  (opencode-test-with-temp-buffer "*opencode: not-chat*"
    (fundamental-mode)
    ;; Request should return nil (no chat buffers, no cache entry)
    (let ((request (list :sessionID "ses_any")))
      (should-not (opencode-popup--find-chat-buffer request)))))

;;; --- Test: find-chat-buffer with multiple matching buffers ---

;;; --- Test: save-input captures text ---

;;; --- Global test queue for show-next tests ---

(defvar opencode-popup-test--pending-queue nil
  "Test queue for show-next tests.")

;;; --- Test: show-next pops from queue ---

(ert-deftest opencode-popup-show-next-pops-from-queue ()
  "Verify that show-next calls show-fn with the first item from the queue."
  (setq opencode-popup-test--pending-queue (list (list :id "req1") (list :id "req2")))
  (let ((show-fn-called nil)
        (show-fn-arg nil))
    (let ((show-fn (lambda (req)
                     (setq show-fn-called t
                           show-fn-arg req)
                     t)))  ; return t for success
      (opencode-popup--show-next 'opencode-popup-test--pending-queue show-fn)
      ;; Verify show-fn was called with first item
      (should show-fn-called)
      (should (equal show-fn-arg (list :id "req1")))
      ;; Verify first item was popped from queue
      (should (length= opencode-popup-test--pending-queue 1))
      (should (equal (car opencode-popup-test--pending-queue) (list :id "req2"))))))

;;; --- Test: show-next pushes back on failure ---

(ert-deftest opencode-popup-show-next-pushes-back-on-failure ()
  "When show-fn returns nil (busy), the item is pushed back to the FRONT."
  (setq opencode-popup-test--pending-queue (list (list :id "req1") (list :id "req2")))
  (let ((show-fn (lambda (_req) nil)))  ; return nil for failure
    (opencode-popup--show-next 'opencode-popup-test--pending-queue show-fn)
    ;; Verify item was popped then pushed back to FRONT
    ;; Queue should still have 2 items: req1 (pushed back) and req2 (original)
    (should (length= opencode-popup-test--pending-queue 2))
    (should (equal (car opencode-popup-test--pending-queue) (list :id "req1")))
    (should (equal (cadr opencode-popup-test--pending-queue) (list :id "req2")))))

;;; --- Test: show-matching finds and pops the correct item ---

(ert-deftest opencode-popup-show-matching-pops-correct-item ()
  "Verify that show-matching finds the item matching predicate and pops it,
not the first item.  Regression test for the drain-popup-queue bug where
requests for different sessions would deadlock because show-next always
popped the first item regardless of which one matched."
  (setq opencode-popup-test--pending-queue
        (list (list :id "req-B" :sessionID "ses_B")
              (list :id "req-A" :sessionID "ses_A")
              (list :id "req-C" :sessionID "ses_A")))
  (let ((shown-req nil))
    (let ((show-fn (lambda (req)
                     (setq shown-req req)
                     t)))
      (opencode-popup--show-matching
       'opencode-popup-test--pending-queue
       (lambda (req) (string= (plist-get req :sessionID) "ses_A"))
       show-fn)
      ;; Should have found and shown req-A (first match), not req-B (first in queue)
      (should shown-req)
      (should (string= (plist-get shown-req :id) "req-A"))
      ;; Queue should have req-B and req-C remaining (req-A was popped)
      (should (length= opencode-popup-test--pending-queue 2))
      (should (string= (plist-get (nth 0 opencode-popup-test--pending-queue) :id) "req-B"))
      (should (string= (plist-get (nth 1 opencode-popup-test--pending-queue) :id) "req-C")))))

(ert-deftest opencode-popup-show-matching-pushes-back-on-failure ()
  "When show-fn returns nil (busy), the matched item is pushed back to front.
Ensures requests aren't lost when the target buffer is busy."
  (setq opencode-popup-test--pending-queue
        (list (list :id "req-B" :sessionID "ses_B")
              (list :id "req-A" :sessionID "ses_A")))
  (let ((show-fn (lambda (_req) nil)))  ;; return nil = failure
    (opencode-popup--show-matching
     'opencode-popup-test--pending-queue
     (lambda (req) (string= (plist-get req :sessionID) "ses_A"))
     show-fn)
    ;; req-A should be pushed back to front
    (should (length= opencode-popup-test--pending-queue 2))
    (should (string= (plist-get (car opencode-popup-test--pending-queue) :id) "req-A"))))

(ert-deftest opencode-popup-show-matching-returns-nil-when-no-match ()
  "When no item matches the predicate, returns nil and queue is unchanged."
  (setq opencode-popup-test--pending-queue
        (list (list :id "req-B" :sessionID "ses_B")))
  (let ((show-fn-called nil))
    (let ((result (opencode-popup--show-matching
                   'opencode-popup-test--pending-queue
                   (lambda (req) (string= (plist-get req :sessionID) "ses_X"))
                   (lambda (_req) (setq show-fn-called t) t))))
      ;; No match found
      (should-not result)
      ;; show-fn should not have been called
      (should-not show-fn-called)
      ;; Queue unchanged
      (should (length= opencode-popup-test--pending-queue 1)))))

;;; --- Test: input-area-valid-p ---

(ert-deftest opencode-popup-input-area-valid-p-nil-marker ()
  "Returns nil when input-start is nil (child sessions, loading state).
Guards against attempting inline popup render in buffers without an input area."
  (opencode-test-with-temp-buffer "*opencode: valid-p-test*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start nil)
    (should-not (opencode-popup--input-area-valid-p))))

(ert-deftest opencode-popup-input-area-valid-p-valid-marker ()
  "Returns non-nil when input-start is a valid marker with position."
  (opencode-test-with-temp-buffer "*opencode: valid-p-test2*"
    (opencode-chat-mode)
    (insert "header\n")
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (should (opencode-popup--input-area-valid-p))))

;;; --- Test: with-inline-region guards against nil input-start ---

(ert-deftest opencode-popup-with-inline-region-nil-input-start ()
  "Verify that with-inline-region signals error when input-start is nil.
This prevents buffer corruption when popup tries to render in child
sessions or during loading before the input area exists."
  (opencode-test-with-temp-buffer "*opencode: nil-input-test*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start nil)
    (should-error
     (opencode-popup--with-inline-region nil opencode-test-prop
       (insert "test"))
     :type 'error)))

(provide 'opencode-popup-test)
;;; opencode-popup-test.el ends here
