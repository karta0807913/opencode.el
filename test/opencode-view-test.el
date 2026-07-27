;;; opencode-view-test.el --- Golden test for the displayed chat view -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Renders a fixed transcript and compares what the user would actually SEE
;; against a checked-in golden file: `line-prefix', plus buffer text with
;; `invisible' spans dropped and `display' specs substituted.
;;
;; Buffer text and display are not the same thing here.  Indentation lives in
;; a `line-prefix' property, markdown markers are hidden with `invisible', and
;; separators are drawn with `display' specs -- so a change can leave every
;; existing assertion green while moving what is on screen.  Asserting on the
;; rendered view is the only way to catch that.
;;
;; Regenerate after an intended display change:
;;   OPENCODE_REGEN_VIEW=1 make test TEST=test/opencode-view-test.el
;; and read the resulting diff before committing it.

;;; Code:

(defvar opencode-view-test--out nil
  "Accumulator for the view dump being built.")

(defconst opencode-view-test--golden
  (expand-file-name "fixtures/view-golden.txt"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Checked-in expected view.")

(defun opencode-view-test--emit (s)
  "Append S to the dump under construction."
  (push s opencode-view-test--out))


(require 'test-helper nil t)
(require 'opencode-chat)

(defun opencode-view-test--display-of (spec)
  "Return a printable stand-in for a `display' property SPEC."
  (cond ((stringp spec) spec)
        (t (format "«%S»" spec))))

(defun opencode-view-test--visible (beg end)
  "Return the text between BEG and END as displayed."
  (let ((out "") (pos beg))
    (while (< pos end)
      (let* ((next (min end (or (next-property-change pos nil end) end)))
             (disp (get-text-property pos 'display)))
        (unless (invisible-p pos)
          (setq out (concat out (if disp
                                    (opencode-view-test--display-of disp)
                                  (buffer-substring-no-properties pos next)))))
        (setq pos next)))
    out))

(defun opencode-view-test--face-runs (beg end)
  "Return a printable face map over the visible text between BEG and END."
  (let ((runs nil) (pos beg))
    (while (< pos end)
      (let ((next (min end (or (next-single-property-change pos 'face nil end) end))))
        (unless (invisible-p pos)
          (let ((face (get-text-property pos 'face))
                (txt (buffer-substring-no-properties pos next)))
            (when (and face (not (string-empty-p txt)))
              (push (format "%s=%S" txt face) runs))))
        (setq pos next)))
    (string-join (nreverse runs) " ")))

(defun opencode-view-test--dump (label)
  "Print the displayed view of the current buffer under LABEL."
  (opencode-view-test--emit (format "\n===== %s =====\n" label))
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (not (eobp))
        (let* ((beg (point))
               (end (line-end-position))
               (lp (get-text-property beg 'line-prefix))
               (wp (get-text-property beg 'wrap-prefix)))
          (setq n (1+ n))
          (opencode-view-test--emit (format "L%03d PRE[%s] WRAP[%s] TXT[%s]\n"
                         n
                         (if lp (substring-no-properties lp) "")
                         (if wp (substring-no-properties wp) "")
                         (opencode-view-test--visible beg end)))
          (let ((faces (opencode-view-test--face-runs beg end)))
            (unless (string-empty-p faces)
              (opencode-view-test--emit (format "      FACES %s\n" faces)))))
        (forward-line 1)))))

(defun opencode-view-test--force-fontify ()
  "Force markdown fontification regardless of which mechanism drives it.
On the patched tree `jit-lock' never runs in batch, so its worker is
invoked directly; on the base tree the renderer already fontified
eagerly and there is nothing to force."
  (when (fboundp 'opencode-markdown-jit-fontify)
    (opencode-markdown-jit-fontify (point-min) (point-max))))

(defconst opencode-view-test--markdown-text
  (concat "# Heading one\n"
          "## Heading two\n"
          "Plain prose with **bold**, *italic* and `inline code`.\n"
          "Nested ***bold italic*** and a [link](http://example.com).\n"
          "1. ordered item\n2. second ordered\n"
          "- first item\n"
          "- second item\n"
          "* star item\n"
          "> a blockquote line\n"
          "---\n"
          "```elisp\n"
          "(defun foo () (bar 1))\n"
          "```\n"
          "trailing prose")
  "Prose exercising every markdown construct the fontifier supports.")

(defun opencode-view-test-render-assistant ()
  "Render a full assistant message covering every part type."
  (let ((info (list :role "assistant"
                    :id "msg_1"
                    :modelID "test-model"
                    :time (list :created 1700000000000
                                :completed 1700000012000)))
        (parts (vector
                (list :id "p_step0" :type "step-start")
                (list :id "p_reason" :type "reasoning"
                      :text "thinking about **things**\nsecond thought")
                (list :id "p_text" :type "text" :text opencode-view-test--markdown-text
                      :time (list :start 1700000000000 :end 1700000001000))
                (list :id "p_tool" :type "tool" :tool "bash"
                      :state (list :status "completed"
                                   :input (list :command "ls -la")
                                   :output "total 8\ndrwxr-xr-x 2 user user"
                                   :time (list :start 1700000002000
                                               :end 1700000003000)))
                (list :id "p_sub" :type "subtask" :command "review"
                      :description "review the diff" :agent "reviewer"
                      :prompt "Check **this** carefully\n- point one")
                (list :id "p_file" :type "file" :filename "src/main.el"
                      :mime "text/plain")
                (list :id "p_agent" :type "agent" :name "helper")
                (list :id "p_stepf" :type "step-finish" :cost 0.0123))))
    (opencode-chat--render-assistant-message info parts)))

(defun opencode-view-test-render-user ()
  "Render a user message with markdown prose."
  (opencode-chat--render-user-message
   (list :role "user" :id "msg_0" :time (list :created 1700000000000))
   (vector (list :id "p_u" :type "text"
                 :text "user asks **something**\n- with a list"))))

(defun opencode-view-test-run ()
  "Render each scenario in a fresh buffer and dump the displayed view."
  (dolist (spec (list (cons "USER MESSAGE" #'opencode-view-test-render-user)
                      (cons "ASSISTANT MESSAGE" #'opencode-view-test-render-assistant)))
    (with-current-buffer (get-buffer-create (format "*opencode-view-test-%s*" (car spec)))
      (erase-buffer)
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (funcall (cdr spec))
        (opencode-view-test--force-fontify))
      (opencode-view-test--dump (car spec))))
  ;; Streaming path, which builds lines incrementally rather than in one go.
  (with-current-buffer (get-buffer-create "*opencode-view-test-stream*")
    (erase-buffer)
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "# Streamed heading\n" "text")
      (opencode-chat--insert-streaming-delta "with **bold** and\n" "text")
      (opencode-chat--insert-streaming-delta "- a list item" "text")
      (opencode-view-test--force-fontify))
    (opencode-view-test--dump "STREAMING DELTAS"))
  (with-current-buffer (get-buffer-create "*opencode-view-test-reason*")
    (erase-buffer)
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "reasoning **line**\nsecond" "reasoning")
      (opencode-view-test--force-fontify))
    (opencode-view-test--dump "STREAMING REASONING")))


(defun opencode-view-test--normalise (s)
  "Strip clock times from S so the golden file is timezone-independent."
  (replace-regexp-in-string "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" "HH:MM:SS" s))

(defun opencode-view-test--capture ()
  "Render every scenario and return the normalised view dump."
  (let ((opencode-view-test--out nil))
    (opencode-view-test-run)
    (opencode-view-test--normalise
     (apply #'concat (nreverse opencode-view-test--out)))))

(ert-deftest opencode-view-rendered-display-matches-golden ()
  "Verify the rendered chat view matches the checked-in golden file.
Covers both message roles, every part type, and the streaming paths.
A diff here means what the user sees changed --- which existing tests
cannot detect, since they assert on buffer text and properties rather
than on the composition of `line-prefix', `invisible' and `display'."
  (let ((actual (opencode-view-test--capture)))
    (if (getenv "OPENCODE_REGEN_VIEW")
        (with-temp-file opencode-view-test--golden (insert actual))
      (let ((expected (with-temp-buffer
                        (insert-file-contents opencode-view-test--golden)
                        (buffer-string))))
        (unless (string= actual expected)
          (let ((dump (make-temp-file "opencode-view-actual" nil ".txt")))
            (with-temp-file dump (insert actual))
            (ert-fail (format "rendered view changed; actual written to %s" dump))))
        (should (string= actual expected))))))

(provide 'opencode-view-test)
;;; opencode-view-test.el ends here
