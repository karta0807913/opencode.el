;;; opencode-tool-render.el --- Tool-call body rendering + registry -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Renderer registry and built-in body renderers for OpenCode tool
;; calls.  Extracted from `opencode-chat-message.el' so chat-message
;; owns message/part *structure* while this module owns tool-body
;; *rendering*.
;;
;; Renderer APIs:
;;   `opencode-chat-set-tool-renderer' TOOL-NAME FN
;;   `opencode-chat-remove-tool-renderer' TOOL-NAME
;;
;; Dispatch (internal, called by `opencode-chat--render-tool-part'):
;;   `opencode-chat--tool-render-model' TOOL-NAME STATUS INPUT OUTPUT METADATA PART
;;
;; Built-ins are declared in `opencode-chat-tool-renderers':
;;   - bash                              → `--render-bash-body'
;;   - read, write                       → `--render-file-path-body'
;;   - grep, glob                        → `--render-search-body'
;;   - task                              → `--render-task-body'
;;   - edit                              → `--render-edit-body'
;;   - apply_patch                       → `--render-apply-patch-body'
;;   - todowrite, todo_write             → `--render-todowrite-body'
;;
;; Unregistered tools (MCP, or unknown) fall through to
;; `--render-mcp-generic-body' and stay expanded by default.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'opencode-domain)
(require 'opencode-backend)
(require 'opencode-faces)
(require 'opencode-diff)
(require 'opencode-todo)
(require 'opencode-util)
(require 'opencode-log)

(declare-function opencode-chat-open "opencode-chat" (session-id &optional directory display-action))
(declare-function opencode-chat--session-id "opencode-chat-state" ())
(declare-function opencode-chat--session "opencode-chat-state" ())
(declare-function opencode-chat--diff-cache "opencode-chat-state" ())
(declare-function opencode-chat--diff-shown "opencode-chat-state" ())
(declare-function opencode-chat--current-message-id "opencode-chat-state" ())
(declare-function opencode-chat--schedule-refresh "opencode-chat" ())
(declare-function opencode-chat--backend "opencode-chat-state" ())

(defvar opencode-chat-message-file-map)

;;; --- Customization ---

(defcustom opencode-chat-tool-output-max-lines -1
  "Maximum number of lines to render for tool output.
When set to -1, render all lines without a line-count limit."
  :type 'integer
  :group 'opencode-chat)

(defcustom opencode-chat-tool-output-max-chars -1
  "Maximum number of characters to render for tool output.
When set to -1, render all characters without a character-count limit."
  :type 'integer
  :group 'opencode-chat)

;;; --- Registry ---

(defvar-local opencode-chat--tool-renderer-overrides nil
  "Buffer-local tool renderer overrides.
Hash table mapping tool-name string to declarative renderer function.")

(defvar opencode-chat--core-tool-renderers (make-hash-table :test 'equal)
  "Private registry for core-controlled reserved tool renderers.")

(defconst opencode-chat--tool-renderer-reserved '("question" "permission")
  "Tool names reserved for core-controlled rendering.")

(defcustom opencode-chat-tool-renderers
  '(("bash"       :function opencode-chat--render-bash-body      :collapsed-p t :legacy t)
    ("read"       :function opencode-chat--render-file-path-body :collapsed-p t :legacy t)
    ("write"      :function opencode-chat--render-file-path-body :collapsed-p t :legacy t)
    ("grep"       :function opencode-chat--render-search-body    :collapsed-p t :legacy t)
    ("glob"       :function opencode-chat--render-search-body    :collapsed-p t :legacy t)
    ("task"       :function opencode-chat--render-task-body      :collapsed-p t :legacy t)
    ("edit"       :function opencode-chat--render-edit-body      :collapsed-p nil :legacy t)
    ("apply_patch" :function opencode-chat--render-apply-patch-body
                   :collapsed-p nil :legacy t)
    ("todowrite"  :function opencode-chat--render-todowrite-body :collapsed-p nil :legacy t)
    ("todo_write" :function opencode-chat--render-todowrite-body :collapsed-p nil :legacy t))
  "Default declarative tool renderers.
Each entry has the form (TOOL-NAME . PROPERTIES), written as
\(TOOL-NAME :function FUNCTION ...).  FUNCTION is called in the
current chat buffer with one context plist and should return nil or a
declarative plist with optional keys :collapsed-p, :tool-name,
:summary, :input, and :output.

Entries with :legacy non-nil adapt an old imperative FUNCTION that
accepts (INPUT OUTPUT METADATA), inserts into the current buffer, and
returns no declarative value."
  :type '(repeat (cons (string :tag "Tool name")
                       (plist :options ((:function function)
                                        (:collapsed-p boolean)
                                        (:legacy boolean)))))
  :group 'opencode-chat)

(defun opencode-chat--reserved-tool-renderer-p (tool-name)
  "Return non-nil if TOOL-NAME is reserved for core rendering."
  (member tool-name opencode-chat--tool-renderer-reserved))

(defun opencode-chat--ensure-tool-renderer-overrides ()
  "Return the current buffer's tool renderer override hash table."
  (unless (hash-table-p opencode-chat--tool-renderer-overrides)
    (setq opencode-chat--tool-renderer-overrides (make-hash-table :test 'equal)))
  opencode-chat--tool-renderer-overrides)

(defun opencode-chat-set-tool-renderer (tool-name renderer-fn)
  "Set a buffer-local declarative RENDERER-FN for TOOL-NAME.
RENDERER-FN is called in the current chat buffer with one context
plist containing at least :phase, :tool-name, :status, :input,
:output, :metadata, and :part.  It returns nil to fall back to the
default renderer, or a plist with optional :collapsed-p, :tool-name,
:summary, :input, and :output keys.

The reserved tool names \"question\" and \"permission\" are
core-controlled and signal `user-error'."
  (when (opencode-chat--reserved-tool-renderer-p tool-name)
    (user-error "Tool renderer for %s is reserved by opencode.el" tool-name))
  (unless (functionp renderer-fn)
    (user-error "Tool renderer must be a function"))
  (puthash tool-name renderer-fn (opencode-chat--ensure-tool-renderer-overrides)))

(defun opencode-chat-remove-tool-renderer (tool-name)
  "Remove the buffer-local tool renderer override for TOOL-NAME.
Removing an override restores the default renderer.  The reserved tool
names \"question\" and \"permission\" are core-controlled and signal
`user-error'."
  (when (opencode-chat--reserved-tool-renderer-p tool-name)
    (user-error "Tool renderer for %s is reserved by opencode.el" tool-name))
  (when (hash-table-p opencode-chat--tool-renderer-overrides)
    (remhash tool-name opencode-chat--tool-renderer-overrides)))

(defun opencode-chat--register-core-tool-renderer (tool-name renderer-fn &optional legacy)
  "Privately register core-controlled RENDERER-FN for TOOL-NAME.
When LEGACY is non-nil, RENDERER-FN is an old imperative renderer
accepting (INPUT OUTPUT METADATA)."
  (puthash tool-name
           (list :function renderer-fn
                 :collapsed-p nil
                 :legacy (and legacy t)
                 :core t)
           opencode-chat--core-tool-renderers))

(defun opencode-chat--default-tool-entry (tool-name)
  "Return the default renderer entry for TOOL-NAME."
  (assoc tool-name opencode-chat-tool-renderers))

(defun opencode-chat--builtin-tool-p (tool-name)
  "Return non-nil if TOOL-NAME has a built-in default renderer."
  (and (opencode-chat--default-tool-entry tool-name) t))

(defun opencode-chat--tool-status-phase (status)
  "Map tool STATUS string to a renderer phase symbol."
  (pcase status
    ("running" 'running)
    ((or "completed" "error") 'end)
    (_ 'begin)))

(defun opencode-chat--tool-effective-output (output metadata)
  "Return effective full OUTPUT, falling back to METADATA.output."
  (cond
   ((and output (stringp output) (not (string-empty-p output))) output)
   ((when-let* ((m-out (and metadata (plist-get metadata :output)))
                ((stringp m-out))
                ((not (string-empty-p m-out))))
      m-out))
   (output output)))

(defun opencode-chat--capture-legacy-tool-renderer (fn input output metadata)
  "Call legacy renderer FN and return a property-preserving string.

FN draws into a temp buffer, not the transcript.  Drawing into the real
buffer and deleting the result afterwards left anything FN inserted
inside a `save-excursion' behind permanently --- point returns to where
it started, so the cleanup deletes an empty region --- and it ran the
chat buffer's `after-change-functions' over text the user never sees.

The originating chat state is carried across so renderers that read it
still work: `--render-task-body' consults `opencode-chat--session-id' to
record the child->parent link.  Only reads are safe here; a write would
trip the state's own buffer-ownership check, which is correct --- a
renderer capturing its output has no business mutating session state."
  (let ((state opencode-chat--state))
    (with-temp-buffer
      (setq opencode-chat--state state)
      (funcall fn input output metadata)
      (buffer-string))))

(defun opencode-chat--adapt-legacy-tool-renderer (fn context)
  "Adapt old imperative FN to a declarative model using CONTEXT."
  (let* ((input (plist-get context :input))
         (output (plist-get context :output))
         (metadata (plist-get context :metadata))
         (body (opencode-chat--capture-legacy-tool-renderer fn input output metadata)))
    (when (and body (not (string-empty-p body)))
      (list :output body))))

(defun opencode-chat--call-tool-renderer-entry (entry context)
  "Call renderer ENTRY with CONTEXT and return its declarative result."
  (let ((fn (plist-get entry :function)))
    (when fn
      (if (plist-get entry :legacy)
          (opencode-chat--adapt-legacy-tool-renderer fn context)
        (funcall fn context)))))

(defun opencode-chat--merge-tool-render-result (base result)
  "Return BASE model merged with non-absent keys from RESULT."
  (let ((merged (copy-sequence base)))
    (dolist (key '(:collapsed-p :tool-name :summary :input :output))
      (when (plist-member result key)
        (setq merged (plist-put merged key (plist-get result key)))))
    merged))

(defun opencode-chat--tool-render-model
    (tool-name status input output metadata part arg-summary)
  "Return declarative render model for a tool part.
TOOL-NAME, STATUS, INPUT, OUTPUT, METADATA, PART, and ARG-SUMMARY are
the normalized part fields.  Buffer-local overrides are tried first;
nil from an override falls back to defaults."
  (let* ((effective-output (opencode-chat--tool-effective-output output metadata))
         (context (list :phase (opencode-chat--tool-status-phase status)
                        :tool-name tool-name
                        :status status
                        :input input
                        :output effective-output
                        :metadata metadata
                        :part part))
         (core-entry (gethash tool-name opencode-chat--core-tool-renderers))
         (default-entry (opencode-chat--default-tool-entry tool-name))
         (default-props (cdr default-entry))
         (entry (or core-entry default-props))
         (default-collapsed
          (and (plist-member entry :collapsed-p)
               (plist-get entry :collapsed-p)))
         (base (list :collapsed-p default-collapsed
                     :tool-name tool-name
                     :summary arg-summary
                     :input nil
                     :output nil))
         (override (and (not core-entry)
                        (hash-table-p opencode-chat--tool-renderer-overrides)
                        (gethash tool-name opencode-chat--tool-renderer-overrides)))
         (override-result (and override (funcall override context)))
         (result (or override-result
                     (and entry
                          (opencode-chat--call-tool-renderer-entry entry context))
                     (opencode-chat--adapt-legacy-tool-renderer
                      #'opencode-chat--render-mcp-generic-body context))))
    (opencode-chat--merge-tool-render-result base result)))

(defun opencode-chat--render-tool-field (field)
  "Insert declarative tool FIELD if present."
  (when field
    (insert field)))

;;; --- Normalization ---

(defun opencode-chat--normalize-tool-part (part)
  "Collapse old/new tool-part formats into a unified plist.
The old format uses :toolName / :args / :state=string / :duration;
the new API format uses :tool / :state=plist with :status :input
:output :metadata :time.  Returns:

  (:tool-name STRING
   :state STRING-OR-NIL   ; pending / running / completed / error
   :duration MS-OR-NIL
   :arg-summary STRING-OR-NIL
   :input PLIST-OR-NIL
   :output STRING-OR-NIL
   :metadata PLIST-OR-NIL)"
  (let* ((state-val (plist-get part :state))
         (new-format-p (and state-val (listp state-val))))
    (if new-format-p
        (let* ((state (or (plist-get state-val :status) "pending"))
               (tool-name (or (plist-get part :tool) "tool"))
               (td (plist-get state-val :time))
               (ts (and td (plist-get td :start)))
               (te (and td (plist-get td :end)))
               (duration (when (and (numberp ts) (numberp te) (> te ts)) (- te ts)))
               (title (let ((t_ (plist-get state-val :title)))
                        (when (and (stringp t_) (not (string-empty-p (string-trim t_))))
                          t_)))
               (input (plist-get state-val :input))
               (arg-summary (or title
                                (opencode-chat--tool-input-summary tool-name input))))
          (list :tool-name tool-name
                :state state
                :duration duration
                :arg-summary arg-summary
                :input input
                :output (plist-get state-val :output)
                :metadata (plist-get state-val :metadata)))
      (list :tool-name (or (plist-get part :toolName) "tool")
            :state (or state-val "pending")
            :duration (plist-get part :duration)
            :arg-summary (opencode-chat--tool-arg-summary (plist-get part :args))
            :input nil
            :output nil
            :metadata nil))))

;;; --- Input-summary helpers (header display) ---

(defun opencode-chat--tool-input-summary (tool-name input)
  "Extract a short summary from TOOL-NAME and INPUT plist.
INPUT is the :input plist from :state.
Returns a concise human-readable string, or nil."
  (when input
    (cond
     ;; Todowrite: show count and completion stats
     ((and tool-name (string-match-p "todowrite\\|todo_write" tool-name))
      (let* ((todos (plist-get input :todos))
             (total (if (vectorp todos) (length todos) 0))
             (done 0))
        (when (vectorp todos)
          (seq-doseq (todo todos)
            (when (string= (plist-get todo :status) "completed")
              (cl-incf done))))
        (if (> total 0)
            (format "%d/%d done" done total)
          "0 todos")))
     ;; Bash: show "$ command" (or description as fallback)
     ((and tool-name (string= tool-name "bash"))
      (if-let* ((cmd (plist-get input :command)))
          (format "$ %s" cmd)
        (plist-get input :description)))
     ;; Grep/Glob: pattern with include filter and path
     ((and tool-name (string-match-p "grep\\|glob" tool-name))
      (let ((pattern (plist-get input :pattern))
            (path (plist-get input :path))
            (include (plist-get input :include)))
         (cond
          ((and pattern path)
           (format "%s  in: %s%s" pattern (opencode--shorten-path path)
                   (if include (format "  [%s]" include) "")))
          ((and pattern include)
           (format "%s  [%s]" pattern include))
          (pattern pattern)
          (path path))))
      ;; Read/Write/Edit: show shortened file path
      ((and tool-name (string-match-p "read\\|write\\|edit" tool-name))
       (opencode--shorten-path (plist-get input :filePath)))
     ;; Task: show description
     ((and tool-name (string= tool-name "task"))
      (plist-get input :description))
     ;; Default: extract common keys
     (t
      (or (plist-get input :description)
          (plist-get input :filePath)
          (plist-get input :command)
          (plist-get input :path)
          (plist-get input :pattern)
          (plist-get input :query))))))

(defun opencode-chat--tool-arg-summary (args-json)
  "Extract a short summary from ARGS-JSON string."
  (when (and args-json (stringp args-json) (not (string-empty-p args-json)))
    (condition-case nil
        (let ((args (json-parse-string args-json :object-type 'plist)))
          (or (plist-get args :filePath)
              (plist-get args :file_path)
              (plist-get args :command)
              (plist-get args :path)
              (plist-get args :query)
              (truncate-string-to-width args-json 40)))
      (error (truncate-string-to-width args-json 40)))))

;;; --- Shared output rendering ---

(defun opencode-chat--tool-output-apply-limits (output)
  "Return OUTPUT truncated according to tool output custom variables.
`opencode-chat-tool-output-max-chars' and
`opencode-chat-tool-output-max-lines' use -1 to mean unlimited.  If
both limits are set, truncation happens as soon as either one is hit."
  (let* ((max-chars opencode-chat-tool-output-max-chars)
         (max-lines opencode-chat-tool-output-max-lines)
         (char-limit-p (and (integerp max-chars) (>= max-chars 0)))
         (line-limit-p (and (integerp max-lines) (>= max-lines 0)))
         (char-truncated-p (and char-limit-p (> (length output) max-chars)))
         (char-limited (if char-truncated-p
                           (substring output 0 max-chars)
                         output))
         (lines (string-lines char-limited))
         (line-truncated-p (and line-limit-p (length> lines max-lines)))
         (display-lines (if line-truncated-p
                            (take max-lines lines)
                          lines)))
    (list :lines display-lines
          :truncated (or char-truncated-p line-truncated-p))))

(defun opencode-chat--render-tool-output (output metadata)
  "Render shared tool OUTPUT display with METADATA.output streaming fallback.
While a tool is still running, the final `:output' slot is nil and
progressive stdout lives under `metadata.output' — fall back to it so
the user sees output stream in as the command prints, instead of a
blank tool box until completion.  Output is truncated when either
`opencode-chat-tool-output-max-lines' or
`opencode-chat-tool-output-max-chars' is reached; -1 means unlimited."
  (let ((display-output
         (cond
          ((and output (stringp output) (not (string-empty-p output)))
           output)
          ((when-let* ((m-out (and metadata (plist-get metadata :output)))
                        ((stringp m-out))
                        ((not (string-empty-p m-out))))
              m-out)))))
    (when display-output
      (let ((limited (opencode-chat--tool-output-apply-limits display-output)))
        (dolist (line (plist-get limited :lines))
          (insert (propertize (format "   %s\n" line)
                              'face 'font-lock-comment-face)))
        (when (plist-get limited :truncated)
          (insert (propertize "   ... (output truncated)\n"
                              'face 'font-lock-comment-face)))))))

;;; --- Built-in body renderers ---

(defun opencode-chat--render-bash-body (input output metadata)
  "Render `bash' tool body: description + command line + output."
  (when input
    (let ((dim 'font-lock-comment-face)
          (body 'opencode-assistant-body)
          (cmd (plist-get input :command))
          (desc (plist-get input :description)))
      (when desc
        (insert (propertize (format "   %s\n" desc) 'face dim)))
      (when cmd
        (insert (propertize (format "   $ %s\n" cmd) 'face body)))))
  (opencode-chat--render-tool-output output metadata))

(defun opencode-chat--render-file-path-body (input output metadata)
  "Render `read' / `write' tool body: file path + output."
  (when input
    (when-let* ((path (plist-get input :filePath)))
      (insert (propertize (format "   %s\n" path)
                          'face 'opencode-assistant-body))))
  (opencode-chat--render-tool-output output metadata))

(defun opencode-chat--render-search-body (input output metadata)
  "Render `grep' / `glob' tool body: pattern + filter + path, then output."
  (when input
    (let ((dim 'font-lock-comment-face)
          (body 'opencode-assistant-body)
          (pattern (plist-get input :pattern))
          (path (plist-get input :path))
          (include (plist-get input :include)))
      (when pattern
        (insert (propertize (format "   pattern: %s" pattern) 'face body))
        (when include
          (insert (propertize (format "  [%s]" include) 'face dim)))
        (when path
          (insert (propertize (format "  in: %s" path) 'face dim)))
        (insert "\n"))))
  (opencode-chat--render-tool-output output metadata))

(defun opencode-chat--render-task-body (input output metadata)
  "Render `task' (sub-agent) tool body.
Shows description, tool-count, model, and an Open-Sub-Agent button.
Also populates the global child→parent cache so popup dispatch can
route events to the root buffer without an HTTP round-trip."
  (when input
    (let* ((dim 'font-lock-comment-face)
           (description (or (plist-get input :description) "Sub-agent task"))
           (child-session-id (and metadata (plist-get metadata :sessionId)))
           (summary (and metadata (plist-get metadata :summary)))
           (model-info (and metadata (plist-get metadata :model)))
           (model-id (and model-info (plist-get model-info :modelID)))
           (tool-count (and summary (length summary))))
      (when (and child-session-id (opencode-chat--session-id))
        (opencode-domain-child-parent-put child-session-id (opencode-chat--session-id)))
      (insert (propertize (concat "   " description) 'face dim))
      (insert "\n")
      (when (and tool-count (> tool-count 0))
        (insert (propertize (format "   %d tool call%s\n"
                                    tool-count
                                    (if (= tool-count 1) "" "s"))
                            'face dim)))
      (when model-id
        (insert (propertize (format "   model: %s\n" model-id) 'face dim)))
      (when child-session-id
        (insert (propertize "   " 'read-only t))
        (insert-text-button "[Open Sub-Agent]"
                            'action (lambda (_btn)
                                      (opencode-chat-open child-session-id
                                                          (plist-get (opencode-chat--session) :directory)
                                                          'replace))
                            'follow-link t
                            'face 'opencode-tool-name
                            'read-only t
                            'front-sticky '(read-only)
                            'help-echo "Open sub-agent session")
        (insert (propertize "\n" 'read-only t)))))
  (opencode-chat--render-tool-output output metadata))

(defun opencode-chat--render-mcp-generic-body (input output metadata)
  "Render a generic tool body for MCP / unknown tools.
Shows each input plist key as `  key: value' on its own line, then
the shared output display."
  (when (and input (listp input))
    (let ((dim 'font-lock-comment-face)
          (body 'opencode-assistant-body)
          (max-val-width 200)
          (kv input))
      (while (and kv (keywordp (car kv)))
        (let* ((key (substring (symbol-name (car kv)) 1))
               (val (cadr kv))
               (val-str (opencode-chat--format-tool-value val))
               (multiline-p (and (stringp val) (string-match-p "\n" val))))
          (cond
           (multiline-p
            (insert (propertize (format "   %s:\n" key) 'face dim))
            (dolist (line (string-lines val))
              (insert (propertize (format "     %s\n" line) 'face body))))
           (t
            (when (> (length val-str) max-val-width)
              (setq val-str (concat (substring val-str 0 max-val-width) "…")))
            (insert (propertize (format "   %s: " key) 'face dim))
            (insert (propertize (format "%s\n" val-str) 'face body)))))
        (setq kv (cddr kv)))))
  (opencode-chat--render-tool-output output metadata))

(defun opencode-chat--format-tool-value (val)
  "Format VAL (from a tool input plist) as a single-line string.
JSON nulls (both `nil' after parsing and the explicit `:null' symbol)
render as \"null\", matching how the server sees the input."
  (cond
   ((stringp val) val)
   ((or (null val) (eq val :null)) "null")
   ((eq val t) "true")
   ((eq val :false) "false")
   ((numberp val) (number-to-string val))
   ((vectorp val)
    (concat "["
            (mapconcat #'opencode-chat--format-tool-value (append val nil) ", ")
            "]"))
   ((listp val)
    (let (pairs)
      (while (and val (keywordp (car val)))
        (let ((k (substring (symbol-name (car val)) 1))
              (v (cadr val)))
          (push (format "%s: %s" k (opencode-chat--format-tool-value v)) pairs))
        (setq val (cddr val)))
      (concat "{" (mapconcat #'identity (nreverse pairs) ", ") "}")))
   (t (format "%S" val))))

;;; --- Edit renderer (specialized diff display) ---

(defun opencode-chat--render-edit-body (input output &optional metadata)
  "Render edit tool INPUT as inline diff with added/removed lines.
INPUT is the tool input plist with :filePath and :edits (or
:oldString / :newString).  OUTPUT is the string result (shown as
fallback if no edits).  METADATA may contain :diff (unified diff
string) or :filediff (plist with :before/:after)."
  (opencode--debug "opencode-chat: edit-body input=%S output=%S meta=%S"
                   input output (and metadata (plist-get metadata :diff)))
  (let* ((path (plist-get input :filePath))
         (edits (plist-get input :edits))
         (meta-diff (when metadata (plist-get metadata :diff)))
         (meta-filediff (when metadata (plist-get metadata :filediff)))
         (dim-face 'font-lock-comment-face)
         (edit-body-start (point)))
    ;; File path header
    (when path
      (insert (propertize (format "   %s\n" path) 'face 'link)))
    (cond
     ;; Metadata filediff: before/after content → proper unified diff via diff(1).
     ;; Preferred over metadata.diff because the server's diff interleaves
     ;; +/- lines instead of grouping them into hunks.
     ((and meta-filediff (listp meta-filediff))
      (opencode-chat--render-edit-inline-diff meta-filediff))
     ;; Metadata diff: pre-computed diff string (fallback when no filediff)
     ((and meta-diff (stringp meta-diff) (not (string-empty-p meta-diff)))
      (opencode--insert-diff-lines meta-diff "   " 'font-lock-comment-face t))
     ;; Direct oldString/newString from input (production API format)
     ((plist-get input :oldString)
      (let* ((old-str (plist-get input :oldString))
             (new-str (plist-get input :newString))
             (indent "   ")
             (diff-text (condition-case err
                           (opencode-diff--generate-unified
                            old-str (or new-str "") (or path "file"))
                         (error (opencode--debug "opencode-chat: diff generation failed: %S" err)))))
        (if diff-text
            (opencode--insert-diff-lines diff-text indent 'font-lock-comment-face t)
          (when (and old-str (not (string-empty-p old-str)))
            (opencode--insert-prefixed-lines old-str indent "- " 'opencode-diff-removed))
          (when (and new-str (not (string-empty-p new-str)))
            (opencode--insert-prefixed-lines new-str indent "+ " 'opencode-diff-added)))))
     ;; Structured edits array (test/alternative format)
     ((and edits (or (vectorp edits) (listp edits)))
      (let ((edit-seq (if (vectorp edits) (seq-into edits 'list) edits)))
        (dolist (edit edit-seq)
          (opencode-chat--render-single-edit edit))))
     ;; Diff API fallback: fetch from /session/:id/diff when no edits in input
     ((and (null edits)
           (opencode-chat--current-message-id)
           (opencode-chat--session-id))
      (opencode-chat--render-edit-from-diff-api path output dim-face))
     ;; Fallback: show raw output (old format or no edits)
     ((and output (stringp output) (not (string-empty-p output)))
      (opencode--insert-prefixed-lines output "   " "" dim-face)))
    ;; Make the entire edit body clickable — RET opens the file.
    (when (and path (> (point) edit-body-start))
      (put-text-property edit-body-start (point) 'opencode-file-path path)
      (put-text-property edit-body-start (point) 'keymap opencode-chat-message-file-map)
      (put-text-property edit-body-start (point) 'mouse-face 'highlight)
      (put-text-property edit-body-start (point) 'help-echo "RET: open file"))))

(defun opencode-chat--render-edit-from-diff-api (path output dim-face)
  "Fetch and render edit diff from the diff API for PATH.
Uses message-specific diffs first, falls back to session-wide diffs.
OUTPUT is shown as fallback when no matching diff is found.  Fetches
asynchronously if cache is missing, avoiding main-thread blocking."
  (let* ((msg-id (opencode-chat--current-message-id))
         (sid (opencode-chat--session-id))
         (buf (current-buffer))
         (diffs (or (gethash msg-id (opencode-chat--diff-cache))
                    (gethash "__session__" (opencode-chat--diff-cache)))))
    (when (and (null diffs)
               (not (gethash "__fetching__" (opencode-chat--diff-cache))))
      (puthash "__fetching__" t (opencode-chat--diff-cache))
      (opencode-backend-get-diff
       sid
       (lambda (response)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (remhash "__fetching__" (opencode-chat--diff-cache))
             (when-let* ((body (plist-get response :body)))
               (when (vectorp body)
                 (puthash "__session__" body (opencode-chat--diff-cache))
                  (opencode-chat--schedule-refresh))))))
       nil
       (when (fboundp 'opencode-chat--backend) (opencode-chat--backend))))
    (let ((file-diff (when (and path diffs (length> diffs 0))
                       (seq-find
                        (lambda (d)
                          (let ((dpath (or (plist-get d :file)
                                           (plist-get d :path) "")))
                            (or (string= dpath path)
                                (string-suffix-p (concat "/" (file-name-nondirectory path)) dpath)
                                (string-suffix-p (concat "/" (file-name-nondirectory dpath)) path))))
                        diffs))))
      (if file-diff
          (let ((shown-key (concat msg-id ":" (or path ""))))
            (if (gethash shown-key (opencode-chat--diff-shown))
                (insert (propertize "   (combined diff shown above)\n"
                                    'face 'font-lock-comment-face))
              (puthash shown-key t (opencode-chat--diff-shown))
              (opencode-chat--render-edit-inline-diff file-diff)))
        (when (and output (stringp output) (not (string-empty-p output)))
          (opencode--insert-prefixed-lines output "   " "" dim-face))))))

(defun opencode-chat--render-single-edit (edit)
  "Render a single EDIT operation as a mini diff hunk.
EDIT is a plist from the :edits array.  Supports classic format
(:type/:old_text/:new_text) and MCP format (:op/:pos/:lines)."
  (let* ((type (or (plist-get edit :type)
                   (plist-get edit :op)))
         (old-text (or (plist-get edit :old_text)
                       (plist-get edit :oldText)))
         (new-text (or (plist-get edit :new_text)
                       (plist-get edit :newText)
                       (plist-get edit :text)
                       (let ((lines (plist-get edit :lines)))
                         (cond
                          ((stringp lines) lines)
                          ((vectorp lines)
                           (mapconcat #'identity lines "\n"))
                          ((and (listp lines) lines)
                           (mapconcat #'identity lines "\n"))
                          (t nil)))))
         (line-ref (or (plist-get edit :line)
                       (plist-get edit :start_line)
                       (plist-get edit :after_line)
                       (plist-get edit :before_line)
                       (plist-get edit :pos)))
         (line-num (when (and line-ref (stringp line-ref))
                     (when (string-match "\\`\\([0-9]+\\)" line-ref)
                       (string-to-number (match-string 1 line-ref)))))
         (has-old (and old-text (stringp old-text) (not (string-empty-p old-text))))
         (has-new (and new-text (stringp new-text) (not (string-empty-p new-text))))
         (indent "   "))
    (when (or has-old has-new)
      (when (or type line-num)
        (insert (propertize
                 (format "%s%s%s\n" indent
                         (or type "edit")
                         (if line-num (format " L%d" line-num) ""))
                 'face 'opencode-diff-hunk-header)))
      (when has-old
        (opencode--insert-prefixed-lines old-text indent "- " 'opencode-diff-removed))
      (when has-new
        (opencode--insert-prefixed-lines new-text indent "+ " 'opencode-diff-added)))))

(defun opencode-chat--render-edit-inline-diff (file-diff)
  "Render FILE-DIFF as inline unified diff in the chat buffer.
FILE-DIFF is a plist from the diff API with :file, :before, :after,
:additions, :deletions, :patch."
  (let* ((path (or (plist-get file-diff :file)
                   (plist-get file-diff :path) ""))
         (patch (plist-get file-diff :patch))
         (before (plist-get file-diff :before))
         (after (plist-get file-diff :after))
         (additions (or (plist-get file-diff :additions) 0))
         (deletions (or (plist-get file-diff :deletions) 0))
         (indent "   ")
         (diff-text (or (and patch (not (string-empty-p patch)) patch)
                        (condition-case err
                            (opencode-diff--generate-unified before after path)
                          (error (opencode--debug "opencode-chat: inline diff generation failed: %S" err))))))
    (when (or (> additions 0) (> deletions 0))
      (insert (propertize (format "%s+%d -%d\n" indent additions deletions)
                          'face 'opencode-diff-hunk-header)))
    (if diff-text
        (opencode--insert-diff-lines diff-text indent 'font-lock-comment-face nil)
      (insert (propertize (format "%s(diff unavailable)\n" indent)
                          'face 'font-lock-comment-face)))))

;;; --- Apply-patch renderer ---

(defun opencode-chat--apply-patch-file-header (line)
  "Return the file path named by an apply_patch header LINE, or nil."
  (when (string-match
         "\\`\\*\\*\\* \\(?:Add\\|Update\\|Delete\\) File: \\(.+\\)\\'"
         line)
    (string-trim (match-string 1 line))))

(defun opencode-chat--apply-patch-operation (line)
  "Return the operation symbol named by an apply_patch header LINE."
  (when (string-match
         "\\`\\*\\*\\* \\(Add\\|Update\\|Delete\\) File: " line)
    (intern (downcase (match-string 1 line)))))

(defun opencode-chat--apply-patch-content-line (line)
  "Return LINE without its apply_patch diff prefix."
  (if (and (> (length line) 0)
           (memq (aref line 0) '(?\s ?+ ?-)))
      (substring line 1)
    line))

(defun opencode-chat--apply-patch-image (lines excluded-prefix)
  "Build a hunk image from LINES, excluding EXCLUDED-PREFIX lines."
  (let (image)
    (dolist (line lines (nreverse image))
      (unless (and (> (length line) 0)
                   (= (aref line 0) excluded-prefix))
        (push (opencode-chat--apply-patch-content-line line) image)))))

(defun opencode-chat--apply-patch-move-target (line)
  "Return the destination path named by apply_patch move LINE, or nil."
  (when (string-match "\\`\\*\\*\\* Move to: \\(.+\\)\\'" line)
    (string-trim (match-string 1 line))))

(defun opencode-chat--mark-patch-file-region (start end path)
  "Make patch text from START to END open PATH with RET or `o'."
  (when (and path (< start end))
    (put-text-property start end 'opencode-file-path path)
    (put-text-property start end 'keymap opencode-chat-message-file-map)
    (put-text-property start end 'mouse-face 'highlight)
    (put-text-property start end 'help-echo "RET: open file")))

(defun opencode-chat--render-apply-patch-body (input output &optional _metadata)
  "Render apply_patch INPUT as a colored, per-file clickable diff.
INPUT contains :patchText.  Each Add/Update/Delete file section is
tagged with its own file path, so RET or `o' opens the file belonging
to the patch line at point.  OUTPUT is shown only when no patch text is
available."
  (let ((patch (plist-get input :patchText))
        (indent "   ")
        section-start
        section-path
        section-operation
        hunk-header
        hunk-lines)
    (cl-labels
        ((finish-hunk
          ()
          (when hunk-header
            (let* ((lines (nreverse hunk-lines))
                   (pre-image (opencode-chat--apply-patch-image lines ?+))
                   (post-image (opencode-chat--apply-patch-image lines ?-))
                   (header-start (point))
                   (pre-offset 0)
                   (new-offset 0)
                   (header-metadata
                    (list :operation section-operation
                          :pre-image pre-image
                          :post-image post-image
                          :pre-offset 0
                          :post-offset 0)))
              (insert (propertize (format "%s%s\n" indent hunk-header)
                                  'face 'opencode-diff-hunk-header))
              (put-text-property header-start (point)
                                 'opencode-apply-patch-line header-metadata)
              (dolist (line lines)
                (let ((start (point))
                      (removed-p (string-prefix-p "-" line))
                      (added-p (string-prefix-p "+" line)))
                  (insert
                   (propertize
                    (format "%s%s\n" indent line)
                    'face (opencode-diff--line-face
                           line 'font-lock-comment-face)))
                  (put-text-property
                   start (point) 'opencode-apply-patch-line
                   (list :operation section-operation
                         :pre-image pre-image
                         :post-image post-image
                         :pre-offset pre-offset
                         :post-offset new-offset))
                  (unless added-p (cl-incf pre-offset))
                  (unless removed-p (cl-incf new-offset))))))
          (setq hunk-header nil
                hunk-lines nil)))
      (if (and (stringp patch) (not (string-empty-p patch)))
          (progn
            (dolist (line (string-lines patch))
              (cond
               ((member line '("*** Begin Patch" "*** End Patch"))
                nil)
               ((when-let* ((path (opencode-chat--apply-patch-file-header line)))
                  (finish-hunk)
                  (when section-start
                    (opencode-chat--mark-patch-file-region
                     section-start (point) section-path))
                  (setq section-start (point)
                        section-path path
                        section-operation
                        (opencode-chat--apply-patch-operation line))
                  (insert (propertize (format "%s%s\n" indent path) 'face 'link))
                  t))
               ((when-let* ((path (opencode-chat--apply-patch-move-target line)))
                  (setq section-path path)
                  (insert (propertize (format "%s→ %s\n" indent path) 'face 'link))
                   t))
               ((string-prefix-p "@@" line)
                (finish-hunk)
                (setq hunk-header line))
               ((string= line "*** End of File")
                (finish-hunk))
               (t
                ;; Add-file patches commonly omit an explicit @@ line.  Treat
                ;; their body (and other headerless bodies) as one hunk.
                (unless hunk-header
                  (setq hunk-header "@@"))
                (push line hunk-lines))))
            (finish-hunk)
            (when section-start
              (opencode-chat--mark-patch-file-region
               section-start (point) section-path)))
        (when (and output (stringp output) (not (string-empty-p output)))
          (opencode--insert-prefixed-lines
           output indent "" 'font-lock-comment-face))))))

;;; --- Todowrite renderer ---

(defun opencode-chat--render-todowrite-body (input output &optional _metadata)
  "Render todowrite tool as a compact todo list.
INPUT is the tool input plist with :todos.  OUTPUT is the JSON string
result (also the todo array).  Uses `opencode-todo--render-compact'
for consistent rendering."
  (let* ((todos (or (plist-get input :todos)
                    (when (and output (stringp output))
                      (condition-case err
                          (let ((parsed (json-parse-string
                                         output
                                         :object-type 'plist
                                         :array-type 'array
                                         :null-object nil
                                         :false-object :false)))
                            (if (vectorp parsed) parsed nil))
                        (error (opencode--debug "opencode-chat: todo JSON parse failed: %S" err)))))))
    (if (or (null todos) (= (length todos) 0))
        (insert (propertize "   No todos\n" 'face 'font-lock-comment-face))
      (opencode-todo--render-compact todos :indent "   " :bar-width 16))))

(provide 'opencode-tool-render)
;;; opencode-tool-render.el ends here
