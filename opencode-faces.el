;;; opencode-faces.el --- Face definitions for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; All face definitions for the opencode.el package.
;; Faces inherit from standard Emacs faces so they look correct in any theme.
;; Emacs 30: Uses styled underlines (double-line, dots, dashes) on GUI frames.
;; Emacs 29+: Inherits from new font-lock faces (bracket, escape, number, etc.).

;;; Code:

(defgroup opencode-faces nil
  "Faces for opencode.el."
  :group 'opencode
  :group 'faces)

;;; --- Message faces ---

(defface opencode-user-header
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user message headers."
  :group 'opencode-faces)

(defface opencode-user-body
  '((t :inherit default))
  "Face for user message body text."
  :group 'opencode-faces)

;; Faces below (user-block, assistant-block) use hardcoded colors — no standard equivalent
(defface opencode-user-block
  '((((class color) (background dark))
     :foreground "#3b82f6")
    (((class color) (background light))
     :foreground "#2563eb")
    (t :inherit default))
  "Face for user message block — colors the left stripe character."
  :group 'opencode-faces)

(defface opencode-assistant-header
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant message headers."
  :group 'opencode-faces)

(defface opencode-assistant-body
  '((t :inherit default))
  "Face for assistant message body text."
  :group 'opencode-faces)

(defface opencode-assistant-block
  '((((class color) (background dark))
     :foreground "#a78bfa")
    (((class color) (background light))
     :foreground "#7c3aed")
    (t :inherit default))
  "Face for assistant message block — colors the left stripe character."
  :group 'opencode-faces)

(defface opencode-message-header-line
  '((t :overline t :extend t))
  "Face for the overline at the top of a message block."
  :group 'opencode-faces)

(defface opencode-message-footer-line
  '((t :underline t :extend t))
  "Face for the underline at the bottom of a message block."
  :group 'opencode-faces)

(defface opencode-timestamp
  '((t :inherit font-lock-comment-face))
  "Face for message timestamps."
  :group 'opencode-faces)

(defface opencode-agent-badge
  '((t :inherit font-lock-type-face :weight bold))
  "Face for agent name badges (e.g., claude-sonnet-4)."
  :group 'opencode-faces)

(defface opencode-model-badge
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for model name badges in input area (e.g., [claude-opus-4-6])."
  :group 'opencode-faces)

(defface opencode-variant-badge
  '((t :foreground "#e5c07b" :weight bold))
  "Face for variant display in footer (e.g., max, high)."
  :group 'opencode-faces)

(defface opencode-cost
  '((t :inherit font-lock-number-face))
  "Face for cost display (e.g., $0.12)."
  :group 'opencode-faces)

(defface opencode-tokens
  '((t :inherit font-lock-comment-face))
  "Face for token count display."
  :group 'opencode-faces)

;;; --- Tool call faces ---

(defface opencode-tool-name
  '((t :inherit font-lock-function-call-face :weight bold))
  "Face for tool call names (e.g., read, edit, bash)."
  :group 'opencode-faces)

(defface opencode-tool-arg
  '((t :inherit font-lock-string-face))
  "Face for tool call arguments (e.g., file paths)."
  :group 'opencode-faces)

(defface opencode-tool-pending
  '((((type graphic))
     :inherit font-lock-comment-face
     :underline (:style dashes))
    (t :inherit font-lock-comment-face))
  "Face for pending tool calls.
On GUI frames, uses dashed underline (Emacs 30)."
  :group 'opencode-faces)

(defface opencode-tool-running
  '((t :inherit warning :weight bold))
  "Face for running tool calls."
  :group 'opencode-faces)

(defface opencode-tool-success
  '((t :inherit success))
  "Face for completed tool calls."
  :group 'opencode-faces)

(defface opencode-tool-error
  '((t :inherit error))
  "Face for failed tool calls."
  :group 'opencode-faces)

(defface opencode-tool-duration
  '((t :inherit font-lock-comment-face))
  "Face for tool call duration (e.g., 0.3s)."
  :group 'opencode-faces)

;;; --- Session list faces ---

(defface opencode-session-active
  '((t :inherit success :weight bold))
  "Face for active (busy) sessions in session list."
  :group 'opencode-faces)

(defface opencode-session-idle
  '((t :inherit default))
  "Face for idle sessions in session list."
  :group 'opencode-faces)

(defface opencode-session-archived
  '((t :inherit font-lock-comment-face))
  "Face for archived sessions in session list."
  :group 'opencode-faces)

(defface opencode-session-title
  '((t :inherit bold))
  "Face for session titles."
  :group 'opencode-faces)

(defface opencode-session-time
  '((t :inherit font-lock-comment-face))
  "Face for session timestamps (e.g., 2 min ago)."
  :group 'opencode-faces)

(defface opencode-session-id
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for session IDs."
  :group 'opencode-faces)

(defface opencode-session-stats
  '((t :inherit font-lock-number-face))
  "Face for session stats (e.g., +8 -3  2 files)."
  :group 'opencode-faces)

(defface opencode-session-empty
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for empty session list message."
  :group 'opencode-faces)

;;; --- Project group faces ---

(defface opencode-project-header
  '((t :inherit font-lock-constant-face :weight bold :height 1.1))
  "Face for project group headers in session list."
  :group 'opencode-faces)

;;; --- Diff faces ---

(defface opencode-diff-added
  '((((class color) (background dark)) :background "#1a3320" :extend t)
    (((class color) (background light)) :background "#d6f5d6" :extend t)
    (t :inherit diff-added))
  "Face for added lines in inline diffs."
  :group 'opencode-faces)

(defface opencode-diff-removed
  '((((class color) (background dark)) :background "#3d1f1f" :extend t)
    (((class color) (background light)) :background "#f5d6d6" :extend t)
    (t :inherit diff-removed))
  "Face for removed lines in inline diffs."
  :group 'opencode-faces)

(defface opencode-diff-hunk-header
  '((((class color) (background dark)) :background "#1a2a3a" :foreground "#7ec8e3" :extend t)
    (((class color) (background light)) :background "#d6e5f5" :foreground "#2060a0" :extend t)
    (t :inherit diff-hunk-header))
  "Face for diff hunk headers (@@)."
  :group 'opencode-faces)

(defface opencode-diff-file-header
  '((t :inherit diff-file-header))
  "Face for diff file headers."
  :group 'opencode-faces)

(defface opencode-diff-line-number
  '((t :inherit line-number))
  "Face for line numbers in diff display."
  :group 'opencode-faces)

;;; --- File status faces ---

(defface opencode-file-modified
  '((t :inherit warning))
  "Face for modified file indicator (M)."
  :group 'opencode-faces)

(defface opencode-file-added
  '((t :inherit success))
  "Face for added file indicator (A)."
  :group 'opencode-faces)

(defface opencode-file-deleted
  '((t :inherit error))
  "Face for deleted file indicator (D)."
  :group 'opencode-faces)

(defface opencode-file-renamed
  '((t :inherit font-lock-type-face))
  "Face for renamed file indicator (R)."
  :group 'opencode-faces)

;;; --- UI chrome faces ---

(defface opencode-separator
  '((((type graphic))
     :strike-through t :extend t)
    (t :inherit font-lock-comment-face :extend t))
  "Face for horizontal separator lines."
  :group 'opencode-faces)

(defface opencode-header
  '((((type graphic))
     :inherit header-line
     :underline (:style double-line))
    (t :inherit header-line))
  "Face for section headers.
On GUI frames, uses double-line underline (Emacs 30)."
  :group 'opencode-faces)

(defface opencode-input-prompt
  '((t :inherit minibuffer-prompt))
  "Face for the input area prompt (> )."
  :group 'opencode-faces)

(defface opencode-input-area
  '((t :inherit default))
  "Face for the input text area."
  :group 'opencode-faces)

(defface opencode-section-indicator
  '((t :inherit font-lock-bracket-face))
  "Face for section collapse/expand indicators (▶/▼)."
  :group 'opencode-faces)

(defface opencode-tree-guide
  '((t :inherit font-lock-comment-face))
  "Face for tree guide lines (├─, └─, │)."
  :group 'opencode-faces)

;;; --- Todo faces ---

(defface opencode-todo-completed
  '((t :inherit success))
  "Face for completed todo items (✓)."
  :group 'opencode-faces)

(defface opencode-todo-in-progress
  '((t :inherit warning))
  "Face for in-progress todo items (⏳)."
  :group 'opencode-faces)

(defface opencode-todo-pending
  '((t :inherit font-lock-comment-face))
  "Face for pending todo items (○)."
  :group 'opencode-faces)

(defface opencode-todo-table-header
  '((t :weight bold :underline t))
  "Face for todo table column headers."
  :group 'opencode-faces)

(defface opencode-todo-content
  '((t :inherit default))
  "Face for todo item content text."
  :group 'opencode-faces)

(defface opencode-todo-content-completed
  '((t :inherit font-lock-comment-face :strike-through t))
  "Face for completed todo content (struck through)."
  :group 'opencode-faces)

(defface opencode-todo-priority-high
  '((t :inherit error :weight bold))
  "Face for high priority todo items."
  :group 'opencode-faces)

(defface opencode-todo-priority-medium
  '((t :inherit warning))
  "Face for medium priority todo items."
  :group 'opencode-faces)

(defface opencode-todo-priority-low
  '((t :inherit font-lock-comment-face))
  "Face for low priority todo items."
  :group 'opencode-faces)

(defface opencode-todo-progress
  '((t :inherit success))
  "Face for the progress summary line."
  :group 'opencode-faces)

(defface opencode-todo-progress-bar-filled
  '((((class color) (background dark))
     :background "#22c55e" :foreground "#22c55e")
    (((class color) (background light))
     :background "#16a34a" :foreground "#16a34a")
    (t :inherit success :inverse-video t))
  "Face for the filled portion of the progress bar."
  :group 'opencode-faces)

(defface opencode-todo-progress-bar-empty
  '((((class color) (background dark))
     :background "#374151" :foreground "#374151")
    (((class color) (background light))
     :background "#e5e7eb" :foreground "#e5e7eb")
    (t :inherit shadow :inverse-video t))
  "Face for the empty portion of the progress bar."
  :group 'opencode-faces)

(defface opencode-todo-index
  '((t :inherit font-lock-comment-face))
  "Face for todo item index numbers."
  :group 'opencode-faces)

;;; --- Reasoning/thinking faces ---

(defface opencode-reasoning
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for reasoning/thinking text."
  :group 'opencode-faces)

;;; --- Permission/question popup faces ---

(defface opencode-popup-title
  '((t :inherit font-lock-warning-face :weight bold :height 1.1))
  "Face for popup titles (Permission Required, Question)."
  :group 'opencode-faces)

(defface opencode-popup-key
  '((t :inherit help-key-binding))
  "Face for keybinding hints in popups."
  :group 'opencode-faces)

(defface opencode-popup-border
  '((t :inherit font-lock-comment-face))
  "Face for popup border characters."
  :group 'opencode-faces)

(defface opencode-popup-option
  '((((class color) (background dark))
     :box (:line-width 1 :color "#6b7280")
     :foreground "#e5e7eb")
    (((class color) (background light))
     :box (:line-width 1 :color "#d1d5db")
     :foreground "#1f2937")
    (t :box (:line-width 1) :inherit default))
  "Face for clickable popup option buttons (e.g., ' RET Submit ').
Uses :box property for button-like appearance."
  :group 'opencode-faces)

(defface opencode-popup-option-selected
  '((((class color) (background dark))
     :box (:line-width 1 :color "#3b82f6")
     :foreground "#dbeafe"
     :weight bold)
    (((class color) (background light))
     :box (:line-width 1 :color "#2563eb")
     :foreground "#1e40af"
     :weight bold)
    (t :box (:line-width 1) :weight bold :inherit default))
  "Face for selected popup options (e.g., ☑ 1 Option).
Uses :box property and bold weight to indicate selection."
  :group 'opencode-faces)

;;; --- Connection status faces ---

(defface opencode-connected
  '((t :inherit success))
  "Face for connected status indicator."
  :group 'opencode-faces)

(defface opencode-disconnected
  '((t :inherit error))
  "Face for disconnected status indicator."
  :group 'opencode-faces)

(defface opencode-connecting
  '((t :inherit warning))
  "Face for connecting status indicator."
  :group 'opencode-faces)

(defface opencode-update-notification
  '((t :inherit font-lock-warning-face))
  "Face for update-available notification message."
  :group 'opencode-faces)
;;; --- Step faces ---

(defface opencode-step-separator
  '((((type graphic))
     :inherit font-lock-comment-face
     :underline (:style dots))
    (t :inherit font-lock-comment-face))
  "Face for step separators.
On GUI frames, uses dotted underline (Emacs 30)."
  :group 'opencode-faces)

(defface opencode-step-summary
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for step summary (tokens, cost)."
  :group 'opencode-faces)

;;; --- Subtask faces ---

(defface opencode-subtask-name
  '((t :inherit font-lock-function-call-face :weight bold))
  "Face for subtask command name."
  :group 'opencode-faces)

(defface opencode-subtask-description
  '((t :inherit font-lock-doc-face))
  "Face for subtask description text."
  :group 'opencode-faces)

;;; --- Markdown faces ---

(defface opencode-md-bold
  '((t :weight bold :inherit default))
  "Face for bold markdown text (**text**)."
  :group 'opencode-faces)

(defface opencode-md-italic
  '((t :slant italic :inherit default))
  "Face for italic markdown text (*text*)."
  :group 'opencode-faces)

(defface opencode-md-bold-italic
  '((t :weight bold :slant italic :inherit default))
  "Face for bold-italic markdown text (***text***)."
  :group 'opencode-faces)

(defface opencode-md-inline-code
  '((((class color) (background dark))
     :background "#374151" :foreground "#f9a8d4" :inherit fixed-pitch)
    (((class color) (background light))
     :background "#f3f4f6" :foreground "#be185d" :inherit fixed-pitch)
    (t :inherit fixed-pitch))
  "Face for inline code markdown (`code`).
Uses monospace font with subtle background highlight."
  :group 'opencode-faces)

(defface opencode-md-header-1
  '((t :height 1.3 :weight bold :inherit font-lock-keyword-face))
  "Face for level 1 markdown headers (# Header)."
  :group 'opencode-faces)

(defface opencode-md-header-2
  '((t :height 1.2 :weight bold :inherit font-lock-keyword-face))
  "Face for level 2 markdown headers (## Header)."
  :group 'opencode-faces)

(defface opencode-md-header-3
  '((t :height 1.1 :weight bold :inherit font-lock-keyword-face))
  "Face for level 3 markdown headers (### Header)."
  :group 'opencode-faces)

(defface opencode-md-header-4
  '((t :weight bold :inherit font-lock-keyword-face))
  "Face for level 4 markdown headers (#### Header)."
  :group 'opencode-faces)

(defface opencode-md-code-block
  '((((class color) (background dark))
     :background "#1e293b" :extend t)
    (((class color) (background light))
     :background "#f1f5f9" :extend t)
    (t :inherit default :extend t))
  "Face for code block background region (```...```).
Provides subtle background highlight for code blocks."
  :group 'opencode-faces)

(defface opencode-md-code-block-header
  '((t :inherit (font-lock-comment-face fixed-pitch)))
  "Face for code block language header (```lang).
Dimmed foreground to de-emphasize the marker line."
  :group 'opencode-faces)

(defface opencode-md-blockquote
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for blockquote markdown text (> quote).
Slightly dimmed and italicized."
  :group 'opencode-faces)

(defface opencode-md-list-marker
  '((t :inherit font-lock-keyword-face))
  "Face for list markers (- and * in markdown lists)."
  :group 'opencode-faces)

(defface opencode-md-hr
  '((t :strike-through t :inherit font-lock-comment-face))
  "Face for horizontal rules (--- or ***).
Uses strike-through to indicate a dividing line."
  :group 'opencode-faces)

(defface opencode-md-marker
  '((t :inherit font-lock-comment-face))
  "Face for hidden markdown markers (*, `, #, etc.).
Dimmed foreground; visible when user toggles invisibility."
  :group 'opencode-faces)

;;; --- Mention chip faces ---

(defface opencode-mention-file
  '((((class color) (background dark))
     :box (:line-width 1 :color "#16a34a")
     :background "#1a3320"
     :foreground "#86efac"
     :weight bold)
    (((class color) (background light))
     :box (:line-width 1 :color "#059669")
     :background "#d6f5d6"
     :foreground "#166534"
     :weight bold)
    (t :box (:line-width 1) :weight bold :inherit font-lock-string-face))
  "Face for file/directory mention chips."
  :group 'opencode-faces)

(defface opencode-mention-agent
  '((((class color) (background dark))
     :box (:line-width 1 :color "#3b82f6")
     :background "#1e3a8a"
     :foreground "#93c5fd"
     :weight bold)
    (((class color) (background light))
     :box (:line-width 1 :color "#2563eb")
     :background "#dbeafe"
     :foreground "#1e40af"
     :weight bold)
    (t :box (:line-width 1) :weight bold :inherit font-lock-type-face))
  "Face for agent mention chips."
  :group 'opencode-faces)


(provide 'opencode-faces)
;;; opencode-faces.el ends here
