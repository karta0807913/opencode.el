;;; opencode-todo.el --- Session todo list for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Read-only display of session todo items from GET /session/:id/todo.
;; Provides a major mode (derived from `tabulated-list-mode') for viewing
;; and refreshing todo lists.  Renders todos as a column-aligned table
;; with status icons, priority badges, and a progress summary bar.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'opencode-api)
(require 'opencode-ui)
(require 'opencode-faces)

;;; --- Buffer-local variables ---

(defvar-local opencode-todo--session-id nil
  "Session ID for the current todo buffer.")

(defvar-local opencode-todo--todos nil
  "Vector of todo items for the current session.")

;;; --- Keymap ---

(defvar-keymap opencode-todo-mode-map
  :doc "Keymap for `opencode-todo-mode'."
  "g" #'opencode-todo--refresh)

;;; --- Major mode ---

(define-derived-mode opencode-todo-mode tabulated-list-mode "OpenCode Todos"
  "Major mode for the OpenCode session todo list.

\\{opencode-todo-mode-map}"
  :group 'opencode
  (setq truncate-lines t)
  (setq tabulated-list-format
        [("#" 3 nil :right-align t)
         ("Status" 12 nil)
         ("Task" 40 nil)
         ("Priority" 12 nil)])
  (setq tabulated-list-sort-key nil)
  (setq revert-buffer-function #'opencode-todo--revert)
  (tabulated-list-init-header)
  (buffer-disable-undo))

;;; --- API functions ---

(defun opencode-todo--fetch (session-id)
  "Fetch todos for SESSION-ID from the API.
Returns a vector of todo items, or nil on error."
  (condition-case err
      (opencode-api-get-sync (format "/session/%s/todo" session-id))
    (error
     (message "Failed to fetch todos: %s" (error-message-string err))
     nil)))

;;; --- Status helpers ---

(defun opencode-todo--status-icon (status)
  "Return an icon string for the given STATUS.
STATUS should be one of: \"completed\", \"in_progress\", \"pending\"."
  (pcase status
    ("completed"   (propertize "[✓]" 'face 'opencode-todo-completed))
    ("in_progress" (propertize "[•]" 'face 'opencode-todo-in-progress))
    ("pending"     (propertize "[ ]" 'face 'opencode-todo-pending))
    (_             (propertize "[ ]" 'face 'font-lock-comment-face))))

(defun opencode-todo--status-face (status)
  "Return the face symbol for the given STATUS."
  (pcase status
    ("completed"   'opencode-todo-completed)
    ("in_progress" 'opencode-todo-in-progress)
    ("pending"     'opencode-todo-pending)
    (_             'font-lock-comment-face)))

(defun opencode-todo--status-label (status)
  "Return a human-readable label for STATUS."
  (pcase status
    ("completed"   "Done")
    ("in_progress" "Working")
    ("pending"     "Pending")
    (_             (or status "?"))))

(defun opencode-todo--priority-face (priority)
  "Return the face for PRIORITY level."
  (pcase priority
    ("high"   'opencode-todo-priority-high)
    ("medium" 'opencode-todo-priority-medium)
    ("low"    'opencode-todo-priority-low)
    (_        'font-lock-comment-face)))

(defun opencode-todo--priority-icon (priority)
  "Return an icon for PRIORITY level."
  (pcase priority
    ("high"   "↑↑↑")
    ("medium" "↑↑")
    ("low"    "↑")
    (_        "")))

;;; --- Progress helpers ---

(defun opencode-todo--compute-progress (todos)
  "Compute progress stats from TODOS vector.
Returns a plist with :completed, :in-progress, :pending, :total."
  (let ((completed 0) (in-progress 0) (pending 0) (total 0))
    (seq-doseq (todo todos)
      (cl-incf total)
      (pcase (plist-get todo :status)
        ("completed"   (cl-incf completed))
        ("in_progress" (cl-incf in-progress))
        ("pending"     (cl-incf pending))))
    (list :completed completed
          :in-progress in-progress
          :pending pending
          :total total)))

(defun opencode-todo--render-progress-bar (completed total width)
  "Insert a progress bar for COMPLETED out of TOTAL items.
WIDTH is the total character width of the bar."
  (let* ((ratio (if (> total 0) (/ (float completed) total) 0.0))
         (filled (round (* ratio width)))
         (empty (- width filled)))
    (insert (propertize (make-string filled ?█)
                        'face 'opencode-todo-progress-bar-filled))
    (insert (propertize (make-string empty ?░)
                        'face 'opencode-todo-progress-bar-empty))))

;;; --- Compact inline rendering (shared by chat-input + chat-message) ---

(cl-defun opencode-todo--render-compact (todos &key (indent " ") (bar-width 10)
                                              max-content-len show-priority)
  "Insert a compact todo list for TODOS vector at point.

Keyword arguments:
  :indent          Prefix string for each line (default \" \").
  :bar-width       Progress bar character width (default 10).
  :max-content-len When non-nil, truncate task content to this length.
  :show-priority   When non-nil, append priority indicator after content.

Renders: progress bar header + one line per todo item with status icon
and content.  Does nothing if TODOS is nil or empty.
Used by the inline chat footer and the todowrite tool body renderer."
  (when (and todos (> (length todos) 0))
    (let* ((progress (opencode-todo--compute-progress todos))
           (completed (plist-get progress :completed))
           (total (plist-get progress :total))
           (pct (if (> total 0)
                    (round (* 100 (/ (float completed) total)))
                  0)))
      ;; Progress bar header
      (insert indent)
      (opencode-todo--render-progress-bar completed total bar-width)
      (insert " ")
      (insert (propertize (format "%d%%" pct) 'face 'opencode-todo-progress))
      (insert (propertize (format " (%d/%d)" completed total)
                          'face 'font-lock-comment-face))
      (insert "\n")
      ;; Todo items
      (seq-doseq (todo todos)
        (let* ((status (or (plist-get todo :status) "pending"))
               (priority (plist-get todo :priority))
               (content (or (plist-get todo :content) ""))
               (completed-p (string= status "completed"))
               (cancelled-p (string= status "cancelled"))
               (content-face (cond (completed-p 'opencode-todo-content-completed)
                                   (cancelled-p 'font-lock-comment-face)
                                   (t 'opencode-todo-content)))
               (display-content (if (and max-content-len
                                         (> (length content) max-content-len))
                                    (concat (substring content 0 (1- max-content-len))
                                            "\u2026")
                                  content))
               (pri-str (when (and show-priority priority
                                   (not (string-empty-p (opencode-todo--priority-icon priority))))
                          (concat " " (propertize (opencode-todo--priority-icon priority)
                                                  'face (opencode-todo--priority-face priority))))))
          (insert indent
                  (opencode-todo--status-icon status)
                  " "
                  (propertize display-content 'face content-face)
                  (or pri-str "")
                  "\n"))))))

;;; --- Tabulated list entries ---

(defun opencode-todo--entries ()
  "Build `tabulated-list-entries' from `opencode-todo--todos'."
  (let ((entries nil))
    (dotimes (i (length opencode-todo--todos))
      (let* ((todo (aref opencode-todo--todos i))
             (content (plist-get todo :content))
             (status (plist-get todo :status))
             (priority (plist-get todo :priority))
             (completed-p (string= status "completed"))
             (content-face (if completed-p
                               'opencode-todo-content-completed
                             'opencode-todo-content))
             ;; Column 0: index
             (idx-str (propertize (format "%d" (1+ i))
                                  'face 'opencode-todo-index))
             ;; Column 1: status icon + label
             (status-str (concat (opencode-todo--status-icon status)
                                 " "
                                 (propertize (opencode-todo--status-label status)
                                             'face (opencode-todo--status-face status))))
             ;; Column 2: task content
             (task-str (propertize content 'face content-face))
             ;; Column 3: priority icon + label
             (pri-str (if priority
                          (concat (propertize (opencode-todo--priority-icon priority)
                                              'face (opencode-todo--priority-face priority))
                                  " "
                                  (propertize (format "(%s)" priority)
                                              'face (opencode-todo--priority-face priority)))
                        "")))
        (push (list (1+ i) (vector idx-str status-str task-str pri-str))
              entries)))
    (nreverse entries)))

;;; --- Table rendering ---

(defun opencode-todo--render ()
  "Render the todo list as a pretty table in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (or (null opencode-todo--todos)
            (length= opencode-todo--todos 0))
        ;; Empty state
        (progn
          (insert "\n")
          (insert (propertize "  No todos for this session.\n"
                              'face 'font-lock-comment-face))
          (insert "\n"))
      ;; --- Populate tabulated-list-entries and print table ---
      (setq tabulated-list-entries (opencode-todo--entries))
      (tabulated-list-print t)
      ;; --- Insert progress bar + inline header above table rows ---
      (goto-char (point-min))
      (let* ((progress (opencode-todo--compute-progress opencode-todo--todos))
             (completed (plist-get progress :completed))
             (in-prog (plist-get progress :in-progress))
             (total (plist-get progress :total))
             (pct (if (> total 0)
                      (round (* 100 (/ (float completed) total)))
                    0)))
        ;; Progress bar + stats
        (insert "\n  ")
        (opencode-todo--render-progress-bar completed total 20)
        (insert "  ")
        (insert (propertize (format "%d%%" pct) 'face 'opencode-todo-progress))
        (insert (propertize (format "  (%d/%d done" completed total)
                            'face 'font-lock-comment-face))
        (when (> in-prog 0)
          (insert (propertize (format ", %d active" in-prog)
                              'face 'opencode-todo-in-progress)))
        (insert (propertize ")" 'face 'font-lock-comment-face))
        (insert "\n\n"))
      ;; --- Inline table header (for backward compatibility) ---
      (let ((col-status 7)
            (col-content 19)
            (col-priority 60))
        (insert "  ")
        (insert (propertize "#" 'face 'opencode-todo-table-header))
        (insert (make-string (max 1 (- col-status 3)) ?\s))
        (insert (propertize "Status" 'face 'opencode-todo-table-header))
        (insert (make-string (max 1 (- col-content col-status 6)) ?\s))
        (insert (propertize "Task" 'face 'opencode-todo-table-header))
        (insert (make-string (max 1 (- col-priority col-content 4)) ?\s))
        (insert (propertize "Priority" 'face 'opencode-todo-table-header))
        (insert "\n")
        ;; Header underline
        (insert "  ")
        (insert (propertize (make-string 68 ?─)
                            'face 'font-lock-comment-face))
        (insert "\n")))
    ;; Footer
    (goto-char (point-max))
    (insert "\n")
    (opencode-ui--insert-separator)
    (insert (propertize "[g] refresh  [q] quit"
                        'face 'font-lock-comment-face)
            "\n")))

;;; --- Revert support ---

(defun opencode-todo--revert (_ignore-auto _noconfirm)
  "Revert function for `opencode-todo-mode' buffers.
Re-fetches todos and re-renders the buffer."
  (opencode-todo--refresh))

;;; --- Buffer management ---

(defun opencode-todo--open (session-id)
  "Open or create a todo buffer for SESSION-ID.
Fetches todos from the API and renders them."
  (let ((buf (get-buffer-create "*opencode: todos*")))
    (with-current-buffer buf
      (opencode-todo-mode)
      (setq opencode-todo--session-id session-id)
      (setq opencode-todo--todos (opencode-todo--fetch session-id))
      (opencode-todo--render))
    (display-buffer buf)))

(defun opencode-todo--refresh ()
  "Refresh the todo list by re-fetching from the API."
  (interactive)
  (when opencode-todo--session-id
    (setq opencode-todo--todos (opencode-todo--fetch opencode-todo--session-id))
    (opencode-todo--render)
    (message "Todos refreshed")))

;;; --- SSE event handling ---

(defun opencode-todo--on-updated (event)
  "Handle a `todo.updated' SSE event.
If the todo buffer exists and displays the matching session, refresh it.

EVENT is a plist with :type and :properties.  The :properties
contains :sessionID (string) and :todos (vector)."
  (let* ((props (plist-get event :properties))
         (session-id (plist-get props :sessionID))
         (buf (get-buffer "*opencode: todos*")))
    (when (and buf session-id)
      (with-current-buffer buf
        (when (string= opencode-todo--session-id session-id)
          ;; Use the todos from the event directly instead of re-fetching
          (let ((todos (plist-get props :todos)))
            (when todos
              (setq opencode-todo--todos todos)
              (opencode-todo--render))))))))

;;; --- Hook registration is centralized in opencode.el ---

(provide 'opencode-todo)
;;; opencode-todo.el ends here
