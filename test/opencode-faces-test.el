;;; opencode-faces-test.el --- Tests for opencode-faces.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for face definitions.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-faces)
(require 'seq)

;;; --- All faces defined ---

(ert-deftest opencode-faces-all-defined ()
  "All opencode faces should be defined as face objects."
  (let ((expected-faces
         '(opencode-user-header
           opencode-user-body
           opencode-assistant-header
           opencode-assistant-body
           opencode-timestamp
           opencode-agent-badge
           opencode-cost
           opencode-tokens
           opencode-tool-name
           opencode-tool-arg
           opencode-tool-pending
           opencode-tool-running
           opencode-tool-success
           opencode-tool-error
           opencode-tool-duration
           opencode-session-active
           opencode-session-idle
           opencode-session-archived
           opencode-session-title
           opencode-session-time
           opencode-session-id
           opencode-session-stats
           opencode-project-header
           opencode-diff-added
           opencode-diff-removed
           opencode-diff-hunk-header
           opencode-diff-file-header
           opencode-diff-line-number
           opencode-file-modified
           opencode-file-added
           opencode-file-deleted
           opencode-file-renamed
           opencode-separator
           opencode-header
           opencode-input-prompt
           opencode-input-area
           opencode-section-indicator
           opencode-tree-guide
            opencode-todo-completed
            opencode-todo-in-progress
            opencode-todo-pending
            opencode-todo-table-header
            opencode-todo-content
            opencode-todo-content-completed
            opencode-todo-priority-high
            opencode-todo-priority-medium
            opencode-todo-priority-low
            opencode-todo-progress
            opencode-todo-progress-bar-filled
            opencode-todo-progress-bar-empty
            opencode-todo-index
           opencode-reasoning
           opencode-popup-title
           opencode-popup-key
           opencode-popup-border
           opencode-connected
           opencode-disconnected
           opencode-connecting
           opencode-step-separator
           opencode-step-summary)))
    (dolist (face expected-faces)
      (should (facep face)))))

;;; --- Face inheritance ---

(ert-deftest opencode-faces-inherit-correctly ()
  "Key faces should inherit from standard Emacs faces or have explicit specs."
  ;; Diff faces have explicit dark/light display-class specs with fallback inheritance
  (should (or (stringp (face-attribute 'opencode-diff-added :background nil t))
              (eq (face-attribute 'opencode-diff-added :inherit)
                  'diff-added)))
  (should (or (stringp (face-attribute 'opencode-diff-removed :background nil t))
              (eq (face-attribute 'opencode-diff-removed :inherit)
                  'diff-removed)))
  (should (or (stringp (face-attribute 'opencode-diff-hunk-header :background nil t))
              (eq (face-attribute 'opencode-diff-hunk-header :inherit)
                  'diff-hunk-header)))
  ;; Input prompt inherits from minibuffer-prompt
  (should (eq (face-attribute 'opencode-input-prompt :inherit)
              'minibuffer-prompt))
  ;; Tool error inherits from error
  (should (eq (face-attribute 'opencode-tool-error :inherit)
              'error))
  ;; Popup key inherits from help-key-binding
  (should (eq (face-attribute 'opencode-popup-key :inherit)
              'help-key-binding))
  ;; Connection status
  (should (eq (face-attribute 'opencode-connected :inherit)
              'success))
  (should (eq (face-attribute 'opencode-disconnected :inherit)
              'error)))

;;; --- Face group ---

(ert-deftest opencode-faces-group-exists ()
  "The opencode-faces customization group should exist."
  (should (get 'opencode-faces 'group-documentation)))

;;; --- Face attributes valid ---

(ert-deftest opencode-faces-no-invalid-attributes ()
  "All opencode faces should have valid attributes (no errors on access)."
  (let ((faces (seq-filter
                (lambda (sym)
                  (and (facep sym)
                       (string-prefix-p "opencode-" (symbol-name sym))))
                (face-list))))
    (dolist (face faces)
      ;; Accessing attributes should not error
      (should-not (condition-case err
                      (progn
                        (face-attribute face :foreground nil t)
                        (face-attribute face :background nil t)
                        (face-attribute face :weight nil t)
                        (face-attribute face :slant nil t)
                        (face-attribute face :inherit nil t)
                        nil)
                    (error err))))))

(provide 'opencode-faces-test)
;;; opencode-faces-test.el ends here
