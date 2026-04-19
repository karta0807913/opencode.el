;;; opencode-question.el --- Question popup for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; SSE-driven question popup.  When the agent asks a question,
;; the input area of the chat buffer is replaced with a numbered
;; option list.  Press 1-9 to select, RET to submit, r to reject, m to reject with message.
;; After answering, the original input text is restored.
;;
;; Falls back to a standalone buffer when no chat buffer is found.

;;; Code:

(require 'opencode-api)
(require 'opencode-faces)
(require 'opencode-popup)
(require 'opencode-log)

;; Cross-module reference for input-start marker

;;; --- Hook declaration ---

(defvar opencode-sse-question-asked-hook)
(defvar opencode-sse-question-replied-hook)
(defvar opencode-sse-question-rejected-hook)

;;; --- Global state ---

(defvar-local opencode-question--pending nil
  "FIFO list of pending question request plists.
Buffer-local in each chat buffer; SSE events dispatch to the correct
buffer via `opencode-event--dispatch-chat'.")

(defvar-local opencode-question--current nil
  "Currently displayed question request plist.")

;;; --- Buffer-local state ---

(defvar-local opencode-question--question-idx 0
  "Index into questions array.")

(defvar-local opencode-question--answers nil
  "Accumulated answers list-of-lists.")

(defvar-local opencode-question--selected nil
  "Vector of booleans for current question's options.")

(defvar-local opencode-question--custom-text nil
  "Custom answer text, or nil if not using custom.")

;;; --- Shared keymap setup ---

(defun opencode-question--setup-shared-bindings (map)
  "Add shared question bindings (1-9, c, RET, r, m, q, escape, DEL) to MAP."
  (dotimes (i 9)
    (let ((n (1+ i)))
      (keymap-set map (number-to-string n)
                  (let ((num n))
                    (lambda () (interactive) (opencode-question--select-option num))))))
  (keymap-set map "c" #'opencode-question--select-custom)
  (keymap-set map "RET" #'opencode-question--submit)
  (keymap-set map "DEL" #'opencode-question--go-back)
  (keymap-set map "r" #'opencode-question--reject)
  (keymap-set map "m" #'opencode-question--reject-with-message)
  (keymap-set map "q" #'opencode-question--reject)
  (keymap-set map "<escape>" #'opencode-question--reject))

;;; --- Inline keymap ---

(defvar opencode-question--inline-map
  (let ((map (make-sparse-keymap)))
    (opencode-question--setup-shared-bindings map)
    ;; Block self-insert so random keys don't corrupt the UI
    (keymap-set map "<remap> <self-insert-command>" #'ignore)
    map)
  "Keymap active on the inline question region in chat buffers.")

;;; --- Standalone keymap + mode (for fallback / tests) ---

(defvar opencode-question-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (opencode-question--setup-shared-bindings map)
    map)
  "Keymap for `opencode-question-mode'.")
(define-derived-mode opencode-question-mode special-mode "OpenCode Question"
  "Major mode for the OpenCode question popup (standalone fallback).

\\{opencode-question-mode-map}"
  :group 'opencode
  (setq truncate-lines t)
  (buffer-disable-undo))

;;; --- SSE handler ---

(defun opencode-question--on-asked (event)
  "Handle a `question.asked' SSE EVENT.
Extracts the question request and queues it for display.
Runs in the chat buffer context (dispatched by session-id)."
  (when-let* ((props (plist-get event :properties)))
    (setq opencode-question--pending
          (append opencode-question--pending (list props)))
    (opencode-question--show-next)))

;;; --- Display logic ---

(defun opencode-question--show-next ()
  "Show the next pending question, if any and none currently displayed."
  (opencode-popup--show-next
   'opencode-question--pending
   #'opencode-question--show))

(defun opencode-question--show (request)
  "Display question REQUEST inline in the matching chat buffer.
If the matching chat buffer is busy with another popup, returns nil so
the caller pushes REQUEST back to the queue.  If no matching chat buffer
exists (e.g. session not open), also returns nil -- the question stays
queued until the user opens that session.
Returns nil if the buffer has no valid input area (child session / loading)."
  (let ((chat-buf (opencode-popup--find-chat-buffer request)))
    (cond
     ;; Matching chat buffer found, available, and has valid input area
     ((and chat-buf
           (not (buffer-local-value 'opencode-popup--inline-p chat-buf))
           (opencode-popup--input-area-valid-p chat-buf))
      (with-current-buffer chat-buf
        (condition-case err
            (progn
              (setq opencode-question--current request)
              (opencode-popup--save-input)
              (setq opencode-question--question-idx 0
                    opencode-question--answers nil
                    opencode-question--custom-text nil)
              (opencode-question--render-inline)
              t)
          (error
           ;; Render failed -- restore state so future popups aren't blocked
           (opencode--debug "opencode-question: render error: %S" err)
           (setq opencode-question--current nil)
           (when (overlayp opencode-popup--overlay)
             (delete-overlay opencode-popup--overlay))
           (setq opencode-popup--inline-p nil
                 opencode-popup--saved-input nil
                 opencode-popup--overlay nil)
           nil))))
     ;; Busy, no input area, or no match -- push back to queue
     (t nil))))

;;; --- Shared option rendering ---

(defun opencode-question--render-options (options multiple custom standalone)
  "Render OPTIONS list, custom text, and footer hints at point.
If MULTIPLE is non-nil, show checkbox indicators; otherwise radio buttons.
If CUSTOM is non-nil, show the custom answer button and any custom text.
If STANDALONE is non-nil, use standalone buffer formatting; otherwise inline."
  (let ((num-options (length options))
        (questions (plist-get opencode-question--current :questions)))
    ;; Options as face-styled buttons
    (dotimes (i num-options)
      (let* ((opt (aref options i))
             (label (plist-get opt :label))
             (desc (plist-get opt :description))
             (selected-p (aref opencode-question--selected i))
             (indicator (if multiple
                            (if selected-p "☑" "☐")
                          (if selected-p "●" "○")))
             (num (1+ i))
             (btn-face (if selected-p
                           'opencode-popup-option-selected
                         'opencode-popup-option))
             (btn-text (format " %s %s %s " indicator (number-to-string num) label)))
        (insert "  ")
        (insert (propertize btn-text 'face btn-face))
        (when desc
          (insert " " (propertize desc 'face 'font-lock-comment-face)))
        (insert "\n")))
    ;; Custom text display
    (when (and custom opencode-question--custom-text)
      (if standalone
          (progn
            (insert "\n  ")
            (insert (propertize "Custom:" 'face 'font-lock-comment-face))
            (insert " ")
            (insert (propertize opencode-question--custom-text 'face 'default))
            (insert "\n"))
        (insert "  ")
        (insert (propertize "Custom:" 'face 'font-lock-comment-face))
        (insert " " opencode-question--custom-text "\n")))
    ;; Footer hints
    (let ((sep (if standalone "  " " ")))
      (insert (if standalone "\n  " "  "))
      (insert (propertize " RET Submit " 'face 'opencode-popup-option))
      (insert sep)
      (insert (propertize " r Reject " 'face 'opencode-popup-option))
      (insert sep)
      (insert (propertize " m Reject+msg " 'face 'opencode-popup-option))
      (when custom
        (insert sep)
        (insert (propertize " c Type answer " 'face 'opencode-popup-option)))
      (when (> opencode-question--question-idx 0)
        (insert sep)
        (insert (propertize " ⌫ Back " 'face 'opencode-popup-option))))
    ;; Multi-question progress
    (when (length> questions 1)
      (if standalone
          (progn
            (insert "\n")
            (insert (propertize (format "Question %d of %d"
                                        (1+ opencode-question--question-idx)
                                        (length questions))
                                'face 'font-lock-comment-face)))
        (insert "  "
                (propertize (format "(%d/%d)"
                                    (1+ opencode-question--question-idx)
                                    (length questions))
                            'face 'font-lock-comment-face))))
    (insert "\n")))


;;; --- Data extraction helpers ---

(defun opencode-question--current-data ()
  "Extract current question data as a plist.
Returns a plist with keys :header, :question, :options, :custom,
:multiple, :num-options."
  (let* ((questions (plist-get opencode-question--current :questions))
         (q (aref questions opencode-question--question-idx)))
    (list :header (plist-get q :header)
          :question (plist-get q :question)
          :options (plist-get q :options)
          :custom (eq (plist-get q :custom) t)
          :multiple (eq (plist-get q :multiple) t)
          :num-options (length (plist-get q :options)))))

(defun opencode-question--ensure-selected (num-options)
  "Ensure `opencode-question--selected' vector has NUM-OPTIONS slots."
  (unless (and opencode-question--selected
               (length= opencode-question--selected num-options))
    (setq opencode-question--selected (make-vector num-options nil))
    (setq opencode-question--custom-text nil)))


;;; --- Inline rendering (chat buffer input area) ---

(defun opencode-question--render-inline ()
  "Render the question UI inline, replacing the chat buffer input area.
Deletes from `(opencode-chat--input-start)' to end of buffer,
inserts question content with `opencode-question--inline-map'."
  (let* ((data (opencode-question--current-data))
         (header (plist-get data :header))
         (question-text (plist-get data :question))
         (options (plist-get data :options))
         (custom (plist-get data :custom))
         (multiple (plist-get data :multiple))
         (num-options (plist-get data :num-options)))
    (opencode-question--ensure-selected num-options)
    (opencode-popup--with-inline-region opencode-question--inline-map opencode-question
      ;; Title line
      (insert (propertize "─── Question ───" 'face 'opencode-popup-border) "\n")
      ;; Header
      (when header
        (insert " " (propertize header 'face 'opencode-popup-title) "\n"))
      ;; Question text
      (when question-text
        (insert " " question-text "\n"))
      ;; Options, custom text, footer
      (opencode-question--render-options options multiple custom nil))
    ;; Tag the overlay so cross-buffer dismissal can find it by id.
    (when (overlayp opencode-popup--overlay)
      (overlay-put opencode-popup--overlay
                   'opencode-popup-request-id
                   (plist-get opencode-question--current :id)))))

;;; --- Standalone rendering (fallback buffer / tests) ---

(defun opencode-question--render-question ()
  "Render the current question in a standalone buffer.
Used by `opencode-question-mode' buffers and tests."
  (let* ((inhibit-read-only t)
         (data (opencode-question--current-data))
         (header (plist-get data :header))
         (question-text (plist-get data :question))
         (options (plist-get data :options))
         (custom (plist-get data :custom))
         (multiple (plist-get data :multiple))
         (num-options (plist-get data :num-options)))
    (opencode-question--ensure-selected num-options)
    (erase-buffer)
    ;; Top padding
    (insert "\n")
    ;; Title line
    (insert (propertize "─── Question ───" 'face 'opencode-popup-border) "\n\n")
    ;; Header
    (when header
      (insert (propertize header 'face 'opencode-popup-title) "\n"))
    ;; Question text
    (when question-text
      (insert question-text "\n"))
    (insert "\n")
    ;; Options, custom text, footer
    (opencode-question--render-options options multiple custom t)
    (goto-char (point-min))))

;;; --- Selection ---

(defun opencode-question--select-option (n)
  "Toggle or select option N (1-indexed)."
  (when opencode-question--current
    (let* ((data (opencode-question--current-data))
           (options (plist-get data :options))
           (multiple (plist-get data :multiple))
           (idx (1- n)))
      (when (and (>= idx 0) (< idx (length options)))
        ;; Clear custom text when selecting an option
        (setq opencode-question--custom-text nil)
        (if multiple
            ;; Toggle the selected option
            (aset opencode-question--selected idx
                  (not (aref opencode-question--selected idx)))
          ;; Exclusive: deselect all, then select this one
          (dotimes (i (length opencode-question--selected))
            (aset opencode-question--selected i nil))
          (aset opencode-question--selected idx t))
        ;; Re-render in the appropriate mode
        (if opencode-popup--inline-p
            (opencode-question--render-inline)
          (opencode-question--render-question))))))

(defun opencode-question--select-custom ()
  "Read a custom answer from the minibuffer."
  (interactive)
  (when opencode-question--current
    (let ((text (read-string "Custom answer: ")))
      ;; Re-check in case an SSE event dismissed the question while prompting
      (when (and opencode-question--current text (not (string-empty-p text)))
        ;; Deselect all options when using custom
        (dotimes (i (length opencode-question--selected))
          (aset opencode-question--selected i nil))
        (setq opencode-question--custom-text text)
        (if opencode-popup--inline-p
            (opencode-question--render-inline)
          (opencode-question--render-question))))))

(defun opencode-question--go-back ()
  "Go back to the previous question in a multi-question flow.
Pops the last accumulated answer and restores the previous question's
selection state.  Does nothing on the first question."
  (interactive)
  (when (and opencode-question--current
             (> opencode-question--question-idx 0))
    ;; Move back one question
    (setq opencode-question--question-idx
          (1- opencode-question--question-idx))
    ;; Pop the last accumulated answer
    (let ((prev-answer (car (last opencode-question--answers))))
      (setq opencode-question--answers
            (butlast opencode-question--answers))
      ;; Restore selection state from the popped answer
      (let* ((data (opencode-question--current-data))
             (options (plist-get data :options))
             (num-options (length options)))
        (opencode-question--ensure-selected num-options)
        ;; Clear all selections first
        (dotimes (i num-options)
          (aset opencode-question--selected i nil))
        (setq opencode-question--custom-text nil)
        ;; Restore from previous answer
        (when prev-answer
          (let ((is-option nil))
            (dolist (label prev-answer)
              (dotimes (i num-options)
                (when (equal label (plist-get (aref options i) :label))
                  (aset opencode-question--selected i t)
                  (setq is-option t))))
            ;; If no option matched, it was a custom answer
            (unless is-option
              (setq opencode-question--custom-text (car prev-answer)))))))
    ;; Re-render
    (if opencode-popup--inline-p
        (opencode-question--render-inline)
      (opencode-question--render-question))))

;;; --- Submit / Reject ---

(defun opencode-question--submit ()
  "Submit the current answer and advance or send reply."
  (interactive)
  (when opencode-question--current
    (let* ((data (opencode-question--current-data))
           (questions (plist-get opencode-question--current :questions))
           (options (plist-get data :options))
           (labels (list)))
      ;; Collect selected labels
      (if opencode-question--custom-text
          (setq labels (list opencode-question--custom-text))
        (dotimes (i (length opencode-question--selected))
          (when (aref opencode-question--selected i)
            (push (plist-get (aref options i) :label) labels)))
        (setq labels (nreverse labels)))
      ;; Must have at least one selection
      (unless labels
        (user-error "Select at least one option or provide a custom answer"))
      ;; Accumulate answer
      (setq opencode-question--answers
            (append opencode-question--answers (list labels)))
      ;; Advance or reply
      (if (< (1+ opencode-question--question-idx) (length questions))
          ;; More questions
          (progn
            (setq opencode-question--question-idx
                  (1+ opencode-question--question-idx))
            (if opencode-popup--inline-p
                (opencode-question--render-inline)
              (opencode-question--render-question)))
        ;; Last question — send reply
        (let ((saved-current opencode-question--current))
          (opencode-question--reply opencode-question--answers)
          ;; Clean up — but only if on-replied didn't already handle it.
          ;; The sync HTTP call in --reply can trigger accept-process-output,
          ;; which lets the SSE question.replied event fire --on-replied
          ;; re-entrantly.  If that happened, --current is already nil.
          (when (eq opencode-question--current saved-current)
            (opencode-question--cleanup)))))))

(defun opencode-question--reject ()
  "Reject the current question request."
  (interactive)
  (when opencode-question--current
    (let ((saved-current opencode-question--current)
          (id (plist-get opencode-question--current :id)))
      (opencode--debug "opencode-question: rejecting id=%s" id)
      (condition-case err
          (opencode-api-post-sync (format "/question/%s/reject" id))
        (opencode-api-error
         (message "opencode-question: reject failed: %s" (error-message-string err))))
      ;; Clean up — but only if on-rejected didn't already handle it.
      ;; The sync HTTP call above can trigger accept-process-output,
      ;; which lets the SSE question.rejected event fire re-entrantly.
      (when (eq opencode-question--current saved-current)
        (opencode-question--cleanup)))))

(defun opencode-question--reject-with-message ()
  "Reject the current question request with a reason message."
  (interactive)
  (when opencode-question--current
    (let ((msg (read-string "Rejection reason: ")))
      ;; Re-check in case an SSE event dismissed the question while prompting
      (when opencode-question--current
        (let ((saved-current opencode-question--current)
              (id (plist-get opencode-question--current :id)))
          (opencode--debug "opencode-question: rejecting with message id=%s" id)
          (condition-case err
              (opencode-api-post-sync (format "/question/%s/reject" id)
                                      (list :message msg))
            (opencode-api-error
             (message "opencode-question: reject failed: %s" (error-message-string err))))
          ;; Clean up — but only if on-rejected didn't already handle it.
          (when (eq opencode-question--current saved-current)
            (opencode-question--cleanup)))))))

(defun opencode-question--reply (answers)
  "Send ANSWERS to the server for the current question.
ANSWERS is a list of lists of label strings.
Converts to vectors for JSON serialization: [[\"a\"]] → array of arrays."
  (let* ((id (plist-get opencode-question--current :id))
         (vec-answers (vconcat
                       (mapcar (lambda (ans) (vconcat ans))
                               answers))))
    (opencode--debug "opencode-question: replying id=%s answers=%S" id vec-answers)
    (condition-case err
        (opencode-api-post-sync
         (format "/question/%s/reply" id)
         (list :answers vec-answers))
      (opencode-api-error
       (message "opencode-question: reply failed: %s" (error-message-string err))))))

;;; --- Cleanup ---

(defun opencode-question--cleanup ()
  "Clean up after answering or rejecting a question."
  (let* ((saved-current opencode-question--current)
         (request-id (plist-get saved-current :id)))
    (setq opencode-question--current nil)
    ;; Dual-dispatch duplicate purge — see opencode-popup.el comment.
    (opencode-popup--purge-pending-by-id 'opencode-question--pending request-id)
    (opencode-popup--cleanup saved-current
                             "*opencode: question*"
                             #'opencode-question--show-next)))

;;; --- SSE replied/rejected handlers ---

(defun opencode-question--dismiss-if-matching (request-id)
  "Dismiss question popup if its request ID matches REQUEST-ID.
Used by both replied and rejected handlers.  Also purges stale copies
from pending queues in all buffers (dual-dispatch can queue in multiple
buffers).  Idempotent — safe to call even if no popup is displayed."
  (opencode--debug "opencode-question: checking for dismissal requestID=%s" request-id)
  ;; Purge from every buffer's pending queue.
  (opencode-popup--purge-pending-by-id 'opencode-question--pending request-id)
  ;; Dismiss any displayed popup with that id.
  (opencode-popup--dismiss-by-id
   request-id
   (lambda ()
     (opencode--debug "opencode-question: dismissing popup in %s" (buffer-name))
     (opencode-question--cleanup))))

(defun opencode-question--on-replied (event)
  "Handle a `question.replied' SSE EVENT.
Dismiss the question popup if it matches the replied request.
This handles the case where the question was answered elsewhere
(e.g., in the TUI or another Emacs instance)."
  (when-let* ((props (plist-get event :properties))
              (request-id (plist-get props :requestID)))
    (opencode-question--dismiss-if-matching request-id)))

(defun opencode-question--on-rejected (event)
  "Handle a `question.rejected' SSE EVENT.
Dismiss the question popup if it matches the rejected request.
This handles the case where the question was rejected elsewhere
(e.g., in the TUI or another Emacs instance)."
  (when-let* ((props (plist-get event :properties))
              (request-id (plist-get props :requestID)))
    (opencode-question--dismiss-if-matching request-id)))

;;; --- Hook registration is centralized in opencode.el ---

;;; --- Tool body renderer (for chat buffer tool parts) ---

(defun opencode-question--render-tool-body (input _output metadata)
  "Render question tool INPUT with answers from METADATA.
OUTPUT is ignored (question tool has no output).
Called from the tool renderer registry when rendering question tool parts."
  (let* ((questions (plist-get input :questions))
         (answers (when metadata (plist-get metadata :answers)))
         (dim-face 'font-lock-comment-face))
    (when (and questions (length> questions 0))
      (dotimes (i (length questions))
        (let* ((q (aref questions i))
               (question-text (plist-get q :question))
               (header (plist-get q :header))
               (options (plist-get q :options))
               (answer-raw (when (and answers (< i (length answers)))
                           (aref answers i)))
         (answer-list (when answer-raw (seq-into answer-raw 'list))))
          ;; Question header
          (insert (propertize (format "   %s" (or header question-text))
                              'face 'opencode-tool-name))
          ;; Answer inline
          (when answer-list
            (insert (propertize " → " 'face dim-face))
            (insert (propertize (mapconcat #'identity answer-list ", ")
                                'face 'opencode-tool-success)))
          (insert "\n")
          ;; Options
          (when options
            (seq-doseq (opt options)
              (let* ((label (plist-get opt :label))
                     (desc (plist-get opt :description))
                     (selected (and answer-list (member label answer-list))))
                (insert (propertize
                         (format "     %s %s"
                                 (if selected "●" "○")
                                 label)
                         'face (if selected 'opencode-tool-success dim-face)))
                (when desc
                  (insert (propertize (format " — %s" desc) 'face dim-face)))
                (insert "\n")))))))))

;; Register the question tool renderer
(declare-function opencode-chat-register-tool-renderer "opencode-chat-message" (tool-name renderer-fn))
(with-eval-after-load 'opencode-chat-message
  (opencode-chat-register-tool-renderer "question" #'opencode-question--render-tool-body))

(provide 'opencode-question)
;;; opencode-question.el ends here
