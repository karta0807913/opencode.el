;;; opencode-todo-test.el --- Tests for opencode-todo.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the opencode-todo module.

;;; Code:

(require 'ert)
(require 'opencode-todo)
(require 'test-helper)

;;; --- Test: Status icons ---

(ert-deftest opencode-todo-render-status-icons ()
  "Verify that status icons render correctly for each todo state.
Completed shows [✓], in-progress shows [•], pending shows [ ].  If broken,
users cannot quickly scan which tasks are done vs. in-flight vs. waiting."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify completed icon
    (should (opencode-test-buffer-contains-p "[✓]"))
    ;; Verify in-progress icon
    (should (opencode-test-buffer-contains-p "[•]"))
    ;; Verify pending icon
    (should (opencode-test-buffer-contains-p "[ ]"))))

;;; --- Test: Todo content ---

(ert-deftest opencode-todo-render-content ()
  "Verify that todo content text appears in the buffer.
If broken, users see an empty or partial todo list with no task descriptions,
making the todo panel useless for tracking work."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify first todo content
    (should (opencode-test-buffer-contains-p "Examine the authentication code"))
    ;; Verify second todo content
    (should (opencode-test-buffer-contains-p "Fix JWT token validation error handling"))
    ;; Verify third todo content
    (should (opencode-test-buffer-contains-p "Add unit tests for expired token case"))))

;;; --- Test: Empty todo list ---

(ert-deftest opencode-todo-empty-list ()
  "Verify that an empty todo list shows the 'No todos' informational message.
If broken, users see a blank buffer with no feedback, leaving them unsure
whether todos exist or failed to load."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos [])
    (opencode-todo--render)
    ;; Verify empty state message
    (should (opencode-test-buffer-contains-p "No todos for this session"))))

;;; --- Test: Status face mapping ---

(ert-deftest opencode-todo-status-face ()
  "Verify that `opencode-todo--status-face' maps status strings to correct faces.
If broken, completed/in-progress/pending items all look the same, removing
visual distinction between todo states."
  (should (eq (opencode-todo--status-face "completed")
              'opencode-todo-completed))
  (should (eq (opencode-todo--status-face "in_progress")
              'opencode-todo-in-progress))
  (should (eq (opencode-todo--status-face "pending")
              'opencode-todo-pending))
  (should (eq (opencode-todo--status-face "unknown")
              'font-lock-comment-face)))

;;; --- Test: Buffer mode ---

(ert-deftest opencode-todo-buffer-mode ()
  "Verify that the todo buffer activates `opencode-todo-mode'.
If broken, keybindings, hooks, and mode-specific features won't work,
leaving the buffer in an unusable fundamental mode."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify major mode
    (should (eq major-mode 'opencode-todo-mode))))

;;; --- Test: Priority display ---

(ert-deftest opencode-todo-render-priority ()
  "Verify that todo priorities (high/medium/low) are displayed in the buffer.
If broken, users cannot see task importance levels and cannot prioritize
their work effectively."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify priority labels appear in table format
    (should (opencode-test-buffer-contains-p "(high)"))
    (should (opencode-test-buffer-contains-p "(medium)"))
    (should (opencode-test-buffer-contains-p "(low)"))))

;;; --- Test: Table structure ---

(ert-deftest opencode-todo-render-table-header ()
  "Verify that the table header row with column labels is rendered.
If broken, users see a confusing wall of data without column headers,
making it hard to understand what each field represents."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify column headers
    (should (opencode-test-buffer-contains-p "#"))
    (should (opencode-test-buffer-contains-p "Status"))
    (should (opencode-test-buffer-contains-p "Task"))
    (should (opencode-test-buffer-contains-p "Priority"))
    ;; Verify header underline
    (should (opencode-test-buffer-contains-p "─"))))

(ert-deftest opencode-todo-render-table-header-face ()
  "Verify that table headers use the bold `opencode-todo-table-header' face.
If broken, headers blend in with data rows, making it harder to scan
the table structure visually."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    (should (opencode-test-has-face-p "Status" 'opencode-todo-table-header))
    (should (opencode-test-has-face-p "Task" 'opencode-todo-table-header))))

;;; --- Test: Status labels ---

(ert-deftest opencode-todo-render-status-labels ()
  "Verify that human-readable status labels (Done/Working/Pending) appear.
If broken, users see raw API values like 'in_progress' instead of friendly
labels, degrading the UX."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify status labels
    (should (opencode-test-buffer-contains-p "Done"))
    (should (opencode-test-buffer-contains-p "Working"))
    (should (opencode-test-buffer-contains-p "Pending"))))

(ert-deftest opencode-todo-status-label ()
  "Verify that `opencode-todo--status-label' converts API status to user labels.
If broken, raw status strings leak through to the UI, showing 'in_progress'
instead of 'Working'."
  (should (string= (opencode-todo--status-label "completed") "Done"))
  (should (string= (opencode-todo--status-label "in_progress") "Working"))
  (should (string= (opencode-todo--status-label "pending") "Pending"))
  (should (string= (opencode-todo--status-label "other") "other")))

;;; --- Test: Priority faces ---

(ert-deftest opencode-todo-priority-face ()
  "Verify that `opencode-todo--priority-face' maps priority strings to faces.
If broken, high/medium/low priorities all render identically, removing
visual urgency cues from the todo list."
  (should (eq (opencode-todo--priority-face "high")
              'opencode-todo-priority-high))
  (should (eq (opencode-todo--priority-face "medium")
              'opencode-todo-priority-medium))
  (should (eq (opencode-todo--priority-face "low")
              'opencode-todo-priority-low))
  (should (eq (opencode-todo--priority-face "unknown")
              'font-lock-comment-face)))

;;; --- Test: Priority icons ---

(ert-deftest opencode-todo-render-priority-icons ()
  "Verify that priority arrow icons (↑↑↑ for high) are rendered.
If broken, priority levels lack visual iconography, forcing users to read
text labels instead of quickly scanning arrow counts."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; High priority gets triple arrow
    (should (opencode-test-buffer-contains-p "↑↑↑"))))

;;; --- Test: Progress summary ---

(ert-deftest opencode-todo-render-progress-bar ()
  "Verify that the progress bar with percentage and counts is rendered.
If broken, users lose at-a-glance progress visibility and must manually
count completed items to gauge session progress."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify progress bar characters
    (should (opencode-test-buffer-contains-p "█"))
    (should (opencode-test-buffer-contains-p "░"))
    ;; Verify stats: 1 completed out of 5
    (should (opencode-test-buffer-contains-p "20%"))
    (should (opencode-test-buffer-contains-p "(1/5 done"))))

(ert-deftest opencode-todo-compute-progress ()
  "Verify that `opencode-todo--compute-progress' calculates correct counts.
If broken, progress bar shows wrong percentages and counts, misleading
users about actual session completion state."
  (let* ((todos (opencode-test-fixture "todo-list"))
         (progress (opencode-todo--compute-progress todos)))
    (should (= (plist-get progress :completed) 1))
    (should (= (plist-get progress :in-progress) 1))
    (should (= (plist-get progress :pending) 3))
    (should (= (plist-get progress :total) 5))))

;;; --- Test: Completed todo strikethrough ---

(ert-deftest opencode-todo-completed-strikethrough ()
  "Verify that completed todo content uses strikethrough face.
If broken, done items look identical to pending ones, making it hard to
visually distinguish finished work from remaining tasks."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; The completed item should use the strikethrough face
    (should (opencode-test-has-face-p "Examine the authentication code"
                                      'opencode-todo-content-completed))))

;;; --- Test: Index numbers ---

(ert-deftest opencode-todo-render-index-numbers ()
  "Verify that row index numbers are rendered with the correct face.
If broken, rows lack numbered identifiers, making it harder to reference
specific todos when discussing or navigating the list."
  (opencode-test-with-temp-buffer "*test-todo*"
    (opencode-todo-mode)
    (setq opencode-todo--session-id "ses_test")
    (setq opencode-todo--todos (opencode-test-fixture "todo-list"))
    (opencode-todo--render)
    ;; Verify index face appears somewhere in the buffer
    (goto-char (point-min))
    ;; Search past the progress bar to the table area
    (search-forward "─" nil t)
    (let ((found nil))
      (while (and (not found) (not (eobp)))
        (when (eq (get-text-property (point) 'face) 'opencode-todo-index)
          (setq found t))
        (forward-char 1))
      (should found))
    ;; Verify last index (5) appears
    (should (opencode-test-buffer-contains-p "5"))))

(provide 'opencode-todo-test)
;;; opencode-todo-test.el ends here
