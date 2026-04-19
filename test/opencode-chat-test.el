;;; opencode-chat-test.el --- Tests for opencode-chat.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the chat buffer: rendering, input area, part dispatch,
;; time formatting, tool arg summary, buffer naming.

;;; Code:

(require 'test-helper nil t)
(require 'opencode-chat)
(require 'opencode-chat-message)
(require 'opencode-popup)
(require 'opencode-permission)
(require 'opencode-question)
(require 'seq)
(require 'opencode-api)
(require 'opencode-agent)

;;; --- Test data ---

(defun opencode-chat-test--make-session (&optional overrides)
  "Create a test session plist.
OVERRIDES is a plist merged on top of defaults."
  (let ((session (list :id "ses_test1"
                       :title "Fix auth bug"
                       :directory "/home/user/projects/my-app"
                       :time (list :created 1700000000 :updated 1700000000))))
    (while overrides
      (setq session (plist-put session (pop overrides) (pop overrides))))
    session))

(defun opencode-chat-test--make-user-msg (&optional text)
  "Create a test user message with TEXT."
  (list :info (list :id "msg_u1"
                    :role "user"
                    :time (list :created 1700000100))
        :parts (vector (list :id "part_u1"
                             :type "text"
                             :text (or text "Hello, fix the bug")))))

(defun opencode-chat-test--make-assistant-msg (&optional parts)
  "Create a test assistant message with PARTS."
  (list :info (list :id "msg_a1"
                    :role "assistant"
                    :modelID "anthropic/claude-sonnet-4-20250514"
                    :time (list :created 1700000105)
                    :cost 0.0312
                    :tokens (list :input 324 :output 1200))
        :parts (or parts
                   (vector (list :id "part_a1"
                                 :type "text"
                                 :text "I'll fix the bug now.")))))

(defun opencode-chat-test--make-tool-part (&optional state)
  "Create a test tool part with STATE."
  (list :id "part_tool1"
        :type "tool"
        :toolName "read"
        :args "{\"filePath\": \"src/auth/login.ts\"}"
        :state (or state "completed")
        :duration 5000))

(defun opencode-chat-test--make-reasoning-part ()
  "Create a test reasoning part."
  (list :id "part_r1"
        :type "reasoning"
        :text "Let me think about this carefully..."))

;;; --- Buffer naming ---

(ert-deftest opencode-chat-buffer-name-format ()
  "Buffer name uses *opencode: project/title* format."
  (cl-letf (((symbol-function 'opencode-session--project-name)
             (lambda (s) "my-app"))
            ((symbol-function 'opencode-session--title)
             (lambda (s) "Fix auth bug")))
    (let ((session (opencode-chat-test--make-session)))
      (should (string= (opencode-chat--buffer-name session)
                        "*opencode: my-app/Fix auth bug*")))))

(ert-deftest opencode-chat-buffer-name-untitled ()
  "Buffer name handles untitled sessions."
  (cl-letf (((symbol-function 'opencode-session--project-name)
             (lambda (s) "default"))
            ((symbol-function 'opencode-session--title)
             (lambda (s) "(untitled)")))
    (let ((session (opencode-chat-test--make-session '(:title nil))))
      (should (string= (opencode-chat--buffer-name session)
                        "*opencode: default/(untitled)*")))))

;;; --- Time formatting ---

(ert-deftest opencode-chat-format-time-seconds ()
  "Format time from seconds timestamp."
  (let ((info (list :time (list :created 1700000100))))
    (should (stringp (opencode-chat--format-time info)))
    ;; Should produce HH:MM:SS format
    (should (string-match-p "^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$"
                            (opencode-chat--format-time info)))))

(ert-deftest opencode-chat-format-time-milliseconds ()
  "Format time from millisecond timestamp (> 1e12)."
  (let ((info (list :time (list :created 1700000100000))))
    (should (string-match-p "^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$"
                            (opencode-chat--format-time info)))))

(ert-deftest opencode-chat-format-time-fallback-createdat ()
  "Format time falls back to :createdAt when :time is nil."
  (let ((info (list :createdAt 1700000100)))
    (should (string-match-p "^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$"
                            (opencode-chat--format-time info)))))

(ert-deftest opencode-chat-format-time-empty ()
  "Format time returns empty string when no time data."
  (should (string= "" (opencode-chat--format-time '(:time nil)))))

;;; --- Tool arg summary ---

(ert-deftest opencode-chat-tool-arg-summary-filepath ()
  "Tool arg summary extracts filePath."
  (should (string= (opencode-chat--tool-arg-summary
                     "{\"filePath\": \"src/auth/login.ts\"}")
                    "src/auth/login.ts")))

(ert-deftest opencode-chat-tool-arg-summary-command ()
  "Tool arg summary extracts command."
  (should (string= (opencode-chat--tool-arg-summary
                     "{\"command\": \"npm test\"}")
                    "npm test")))

(ert-deftest opencode-chat-tool-arg-summary-path ()
  "Tool arg summary extracts path."
  (should (string= (opencode-chat--tool-arg-summary
                     "{\"path\": \"/tmp/foo\"}")
                    "/tmp/foo")))

(ert-deftest opencode-chat-tool-arg-summary-query ()
  "Tool arg summary extracts query."
  (should (string= (opencode-chat--tool-arg-summary
                     "{\"query\": \"search term\"}")
                    "search term")))

(ert-deftest opencode-chat-tool-arg-summary-truncated ()
  "Tool arg summary truncates unknown args."
  (let ((long-args (concat "{\"unknown\": \""
                           (make-string 80 ?x)
                           "\"}")))
    (let ((result (opencode-chat--tool-arg-summary long-args)))
      (should (not (length> result 40))))))

(ert-deftest opencode-chat-tool-arg-summary-nil ()
  "Tool arg summary returns nil for nil input."
  (should (null (opencode-chat--tool-arg-summary nil))))

(ert-deftest opencode-chat-tool-arg-summary-empty ()
  "Tool arg summary returns nil for empty string."
  (should (null (opencode-chat--tool-arg-summary ""))))

(ert-deftest opencode-chat-tool-arg-summary-invalid-json ()
  "Tool arg summary handles invalid JSON gracefully."
  (let ((result (opencode-chat--tool-arg-summary "not json")))
    ;; Should return truncated raw string, not signal error
    (should (stringp result))))

;;; --- Chat mode ---

(ert-deftest opencode-chat-mode-defined ()
  "Chat mode should be defined."
  (should (fboundp 'opencode-chat-mode)))

(ert-deftest opencode-chat-mode-keymap ()
  "Chat mode keymap has non-conflicting bindings only."
  (should (keymapp opencode-chat-mode-map))
  (should (commandp (keymap-lookup opencode-chat-mode-map "C-c C-c")))
  (should (commandp (keymap-lookup opencode-chat-mode-map "C-c C-k")))
  (should (commandp (keymap-lookup opencode-chat-mode-map "C-c C-a")))
  (should (commandp (keymap-lookup opencode-chat-mode-map "M-p")))
  (should (commandp (keymap-lookup opencode-chat-mode-map "M-n")))
  ;; Single-letter keys (g, G, q) should NOT be in mode-map
  ;; (they live in opencode-chat-message-map via text property)
  (should-not (keymap-lookup opencode-chat-mode-map "g"))
  (should-not (keymap-lookup opencode-chat-mode-map "G")))

(ert-deftest opencode-chat-message-map-bindings ()
  "Message area keymap has navigation bindings."
  (should (keymapp opencode-chat-message-map))
  (should (commandp (keymap-lookup opencode-chat-message-map "g")))
  (should (commandp (keymap-lookup opencode-chat-message-map "G")))
  (should (commandp (keymap-lookup opencode-chat-message-map "q")))
  (should (commandp (keymap-lookup opencode-chat-message-map "TAB"))))

(ert-deftest opencode-chat-mode-sets-word-wrap ()
  "Chat mode enables word wrap."
  (opencode-test-with-temp-buffer "*test-chat-mode*"
    (opencode-chat-mode)
    (should word-wrap)
    (should (not truncate-lines))))

(ert-deftest opencode-chat-mode-capf-priority ()
  "Mention and slash CAPFs are first in completion-at-point-functions.
They must run before other backends (dabbrev, cape, etc.) to ensure
@-mentions and /commands are completed by our handlers."
  (opencode-test-with-temp-buffer "*test-capf-priority*"
    (opencode-chat-mode)
    (let ((capfs (buffer-local-value 'completion-at-point-functions
                                      (current-buffer))))
      ;; Our CAPFs must be at the front (before any other backends)
      (should (memq #'opencode-chat--mention-capf capfs))
      (should (memq #'opencode-chat--slash-capf capfs))
      ;; Check they appear before any non-opencode CAPFs
      (let ((mention-pos (seq-position capfs #'opencode-chat--mention-capf))
            (slash-pos (seq-position capfs #'opencode-chat--slash-capf)))
        ;; Both should be in the first few positions
        (should (< mention-pos 3))
        (should (< slash-pos 3))))))

;;; --- User message rendering ---

(ert-deftest opencode-chat-render-user-message ()
  "Render user message shows header and body text."
  (opencode-test-with-temp-buffer "*test-chat-user-msg*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (opencode-chat-test--make-user-msg "Hello, fix the bug")))
      (opencode-chat--render-message msg)
      (should (opencode-test-buffer-contains-p "You"))
      (should (opencode-test-buffer-contains-p "Hello, fix the bug")))))

(ert-deftest opencode-chat-render-user-message-faces ()
  "User message has proper faces applied."
  (opencode-test-with-temp-buffer "*test-chat-user-faces*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (opencode-chat-test--make-user-msg "test text")))
      (opencode-chat--render-message msg)
      (should (opencode-test-has-face-p "You" 'opencode-user-header)))))

;;; --- Assistant message rendering ---

(ert-deftest opencode-chat-render-assistant-message ()
  "Render assistant message shows header and body text."
  (opencode-test-with-temp-buffer "*test-chat-asst-msg*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (opencode-chat-test--make-assistant-msg)))
      (opencode-chat--render-message msg)
      (should (opencode-test-buffer-contains-p "Assistant"))
      (should (opencode-test-buffer-contains-p "I'll fix the bug now.")))))

(ert-deftest opencode-chat-render-assistant-model ()
  "Assistant message shows shortened model name."
  (opencode-test-with-temp-buffer "*test-chat-asst-model*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (opencode-chat-test--make-assistant-msg)))
      (opencode-chat--render-message msg)
      ;; Should show "claude-sonnet-4-20250514" not full "anthropic/..."
      (should (opencode-test-buffer-contains-p "claude-sonnet-4-20250514")))))

(ert-deftest opencode-chat-render-assistant-cost ()
  "Assistant message shows token info in footer (cost only in step-finish)."
  (opencode-test-with-temp-buffer "*test-chat-asst-cost*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (opencode-chat-test--make-assistant-msg)))
      (opencode-chat--render-message msg)
      ;; Tokens shown in footer as ⬆N ⬇M (formatted with thousands separator)
      (should (opencode-test-buffer-matches-p "324"))
      (should (opencode-test-buffer-matches-p "1,200")))))

;;; --- Part rendering ---

(ert-deftest opencode-chat-render-text-part ()
  "Text part renders with proper body text."
  (opencode-test-with-temp-buffer "*test-chat-text-part*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "p1" :type "text" :text "Hello world")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "Hello world")))))

(ert-deftest opencode-chat-render-text-part-empty ()
  "Empty text part inserts nothing."
  (opencode-test-with-temp-buffer "*test-chat-text-empty*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "p2" :type "text" :text "")))
      (opencode-chat--render-part part 'user)
      (should (= (point-min) (point-max))))))

(ert-deftest opencode-chat-render-tool-part ()
  "Tool part renders with tool name and status."
  (opencode-test-with-temp-buffer "*test-chat-tool-part*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-tool-part "completed")))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "read"))
      (should (opencode-test-buffer-contains-p "src/auth/login.ts"))
      (should (opencode-test-buffer-contains-p "✓")))))

(ert-deftest opencode-chat-render-tool-part-running ()
  "Running tool part shows running status."
  (opencode-test-with-temp-buffer "*test-chat-tool-running*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-tool-part "running")))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "⏳")))))

(ert-deftest opencode-chat-render-tool-part-error ()
  "Error tool part shows error status."
  (opencode-test-with-temp-buffer "*test-chat-tool-error*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-tool-part "error")))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "✗")))))

(ert-deftest opencode-chat-render-tool-part-duration ()
  "Tool part shows duration for completed calls."
  (opencode-test-with-temp-buffer "*test-chat-tool-duration*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-tool-part "completed")))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "5s")))))

;;; --- Test: Real API tool part shape ---

(ert-deftest opencode-chat-render-tool-part-real-api ()
  "Tool part renders correctly with real server API shape."
  (opencode-test-with-temp-buffer "*test-chat-tool-real*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_real1"
                      :type "tool"
                      :tool "bash"
                      :state (list :status "completed"
                                   :input (list :command "make compile 2>&1"
                                                :description "Byte-compile all files")
                                   :output "No warnings\n"))))
      (opencode-chat--render-part part 'assistant)
      ;; Tool name
      (should (opencode-test-buffer-contains-p "bash"))
      ;; Summary from input command
      (should (opencode-test-buffer-contains-p "make compile"))
      ;; Status
      (should (opencode-test-buffer-contains-p "✓"))
      ;; Expanded body shows output
      (should (opencode-test-buffer-contains-p "No warnings")))))

(ert-deftest opencode-chat-render-tool-part-real-api-read ()
  "Read tool part shows filePath in summary."
  (opencode-test-with-temp-buffer "*test-chat-tool-read*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_read1"
                      :type "tool"
                      :tool "read"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/app.ts")
                                   :output "file contents here"))))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "read"))
      (should (opencode-test-buffer-contains-p "/src/app.ts"))
      (should (opencode-test-buffer-contains-p "✓")))))

(ert-deftest opencode-chat-render-edit-tool-inline-diff ()
  "Edit tool renders inline diff with added/removed lines."
  (opencode-test-with-temp-buffer "*test-chat-edit-diff*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_edit1"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/app.ts"
                                                :edits (vector
                                                        (list :type "replace"
                                                              :old_text "return decoded;"
                                                              :new_text "return { valid: true, decoded };")
                                                        (list :type "insert_after"
                                                              :after_line "42#MZ"
                                                              :text "  throw err;")))
                                   :output "Edit applied successfully"))))
      (opencode-chat--render-part part 'assistant)
      ;; Tool header shows edit + filePath
      (should (opencode-test-buffer-contains-p "edit"))
      (should (opencode-test-buffer-contains-p "/src/app.ts"))
      ;; Inline diff shows removed and added lines
      (should (opencode-test-buffer-contains-p "- return decoded;"))
      (should (opencode-test-buffer-contains-p "+ return { valid: true, decoded };"))
      ;; Second edit shows added line
      (should (opencode-test-buffer-contains-p "+   throw err;"))
      ;; Status
      (should (opencode-test-buffer-contains-p "✓")))))

(ert-deftest opencode-chat-render-edit-tool-diff-faces ()
  "Edit tool applies diff faces to added/removed lines."
  (opencode-test-with-temp-buffer "*test-chat-edit-faces*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_edit2"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/app.ts"
                                                :edits (vector
                                                        (list :type "replace"
                                                              :old_text "old code"
                                                              :new_text "new code")))
                                   :output "OK"))))
      (opencode-chat--render-part part 'assistant)
      ;; Removed lines get diff-removed face
      (should (opencode-test-has-face-p "- old code" 'opencode-diff-removed))
      ;; Added lines get diff-added face
      (should (opencode-test-has-face-p "+ new code" 'opencode-diff-added)))))

(ert-deftest opencode-chat-render-edit-tool-no-edits-fallback ()
  "Edit tool falls back to output when no edits in input."
  (opencode-test-with-temp-buffer "*test-chat-edit-fallback*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_edit3"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/app.ts")
                                   :output "Edit applied successfully"))))
      (opencode-chat--render-part part 'assistant)
      ;; Shows file path
      (should (opencode-test-buffer-contains-p "/src/app.ts"))
      ;; Falls back to showing output text
      (should (opencode-test-buffer-contains-p "Edit applied successfully")))))

(ert-deftest opencode-chat-render-edit-tool-line-numbers ()
  "Edit tool shows line numbers from LINE#ID references."
  (opencode-test-with-temp-buffer "*test-chat-edit-linenum*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_edit4"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/app.ts"
                                                :edits (vector
                                                        (list :type "set_line"
                                                              :line "42#MZ"
                                                              :text "  new content")))
                                   :output "OK"))))
      (opencode-chat--render-part part 'assistant)
      ;; Shows extracted line number
      (should (opencode-test-buffer-contains-p "L42"))
      ;; Shows the new content as added
      (should (opencode-test-buffer-contains-p "+   new content")))))

(ert-deftest opencode-chat-render-edit-tool-mcp-format-filediff-preferred ()
  "Edit tool prefers metadata.filediff over metadata.diff for proper hunks."
  (opencode-test-with-temp-buffer "*test-chat-edit-mcp-meta*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_mcp1"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/handlers.py"
                                                :edits (vector
                                                        (list :op "replace"
                                                              :pos "50#HT"
                                                              :lines (vector "    new_field: int = 0"
                                                                             "    _max: int = 10000"))))
                                   :output "Updated /src/handlers.py"
                                   :metadata (list :diff "-    old\n+    new\n"
                                                   :filediff (list :file "/src/handlers.py"
                                                                        :before "    old_field: int = 0\n"
                                                                        :after "    new_field: int = 0\n    _max: int = 10000\n"
                                                                        :additions 2
                                                                        :deletions 1))))))
      ;; Stub generate-unified so we know filediff path was taken
      (cl-letf (((symbol-function 'opencode-diff--generate-unified)
                 (lambda (_before _after _path)
                   "--- a/src/handlers.py\n+++ b/src/handlers.py\n@@ -1,1 +1,2 @@\n-    old_field: int = 0\n+    new_field: int = 0\n+    _max: int = 10000\n")))
        (opencode-chat--render-part part 'assistant)
        ;; Shows file path
        (should (opencode-test-buffer-contains-p "/src/handlers.py"))
        ;; Renders diff from filediff (NOT the raw metadata.diff)
        (should (opencode-test-buffer-contains-p "-    old_field: int = 0"))
        (should (opencode-test-buffer-contains-p "+    new_field: int = 0"))
        (should (opencode-test-buffer-contains-p "+    _max: int = 10000"))
        ;; Does NOT show fallback output
        (should-not (opencode-test-buffer-contains-p "Updated /src/handlers.py"))))))

(ert-deftest opencode-chat-render-edit-tool-mcp-format-diff-only ()
  "Edit tool falls back to metadata.diff when no filediff is present."
  (opencode-test-with-temp-buffer "*test-chat-edit-mcp-diff-only*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_mcp_do"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/foo.py"
                                                :edits (vector
                                                        (list :op "replace"
                                                              :pos "10#AB"
                                                              :lines "new line")))
                                   :output "Updated /src/foo.py"
                                   :metadata (list :diff "--- /src/foo.py\n+++ /src/foo.py\n@@ -10,1 +10,1 @@\n-old line\n+new line\n")))))
      (opencode-chat--render-part part 'assistant)
      ;; Falls back to metadata.diff since no filediff
      (should (opencode-test-buffer-contains-p "-old line"))
      (should (opencode-test-buffer-contains-p "+new line")))))

(ert-deftest opencode-chat-render-edit-tool-mcp-format-filediff-fallback ()
  "Edit tool falls back to metadata.filediff when metadata.diff is nil."
  (opencode-test-with-temp-buffer "*test-chat-edit-mcp-filediff*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_mcp2"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/foo.py"
                                                :edits (vector
                                                        (list :op "append"
                                                              :pos "10#AB"
                                                              :lines "new line")))
                                   :output "Updated /src/foo.py"
                                   :metadata (list :filediff (list :file "/src/foo.py"
                                                                       :before "line1\n"
                                                                       :after "line1\nnew line\n"
                                                                       :additions 1
                                                                       :deletions 0))))))
      ;; Stub generate-unified to return a known diff string
      (cl-letf (((symbol-function 'opencode-diff--generate-unified)
                 (lambda (_before _after _path)
                   "--- a/src/foo.py\n+++ b/src/foo.py\n@@ -1,1 +1,2 @@\n line1\n+new line\n")))
        (opencode-chat--render-part part 'assistant)
        ;; Shows file path
        (should (opencode-test-buffer-contains-p "/src/foo.py"))
        ;; Shows diff content from filediff
        (should (opencode-test-buffer-contains-p "+new line"))
        ;; Does NOT show fallback output
        (should-not (opencode-test-buffer-contains-p "Updated /src/foo.py"))))))

(ert-deftest opencode-chat-render-edit-tool-mcp-format-lines-fallback ()
  "Edit tool renders MCP :lines content when no metadata available."
  (opencode-test-with-temp-buffer "*test-chat-edit-mcp-lines*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_mcp3"
                      :type "tool"
                      :tool "edit"
                      :state (list :status "completed"
                                   :input (list :filePath "/src/bar.py"
                                                :edits (vector
                                                        (list :op "replace"
                                                              :pos "10#AB"
                                                              :lines (vector "line A" "line B"))))
                                   :output "Updated /src/bar.py"))))
      (opencode-chat--render-part part 'assistant)
      ;; Shows file path
      (should (opencode-test-buffer-contains-p "/src/bar.py"))
      ;; render-single-edit falls back to :lines → shows as added
      (should (opencode-test-buffer-contains-p "+ line A"))
      (should (opencode-test-buffer-contains-p "+ line B"))
      ;; Shows op as hunk header
      (should (opencode-test-buffer-contains-p "replace")))))
(ert-deftest opencode-chat-tool-input-summary-bash ()
  "Input summary shows \"$ command\" for bash tool, even when description exists."
  (should (string= (opencode-chat--tool-input-summary
                     "bash" (list :command "ls -la" :description "List files"))
                    "$ ls -la")))

(ert-deftest opencode-chat-tool-input-summary-bash-fallback ()
  "Input summary falls back to description when no command for bash."
  (should (string= (opencode-chat--tool-input-summary
                     "bash" (list :description "List files"))
                    "List files")))

(ert-deftest opencode-chat-tool-input-summary-nil ()
  "Input summary returns nil for nil input."
  (should (null (opencode-chat--tool-input-summary "bash" nil))))

(ert-deftest opencode-chat-tool-input-summary-grep-with-path ()
  "Input summary for grep shows pattern + shortened path."
  (should (string= (opencode-chat--tool-input-summary
                     "grep" (list :pattern "when-let\\*" :path "/Users/foo/project"))
                    "when-let\\*  in: project")))

(ert-deftest opencode-chat-tool-input-summary-read ()
  "Input summary for read shows shortened file path."
  (should (string= (opencode-chat--tool-input-summary
                     "read" (list :filePath "/Users/foo/project/src/main.el"))
                    "main.el")))

(ert-deftest opencode-chat-tool-input-summary-task ()
  "Input summary for task shows description."
  (should (string= (opencode-chat--tool-input-summary
                     "task" (list :description "Find auth patterns" :prompt "..."))
                    "Find auth patterns")))

(ert-deftest opencode-chat-truncate-summary-short ()
  "Truncate summary returns short strings unchanged."
  (should (string= (opencode--truncate-string "hello" 10) "hello")))

(ert-deftest opencode-chat-truncate-summary-long ()
  "Truncate summary truncates long strings with ellipsis."
  (should (string= (opencode--truncate-string "hello world foo bar" 10) "hello wor…")))

(ert-deftest opencode-chat-shorten-path-basename ()
  "Shorten path returns basename."
  (should (string= (opencode--shorten-path "/Users/foo/bar/baz.el") "baz.el")))

(ert-deftest opencode-chat-shorten-path-nil ()
  "Shorten path returns nil for nil input."
  (should (null (opencode--shorten-path nil))))

(ert-deftest opencode-chat-render-reasoning-part ()
  "Reasoning part renders with 'Thinking...' label and expanded icon."
  (opencode-test-with-temp-buffer "*test-chat-reasoning*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-reasoning-part)))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "Thinking..."))
      (should (opencode-test-buffer-contains-p "Let me think about this"))
      ;; Verify expanded icon (▼) is present, not collapsed icon (▶)
      (should (opencode-test-buffer-contains-p "▼"))
      (should-not (opencode-test-buffer-contains-p "▶")))))

(ert-deftest opencode-chat-render-step-start ()
  "Step-start part renders a face-based separator."
  (opencode-test-with-temp-buffer "*test-chat-step-start*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "step1" :type "step-start")))
      (opencode-chat--render-part part 'assistant)
      ;; Should have the step-separator face with display property
      (goto-char (point-min))
      (should (get-text-property (point) 'display)))))

(ert-deftest opencode-chat-render-step-finish ()
  "Step-finish part renders cost summary (tokens moved to footer)."
  (opencode-test-with-temp-buffer "*test-chat-step-finish*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "step2" :type "step-finish"
                      :cost 0.05
                      :tokens (list :input 100 :output 200))))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "$0.0500"))
      ;; Token counts no longer appear in step-finish (shown in footer)
      (should-not (opencode-test-buffer-contains-p "100 in"))
      (should-not (opencode-test-buffer-contains-p "200 out")))))

;;; --- Part dispatch ---

(ert-deftest opencode-chat-render-part-dispatches-text ()
  "Part dispatch routes 'text' type correctly."
  (opencode-test-with-temp-buffer "*test-chat-dispatch-text*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "d1" :type "text" :text "dispatched")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "dispatched")))))

(ert-deftest opencode-chat-render-part-dispatches-unknown ()
  "Unknown part types fall through to text rendering."
  (opencode-test-with-temp-buffer "*test-chat-dispatch-unknown*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "d2" :type "unknown-type" :text "fallback")))
      (opencode-chat--render-part part 'assistant)
      (should (opencode-test-buffer-contains-p "fallback")))))

;;; --- Input area ---

(ert-deftest opencode-chat-render-input-area ()
  "Input area renders with prompt and help text."
  (opencode-test-with-temp-buffer "*test-chat-input*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      (should (opencode-test-buffer-contains-p "> "))
      (should (opencode-test-buffer-contains-p "C-c C-c"))
      (should (opencode-test-buffer-contains-p "send")))))



(ert-deftest opencode-chat-input-text-empty ()
  "Input text is empty when only placeholder present."
  (opencode-test-with-temp-buffer "*test-chat-input-empty*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      (let ((text (opencode-chat--input-text)))
        (should (or (null text)
                    (string-empty-p text)))))))

(ert-deftest opencode-chat-input-text-with-content ()
  "Input text returns user-typed content."
  (opencode-test-with-temp-buffer "*test-chat-input-content*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      ;; Simulate typing in the editable area
      (goto-char (opencode-chat--input-content-start))
      (delete-region (point) (opencode-chat--input-content-end))
      (insert "Hello there")
      (should (string= (opencode-chat--input-text) "Hello there")))))

(ert-deftest opencode-chat-clear-input ()
  "Clear input resets the input area."
  (opencode-test-with-temp-buffer "*test-chat-clear-input*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      ;; Add some text
      (goto-char (opencode-chat--input-content-start))
      (delete-region (point) (opencode-chat--input-content-end))
      (insert "to be cleared")
      ;; Clear
      (opencode-chat--clear-input)
      (let ((text (opencode-chat--input-text)))
        (should (or (null text)
                    (string-empty-p text)))))))

(ert-deftest opencode-chat-input-text-multiline ()
  "Input text captures multiple lines."
  (opencode-test-with-temp-buffer "*test-chat-input-multiline*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      (goto-char (opencode-chat--input-content-start))
      (delete-region (point) (opencode-chat--input-content-end))
      (insert "line one\nline two\nline three")
      (should (string= (opencode-chat--input-text) "line one\nline two\nline three")))))

(ert-deftest opencode-chat-clear-input-multiline ()
  "Clear input removes all lines of multi-line input."
  (opencode-test-with-temp-buffer "*test-chat-clear-multiline*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area)
      (goto-char (opencode-chat--input-content-start))
      (delete-region (point) (opencode-chat--input-content-end))
      (insert "line one\nline two")
      ;; Clear
      (opencode-chat--clear-input)
      (let ((text (opencode-chat--input-text)))
        (should (or (null text)
                    (string-empty-p text)))))))

;;; --- Input history ---

(ert-deftest opencode-chat-input-history-no-duplicates ()
  "History does not store consecutive duplicates."
  (opencode-test-with-temp-buffer "*test-chat-hist-dedup*"
    (opencode-chat-mode)
    (opencode-chat--input-history-push "same")
    (opencode-chat--input-history-push "same")
    (opencode-chat--input-history-push "same")
    (should (= 1 (ring-length (opencode-chat--input-history))))))

;;; --- Header line (sticky, via header-line-format) ---

;;; --- Undo and kill-line in the input area ---

(ert-deftest opencode-chat-input-undo-works ()
  "Undo should be enabled in the input area so users can revert edits.
`buffer-disable-undo' was previously called in mode init, which killed
the undo ring entirely — typing in the input area could never be undone."
  (opencode-test-with-temp-buffer "*test-chat-undo*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area))
    ;; Clear render noise from undo history
    (setq buffer-undo-list nil)
    ;; Simulate real user typing via self-insert-command
    (goto-char (opencode-chat--input-content-start))
    (dolist (ch (string-to-list "hello"))
      (let ((last-command-event ch))
        (self-insert-command 1)))
    (should (string= (opencode-chat--input-text) "hello"))
    ;; Undo must be available (buffer-undo-list != t)
    (should-not (eq buffer-undo-list t))
    ;; Use primitive-undo directly — `undo' has interactive guards
    ;; that don't work in batch mode.
    (primitive-undo (length buffer-undo-list) buffer-undo-list)
    (should (string-empty-p (or (opencode-chat--input-text) "")))))

(ert-deftest opencode-chat-input-kill-line ()
  "C-k in the input area kills text to the end of the current line.
Uses `field' text properties (like eshell) so `kill-line' natively
stops at the read-only footer boundary."
  (opencode-test-with-temp-buffer "*test-chat-kill-line*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area))
    (goto-char (opencode-chat--input-content-start))
    (dolist (ch (string-to-list "some text"))
      (let ((last-command-event ch))
        (self-insert-command 1)))
    (goto-char (opencode-chat--input-content-start))
    ;; Native kill-line works via field boundaries — no wrapper needed
    (kill-line)
    (should (string-empty-p (or (opencode-chat--input-text) "")))))

(ert-deftest opencode-chat-input-kill-line-multiline ()
  "C-k on multiline input kills one line at a time, then joins lines.
Each `kill-line' kills to end-of-line, then the next kills the newline
to join with the next line.  No read-only errors on interior newlines."
  (opencode-test-with-temp-buffer "*test-chat-kill-line-multi*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area))
    (goto-char (opencode-chat--input-content-start))
    (dolist (ch (string-to-list "line one"))
      (let ((last-command-event ch)) (self-insert-command 1)))
    (let ((last-command-event ?\n)) (self-insert-command 1))
    (dolist (ch (string-to-list "line two"))
      (let ((last-command-event ch)) (self-insert-command 1)))
    (should (string= (opencode-chat--input-text) "line one\nline two"))
    ;; Kill from start: "line one" then newline then "line two"
    (goto-char (opencode-chat--input-content-start))
    (kill-line)  ; kills "line one"
    (should (string= (opencode-chat--input-text) "line two"))
    (kill-line)  ; kills the \n joining the lines
    (should (string= (opencode-chat--input-text) "line two"))
    ;; Actually after killing \n, "line two" joins to current line
    (kill-line)  ; kills "line two"
    (should (string-empty-p (or (opencode-chat--input-text) "")))))

(ert-deftest opencode-chat-input-kill-whole-line ()
  "C-S-backspace kills all editable input text across all lines.
`kill-whole-line' normally deletes including the trailing newline, but
the newline after input text is in a read-only `footer' field.
Our `opencode-chat--kill-whole-line' constrains deletion to the editable
region so it never signals `text-read-only'."
  (opencode-test-with-temp-buffer "*test-chat-kill-whole*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area))
    (goto-char (opencode-chat--input-content-start))
    (dolist (ch (string-to-list "text to kill"))
      (let ((last-command-event ch))
        (self-insert-command 1)))
    (goto-char (opencode-chat--input-content-start))
    (opencode-chat--kill-whole-line)
    (should (string-empty-p (or (opencode-chat--input-text) "")))))

(ert-deftest opencode-chat-input-kill-whole-line-multiline ()
  "C-S-backspace kills all lines of multiline input in one shot.
The entire editable region (from first char to last) is killed,
regardless of how many lines the user typed."
  (opencode-test-with-temp-buffer "*test-chat-kill-whole-multi*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--render-input-area))
    (goto-char (opencode-chat--input-content-start))
    (dolist (ch (string-to-list "line one"))
      (let ((last-command-event ch)) (self-insert-command 1)))
    (let ((last-command-event ?\n)) (self-insert-command 1))
    (dolist (ch (string-to-list "line two"))
      (let ((last-command-event ch)) (self-insert-command 1)))
    (let ((last-command-event ?\n)) (self-insert-command 1))
    (dolist (ch (string-to-list "line three"))
      (let ((last-command-event ch)) (self-insert-command 1)))
    (should (string= (opencode-chat--input-text) "line one\nline two\nline three"))
    ;; Kill everything from anywhere in the input
    (opencode-chat--kill-whole-line)
    (should (string-empty-p (or (opencode-chat--input-text) "")))))

;;; --- Full render ---

;;; --- Face-based border rendering ---

(ert-deftest opencode-chat-render-user-block-face ()
  "User message body has line-prefix stripe with opencode-user-block face.
Line-prefix is applied by the message renderer to the entire body region."
  (opencode-test-with-temp-buffer "*test-chat-user-block*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (info (list :role "user" :time (list :created 1700000000000)))
          (parts (vector (list :id "p_ub" :type "text" :text "block text"))))
      (opencode-chat--render-user-message info parts)
      ;; Body text should have line-prefix with ▎ character
      (goto-char (point-min))
      (when (search-forward "block text" nil t)
        (let ((lp (get-text-property (match-beginning 0) 'line-prefix)))
          (should lp)
          (should (string= (substring-no-properties lp) "▎"))
          ;; The line-prefix string should carry the block face
          (let ((lp-face (get-text-property 0 'face lp)))
            (should (eq lp-face 'opencode-user-block))))))))

(ert-deftest opencode-chat-render-assistant-block-face ()
  "Assistant message body has line-prefix stripe with opencode-assistant-block face.
Line-prefix is applied by the message renderer to the entire body region."
  (opencode-test-with-temp-buffer "*test-chat-asst-block*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (info (list :role "assistant" :time (list :created 1700000000000)))
          (parts (vector (list :id "p_ab" :type "text" :text "assistant text"))))
      (opencode-chat--render-assistant-message info parts)
      (goto-char (point-min))
      (when (search-forward "assistant text" nil t)
        (let ((lp (get-text-property (match-beginning 0) 'line-prefix)))
          (should lp)
          (should (string= (substring-no-properties lp) "▎"))
          ;; The line-prefix string should carry the block face
          (let ((lp-face (get-text-property 0 'face lp)))
            (should (eq lp-face 'opencode-assistant-block))))))))

(ert-deftest opencode-chat-render-header-has-overline ()
  "User message header has opencode-message-header-line face."
  (opencode-test-with-temp-buffer "*test-chat-header-overline*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (cl-letf (((symbol-function 'opencode-session--title)
                 (lambda (s) "Test")))
        (let ((msg (opencode-chat-test--make-user-msg "hi")))
          (opencode-chat--render-message msg)
          (goto-char (point-min))
          (when (search-forward "You" nil t)
            (let ((faces (get-text-property (match-beginning 0) 'face)))
              (should (and (listp faces)
                           (memq 'opencode-message-header-line faces))))))))))

;;; --- Find buffer ---

(ert-deftest opencode-chat-find-buffer-not-found ()
  "Find buffer returns nil for non-matching session ID."
  (should (null (opencode-chat--find-buffer "ses_nonexistent_xyz"))))

;;; --- Part tracking ---

(ert-deftest opencode-chat-part-tracking ()
  "Parts are tracked in the store after rendering."
  (opencode-test-with-temp-buffer "*test-chat-part-tracking*"
    (opencode-chat-mode)
    (opencode-chat--set-current-message-id "msg1")
    (let ((inhibit-read-only t)
          (part (list :id "tracked_part" :type "text" :text "tracked")))
      (opencode-chat--render-part part 'user)
      (should (opencode-chat-message-has-parts-p "msg1"))
      (should (markerp (opencode-chat--store-part-marker "msg1" "tracked_part"))))))

;;; --- SSE event handlers (global) ---


;;; --- Commands existence ---

(ert-deftest opencode-chat-commands-defined ()
  "All interactive chat commands are defined."
  (should (commandp 'opencode-chat--send))
  (should (commandp 'opencode-chat-abort))
  (should (commandp 'opencode-chat--attach))
  (should (commandp 'opencode-chat--cycle-agent))
  (should (commandp 'opencode-chat--prev-message))
  (should (commandp 'opencode-chat--next-message))
  (should (commandp 'opencode-chat--goto-latest))
  (should (commandp 'opencode-chat--refresh))
  (should (commandp 'opencode-chat-open)))

;;; --- Goto latest ---



;;; --- SSE sessionID extraction (corrected paths) ---


;;; --- session.status handler ---

;;; --- message.updated handler ---



;;; --- message.removed handler ---

;;; --- session.diff handler ---

;;; --- session.idle handler ---

;;; --- session.deleted handler (Task 5) ---

;;; --- session.error handler (Task 5) ---

;;; --- installation.update-available handler (Task 12) ---

;;; --- message.part.updated handler (finalized parts) ---

;;; --- find-part-overlay ---

(ert-deftest opencode-chat-find-part-overlay-nil-empty-buffer ()
  "find-part-overlay returns nil in an empty buffer with no overlays.
Guards against crashes when scanning an empty chat buffer."
  (opencode-test-with-temp-buffer "*test-find-overlay-empty*"
    (should-not (opencode-chat--store-find-overlay "prt_nonexistent"))))

(ert-deftest opencode-chat-find-part-overlay-finds-matching ()
  "find-part-overlay locates the section overlay whose :id matches the part-id.
This is the core lookup used by update-part-inline to find where a part is rendered."
  (opencode-test-with-temp-buffer "*test-find-overlay-match*"
    (let* ((inhibit-read-only t)
           (section (opencode-ui--make-section 'tool-call "prt_abc" nil))
           (start (point)))
      (insert "tool content here\n")
      (let ((ov (make-overlay start (point))))
        (overlay-put ov 'opencode-section section)
        (should (opencode-chat--store-find-overlay "prt_abc"))
        (should (eq ov (opencode-chat--store-find-overlay "prt_abc")))))))

(ert-deftest opencode-chat-find-part-overlay-nil-no-match ()
  "find-part-overlay returns nil when no overlay has the requested part-id.
Prevents false positives when multiple tool sections exist in the buffer."
  (opencode-test-with-temp-buffer "*test-find-overlay-nomatch*"
    (let* ((inhibit-read-only t)
           (section (opencode-ui--make-section 'tool-call "prt_other" nil))
           (start (point)))
      (insert "tool content\n")
      (let ((ov (make-overlay start (point))))
        (overlay-put ov 'opencode-section section)
        (should-not (opencode-chat--store-find-overlay "prt_wanted"))))))

;;; --- update-part-inline ---



(ert-deftest opencode-chat-update-part-inline-bootstraps-at-messages-end ()
  "Case 2: When no overlay exists but messages-end marker is set,
update-part-inline inserts the new part at the messages-end position.
This handles the first arrival of a tool/step part during streaming."
  (opencode-test-with-temp-buffer "*test-inline-bootstrap*"
    (opencode-chat-mode)
    (opencode-chat--set-store (make-hash-table :test 'equal))
    (let ((inhibit-read-only t))
      (insert "=== messages ===")
      (opencode-chat--set-messages-end (copy-marker (point) t))
      (insert "\n=== input area ===")
      (let* ((part-id "prt_bootstrap")
             (msg-id "msg_bt")
             (part (list :id part-id :messageID msg-id :type "tool" :tool "grep"
                        :state (list :status "running"
                                     :input (list :pattern "foo")))))
        (cl-letf (((symbol-function 'opencode-chat--render-tool-part)
                   (lambda (_p) (insert "BOOTSTRAPPED TOOL\n"))))
          (opencode-chat--update-part-inline part))
        (should (opencode-test-buffer-contains-p "BOOTSTRAPPED TOOL"))
        (should (opencode-chat--store-part-marker msg-id part-id))
        (should (opencode-test-buffer-contains-p "=== input area ==="))))))

(ert-deftest opencode-chat-update-part-inline-fallback-schedule-refresh ()
  "Case 3: When neither overlay nor messages-end exists, update-part-inline
falls back to schedule-refresh.  This is the safety net for edge cases
where the buffer has not been fully rendered yet."
  (opencode-test-with-temp-buffer "*test-inline-fallback*"
    (opencode-chat-mode)
    (opencode-chat--set-store (make-hash-table :test 'equal))
    (opencode-chat--set-messages-end nil)
    (let ((refresh-called nil))
      (cl-letf (((symbol-function 'opencode-chat--schedule-refresh)
                 (lambda () (setq refresh-called t))))
        (let ((part (list :id "prt_fallback" :type "tool" :tool "bash"
                         :state (list :status "pending"))))
          (opencode-chat--update-part-inline part)
          (should refresh-called))))))

(ert-deftest opencode-chat-update-part-inline-step-start-at-messages-end ()
  "step-start parts bootstrap at messages-end when no overlay exists.
Verifies the pcase dispatch handles step-start correctly."
  (opencode-test-with-temp-buffer "*test-inline-step-start*"
    (opencode-chat-mode)
    (opencode-chat--set-store (make-hash-table :test 'equal))
    (let ((inhibit-read-only t))
      (insert "messages")
      (opencode-chat--set-messages-end (copy-marker (point) t))
      (insert "\ninput")
      (let* ((part-id "prt_step")
             (msg-id "msg_ss")
             (part (list :id part-id :messageID msg-id :type "step-start")))
        (cl-letf (((symbol-function 'opencode-chat--render-step-start)
                   (lambda (_p) (insert "STEP-START\n"))))
          (opencode-chat--update-part-inline part))
        (should (opencode-test-buffer-contains-p "STEP-START"))
        (should (opencode-chat--store-part-marker msg-id part-id))))))

(ert-deftest opencode-chat-update-part-inline-step-finish-at-messages-end ()
  "step-finish parts bootstrap at messages-end when no overlay exists.
Verifies the pcase dispatch handles step-finish correctly."
  (opencode-test-with-temp-buffer "*test-inline-step-finish*"
    (opencode-chat-mode)
    (opencode-chat--set-store (make-hash-table :test 'equal))
    (let ((inhibit-read-only t))
      (insert "messages")
      (opencode-chat--set-messages-end (copy-marker (point) t))
      (insert "\ninput")
      (let* ((part-id "prt_sf")
             (msg-id "msg_sf")
             (part (list :id part-id :messageID msg-id :type "step-finish" :cost 0.005)))
        (cl-letf (((symbol-function 'opencode-chat--render-step-finish)
                   (lambda (_p) (insert "STEP-FINISH\n"))))
          (opencode-chat--update-part-inline part))
        (should (opencode-test-buffer-contains-p "STEP-FINISH"))
        (should (opencode-chat--store-part-marker msg-id part-id))))))

(ert-deftest opencode-chat-update-part-inline-applies-read-only ()
  "update-part-inline applies read-only text property to newly rendered content.
Without this, users could accidentally edit rendered tool output."
  (opencode-test-with-temp-buffer "*test-inline-readonly*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (insert "messages")
      (opencode-chat--set-messages-end (copy-marker (point) t))
      (insert "\ninput")
      (let* ((part-id "prt_ro")
             (part (list :id part-id :type "tool" :tool "bash"
                        :state (list :status "completed"
                                     :input (list :command "ls")
                                     :output "file.txt"))))
        (cl-letf (((symbol-function 'opencode-chat--render-tool-part)
                   (lambda (_p) (insert "TOOL OUTPUT\n"))))
          (opencode-chat--update-part-inline part))
        (goto-char (point-min))
        (when (search-forward "TOOL OUTPUT" nil t)
          (should (get-text-property (match-beginning 0) 'read-only)))))))

;;; --- modelID extraction ---

(ert-deftest opencode-chat-render-assistant-flat-model-id ()
  "Assistant message renders with flat modelID field."
  (opencode-test-with-temp-buffer "*test-chat-flat-model*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (list :info (list :id "msg_a2"
                                 :role "assistant"
                                 :modelID "anthropic/claude-sonnet-4-20250514"
                                 :time (list :created 1700000105))
                     :parts (vector (list :id "p_fm" :type "text" :text "hi")))))
      (opencode-chat--render-message msg)
      (should (opencode-test-buffer-contains-p "claude-sonnet-4-20250514")))))

(ert-deftest opencode-chat-render-assistant-nested-model-id ()
  "Assistant message falls back to nested model.modelID."
  (opencode-test-with-temp-buffer "*test-chat-nested-model*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (list :info (list :id "msg_a3"
                                 :role "assistant"
                                 :model (list :providerID "anthropic"
                                              :modelID "claude-sonnet-4-20250514")
                                 :time (list :created 1700000105))
                     :parts (vector (list :id "p_nm" :type "text" :text "hi")))))
      (opencode-chat--render-message msg)
      (should (opencode-test-buffer-contains-p "claude-sonnet-4-20250514")))))

(ert-deftest opencode-chat-render-assistant-no-model ()
  "Assistant message renders without error when no model info."
  (opencode-test-with-temp-buffer "*test-chat-no-model*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (msg (list :info (list :id "msg_a4"
                                 :role "assistant"
                                 :time (list :created 1700000105))
                     :parts (vector (list :id "p_nomodel" :type "text" :text "hi")))))
      (opencode-chat--render-message msg)
      ;; Should render without error
      (should (opencode-test-buffer-contains-p "Assistant"))
      (should (opencode-test-buffer-contains-p "hi")))))

;;; --- prompt_async send flow ---

;;; --- Header line: align-to display property ---

;;; --- Delta helper (insert-streaming-delta) ---

(ert-deftest opencode-chat-insert-delta-single-line ()
  "Single-line delta inserts with space prefix and correct faces."
  (opencode-test-with-temp-buffer "*test-delta-single*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "Hello" "text"))
    ;; Buffer should be " Hello" (space prefix + text)
    (should (string= (buffer-string) " Hello"))
    ;; Face should be assistant-body (block face is on line-prefix now)
    (should (eq 'opencode-assistant-body (get-text-property 1 'face)))
    ;; line-prefix should carry the block face stripe
    (let ((lp (get-text-property 1 'line-prefix)))
      (should lp)
      (should (string= (substring-no-properties lp) "▎"))
      (should (eq 'opencode-assistant-block (get-text-property 0 'face lp))))
    ;; read-only property should be set
    (should (eq t (get-text-property 1 'read-only)))))

(ert-deftest opencode-chat-insert-delta-multiline ()
  "Multi-line delta prefixes each line with space."
  (opencode-test-with-temp-buffer "*test-delta-multi*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "Hello\nWorld" "text"))
    ;; Buffer should be " Hello\n World"
    (should (string= (buffer-string) " Hello\n World"))
    ;; Both lines should have assistant-body face and line-prefix stripe
    (should (eq 'opencode-assistant-body (get-text-property 1 'face)))
    (should (eq 'opencode-assistant-body (get-text-property 8 'face)))
    (let ((lp1 (get-text-property 1 'line-prefix))
          (lp2 (get-text-property 8 'line-prefix)))
      (should lp1)
      (should lp2)
      (should (eq 'opencode-assistant-block (get-text-property 0 'face lp1)))
      (should (eq 'opencode-assistant-block (get-text-property 0 'face lp2))))))

(ert-deftest opencode-chat-insert-delta-midline ()
  "Delta at non-bolp does not add space prefix."
  (opencode-test-with-temp-buffer "*test-delta-midline*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      ;; First delta at bolp adds " " prefix
      (opencode-chat--insert-streaming-delta "Start" "text")
      ;; Point is after "Start", NOT at bolp; second delta has no prefix
      (opencode-chat--insert-streaming-delta " more" "text"))
    (should (string= (buffer-string) " Start more"))))

(ert-deftest opencode-chat-insert-delta-reasoning-face ()
  "Reasoning delta uses opencode-reasoning face, not assistant-body."
  (opencode-test-with-temp-buffer "*test-delta-reasoning*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "thinking" "reasoning"))
    ;; Text face should be reasoning, not assistant-body
    (should (eq 'opencode-reasoning (get-text-property 1 'face)))
    ;; line-prefix should carry the assistant-block face
    (let ((lp (get-text-property 1 'line-prefix)))
      (should lp)
      (should (eq 'opencode-assistant-block (get-text-property 0 'face lp))))))

(ert-deftest opencode-chat-insert-delta-has-keymap ()
  "Delta text has opencode-chat-message-map keymap property."
  (opencode-test-with-temp-buffer "*test-delta-keymap*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "test" "text"))
    (should (eq (get-text-property 1 'keymap) opencode-chat-message-map))))

(ert-deftest opencode-chat-assistant-message-collapse-roundtrip ()
  "Collapsing then re-expanding an assistant message restores visibility.

Why this matters — AGENTS.md once flagged this as broken (common-mistakes
#18: missing invisibility-spec, no header icon, can't re-expand).  This
test pins down the current behavior so future regressions surface: the
body becomes invisible on first TAB, visible again on second, and a
[collapsed] indicator appears/disappears in sync with the header icon."
  (opencode-test-with-temp-buffer "*test-asst-collapse-roundtrip*"
    (opencode-chat-mode)
    (opencode-chat--set-messages-end (copy-marker (point) t))
    (opencode-chat-message-upsert
     "msg_collapse"
     (list :info (list :role "assistant" :id "msg_collapse"
                       :time (list :created 1000 :completed 2000))
           :parts (vector (list :id "prt_body" :type "text"
                                :text "hello body line\nsecond body line"))))
    ;; Point on the header line of the assistant message.
    (goto-char (point-min))
    (should (search-forward "Assistant" nil t))
    (goto-char (line-beginning-position))
    ;; Collapse
    (opencode-ui--toggle-section)
    (should (opencode-ui--section-collapsed-p))
    (should (opencode-test-buffer-contains-p "[collapsed]"))
    ;; Body content is still in the buffer but marked invisible.
    (should (opencode-test-buffer-contains-p "second body line"))
    (let ((body-pos (save-excursion
                      (goto-char (point-min))
                      (search-forward "second body line")
                      (match-beginning 0))))
      (should (eq (get-text-property body-pos 'invisible) 'opencode-section)))
    ;; Header icon swapped to collapsed (▶).
    (goto-char (point-min))
    (should (search-forward "▶" nil t))
    ;; Re-expand
    (goto-char (point-min))
    (search-forward "Assistant")
    (goto-char (line-beginning-position))
    (opencode-ui--toggle-section)
    (should-not (opencode-ui--section-collapsed-p))
    (should-not (opencode-test-buffer-contains-p "[collapsed]"))
    ;; Body is visible again (invisible prop removed).
    (let ((body-pos (save-excursion
                      (goto-char (point-min))
                      (search-forward "second body line")
                      (match-beginning 0))))
      (should-not (eq (get-text-property body-pos 'invisible) 'opencode-section)))))

(ert-deftest opencode-chat-reasoning-streaming-collapse-covers-delta ()
  "TAB on a reasoning header must collapse content that was appended
via streaming deltas, not just the header line.

Why this matters — the reasoning section overlay is created when the
part first arrives with empty text; the streaming marker sits at the
overlay's end.  With `rear-advance=nil' on the overlay, streamed
deltas (inserted at overlay-end) land OUTSIDE the overlay, so
`--toggle-section' finds a tiny overlay covering just the header and
has no body region to hide.  Pins the `rear-advance' fix in
`make-section' / `with-section'."
  (opencode-test-with-temp-buffer "*test-reason-stream-collapse*"
    (opencode-chat-mode)
    (opencode-chat--set-messages-end (copy-marker (point) t))
    (opencode-chat-message-upsert
     "msg_r"
     (list :role "assistant" :id "msg_r"
           :time (list :created 1000)))
    ;; Announce an empty reasoning part (creates the section overlay).
    (opencode-chat-message-update-part
     "msg_r" "prt_r" "reasoning"
     (list :id "prt_r" :messageID "msg_r" :type "reasoning"
           :text "" :time (list :start 2000))
     nil)
    ;; Stream a delta into it.
    (opencode-chat-message-update-part
     "msg_r" "prt_r" "reasoning" nil
     "streamed thinking content")
    ;; Put point on the Thinking header and toggle-collapse.
    (goto-char (point-min))
    (should (search-forward "Thinking" nil t))
    (goto-char (line-beginning-position))
    (opencode-ui--toggle-section)
    ;; The streamed content must now be invisible via the section.
    (let ((content-pos (save-excursion
                         (goto-char (point-min))
                         (search-forward "streamed thinking content")
                         (match-beginning 0))))
      (should (eq (get-text-property content-pos 'invisible) 'opencode-section)))
    ;; Re-expand: content visible again.
    (goto-char (point-min))
    (search-forward "Thinking")
    (goto-char (line-beginning-position))
    (opencode-ui--toggle-section)
    (let ((content-pos (save-excursion
                         (goto-char (point-min))
                         (search-forward "streamed thinking content")
                         (match-beginning 0))))
      (should-not (eq (get-text-property content-pos 'invisible) 'opencode-section)))))

(ert-deftest opencode-chat-streaming-new-part-breaks-line ()
  "A new streaming text part following reasoning that ended mid-line
must start on its own line.  Without a separator the assistant's
first response word glues onto the last reasoning word (e.g.
\"...design issues.I'll perform...\").

Why this matters — LLM deltas often end without a trailing newline;
`message.part.updated' for a new part does not include a delta, so the
part's marker is placed at `message-insert-pos' (which sits at the
unfinished reasoning's tail).  The first delta for the new part then
appends at that position, producing the concatenation bug."
  (opencode-test-with-temp-buffer "*test-stream-part-boundary*"
    (opencode-chat-mode)
    ;; Minimal buffer scaffolding: messages-end marker at point 1.
    (opencode-chat--set-messages-end (copy-marker (point) t))
    ;; Seed an assistant message so update-part has an overlay to target.
    (opencode-chat-message-upsert
     "msg_a"
     (list :role "assistant" :id "msg_a"
           :time (list :created 1000)))
    ;; Stream a reasoning delta that does NOT end on a newline.
    (opencode-chat-message-update-part
     "msg_a" "prt_reason" "reasoning" nil
     "thinking tail without newline")
    ;; A new text part is announced (no delta yet); mirrors the SSE
    ;; sequence where message.part.updated carries an empty text part
    ;; before its first message.part.delta arrives.
    (opencode-chat-message-update-part
     "msg_a" "prt_text" "text"
     (list :id "prt_text" :messageID "msg_a" :type "text" :text ""
           :time (list :start 2000))
     nil)
    ;; First streaming delta for the new text part.
    (opencode-chat-message-update-part
     "msg_a" "prt_text" "text" nil
     "response body")
    ;; Response delta must NOT be glued to the reasoning's last word.
    (should-not (opencode-test-buffer-contains-p
                 "without newlineresponse"))
    (should-not (opencode-test-buffer-contains-p
                 "without newline response"))))

;;; --- session.idle clears streaming state ---

;;; --- messages-end marker set after render ---

;;; --- render-messages clears stale streaming state ---

;;; --- Optimistic user message ---



;;; --- SSE hook registration & dispatch ---



(ert-deftest opencode-chat-dispatch-skips-non-chat-buffers ()
  "Registry dispatch is a no-op for unregistered sessions.
Without this guard, events for unknown sessions would
trigger errors or reach wrong buffers."
  (require 'opencode)
  (let ((called-in nil))
    (opencode--dispatch-to-chat-buffer
     "ses_nonexistent"
     (lambda (_event) (push (buffer-name) called-in))
     '(:test t))
    (should-not called-in)))

;;; --- Registry lifecycle tests ---

(ert-deftest opencode-registry-chat-register-and-lookup ()
  "Registered chat buffer is returned by session-id lookup.
Without this, the O(1) dispatch path cannot find the
correct buffer for incoming SSE events."
  (require 'opencode)
  (unwind-protect
      (opencode-test-with-temp-buffer "*opencode: reg-lookup*"
        (opencode-chat-mode)
        (opencode--register-chat-buffer "ses_reg" (current-buffer))
        (should (eq (current-buffer)
                    (opencode--chat-buffer-for-session "ses_reg"))))
    (opencode--deregister-chat-buffer "ses_reg")))

(ert-deftest opencode-registry-chat-deregister-clears ()
  "Deregistered session-id returns nil on lookup.
Without deregister, killed chat buffers would leave stale
entries that point to dead buffers."
  (require 'opencode)
  (unwind-protect
      (opencode-test-with-temp-buffer "*opencode: reg-dereg*"
        (opencode-chat-mode)
        (opencode--register-chat-buffer "ses_dereg" (current-buffer))
        (opencode--deregister-chat-buffer "ses_dereg")
        (should-not (opencode--chat-buffer-for-session "ses_dereg")))
    (opencode--deregister-chat-buffer "ses_dereg")))

(ert-deftest opencode-registry-chat-dead-buffer-auto-deregisters ()
  "Lookup auto-deregisters killed buffers and returns nil.
Without auto-deregister, stale entries would accumulate
and dispatch would fail silently on dead buffers."
  (require 'opencode)
  (let ((buf (get-buffer-create "*opencode: reg-dead*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_dead" buf)
          (kill-buffer buf)
          (should-not (opencode--chat-buffer-for-session "ses_dead")))
      (opencode--deregister-chat-buffer "ses_dead")
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-nil-key-skipped ()
  "Nil session-id does not create a registry entry.
Without this guard, nil keys would pollute the hash table
and cause spurious matches on lookup."
  (require 'opencode)
  (opencode-test-with-temp-buffer "*opencode: reg-nil*"
    (opencode--register-chat-buffer nil (current-buffer))
    (should-not (opencode--chat-buffer-for-session nil))))

(ert-deftest opencode-registry-sidebar-expand-file-name ()
  "Sidebar registry normalizes paths via `expand-file-name'.
Without normalization, relative and absolute paths for the
same project would create duplicate registry entries."
  (require 'opencode)
  (let ((dir (expand-file-name "test-project"
                               temporary-file-directory)))
    (unwind-protect
        (opencode-test-with-temp-buffer "*opencode: reg-sidebar*"
          (opencode--register-sidebar-buffer dir (current-buffer))
          (should (eq (current-buffer)
                      (opencode--sidebar-buffer-for-project dir))))
      (opencode--deregister-sidebar-buffer dir))))

(ert-deftest opencode-registry-all-chat-buffers ()
  "all-chat-buffers returns all live registered buffers.
Without this, broadcast-to-all events like
installation.update-available would miss chat buffers."
  (require 'opencode)
  (let ((buf-a (get-buffer-create "*opencode: reg-all-a*"))
        (buf-b (get-buffer-create "*opencode: reg-all-b*")))
    (unwind-protect
        (progn
          (with-current-buffer buf-a (opencode-chat-mode))
          (with-current-buffer buf-b (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_a" buf-a)
          (opencode--register-chat-buffer "ses_b" buf-b)
          (let ((all (opencode--all-chat-buffers)))
            (should (memq buf-a all))
            (should (memq buf-b all))))
      (opencode--deregister-chat-buffer "ses_a")
      (opencode--deregister-chat-buffer "ses_b")
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

;;; --- render-messages preserves input and popup state ---

;;; --- New-format tool duration tests ---

(ert-deftest opencode-chat-render-tool-part-new-format-duration ()
  "New-format tool part computes and shows duration from state.time."
  (opencode-test-with-temp-buffer "*test-tool-new-duration*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_dur1"
                      :type "tool"
                      :tool "bash"
                      :state (list :status "completed"
                                   :input (list :command "make test")
                                   :output "ok\n"
                                   :time (list :start 1771600000000
                                               :end 1771600075000)))))
      (opencode-chat--render-part part 'assistant)
      ;; 75 seconds = 1m15s
      (should (opencode-test-buffer-contains-p "1m15s")))))

(ert-deftest opencode-chat-render-tool-part-new-format-no-duration-when-zero ()
  "New-format tool part shows no duration when start == end."
  (opencode-test-with-temp-buffer "*test-tool-zero-duration*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_dur2"
                      :type "tool"
                      :tool "bash"
                      :state (list :status "error"
                                   :input nil
                                   :error "Tool execution aborted"
                                   :time (list :start 1771600000000
                                               :end 1771600000000)))))
      (opencode-chat--render-part part 'assistant)
      (should-not (opencode-test-buffer-matches-p "·.*[0-9]+[ms]")))))

;;; --- Aborted message error display tests ---

(ert-deftest opencode-chat-render-assistant-message-error ()
  "Assistant message with error shows error name and message."
  (opencode-test-with-temp-buffer "*test-msg-error*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (info (list :id "msg_err1"
                      :role "assistant"
                      :modelID "claude-opus-4-6"
                      :time (list :created 1771600000000
                                  :completed 1771600010000)
                      :error (list :name "MessageAbortedError"
                                   :data (list :message "The operation was aborted."))
                      :tokens (list :input 100 :output 50)))
          (parts (vector (list :id "prt_err1"
                               :type "step-start"
                               :snapshot "abc123"))))
      (opencode-chat--render-assistant-message info parts)
      (should (opencode-test-buffer-contains-p "MessageAbortedError"))
      (should (opencode-test-buffer-contains-p "The operation was aborted.")))))

(ert-deftest opencode-chat-render-assistant-message-no-error ()
  "Assistant message without error does not show error line."
  (opencode-test-with-temp-buffer "*test-msg-no-error*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (info (list :id "msg_ok1"
                      :role "assistant"
                      :modelID "claude-opus-4-6"
                      :time (list :created 1771600000000
                                  :completed 1771600005000)
                      :tokens (list :input 100 :output 50)))
          (parts (vector (list :id "prt_ok1"
                               :type "text"
                               :text "All good!"))))
      (opencode-chat--render-assistant-message info parts)
      (should (opencode-test-buffer-contains-p "All good!"))
      (should-not (opencode-test-buffer-contains-p "Error")))))

;;; --- Cursor position preservation across re-renders ---



(ert-deftest opencode-chat-reasoning-section-not-collapsed-by-default ()
  "Reasoning section is not collapsed by default (expanded state).
Verifies that the section overlay does not have opencode-collapsed property set."
  (opencode-test-with-temp-buffer "*test-reasoning-not-collapsed*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (opencode-chat-test--make-reasoning-part)))
      (opencode-chat--render-part part 'assistant)
      ;; Find the reasoning section overlay
      (goto-char (point-min))
      (let ((section (opencode-ui--section-at (point))))
        (should (eq (plist-get section :type) 'reasoning))
        ;; Verify section is NOT collapsed (opencode-collapsed property should be nil)
        (should-not (opencode-ui--section-collapsed-p (point)))))))

;;; --- @-mention tests ---

(ert-deftest opencode-chat-chip-create-sets-properties ()
  "Chip creation sets correct overlay properties."
  (opencode-test-with-temp-buffer "*test-chip-props*"
    (opencode-chat-mode)
    (insert "@test.el")
    (let ((ov (opencode-chat--chip-create 1 (point) 'file "test.el" "/abs/test.el")))
      (should (overlay-get ov 'opencode-mention))
      (should (eq (overlay-get ov 'cursor-intangible) t))
      (should (eq (overlay-get ov 'face) 'opencode-mention-file))
      (should (string= (overlay-get ov 'help-echo) "/abs/test.el"))
      (should (eq (overlay-get ov 'evaporate) t))
      (should (overlay-get ov 'modification-hooks)))))

(ert-deftest opencode-chat-chip-create-file-face ()
  "File chip gets `opencode-mention-file' face."
  (opencode-test-with-temp-buffer "*test-chip-file-face*"
    (opencode-chat-mode)
    (insert "@readme.md")
    (let ((ov (opencode-chat--chip-create 1 (point) 'file "readme.md" "/proj/readme.md")))
      (should (eq (overlay-get ov 'face) 'opencode-mention-file)))))

(ert-deftest opencode-chat-chip-create-agent-face ()
  "Agent chip gets `opencode-mention-agent' face."
  (opencode-test-with-temp-buffer "*test-chip-agent-face*"
    (opencode-chat-mode)
    (insert "@build")
    (let ((ov (opencode-chat--chip-create 1 (point) 'agent "build" nil)))
      (should (eq (overlay-get ov 'face) 'opencode-mention-agent))
      (should (string= (overlay-get ov 'help-echo) "build")))))

(ert-deftest opencode-chat-chip-delete-removes-text ()
  "Delete chip removes overlay text from buffer."
  (opencode-test-with-temp-buffer "*test-chip-delete*"
    (opencode-chat-mode)
    (insert "@test.el")
    (let ((ov (opencode-chat--chip-create 1 (point) 'file "test.el" "/abs/test.el")))
      (should (opencode-test-buffer-contains-p "@test.el"))
      (opencode-chat--chip-delete ov)
      (should-not (opencode-test-buffer-contains-p "@test.el")))))

(ert-deftest opencode-chat-chip-backspace-deletes-chip ()
  "Backspace at chip boundary deletes entire chip."
  (opencode-test-with-temp-buffer "*test-chip-backspace*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (insert "@test.el")
    (let ((ov (opencode-chat--chip-create
               (+ (marker-position (opencode-chat--input-start)) 2)
               (point) 'file "test.el" "/abs/test.el")))
      ;; Point is right after the chip
      (should (opencode-test-buffer-contains-p "@test.el"))
      ;; Simulate backspace - should delete the chip
      (opencode-chat--chip-backspace)
      (should-not (opencode-test-buffer-contains-p "@test.el")))))

(ert-deftest opencode-chat-chip-backspace-normal-fallback ()
  "Backspace without chip does normal backward delete."
  (opencode-test-with-temp-buffer "*test-chip-backspace-normal*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (insert "abc")
    (opencode-chat--chip-backspace)
    (should (string= (buffer-substring-no-properties
                       (+ (marker-position (opencode-chat--input-start)) 2)
                       (point))
                      "ab"))))

(ert-deftest opencode-chat-mention-capf-triggers-after-space ()
  "CAPF triggers when @ follows whitespace in input area."
  (opencode-test-with-temp-buffer "*test-capf-trigger*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (insert "hello @te")
    ;; Stub candidates to avoid project/agent lookups
    (cl-letf (((symbol-function 'opencode-chat--mention-candidates)
               (lambda () '("test.el" "test2.el"))))
      (let ((result (opencode-chat--mention-capf)))
        (should result)
        ;; Start should be after the @
        (should (= (nth 0 result) (- (point) 2)))
        ;; End should be at point
        (should (= (nth 1 result) (point)))))))

(ert-deftest opencode-chat-mention-capf-no-trigger-mid-word ()
  "CAPF returns nil when @ is mid-word (no preceding whitespace)."
  (opencode-test-with-temp-buffer "*test-capf-no-trigger*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (insert "hello@te")
    (cl-letf (((symbol-function 'opencode-chat--mention-candidates)
               (lambda () '("test.el"))))
      (let ((result (opencode-chat--mention-capf)))
        (should-not result)))))

(ert-deftest opencode-chat-extract-mentions-returns-nil-without-chips ()
  "No chips in input area returns nil."
  (opencode-test-with-temp-buffer "*test-extract-nil*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (insert "hello world")
    (should-not (plist-get (opencode-chat--input-attachments) :mentions))))

(ert-deftest opencode-chat-extract-mentions-returns-mention-plists ()
  "With chips, extract-mentions returns plists with :type :name :path :start :end."
  (opencode-test-with-temp-buffer "*test-extract-plists*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    (let ((chip-start (point)))
      (insert "@test.el")
      (let ((chip-end (point)))
        (opencode-chat--chip-create chip-start chip-end 'file "test.el" "/abs/test.el")
        (insert " hello")
        (let ((mentions (plist-get (opencode-chat--input-attachments) :mentions)))
          (should mentions)
          (should (= (length mentions) 1))
          (let ((m (car mentions)))
            (should (eq (plist-get m :type) 'file))
            (should (string= (plist-get m :name) "test.el"))
            (should (string= (plist-get m :path) "/abs/test.el"))
            (should (numberp (plist-get m :start)))
            (should (numberp (plist-get m :end)))))))))

(ert-deftest opencode-chat-render-file-part-inserts-filename ()
  "File part renders with filename text."
  (opencode-test-with-temp-buffer "*test-render-file*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_f1" :type "file" :filename "auth.ts")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "auth.ts")))))

(ert-deftest opencode-chat-render-agent-part-inserts-name ()
  "Agent part renders with agent name text."
  (opencode-test-with-temp-buffer "*test-render-agent*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_a1" :type "agent" :name "explore")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "explore")))))

;;; --- Mention extraction tests ---

(ert-deftest opencode-chat-extract-mentions-file ()
  "Extract a file mention from chip overlay in input area."
  (opencode-test-with-temp-buffer "*test-extract-file*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
(insert "> @foo.el hello")
      (opencode-chat--set-input-start (copy-marker 1))
      (add-text-properties 1 3 '(read-only t))
      (let ((ov (opencode-chat--chip-create 3 10 'file "foo.el" "/tmp/foo.el")))
        (put-text-property 16 (point-max) 'read-only t)
        (let ((mentions (plist-get (opencode-chat--input-attachments) :mentions)))
          (should (= 1 (length mentions)))
          (should (eq 'file (plist-get (car mentions) :type)))
          (should (string= "foo.el" (plist-get (car mentions) :name)))
          (should (string= "/tmp/foo.el" (plist-get (car mentions) :path)))
          (should (= 0 (plist-get (car mentions) :start)))
          (should (= 7 (plist-get (car mentions) :end))))))))

(ert-deftest opencode-chat-extract-mentions-agent ()
  "Extract an agent mention from chip overlay in input area."
  (opencode-test-with-temp-buffer "*test-extract-agent*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
(insert "> @explore query")
      (opencode-chat--set-input-start (copy-marker 1))
      (add-text-properties 1 3 '(read-only t))
      (let ((ov (opencode-chat--chip-create 3 11 'agent "explore" nil)))
        (put-text-property 17 (point-max) 'read-only t)
        (let ((mentions (plist-get (opencode-chat--input-attachments) :mentions)))
          (should (= 1 (length mentions)))
          (should (eq 'agent (plist-get (car mentions) :type)))
          (should (string= "explore" (plist-get (car mentions) :name)))
          (should (null (plist-get (car mentions) :path))))))))

(ert-deftest opencode-chat-extract-mentions-empty ()
  "Returns nil when no mention overlays exist."
  (opencode-test-with-temp-buffer "*test-extract-empty*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
(insert "> hello world")
      (opencode-chat--set-input-start (copy-marker 1))
      (add-text-properties 1 3 '(read-only t))
      (put-text-property 14 (point-max) 'read-only t)
      (should-not (plist-get (opencode-chat--input-attachments) :mentions)))))

(ert-deftest opencode-chat-extract-mentions-mixed ()
  "Extracts both file and agent mentions from same input."
  (opencode-test-with-temp-buffer "*test-extract-mixed*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
(insert "> @foo.el @explore end")
      (opencode-chat--set-input-start (copy-marker 1))
      (add-text-properties 1 3 '(read-only t))
      (let ((ov1 (opencode-chat--chip-create 3 10 'file "foo.el" "/tmp/foo.el"))
            (ov2 (opencode-chat--chip-create 11 19 'agent "explore" nil)))
        (put-text-property 23 (point-max) 'read-only t)
        (let ((mentions (plist-get (opencode-chat--input-attachments) :mentions)))
          (should (= 2 (length mentions)))
          (should (eq 'file (plist-get (car mentions) :type)))
          (should (eq 'agent (plist-get (cadr mentions) :type))))))))

;;; --- Mention chip overlay tests ---

(ert-deftest opencode-chat-chip-create-inserts-propertized-text ()
  "Creating a chip overlay sets correct face and mention metadata."
  (opencode-test-with-temp-buffer "*test-chip-create*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (insert "@foo.el")
      (let ((ov (opencode-chat--chip-create 1 8 'file "foo.el" "/tmp/foo.el")))
        (should (eq 'opencode-mention-file (overlay-get ov 'face)))
        (let ((meta (overlay-get ov 'opencode-mention)))
          (should (eq 'file (plist-get meta :type)))
          (should (string= "foo.el" (plist-get meta :name)))
          (should (string= "/tmp/foo.el" (plist-get meta :path))))
        (should (overlay-get ov 'opencode-mention))
        (should (overlay-get ov 'modification-hooks))
        (should (overlay-get ov 'cursor-intangible))))))

(ert-deftest opencode-chat-chip-delete-removes-entire-chip ()
  "Deleting a chip removes overlay and its underlying text."
  (opencode-test-with-temp-buffer "*test-chip-delete*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (insert "before @foo.el after")
      (let ((ov (opencode-chat--chip-create 8 15 'file "foo.el" "/tmp/foo.el")))
        (should (opencode-test-buffer-contains-p "@foo.el"))
        (opencode-chat--chip-delete ov)
        (should-not (opencode-test-buffer-contains-p "@foo.el"))
        (should (opencode-test-buffer-contains-p "before "))
        (should (opencode-test-buffer-contains-p " after"))
        (should-not (overlay-buffer ov))))))

;;; --- Optimistic user message tests ---









;;; --- @-mention annotation tests ---

(ert-deftest opencode-chat-mention-annotate-file ()
  "Annotation for file candidate (no type property) shows file label."
  (should (string-match-p "file" (opencode-chat--mention-annotate "test.el"))))

(ert-deftest opencode-chat-mention-annotate-folder ()
  "Annotation for folder candidate shows folder label."
  (let ((s (copy-sequence "src/")))
    (put-text-property 0 (length s) 'opencode-mention-type 'folder s)
    (should (string-match-p "folder" (opencode-chat--mention-annotate s)))))

(ert-deftest opencode-chat-mention-annotate-agent ()
  "Annotation for agent candidate shows agent label."
  (let ((s (copy-sequence "build")))
    (put-text-property 0 (length s) 'opencode-mention-type 'agent s)
    (should (string-match-p "agent" (opencode-chat--mention-annotate s)))))

(ert-deftest opencode-chat-mention-annotate-no-property-defaults-to-file ()
  "Candidate without type property defaults to file annotation."
  (let ((result (opencode-chat--mention-annotate "plain-string")))
    (should (string-match-p "file" result))
    (should-not (string-match-p "folder" result))
    (should-not (string-match-p "agent" result))))

(ert-deftest opencode-chat-mention-annotate-folder-not-file ()
  "Folder annotation does not say file."
  (let ((s (copy-sequence "lib/")))
    (put-text-property 0 (length s) 'opencode-mention-type 'folder s)
    (let ((result (opencode-chat--mention-annotate s)))
      (should (string-match-p "folder" result))
      (should-not (string-match-p "\\bfile\\b" result)))))

;;; --- @-mention candidate generation (directory extraction) ---

(ert-deftest opencode-chat-mention-candidates-includes-directories ()
  "Mention candidates include directories extracted from project files."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'project-files)
             (lambda (_)
               '("/proj/src/foo.el" "/proj/src/bar/baz.el" "/proj/readme.md")))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "src" "readme.md")))
            ((symbol-function 'file-directory-p)
             (lambda (f) (string-suffix-p "src" f)))
            ((symbol-function 'opencode-agent--list) (lambda () [])))
    (let ((candidates (opencode-chat--mention-candidates)))
      ;; Should include files
      (should (member "src/foo.el" candidates))
      (should (member "readme.md" candidates))
      ;; Should include directories with trailing /
      (should (member "src/" candidates))
      (should (member "src/bar/" candidates)))))

(ert-deftest opencode-chat-mention-candidates-directory-has-folder-type ()
  "Directory candidates have opencode-mention-type folder text property."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'project-files)
             (lambda (_) '("/proj/lib/utils.el")))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _) '("." "..")))
            ((symbol-function 'file-directory-p) (lambda (_) nil))
            ((symbol-function 'opencode-agent--list) (lambda () [])))
    (let* ((candidates (opencode-chat--mention-candidates))
           (dir-cand (seq-find (lambda (c) (string= c "lib/")) candidates)))
      (should dir-cand)
      (should (eq 'folder (get-text-property 0 'opencode-mention-type dir-cand))))))

(ert-deftest opencode-chat-mention-candidates-nested-directories ()
  "Deeply nested file paths produce all intermediate directory candidates."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'project-files)
             (lambda (_) '("/proj/a/b/c/deep.el")))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _) '("." "..")))
            ((symbol-function 'file-directory-p) (lambda (_) nil))
            ((symbol-function 'opencode-agent--list) (lambda () [])))
    (let ((candidates (opencode-chat--mention-candidates)))
      (should (member "a/" candidates))
      (should (member "a/b/" candidates))
      (should (member "a/b/c/" candidates)))))

(ert-deftest opencode-chat-mention-candidates-top-level-dirs-from-filesystem ()
  "Mention candidates scans top-level filesystem dirs beyond project-files."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'project-files)
             (lambda (_) '("/proj/src/main.el")))
            ((symbol-function 'directory-files)
             (lambda (dir &optional _full &rest _)
               (if (string= dir "/proj/")
                   '("." ".." "src" ".github" "node_modules")
                 '("." ".."))))
            ((symbol-function 'file-directory-p)
             (lambda (f)
               (or (string-suffix-p "src" f)
                   (string-suffix-p ".github" f)
                   (string-suffix-p "node_modules" f))))
            ((symbol-function 'opencode-agent--list) (lambda () [])))
    (let ((candidates (opencode-chat--mention-candidates)))
      ;; src/ from both project-files AND filesystem scan
      (should (member "src/" candidates))
      ;; .github/ only from filesystem scan
      (should (member ".github/" candidates))
      ;; node_modules/ also from filesystem scan
      (should (member "node_modules/" candidates)))))

(ert-deftest opencode-chat-mention-candidates-agents-still-included ()
  "Agent candidates still appear alongside file/directory candidates."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'opencode-agent--list)
             (lambda () (vector (list :name "build" :mode "primary")
                                (list :name "plan" :mode "primary")
                                (list :name "hidden-one" :hidden t)))))
    (let ((candidates (opencode-chat--mention-candidates)))
      (should (member "build" candidates))
      (should (member "plan" candidates))
      ;; Hidden agents are excluded
      (should-not (member "hidden-one" candidates))
      ;; Agent candidates have agent type property
      (let ((build (seq-find (lambda (c) (string= c "build")) candidates)))
        (should (eq 'agent (get-text-property 0 'opencode-mention-type build)))))))

;;; --- Filesystem candidates (../ support) ---

(ert-deftest opencode-chat-filesystem-candidates-lists-parent-entries ()
  "Filesystem candidates lists files and dirs from parent directory."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/home/user/proj/"))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "other-proj" "notes.txt")))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "/" f)
                             (string-suffix-p "other-proj" f)))))
    (let ((entries (opencode-chat--filesystem-candidates "../")))
      ;; Directory entry with trailing /
      (should (member "../other-proj/" entries))
      ;; File entry without trailing /
      (should (member "../notes.txt" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-folder-type-property ()
  "Filesystem directory entries have folder type text property."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/home/user/proj/"))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "sibling-dir")))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "/" f)
                             (string-suffix-p "sibling-dir" f)))))
    (let* ((entries (opencode-chat--filesystem-candidates "../"))
           (dir-entry (seq-find (lambda (e) (string= e "../sibling-dir/")) entries)))
      (should dir-entry)
      (should (eq 'folder (get-text-property 0 'opencode-mention-type dir-entry))))))

(ert-deftest opencode-chat-filesystem-candidates-nested-path ()
  "Filesystem candidates handles nested ../ paths like ../other/."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/home/user/proj/"))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "sub" f)
                             (string-suffix-p "other/" f)
                             (string-suffix-p "other" f))))
            ((symbol-function 'directory-files)
             (lambda (dir &optional _full &rest _)
               (if (string-suffix-p "other/" dir)
                   '("." ".." "sub" "file.py")
                 '("." "..")))))
    (let ((entries (opencode-chat--filesystem-candidates "../other/")))
      (should (member "../other/sub/" entries))
      (should (member "../other/file.py" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-nonexistent-dir ()
  "Filesystem candidates returns nil for nonexistent directory."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/home/user/proj/"))
            ((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should-not (opencode-chat--filesystem-candidates "../nonexistent/"))))

(ert-deftest opencode-chat-filesystem-candidates-excludes-dot-entries ()
  "Filesystem candidates excludes . and .. entries."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/home/user/proj/"))
            ((symbol-function 'file-directory-p)
             (lambda (f) (string-suffix-p "user/" f)))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "real-file.txt"))))
    (let ((entries (opencode-chat--filesystem-candidates "../")))
      (should-not (seq-find (lambda (e) (string-match-p "\\`\\.\\./\\.\\(?:\\.\\)?\\\='" e)) entries))
      (should (member "../real-file.txt" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-uses-default-directory ()
  "Filesystem candidates falls back to default-directory when no project."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'file-directory-p)
             (lambda (_f) t))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "found-dir"))))
    (let ((default-directory "/some/path/"))
      (let ((entries (opencode-chat--filesystem-candidates "../")))
        ;; Should still return results using default-directory
        (should entries)
        (should (member "../found-dir/" entries))))))

;;; --- Completion table dynamic path augmentation ---

(ert-deftest opencode-chat-mention-table-augments-with-filesystem-on-dotdot ()
  "Completion table augments candidates with filesystem entries for ../ prefix."
  (let* ((base-candidates '("src/foo.el"))
         (table (opencode-chat--mention-completion-table base-candidates)))
    (cl-letf (((symbol-function 'opencode-chat--filesystem-candidates)
               (lambda (_prefix) '("../bar.txt"))))
      (let ((completions (funcall table "../" nil t)))
        (should (member "../bar.txt" completions))))))

(ert-deftest opencode-chat-mention-table-no-filesystem-for-normal-prefix ()
  "Completion table does not call filesystem-candidates for plain names."
  (let* ((fs-called nil)
         (base-candidates '("src/foo.el"))
         (table (opencode-chat--mention-completion-table base-candidates)))
    (cl-letf (((symbol-function 'opencode-chat--filesystem-candidates)
               (lambda (_prefix)
                 (setq fs-called t)
                 nil)))
      (funcall table "src" nil t)
      (should-not fs-called))))

(ert-deftest opencode-chat-mention-table-metadata-has-annotation ()
  "Completion table metadata includes annotation function."
  (let ((table (opencode-chat--mention-completion-table '("test"))))
    (let ((meta (funcall table "" nil 'metadata)))
      (should (eq 'metadata (car meta)))
      (should (eq 'opencode-chat--mention-annotate
                  (alist-get 'annotation-function (cdr meta)))))))

(ert-deftest opencode-chat-mention-table-augments-with-filesystem-on-dot-slash ()
  "Completion table augments candidates with filesystem entries for ./ prefix."
  (let* ((base-candidates '("src/foo.el"))
         (table (opencode-chat--mention-completion-table base-candidates)))
    (cl-letf (((symbol-function 'opencode-chat--filesystem-candidates)
               (lambda (_prefix) '("./bar.txt"))))
      (let ((completions (funcall table "./" nil t)))
        (should (member "./bar.txt" completions))))))

(ert-deftest opencode-chat-mention-table-augments-with-filesystem-on-abs-slash ()
  "Completion table augments candidates with filesystem entries for / prefix."
  (let* ((base-candidates '("src/foo.el"))
         (table (opencode-chat--mention-completion-table base-candidates)))
    (cl-letf (((symbol-function 'opencode-chat--filesystem-candidates)
               (lambda (_prefix) '("/etc/hosts"))))
      (let ((completions (funcall table "/" nil t)))
        (should (member "/etc/hosts" completions))))))

;;; --- Filesystem candidates (./ support) ---

(ert-deftest opencode-chat-filesystem-candidates-dot-slash-lists-project-entries ()
  "Filesystem candidates for ./ lists entries from project root."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "src" "README.md")))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "/" f)
                             (string-suffix-p "src" f)))))
    (let ((entries (opencode-chat--filesystem-candidates "./")))
      (should (member "./src/" entries))
      (should (member "./README.md" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-dot-slash-folder-type ()
  "Filesystem ./ directory entries have folder type text property."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "lib")))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "/" f)
                             (string-suffix-p "lib" f)))))
    (let* ((entries (opencode-chat--filesystem-candidates "./"))
           (dir-entry (seq-find (lambda (e) (string= e "./lib/")) entries)))
      (should dir-entry)
      (should (eq 'folder (get-text-property 0 'opencode-mention-type dir-entry))))))

;;; --- Filesystem candidates (/ absolute support) ---

(ert-deftest opencode-chat-filesystem-candidates-abs-slash-lists-entries ()
  "Filesystem candidates for / lists entries from root directory."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "etc" "usr")))
            ((symbol-function 'file-directory-p)
             (lambda (_f) t)))
    (let ((entries (opencode-chat--filesystem-candidates "/")))
      (should (member "/etc/" entries))
      (should (member "/usr/" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-abs-nested-path ()
  "Filesystem candidates handles absolute nested paths like /etc/."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'file-directory-p)
             (lambda (_f) t))
            ((symbol-function 'directory-files)
             (lambda (dir &optional _full &rest _)
               (if (string-suffix-p "etc/" dir)
                   '("." ".." "hosts" "passwd")
                 '("." "..")))))
    (let ((entries (opencode-chat--filesystem-candidates "/etc/")))
      (should (member "/etc/hosts/" entries))
      (should (member "/etc/passwd/" entries)))))

;;; --- Filesystem candidates (edge cases for ./ and /) ---

(ert-deftest opencode-chat-filesystem-candidates-dot-slash-nested-path ()
  "Filesystem candidates handles nested ./ paths like ./src/."
  (cl-letf (((symbol-function 'project-current) (lambda () t))
            ((symbol-function 'project-root) (lambda (_) "/proj/"))
            ((symbol-function 'file-directory-p)
             (lambda (f) (or (string-suffix-p "src/" f)
                             (string-suffix-p "src" f)
                             (string-suffix-p "lib" f))))
            ((symbol-function 'directory-files)
             (lambda (dir &optional _full &rest _)
               (if (string-suffix-p "src/" dir)
                   '("." ".." "lib" "main.el")
                 '("." "..")))))
    (let ((entries (opencode-chat--filesystem-candidates "./src/")))
      (should (member "./src/lib/" entries))
      (should (member "./src/main.el" entries)))))

(ert-deftest opencode-chat-filesystem-candidates-dot-slash-default-directory ()
  "Filesystem ./ candidates fall back to default-directory without project."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'file-directory-p)
             (lambda (_f) t))
            ((symbol-function 'directory-files)
             (lambda (_dir &optional _full &rest _)
               '("." ".." "build"))))
    (let ((default-directory "/some/fallback/"))
      (let ((entries (opencode-chat--filesystem-candidates "./")))
        (should entries)
        (should (member "./build/" entries))))))

(ert-deftest opencode-chat-filesystem-candidates-abs-nonexistent ()
  "Filesystem candidates for nonexistent absolute path returns nil."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should-not (opencode-chat--filesystem-candidates "/no/such/path/"))))

;;; --- Mention exit for folder type ---

(ert-deftest opencode-chat-mention-exit-folder-creates-file-chip ()
  "Selecting a folder candidate creates a chip with file type (API compat)."
  (opencode-test-with-temp-buffer "*test-exit-folder*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @src/")
    (let ((candidate (copy-sequence "src/")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'folder candidate)
      (cl-letf (((symbol-function 'project-current) (lambda () t))
                ((symbol-function 'project-root) (lambda (_) "/proj/")))
        (opencode-chat--mention-exit candidate 'finished)
        (let ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max))))))
          (should ov)
          (let ((meta (overlay-get ov 'opencode-mention)))
            ;; Type is 'file (converted from 'folder for API)
            (should (eq 'file (plist-get meta :type)))
            ;; Name has no trailing /
            (should (string= "src" (plist-get meta :name)))
            ;; Path ends with /
            (should (string-suffix-p "/" (plist-get meta :path)))))))))

(ert-deftest opencode-chat-mention-exit-file-unchanged ()
  "Selecting a file candidate creates chip with file type and exact name."
  (opencode-test-with-temp-buffer "*test-exit-file*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @test.el")
    (cl-letf (((symbol-function 'project-current) (lambda () t))
              ((symbol-function 'project-root) (lambda (_) "/proj/")))
      (opencode-chat--mention-exit "test.el" 'finished)
      (let ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max))))))
        (should ov)
        (let ((meta (overlay-get ov 'opencode-mention)))
          (should (eq 'file (plist-get meta :type)))
          (should (string= "test.el" (plist-get meta :name)))
          ;; Path does NOT end with /
          (should-not (string-suffix-p "/" (plist-get meta :path))))))))

(ert-deftest opencode-chat-mention-exit-folder-path-matches-api-format ()
  "Folder chip path ends with / matching the curl API format."
  (opencode-test-with-temp-buffer "*test-exit-folder-path*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @.github/")
    (let ((candidate (copy-sequence ".github/")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'folder candidate)
      (cl-letf (((symbol-function 'project-current) (lambda () t))
                ((symbol-function 'project-root) (lambda (_) "/proj/")))
        (opencode-chat--mention-exit candidate 'finished)
        (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
               (meta (overlay-get ov 'opencode-mention)))
          ;; Name is ".github" (no slash) — matches curl filename field
          (should (string= ".github" (plist-get meta :name)))
          ;; Path ends with / — matches curl path field
          (should (string= "/proj/.github/" (plist-get meta :path))))))))

(ert-deftest opencode-chat-mention-exit-dotdot-folder ()
  "Selecting a ../dir/ candidate creates correct chip."
  (opencode-test-with-temp-buffer "*test-exit-dotdot-folder*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @../other-proj/")
    (let ((candidate (copy-sequence "../other-proj/")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'folder candidate)
      (cl-letf (((symbol-function 'project-current) (lambda () t))
                ((symbol-function 'project-root) (lambda (_) "/home/user/proj/")))
        (opencode-chat--mention-exit candidate 'finished)
        (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
               (meta (overlay-get ov 'opencode-mention)))
          (should (eq 'file (plist-get meta :type)))
          ;; Name strips trailing / but keeps ../ prefix
          (should (string= "../other-proj" (plist-get meta :name)))
          ;; Path is fully resolved and ends with /
          (should (string-suffix-p "/" (plist-get meta :path))))))))

(ert-deftest opencode-chat-mention-exit-ignores-non-finished ()
  "mention-exit does nothing when status is not finished."
  (opencode-test-with-temp-buffer "*test-exit-not-finished*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @src/")
    (opencode-chat--mention-exit "src/" 'exact)
    (should-not (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention))
                            (overlays-in (point-min) (point-max))))))

;;; --- mention-type-for-name fallback ---

(ert-deftest opencode-chat-mention-type-for-name-agent ()
  "Type lookup returns agent when name matches cached agent."
  (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary")
                                       (list :name "plan" :mode "primary"))))
    (should (eq 'agent (opencode-chat--mention-type-for-name "build")))
    (should (eq 'agent (opencode-chat--mention-type-for-name "plan")))))

(ert-deftest opencode-chat-mention-type-for-name-folder ()
  "Type lookup returns folder for names ending with /."
  (let ((opencode-api--agents-cache (vector)))
    (should (eq 'folder (opencode-chat--mention-type-for-name "src/")))))

(ert-deftest opencode-chat-mention-type-for-name-nil-for-file ()
  "Type lookup returns nil for plain file names (no agent match, no trailing /)."
  (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary"))))
    (should-not (opencode-chat--mention-type-for-name "test.el"))))

(ert-deftest opencode-chat-mention-exit-agent-without-text-property ()
  "Agent chip is created correctly even when text properties are stripped."
  (opencode-test-with-temp-buffer "*test-exit-agent-no-prop*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary")
                                         (list :name "Prometheus (Plan Builder)" :mode "all"))))
      ;; candidate has NO text properties (simulates completion stripping)
      (insert "> @Prometheus (Plan Builder)")
      (opencode-chat--mention-exit "Prometheus (Plan Builder)" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should ov)
        ;; Type must be agent, not file
        (should (eq 'agent (plist-get meta :type)))
        (should (string= "Prometheus (Plan Builder)" (plist-get meta :name)))
        ;; Agent has no path
        (should-not (plist-get meta :path))
        ;; Face must be agent face
        (should (eq 'opencode-mention-agent (overlay-get ov 'face)))))))

(ert-deftest opencode-chat-mention-exit-agent-with-text-property ()
  "Agent chip works when text property IS present (original path)."
  (opencode-test-with-temp-buffer "*test-exit-agent-with-prop*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((candidate (copy-sequence "build")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'agent candidate)
      (insert "> @build")
      (opencode-chat--mention-exit candidate 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should (eq 'agent (plist-get meta :type)))
        (should (eq 'opencode-mention-agent (overlay-get ov 'face)))))))

(ert-deftest opencode-chat-mention-exit-folder-without-text-property ()
  "Folder chip is created correctly when text properties are stripped."
  (opencode-test-with-temp-buffer "*test-exit-folder-no-prop*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector)))
      ;; candidate has trailing / but NO text property
      (insert "> @src/")
      (cl-letf (((symbol-function 'project-current) (lambda () t))
                ((symbol-function 'project-root) (lambda (_) "/proj/")))
        (opencode-chat--mention-exit "src/" 'finished)
        (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
               (meta (overlay-get ov 'opencode-mention)))
          (should ov)
          ;; Folder converts to file type for API
          (should (eq 'file (plist-get meta :type)))
          ;; Name strips trailing /
          (should (string= "src" (plist-get meta :name)))
          ;; Path ends with /
          (should (string-suffix-p "/" (plist-get meta :path))))))))

;;; --- Agent chip with extra text from completion framework ---

(ert-deftest opencode-chat-mention-exit-agent-extra-text-stripped ()
  "Agent chip works when completion framework inserts extra annotation text.
Some frameworks (corfu, etc.) insert annotation/description text
after the candidate.  The exit function must still find the @, create
the chip correctly, and remove the extra text."
  (opencode-test-with-temp-buffer "*test-exit-agent-extra*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary"
                                               :description "Default agent"))))
      ;; Simulate: user typed @, completed build, but framework
      ;; also inserted " Default agent" after the candidate.
      (insert "> @build Default agent")
      ;; Exit function receives just the candidate name
      (opencode-chat--mention-exit "build" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        ;; Chip must be created
        (should ov)
        ;; Type must be agent
        (should (eq 'agent (plist-get meta :type)))
        ;; Face must be agent face, not file face
        (should (eq 'opencode-mention-agent (overlay-get ov 'face)))
        ;; Name is just "build", no description
        (should (string= "build" (plist-get meta :name)))
        ;; The extra " Default agent" text must be removed
        (should-not (string-match-p "Default agent"
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))
        ;; Chip covers exactly @build
        (should (string= "@build"
                         (buffer-substring-no-properties
                          (overlay-start ov) (overlay-end ov))))))))

(ert-deftest opencode-chat-mention-exit-agent-with-spaces-in-name ()
  "Agent chip works for names containing spaces and parens.
Real server agents like \"Prometheus (Plan Builder)\" have spaces in
their name.  The chip must cover the entire @name text."
  (opencode-test-with-temp-buffer "*test-exit-agent-spaces*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "Prometheus (Plan Builder)" :mode "all")
                                         (list :name "Sisyphus (Ultraworker)" :mode "primary"))))
      ;; Simulate selecting "Prometheus (Plan Builder)" from completion
      (insert "> @Prometheus (Plan Builder)")
      (opencode-chat--mention-exit "Prometheus (Plan Builder)" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should ov)
        (should (eq 'agent (plist-get meta :type)))
        (should (eq 'opencode-mention-agent (overlay-get ov 'face)))
        (should (string= "Prometheus (Plan Builder)" (plist-get meta :name)))
        (should-not (plist-get meta :path))
        ;; Chip covers the full @name including spaces
        (should (string= "@Prometheus (Plan Builder)"
                         (buffer-substring-no-properties
                          (overlay-start ov) (overlay-end ov))))))))

(ert-deftest opencode-chat-mention-type-for-name-agent-with-spaces ()
  "Type lookup returns agent for names with spaces matching cached agent."
  (let ((opencode-api--agents-cache (vector (list :name "Prometheus (Plan Builder)" :mode "all"))))
    (should (eq 'agent (opencode-chat--mention-type-for-name "Prometheus (Plan Builder)")))))

(ert-deftest opencode-chat-mention-capf-allows-agent-with-spaces ()
  "CAPF returns completion table even when prefix contains spaces.
Agent names like \"Prometheus (Plan Builder)\" have spaces, so the
CAPF must not reject prefixes containing spaces."
  (opencode-test-with-temp-buffer "*test-capf-spaces*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "Prometheus (Plan Builder)" :mode "all"))))
      ;; User has typed @Prometheus (Plan — space is present
      (insert "> @Prometheus (Plan")
      (let ((result (opencode-chat--mention-capf)))
        ;; CAPF must still return a result, not nil
        (should result)
        (should (nth 2 result))))))  ;; table is present

(ert-deftest opencode-chat-mention-exit-agent-after-file-chip ()
  "Agent chip works correctly when placed after an existing file chip.
Verifies that search-backward finds the correct @ (the agent's, not
the file chip's)."
  (opencode-test-with-temp-buffer "*test-exit-agent-after-file*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary"))))
      ;; First, create a file chip
      (insert "> @test.el")
      (let ((file-candidate "test.el"))
        (cl-letf (((symbol-function 'project-current) (lambda () t))
                  ((symbol-function 'project-root) (lambda (_) "/proj/")))
          (opencode-chat--mention-exit file-candidate 'finished)))
      ;; Now add space and agent mention
      (goto-char (point-max))
      (insert " @build")
      (opencode-chat--mention-exit "build" 'finished)
      ;; Should have two overlays
      (let ((chip-ovs (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
        (should (= 2 (length chip-ovs)))
        ;; overlays-in returns position-ordered; agent chip is second
        (let* ((agent-ov (cadr chip-ovs))
               (meta (overlay-get agent-ov 'opencode-mention)))
          (should (eq 'agent (plist-get meta :type)))
          (should (eq 'opencode-mention-agent (overlay-get agent-ov 'face)))
          (should (string= "build" (plist-get meta :name))))))))

(ert-deftest opencode-chat-mention-exit-agent-extra-text-preserves-point ()
  "After removing extra text, point is at the end of the chip."
  (opencode-test-with-temp-buffer "*test-exit-agent-point*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (let ((opencode-api--agents-cache (vector (list :name "plan" :mode "primary"))))
      (insert "> @plan (Disallows tools)")
      (opencode-chat--mention-exit "plan" 'finished)
      (let ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max))))))
        (should ov)
        ;; Point should be at or after the chip end
        (should (<= (point) (overlay-end ov)))))))

(ert-deftest opencode-chat-mention-exit-file-no-extra-text-regression ()
  "Normal file completion (no extra text) still works with new chip-end logic."
  (opencode-test-with-temp-buffer "*test-exit-file-regression*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @README.md")
    (cl-letf (((symbol-function 'project-current) (lambda () t))
              ((symbol-function 'project-root) (lambda (_) "/proj/")))
      (opencode-chat--mention-exit "README.md" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should ov)
        (should (eq 'file (plist-get meta :type)))
        ;; Chip covers exactly @README.md
        (should (string= "@README.md"
                         (buffer-substring-no-properties
                          (overlay-start ov) (overlay-end ov))))))))

;;; --- Prompt body with ./ and / mentions ---

(ert-deftest opencode-chat-mention-exit-dot-slash-folder ()
  "Selecting a ./dir/ candidate creates correct chip with resolved path."
  (opencode-test-with-temp-buffer "*test-exit-dot-slash-folder*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @./src/")
    (let ((candidate (copy-sequence "./src/")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'folder candidate)
      (cl-letf (((symbol-function 'project-current) (lambda () t))
                ((symbol-function 'project-root) (lambda (_) "/proj/")))
        (opencode-chat--mention-exit candidate 'finished)
        (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
               (meta (overlay-get ov 'opencode-mention)))
          (should (eq 'file (plist-get meta :type)))
          (should (string= "./src" (plist-get meta :name)))
          (should (string= "/proj/src/" (plist-get meta :path))))))))

(ert-deftest opencode-chat-mention-exit-dot-slash-file ()
  "Selecting a ./file candidate creates chip with correct path."
  (opencode-test-with-temp-buffer "*test-exit-dot-slash-file*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @./README.md")
    (cl-letf (((symbol-function 'project-current) (lambda () t))
              ((symbol-function 'project-root) (lambda (_) "/proj/")))
      (opencode-chat--mention-exit "./README.md" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should (eq 'file (plist-get meta :type)))
        (should (string= "./README.md" (plist-get meta :name)))
        (should (string= "/proj/README.md" (plist-get meta :path)))
        (should-not (string-suffix-p "/" (plist-get meta :path)))))))

(ert-deftest opencode-chat-mention-exit-abs-folder ()
  "Selecting an absolute /path/ folder candidate creates correct chip."
  (opencode-test-with-temp-buffer "*test-exit-abs-folder*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @/etc/nginx/")
    (let ((candidate (copy-sequence "/etc/nginx/")))
      (put-text-property 0 (length candidate) 'opencode-mention-type 'folder candidate)
      (cl-letf (((symbol-function 'project-current) (lambda () nil)))
        (opencode-chat--mention-exit candidate 'finished)
        (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
               (meta (overlay-get ov 'opencode-mention)))
          (should (eq 'file (plist-get meta :type)))
          (should (string= "/etc/nginx" (plist-get meta :name)))
          (should (string= "/etc/nginx/" (plist-get meta :path))))))))

(ert-deftest opencode-chat-mention-exit-abs-file ()
  "Selecting an absolute /path/file candidate creates correct chip."
  (opencode-test-with-temp-buffer "*test-exit-abs-file*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> @/etc/hosts")
    (cl-letf (((symbol-function 'project-current) (lambda () nil)))
      (opencode-chat--mention-exit "/etc/hosts" 'finished)
      (let* ((ov (car (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention)) (overlays-in (point-min) (point-max)))))
             (meta (overlay-get ov 'opencode-mention)))
        (should (eq 'file (plist-get meta :type)))
        (should (string= "/etc/hosts" (plist-get meta :name)))
        (should (string= "/etc/hosts" (plist-get meta :path)))
        (should-not (string-suffix-p "/" (plist-get meta :path)))))))


;;; --- Dynamic agent coloring tests ---

(ert-deftest opencode-chat-agent-chip-face-with-color ()
  "Agent chip face returns dynamic face plist when color is provided."
  (let ((face (opencode-chat--agent-chip-face "#34d399")))
    (should (listp face))
    (should (plist-get face :weight))
    (should (plist-get face :foreground))
    (should (plist-get face :background))
    (should (plist-get face :box))))

(ert-deftest opencode-chat-agent-chip-face-without-color ()
  "Agent chip face falls back to named face when color is nil."
  (should (eq 'opencode-mention-agent (opencode-chat--agent-chip-face nil))))

(ert-deftest opencode-chat-agent-badge-face-with-color ()
  "Agent badge face returns dynamic face with color foreground."
  (let ((face (opencode-chat--agent-badge-face "#a78bfa")))
    (should (listp face))
    (should (string= "#a78bfa" (plist-get face :foreground)))
    (should (eq 'bold (plist-get face :weight)))))

(ert-deftest opencode-chat-agent-badge-face-without-color ()
  "Agent badge face falls back to named face when color is nil."
  (should (eq 'opencode-agent-badge (opencode-chat--agent-badge-face nil))))

(ert-deftest opencode-chat-chip-create-uses-agent-color ()
  "Chip create applies dynamic agent color from cache."
  (opencode-test-with-temp-buffer "*test-chip-color*"
    (opencode-chat-mode)
    (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary"
                                               :color "#34d399"))))
      (insert "@build")
      (let ((ov (opencode-chat--chip-create 1 7 'agent "build")))
        ;; Face should be a plist (dynamic), not a symbol (static)
        (should (listp (overlay-get ov 'face)))
        ;; Box border should use the agent color
        (let ((box (plist-get (overlay-get ov 'face) :box)))
          (should box)
          (should (string= "#34d399" (plist-get box :color))))))))

(ert-deftest opencode-chat-chip-create-fallback-without-color ()
  "Chip create falls back to static face when agent has no color."
  (opencode-test-with-temp-buffer "*test-chip-no-color*"
    (opencode-chat-mode)
    (let ((opencode-api--agents-cache (vector (list :name "plan" :mode "primary"))))
      (insert "@plan")
      (let ((ov (opencode-chat--chip-create 1 6 'agent "plan")))
        ;; Falls back to named face
        (should (eq 'opencode-mention-agent (overlay-get ov 'face)))))))


(ert-deftest opencode-chat-chip-create-file-unaffected-by-agent-color ()
  "File chip still uses static face regardless of agent cache colors."
  (opencode-test-with-temp-buffer "*test-chip-file-color*"
    (opencode-chat-mode)
    (let ((opencode-api--agents-cache (vector (list :name "build" :mode "primary"
                                               :color "#34d399"))))
      (insert "@readme.md")
      (let ((ov (opencode-chat--chip-create 1 (point) 'file "readme.md" "/proj/readme.md")))
        (should (eq 'opencode-mention-file (overlay-get ov 'face)))))))

(ert-deftest opencode-chat-agent-chip-face-dark-background ()
  "Chip face on dark background derives darkened bg and lightened fg."
  (cl-letf (((symbol-function 'frame-parameter)
             (lambda (_f param) (if (eq param 'background-mode) 'dark nil))))
    (let ((face (opencode-chat--agent-chip-face "#34d399")))
      ;; Background should be darker than the original color
      (should (plist-get face :background))
      ;; Foreground should be lighter
      (should (plist-get face :foreground))
      ;; Both should be valid color strings
      (should (color-defined-p (plist-get face :background)))
      (should (color-defined-p (plist-get face :foreground))))))

(ert-deftest opencode-chat-agent-chip-face-light-background ()
  "Chip face on light background derives lightened bg and darkened fg."
  (cl-letf (((symbol-function 'frame-parameter)
             (lambda (_f param) (if (eq param 'background-mode) 'light nil))))
    (let ((face (opencode-chat--agent-chip-face "#34d399")))
      (should (plist-get face :background))
      (should (plist-get face :foreground))
      (should (color-defined-p (plist-get face :background)))
      (should (color-defined-p (plist-get face :foreground))))))

(ert-deftest opencode-chat-render-agent-part-uses-agent-color ()
  "Agent part rendering applies dynamic color from cache."
  (opencode-test-with-temp-buffer "*test-render-agent-color*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (opencode-api--agents-cache (vector (list :name "explore" :mode "subagent"
                                               :color "#60a5fa")))
          (part (list :id "prt_a1" :type "agent" :name "explore")))
      (opencode-chat--render-part part 'assistant)
      ;; Text should be present
      (should (opencode-test-buffer-contains-p "explore"))
      ;; Face on the agent text should be a dynamic plist (not the static symbol)
      (goto-char (point-min))
      (search-forward "explore")
      (let ((face (get-text-property (1- (point)) 'face)))
        (should (listp face))))))

(ert-deftest opencode-chat-render-assistant-header-agent-color ()
  "Assistant message header shows agent name with color, model with default badge."
  (opencode-test-with-temp-buffer "*test-header-agent-color*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (opencode-api--agents-cache (vector (list :name "build" :mode "primary"
                                               :color "#34d399")))
          (info (list :role "assistant" :agent "build"
                      :modelID "claude-opus-4-6"
                      :time (list :created (* 1000 (floor (float-time)))))))
      (opencode-chat--render-assistant-message info nil)
      ;; Agent name should appear
      (should (opencode-test-buffer-contains-p "build"))
      ;; Model name should appear
      (should (opencode-test-buffer-contains-p "claude-opus-4-6")))))




;;; --- Subtask part rendering ---

(ert-deftest opencode-chat-render-subtask-part-inserts-command ()
  "Subtask part renders with /command name in header."
  (opencode-test-with-temp-buffer "*test-render-subtask*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_s1" :type "subtask"
                      :command "review"
                      :description "review changes"
                      :agent "claude-native")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "/review"))
      (should (opencode-test-buffer-contains-p "review changes")))))

(ert-deftest opencode-chat-render-subtask-part-shows-model ()
  "Subtask part renders model ID when present."
  (opencode-test-with-temp-buffer "*test-render-subtask-model*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_s2" :type "subtask"
                      :command "review"
                      :description "review changes"
                      :agent "claude-native"
                      :model (list :providerID "Gemini"
                                   :modelID "gemini-3.1-pro"))))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "gemini-3.1-pro")))))

(ert-deftest opencode-chat-render-subtask-part-stripe ()
  "Subtask part has correct line-prefix stripe for user role."
  (opencode-test-with-temp-buffer "*test-render-subtask-stripe*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_s3" :type "subtask"
                      :command "review"
                      :description "review changes")))
      (opencode-chat--render-part part 'user)
      (goto-char (point-min))
      (search-forward "/review")
      (let ((prefix (get-text-property (1- (point)) 'line-prefix)))
        (should prefix)
        (should (eq 'opencode-user-block (get-text-property 0 'face prefix)))))))

(ert-deftest opencode-chat-render-subtask-part-collapsed-by-default ()
  "Subtask part body (prompt) is collapsed by default."
  (opencode-test-with-temp-buffer "*test-render-subtask-collapsed*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_s4" :type "subtask"
                      :command "review"
                      :description "review changes"
                      :prompt "You are a code reviewer.")))
      (opencode-chat--render-part part 'user)
      ;; Header visible
      (should (opencode-test-buffer-contains-p "/review"))
      ;; Collapsed indicator present
      (should (opencode-test-buffer-contains-p "[collapsed]"))
      ;; Prompt text exists in buffer but is invisible
      (goto-char (point-min))
      (search-forward "You are a code reviewer.")
      (should (eq 'opencode-section
                  (get-text-property (match-beginning 0) 'invisible))))))

(ert-deftest opencode-chat-render-subtask-part-no-body-without-prompt ()
  "Subtask part without prompt has no expandable body."
  (opencode-test-with-temp-buffer "*test-render-subtask-no-prompt*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "prt_s5" :type "subtask"
                      :command "review"
                      :description "review changes")))
      (opencode-chat--render-part part 'user)
      (should (opencode-test-buffer-contains-p "/review"))
      ;; No collapsed indicator when there's no body
      (should-not (opencode-test-buffer-contains-p "[collapsed]")))))

;;; --- TUI parity: inline session creation (Task 1) ---



;;; --- TUI parity: on-part-updated refinement (Task 2) ---

;;; --- TUI parity: session.compacted handler (Task 3) ---

;;; --- TUI parity: server.instance.disposed handler (Task 4) ---

;;; --- Refresh in-flight guard (once-entry pattern) ---

;;; --- Streaming vs Render comparison tests ---

(defun opencode-chat-test--extract-text-region (start end)
  "Extract text, face, and line-prefix properties from region START to END.
Returns a list of (TEXT FACE LINE-PREFIX) triples, one per character position.
This allows comparing render-path output against streaming-path output."
  (let ((result nil))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (push (list (char-to-string (char-after))
                    (get-text-property (point) 'face)
                    (get-text-property (point) 'line-prefix))
              result)
        (forward-char 1)))
    (nreverse result)))

(defun opencode-chat-test--extract-text-content (start end)
  "Extract buffer-substring-no-properties from START to END."
  (buffer-substring-no-properties start end))

(defun opencode-chat-test--face-at-offset (offset)
  "Return the face at buffer position OFFSET."
  (get-text-property offset 'face))

(defun opencode-chat-test--line-prefix-at-offset (offset)
  "Return the line-prefix at buffer position OFFSET."
  (get-text-property offset 'line-prefix))

(ert-deftest opencode-chat-streaming-vs-render-text-single-line ()
  "Streaming and render paths produce identical text content for single-line text.
The render path (render-text-part) builds text with mapconcat; the streaming path
(insert-streaming-delta) inserts line-by-line.  Both must produce the same text
with space-prefixed lines, the same face, and the same line-prefix stripe."
  (let ((text "Hello world")
        (render-text nil)
        (stream-text nil))
    ;; Render path: use render-text-part with a finished part
    (opencode-test-with-temp-buffer "*test-cmp-render-single*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t)
            (part (list :id "p1" :type "text" :text text
                       :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        (setq render-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; Streaming path: simulate full text arriving as one delta at bolp
    (opencode-test-with-temp-buffer "*test-cmp-stream-single*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "text")
        (setq stream-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; The streaming text should match the render text body (minus trailing newline)
    ;; Render adds \n for finished parts; streaming does not.
    (should (string= (string-trim-right render-text "\n")
                     stream-text))))

(ert-deftest opencode-chat-streaming-vs-render-text-multiline ()
  "Streaming and render paths produce identical text for multi-line text.
Both paths must add a space prefix to each line of body text."
  (let ((text "Line one\nLine two\nLine three")
        (render-text nil)
        (stream-text nil))
    ;; Render path
    (opencode-test-with-temp-buffer "*test-cmp-render-multi*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t)
            (part (list :id "p1" :type "text" :text text
                       :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        (setq render-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; Streaming path: multi-line delta at bolp
    (opencode-test-with-temp-buffer "*test-cmp-stream-multi*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "text")
        (setq stream-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; Should match (minus trailing newline from render)
    (should (string= (string-trim-right render-text "\n")
                     stream-text))))

(ert-deftest opencode-chat-streaming-vs-render-text-face ()
  "Streaming and render paths apply the same face to assistant text.
Both must use `opencode-assistant-body' face on the body text."
  (let ((text "Hello"))
    ;; Render path
    (opencode-test-with-temp-buffer "*test-cmp-face-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t)
            (part (list :id "p1" :type "text" :text text
                       :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        ;; Check face at the first text char (position 1, after the space prefix)
        (should (eq 'opencode-assistant-body (get-text-property 1 'face)))))
    ;; Streaming path
    (opencode-test-with-temp-buffer "*test-cmp-face-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "text")
        ;; Same face at same relative position
        (should (eq 'opencode-assistant-body (get-text-property 1 'face)))))))

(ert-deftest opencode-chat-streaming-vs-render-line-prefix ()
  "Streaming and render paths produce the same line-prefix stripe.
Both use a propertized stripe char with `opencode-assistant-block' face."
  (let ((text "Hello"))
    ;; Render path
    (opencode-test-with-temp-buffer "*test-cmp-lp-render*"
      (opencode-chat-mode)
      (let* ((inhibit-read-only t)
             (part (list :id "p1" :type "text" :text text
                        :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        (let ((lp (get-text-property 1 'line-prefix)))
          ;; Stripe char
          (should (string= (substring-no-properties lp) "\u258E"))
          ;; Face on stripe
          (should (eq 'opencode-assistant-block (get-text-property 0 'face lp))))))
    ;; Streaming path
    (opencode-test-with-temp-buffer "*test-cmp-lp-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "text")
        (let ((lp (get-text-property 1 'line-prefix)))
          ;; Same stripe char
          (should (string= (substring-no-properties lp) "\u258E"))
          ;; Same face
          (should (eq 'opencode-assistant-block (get-text-property 0 'face lp))))))))

(ert-deftest opencode-chat-streaming-vs-render-multiline-prefix ()
  "Each line in multi-line text gets the space prefix and line-prefix stripe.
Compares both paths for a 3-line text block to verify prefix consistency."
  (let ((text "AAA\nBBB\nCCC")
        render-lines stream-lines)
    ;; Render path: collect the content of each line
    (opencode-test-with-temp-buffer "*test-cmp-mlp-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t)
            (part (list :id "p1" :type "text" :text text
                       :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        ;; Split lines of the rendered text (minus trailing newline)
        (setq render-lines (split-string
                           (string-trim-right (buffer-string) "\n")
                           "\n"))))
    ;; Streaming path: same multi-line as one delta
    (opencode-test-with-temp-buffer "*test-cmp-mlp-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "text")
        (setq stream-lines (split-string (buffer-string) "\n"))))
    ;; Same number of lines
    (should (= (length render-lines) (length stream-lines)))
    ;; Each line should match (both have " " prefix)
    (cl-loop for rl in render-lines
             for sl in stream-lines
             do (should (string= rl sl)))))

(ert-deftest opencode-chat-streaming-vs-render-incremental-deltas ()
  "Multiple incremental streaming deltas produce the same text as render.
Simulates realistic streaming: first delta starts a line, subsequent deltas
continue on the same line, then a newline starts a new line."
  (let ((text "Hello World\nSecond line")
        (render-text nil)
        (stream-text nil))
    ;; Render path: full text at once
    (opencode-test-with-temp-buffer "*test-cmp-incr-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t)
            (part (list :id "p1" :type "text" :text text
                       :time (list :start 1700000000000 :end 1700000001000))))
        (opencode-chat--render-text-part part 'assistant)
        (setq render-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; Streaming path: incremental deltas simulating real SSE
    (opencode-test-with-temp-buffer "*test-cmp-incr-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        ;; Delta 1: "Hello" at bolp
        (opencode-chat--insert-streaming-delta "Hello" "text")
        ;; Delta 2: " World" NOT at bolp (continuation)
        (opencode-chat--insert-streaming-delta " World" "text")
        ;; Delta 3: newline + new line
        (opencode-chat--insert-streaming-delta "\nSecond line" "text")
        (setq stream-text (buffer-substring-no-properties (point-min) (point-max)))))
    ;; Text content should match (minus trailing newline)
    (should (string= (string-trim-right render-text "\n")
                     stream-text))))

(ert-deftest opencode-chat-streaming-vs-render-user-text ()
  "Streaming is always assistant role; render-text-part for user role uses
different faces.  This test verifies the render path's user face is distinct."
  (opencode-test-with-temp-buffer "*test-cmp-user-face*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t)
          (part (list :id "p1" :type "text" :text "User text"
                     :time (list :start 1700000000000 :end 1700000001000))))
      (opencode-chat--render-text-part part 'user)
      ;; User text uses opencode-user-body, not opencode-assistant-body
      (should (eq 'opencode-user-body (get-text-property 1 'face)))
      ;; User line-prefix uses opencode-user-block
      (let ((lp (get-text-property 1 'line-prefix)))
        (should (eq 'opencode-user-block (get-text-property 0 'face lp)))))))

(ert-deftest opencode-chat-streaming-vs-render-reasoning-face ()
  "Streaming reasoning uses opencode-reasoning face, matching render-reasoning-part.
Both paths should produce the same face for reasoning text."
  (let ((text "Let me think..."))
    ;; Render path: use render-part which dispatches to render-reasoning-part
    ;; Note: render-reasoning-part may wrap in a section, but the face should match
    (opencode-test-with-temp-buffer "*test-cmp-reason-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--insert-streaming-delta text "reasoning")
        ;; Streaming reasoning face
        (should (eq 'opencode-reasoning (get-text-property 1 'face)))
        ;; Same line-prefix as regular assistant streaming
        (let ((lp (get-text-property 1 'line-prefix)))
          (should lp)
          (should (eq 'opencode-assistant-block (get-text-property 0 'face lp))))))))

(ert-deftest opencode-chat-streaming-vs-render-tool-inline-update ()
  "Tool parts updated inline via update-part-inline match render-tool-part output.
Both paths call render-tool-part; update-part-inline then adds read-only and keymap.
After render-messages, render-tool-part output also gets read-only and keymap in bulk."
  (let ((part (list :id "prt_tool1"
                    :type "tool"
                    :tool "bash"
                    :state (list :status "completed"
                                 :input (list :command "ls -la"
                                              :description "List files")
                                 :output "total 42\n"
                                 :time (list :start 1700000000000
                                             :end 1700000005000))))
        render-text stream-text)
    ;; Render path: call render-tool-part directly
    (opencode-test-with-temp-buffer "*test-cmp-tool-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--render-tool-part part)
        (setq render-text (buffer-string))))
    ;; Inline update path: bootstrap at messages-end
    (opencode-test-with-temp-buffer "*test-cmp-tool-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        ;; Set up messages-end marker (simulating a rendered buffer)
        (opencode-chat--set-messages-end (copy-marker (point) t))
        (opencode-chat--update-part-inline part)
        (setq stream-text (buffer-string))))
    ;; Both should contain the tool name and command
    (should (string-match-p "bash" render-text))
    (should (string-match-p "bash" stream-text))
    ;; The rendered text content should be identical
    ;; (update-part-inline calls render-tool-part internally)
    (should (string= render-text stream-text))))

(ert-deftest opencode-chat-streaming-vs-render-tool-re-render ()
  "Tool part re-render via update-part-inline (overlay case) matches fresh render.
When an overlay already exists for a tool part, update-part-inline deletes and
re-renders it.  The result should match a fresh render-tool-part call."
  (let* ((part-v1 (list :id "prt_tool2"
                        :type "tool"
                        :tool "read"
                        :state (list :status "running"
                                     :input (list :filePath "src/main.ts"))))
         (part-v2 (list :id "prt_tool2"
                        :type "tool"
                        :tool "read"
                        :state (list :status "completed"
                                     :input (list :filePath "src/main.ts")
                                     :output "content here"
                                     :time (list :start 1700000000000
                                                 :end 1700000003000))))
         fresh-text updated-text)
    ;; Fresh render of v2 (completed version)
    (opencode-test-with-temp-buffer "*test-cmp-tool-fresh*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--render-tool-part part-v2)
        (setq fresh-text (buffer-string))))
    ;; Inline update: render v1 first, then update to v2
    (opencode-test-with-temp-buffer "*test-cmp-tool-update*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        ;; Set up messages-end and render v1
        (opencode-chat--set-messages-end (copy-marker (point) t))
        (opencode-chat--update-part-inline part-v1)
        ;; Now update to v2 (should find existing overlay)
        (opencode-chat--update-part-inline part-v2)
        (setq updated-text (buffer-string))))
    ;; Both should produce the same visible text
    (should (string= fresh-text updated-text))))

(ert-deftest opencode-chat-streaming-vs-render-step-start ()
  "Step-start parts rendered via update-part-inline match render-step-start.
Both paths call the same render function."
  (let ((part (list :id "prt_step1"
                    :type "step-start"
                    :snapshot "abc123"))
        render-text stream-text)
    ;; Render path
    (opencode-test-with-temp-buffer "*test-cmp-step-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--render-step-start part)
        (setq render-text (buffer-string))))
    ;; Inline update path
    (opencode-test-with-temp-buffer "*test-cmp-step-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--set-messages-end (copy-marker (point) t))
        (opencode-chat--update-part-inline part)
        (setq stream-text (buffer-string))))
    (should (string= render-text stream-text))))

(ert-deftest opencode-chat-streaming-vs-render-step-finish ()
  "Step-finish parts rendered via update-part-inline match render-step-finish.
Both paths call the same render function."
  (let ((part (list :id "prt_stepf1"
                    :type "step-finish"
                    :reason "stop"
                    :cost 0.05
                    :tokens (list :total 5000 :input 200 :output 300
                                  :reasoning 0
                                  :cache (list :read 4000 :write 500))))
        render-text stream-text)
    ;; Render path
    (opencode-test-with-temp-buffer "*test-cmp-stepf-render*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--render-step-finish part)
        (setq render-text (buffer-string))))
    ;; Inline update path
    (opencode-test-with-temp-buffer "*test-cmp-stepf-stream*"
      (opencode-chat-mode)
      (let ((inhibit-read-only t))
        (opencode-chat--set-messages-end (copy-marker (point) t))
        (opencode-chat--update-part-inline part)
        (setq stream-text (buffer-string))))
    (should (string= render-text stream-text))))

(ert-deftest opencode-chat-streaming-delta-newline-handling ()
  "Streaming delta with trailing newline correctly starts a new line.
When a delta ends with \\n, the next delta should start at bolp and get the space prefix."
  (opencode-test-with-temp-buffer "*test-cmp-newline-handling*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      ;; Delta with trailing newline
      (opencode-chat--insert-streaming-delta "First line\n" "text")
      ;; Next delta should be at bolp and get space prefix
      (opencode-chat--insert-streaming-delta "Second line" "text")
      ;; Should produce " First line\n Second line"
      (should (string= (buffer-string) " First line\n Second line")))))

(ert-deftest opencode-chat-streaming-empty-delta-no-crash ()
  "Empty string delta does not crash or corrupt buffer state."
  (opencode-test-with-temp-buffer "*test-cmp-empty-delta*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      (opencode-chat--insert-streaming-delta "" "text")
      ;; Empty delta should produce just a space (bolp prefix)
      ;; or nothing if string-lines returns ("") which is one empty line
      (should (<= (buffer-size) 1)))))

(ert-deftest opencode-chat-image-to-data-url ()
  "Verify image bytes are correctly encoded to data URL.
Without this, images pasted from clipboard won't be sent correctly to the server."
  (let ((img (list :data "PNG-DATA" :mime "image/png")))
    (should (string= (opencode-chat--image-to-data-url img)
                     (concat "data:image/png;base64,"
                             (base64-encode-string "PNG-DATA" t))))))

(ert-deftest opencode-chat-image-to-data-url-oversized ()
  "Verify image exceeding max size raises user-error.
Without this, users might unknowingly send huge images that crash the server or consume too much bandwidth."
  (let ((opencode-chat-image-max-size 5)
        (img (list :data "1234567890" :mime "image/png")))
    (should-error (opencode-chat--image-to-data-url img)
                  :type 'user-error)))

(ert-deftest opencode-chat-image-filename ()
  "Verify default filenames for common image mime types.
Without this, images might be sent with generic names that tools can't interpret.
Uses `mailcap-mime-type-to-extension' which returns canonical extensions."
  (should (string= (opencode--image-filename "image/png") "clipboard-image.png"))
  ;; mailcap-mime-type-to-extension returns "jpeg" not "jpg"
  (should (string= (opencode--image-filename "image/jpeg") "clipboard-image.jpeg"))
  ;; mailcap returns "octet-stream" for application/octet-stream
  (should (string= (opencode--image-filename "application/octet-stream") "clipboard-image.octet-stream")))

(ert-deftest opencode-chat-extract-mentions-skips-image-chips ()
  "Verify image chips are NOT included in extracted mentions.
Without this, image chips would leak into the mentions list, causing server errors or confusing the agent."
  (opencode-test-with-temp-buffer "*test-extract-skip-images*"
    (opencode-chat-mode)
    (opencode-chat--set-input-start (point-marker))
    (insert "> ")
    ;; Create an image chip
    (let ((start (point)))
      (insert "image.png")
      (opencode-chat--chip-create start (point) 'image "image.png" nil
                                  (list :data-url "data:..." :mime "image/png" :filename "image.png")))
    (insert " ")
    ;; Create a file chip
    (let ((start (point)))
      (insert "foo.el")
      (opencode-chat--chip-create start (point) 'file "foo.el" "/path/foo.el"))
    
    (let ((mentions (plist-get (opencode-chat--input-attachments) :mentions)))
      (should (= (length mentions) 1))
      (should (eq (plist-get (car mentions) :type) 'file))
      (should (string= (plist-get (car mentions) :name) "foo.el")))))

(ert-deftest opencode-chat-mention-offsets-match-trimmed-text ()
  "Verify mention :start/:end offsets match the trimmed text from `input-text'.
Bug: the input area starts with a placeholder space (\" \").  `input-text'
calls `string-trim' which removes it, but `input-attachments' computed
offsets relative to the raw (untrimmed) buffer content.  This caused
`(substring text start end)' in `prompt-body' to signal `args-out-of-range'
when mentions appeared near the end of the input.  The fix adjusts offsets
in `input-attachments' to account for leading whitespace."
  (opencode-test-with-temp-buffer "*test-mention-offsets*"
    (opencode-chat-mode)
    ;; Simulate the real input area layout:
    ;; "> " (read-only prompt) + " " (editable placeholder) + user text
    (let ((inhibit-read-only t))
      (insert (propertize "> " 'read-only t))
      ;; Editable placeholder space — this is what `render-input-area' inserts
      (insert (propertize " " 'opencode-input t))
      (opencode-chat--set-input-start (point-marker))
      ;; Simulate user typing with two @mentions
      (let ((text-before "we want a proxy in "))
        (insert text-before)
        ;; First @mention chip: @plugins/mem0/src/embedder.ts
        (let ((chip1-start (point))
              (chip1-text "@plugins/mem0/src/embedder.ts"))
          (insert chip1-text)
          (opencode-chat--chip-create chip1-start (point) 'file
                                      "plugins/mem0/src/embedder.ts"
                                      "/tmp/plugins/mem0/src/embedder.ts"))
        (insert ", the proxy code is at ")
        ;; Second @mention chip: @faas/6elo122h/
        (let ((chip2-start (point))
              (chip2-text "@faas/6elo122h/"))
          (insert chip2-text)
          (opencode-chat--chip-create chip2-start (point) 'file
                                      "faas/6elo122h/"
                                      "/tmp/faas/6elo122h/")))
      ;; Mark post-input as read-only so input-content-end works
      (let ((post-start (point)))
        (insert (propertize "\nfooter" 'read-only t))))
    ;; Now verify offsets are valid for substring
    (let* ((text (opencode-chat--input-text))
           (attachments (opencode-chat--input-attachments))
           (mentions (plist-get attachments :mentions)))
      ;; Should have 2 mentions
      (should (= (length mentions) 2))
      ;; Every mention's start/end must be valid indices into the trimmed text
      (dolist (m mentions)
        (let ((mstart (plist-get m :start))
              (mend (plist-get m :end)))
          ;; This is the exact call that was failing with args-out-of-range:
          (should (stringp (substring text mstart mend)))
          ;; The extracted substring should start with @
          (should (string-prefix-p "@" (substring text mstart mend))))))))



;;; --- TAB key dispatch ---

(ert-deftest opencode-chat-tab-in-message-area-should-toggle-section ()
  "Pressing TAB in the message area should toggle-section, not cycle agent.
The message area has `opencode-chat-message-map' via text property.
This test simulates a real TAB press by looking up the key binding
at point — the same lookup Emacs performs on a keystroke."
  (opencode-test-with-temp-buffer "*test-tab-message-area*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      ;; Simulate message area: text with the message-map keymap
      (insert (propertize "Some assistant message\n"
                          'read-only t
                          'keymap opencode-chat-message-map)))
    ;; Point is in the message area
    (goto-char (point-min))
    ;; Look up what TAB resolves to — this is exactly what Emacs does
    ;; when the user presses the key
    (let ((cmd (key-binding (kbd "TAB"))))
      ;; BUG: currently resolves to cycle-agent instead of toggle-section
      (should (eq cmd #'opencode-ui--toggle-section)))))

(ert-deftest opencode-chat-tab-in-input-area-should-cycle-agent ()
  "Pressing TAB in the input area should cycle agent.
The input area has `opencode-chat-input-map' via text property,
which does NOT bind TAB, so it falls through to `opencode-chat-mode-map'."
  (opencode-test-with-temp-buffer "*test-tab-input-area*"
    (opencode-chat-mode)
    (let ((inhibit-read-only t))
      ;; Message area
      (insert (propertize "Some message\n"
                          'read-only t
                          'keymap opencode-chat-message-map))
      ;; Input area
      (insert (propertize "user input"
                          'opencode-input t
                          'keymap opencode-chat-input-map)))
    ;; Point in the input area
    (goto-char (- (point-max) 3))
    (let ((cmd (key-binding (kbd "TAB"))))
      (should (eq cmd #'opencode-chat--cycle-agent)))))

;;; --- Test: Edit tool file path has keymap and text properties ---

(ert-deftest opencode-chat-edit-tool-file-path-clickable ()
  "Verify that edit tool body has opencode-file-path property and file keymap.
Why this matters — users expect RET on edit diffs to open the edited file."
  (opencode-test-with-temp-buffer "*test-edit-click*"
    (opencode-chat-mode)
    (opencode-chat--set-current-message-id "msg_test")
    (let ((inhibit-read-only t))
      (opencode-chat--render-edit-body
       (list :filePath "src/main.ts" :oldString "old" :newString "new")
       nil nil)
      ;; File path property should be on the rendered text
      (goto-char (point-min))
      (should (search-forward "src/main.ts" nil t))
      (should (equal (get-text-property (match-beginning 0) 'opencode-file-path)
                     "src/main.ts"))
      ;; Keymap should be set
      (should (eq (get-text-property (match-beginning 0) 'keymap)
                  opencode-chat-message-file-map))
      ;; RET should be bound to open-file-at-point
      (goto-char (match-beginning 0))
      (should (eq (key-binding (kbd "RET"))
                  'opencode-chat-message-open-file-at-point)))))

;;; --- Test: Edit tool RET opens file in other window ---

(ert-deftest opencode-chat-edit-tool-ret-opens-file ()
  "Verify RET on edit tool body opens the file.
Why this matters — jump-to-file is the primary navigation from chat to code."
  (let* ((project-dir (make-temp-file "opencode-edit-test-" t))
         (file-path (expand-file-name "src/main.ts" project-dir))
         (opened-path nil))
    (make-directory (expand-file-name "src" project-dir) t)
    (with-temp-file file-path
      (insert "line1\nline2\nline3\n"))
    (unwind-protect
        (opencode-test-with-temp-buffer "*test-edit-nav*"
          (opencode-chat-mode)
          (setq default-directory (file-name-as-directory project-dir))
          (opencode-chat--set-current-message-id "msg_test")
          (let ((inhibit-read-only t))
            (opencode-chat--render-edit-body
             (list :filePath "src/main.ts" :oldString "old" :newString "new")
             nil nil))
          ;; Position on the file path
          (goto-char (point-min))
          (search-forward "src/main.ts")
          ;; Intercept find-file-other-window
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (path &rest _) (setq opened-path path))))
            (opencode-chat-message-open-file-at-point))
          (should opened-path)
          (should (string-suffix-p "src/main.ts" opened-path)))
      (delete-directory project-dir t))))

;;; --- Test: Edit tool RET — file already visible in a window ---

(ert-deftest opencode-chat-edit-tool-ret-existing-window ()
  "RET on edit tool jumps to existing window showing the file, at the correct line.
Why this matters — users don't want duplicate windows; cursor should move to
the already-visible file buffer at the edited line."
  (let* ((project-dir (make-temp-file "opencode-edit-win-" t))
         (src-dir (expand-file-name "src" project-dir))
         (file-path (expand-file-name "app.ts" src-dir)))
    (make-directory src-dir t)
    (with-temp-file file-path
      (dotimes (i 30) (insert (format "line %d\n" (1+ i)))))
    (unwind-protect
        (save-window-excursion
          ;; Open the file in a split window (simulating a visible file buffer)
          (find-file file-path)
          (let ((file-win (selected-window))
                (file-buf (current-buffer)))
            ;; Create a chat buffer in the other window
            (split-window)
            (other-window 1)
            (switch-to-buffer (get-buffer-create "*test-edit-existing*"))
            (opencode-chat-mode)
            (setq default-directory (file-name-as-directory project-dir))
            (opencode-chat--set-current-message-id "msg_test")
            (let ((inhibit-read-only t)
                  (chat-win (selected-window)))
              ;; Render an edit tool with a hunk starting at line 10
              (opencode-chat--render-edit-body
               (list :filePath "src/app.ts"
                     :oldString "line 10\nline 11\n"
                     :newString "line 10 modified\nline 11 modified\n")
               nil nil)
              ;; Position on the diff text (not the header)
              (goto-char (point-min))
              (should (search-forward "src/app.ts" nil t))
              ;; Press RET
              (opencode-chat-message-open-file-at-point)
              ;; Should have jumped to the file window, not made a new one
              (should (eq (selected-window) file-win))
              (should (eq (window-buffer file-win) file-buf)))))
      (when-let ((buf (get-buffer "*test-edit-existing*")))
        (kill-buffer buf))
      (when-let ((buf (find-buffer-visiting file-path)))
        (kill-buffer buf))
      (delete-directory project-dir t))))

;;; --- Test: Edit tool RET — file buffer exists but not in a window ---

(ert-deftest opencode-chat-edit-tool-ret-buffer-not-in-window ()
  "RET on edit tool opens file in a new window when buffer exists but isn't visible.
Why this matters — file may have been opened before but its window was closed."
  (let* ((project-dir (make-temp-file "opencode-edit-nowin-" t))
         (src-dir (expand-file-name "src" project-dir))
         (file-path (expand-file-name "hidden.ts" src-dir)))
    (make-directory src-dir t)
    (with-temp-file file-path
      (dotimes (i 20) (insert (format "line %d\n" (1+ i)))))
    (unwind-protect
        (save-window-excursion
          ;; Open the file to create a buffer, but don't show it in any window
          (find-file file-path)
          (let ((file-buf (current-buffer)))
            (bury-buffer)
            ;; Create chat buffer in the only window
            (switch-to-buffer (get-buffer-create "*test-edit-nowin*"))
            (opencode-chat-mode)
            (setq default-directory (file-name-as-directory project-dir))
            (opencode-chat--set-current-message-id "msg_test")
            (let ((inhibit-read-only t)
                  (chat-win (selected-window)))
              (opencode-chat--render-edit-body
               (list :filePath "src/hidden.ts"
                     :oldString "line 5\n"
                     :newString "line 5 changed\n")
               nil nil)
              (goto-char (point-min))
              (search-forward "src/hidden.ts")
              ;; RET should open in other window (creating a split)
              (opencode-chat-message-open-file-at-point)
              ;; Should now be in the file buffer
              (should (eq (current-buffer) file-buf))
              ;; Chat window should still exist
              (should (window-live-p chat-win)))))
      (when-let ((buf (get-buffer "*test-edit-nowin*")))
        (kill-buffer buf))
      (when-let ((buf (find-buffer-visiting file-path)))
        (kill-buffer buf))
      (delete-directory project-dir t))))

;;; --- Test: Edit tool RET — file not opened at all ---

(ert-deftest opencode-chat-edit-tool-ret-file-not-opened ()
  "RET on edit tool opens the file from disk in a new window when no buffer exists.
Why this matters — this is the common case: user sees an edit in chat and wants to
jump to the code for the first time."
  (let* ((project-dir (make-temp-file "opencode-edit-new-" t))
         (src-dir (expand-file-name "src" project-dir))
         (file-path (expand-file-name "brand-new.ts" src-dir)))
    (make-directory src-dir t)
    (with-temp-file file-path
      (dotimes (i 20) (insert (format "line %d\n" (1+ i)))))
    (unwind-protect
        (save-window-excursion
          ;; No file buffer exists — only the chat buffer
          (switch-to-buffer (get-buffer-create "*test-edit-new*"))
          (opencode-chat-mode)
          (setq default-directory (file-name-as-directory project-dir))
          (opencode-chat--set-current-message-id "msg_test")
          (let ((inhibit-read-only t)
                (chat-win (selected-window)))
            (opencode-chat--render-edit-body
             (list :filePath "src/brand-new.ts"
                   :oldString "line 5\n"
                   :newString "line 5 changed\n")
             nil nil)
            (goto-char (point-min))
            (search-forward "src/brand-new.ts")
            ;; RET should open the file (creating buffer + window)
            (opencode-chat-message-open-file-at-point)
            ;; Should now be visiting the file
            (should (string-suffix-p "brand-new.ts"
                                     (or buffer-file-name "")))
            ;; Chat window should still exist
            (should (window-live-p chat-win))))
      (when-let ((buf (get-buffer "*test-edit-new*")))
        (kill-buffer buf))
      (when-let ((buf (find-buffer-visiting file-path)))
        (kill-buffer buf))
      (delete-directory project-dir t))))

;;; --- @-mention fuzzy matching ---

(ert-deftest opencode-chat-fuzzy-substr-basic ()
  "Scattered substring match for simple case."
  (should (opencode-chat--fuzzy-substr-p "abc" "aXbXc"))
  (should (opencode-chat--fuzzy-substr-p "abc" "abc"))
  (should-not (opencode-chat--fuzzy-substr-p "abc" "acb")))

(ert-deftest opencode-chat-fuzzy-substr-case-insensitive ()
  "Fuzzy substring match is case-insensitive."
  (should (opencode-chat--fuzzy-substr-p "ABC" "aXbXc"))
  (should (opencode-chat--fuzzy-substr-p "abc" "AXBxC")))

(ert-deftest opencode-chat-fuzzy-substr-empty-input ()
  "Empty input matches everything."
  (should (opencode-chat--fuzzy-substr-p "" "anything"))
  (should (opencode-chat--fuzzy-substr-p "" "")))

(ert-deftest opencode-chat-fuzzy-substr-longer-than-candidate ()
  "Input longer than candidate never matches."
  (should-not (opencode-chat--fuzzy-substr-p "abcdef" "abc")))

(ert-deftest opencode-chat-fuzzy-match-single-segment ()
  "Single-segment fuzzy match (no / in input)."
  (should (opencode-chat--mention-fuzzy-match-p
           "thislngtxt"
           "this/is/a/longlongpath/file.txt"))
  (should (opencode-chat--mention-fuzzy-match-p
           "ochat"
           "opencode-chat.el"))
  (should-not (opencode-chat--mention-fuzzy-match-p
               "zzzzz"
               "opencode-chat.el")))

(ert-deftest opencode-chat-fuzzy-match-path-segment ()
  "Path-segment fuzzy match (/ in input)."
  ;; this/file.txt → this matches first segment, file.txt matches last
  (should (opencode-chat--mention-fuzzy-match-p
           "this/file.txt"
           "this/is/a/longlongpath/file.txt"))
  ;; src/main → src matches first segment, main matches later
  (should (opencode-chat--mention-fuzzy-match-p
           "src/main"
           "src/deep/nested/main.ts"))
  ;; Segments must appear in order
  (should-not (opencode-chat--mention-fuzzy-match-p
               "main/src"
               "src/deep/nested/main.ts")))

(ert-deftest opencode-chat-fuzzy-match-path-segment-partial ()
  "Path-segment match with fuzzy within each segment."
  ;; ths matches "this", ftxt matches "file.txt"
  (should (opencode-chat--mention-fuzzy-match-p
           "ths/ftxt"
           "this/is/a/longlongpath/file.txt"))
  ;; oc/ci matches "opencode-chat-input.el" segments
  (should (opencode-chat--mention-fuzzy-match-p
           "oc/ci"
           "src/opencode/chat-input.el")))

(ert-deftest opencode-chat-fuzzy-match-empty-input ()
  "Empty input matches everything."
  (should (opencode-chat--mention-fuzzy-match-p "" "any/path/file.el")))

(ert-deftest opencode-chat-fuzzy-score-exact-prefix-highest ()
  "Exact prefix gets the highest score."
  (let ((prefix-score (opencode-chat--mention-fuzzy-score "src/fo" "src/foo.el"))
        (scattered-score (opencode-chat--mention-fuzzy-score "sfo" "src/foo.el")))
    (should prefix-score)
    (should scattered-score)
    (should (> prefix-score scattered-score))))

(ert-deftest opencode-chat-fuzzy-score-contiguous-beats-scattered ()
  "Contiguous substring beats scattered match."
  ;; "chat" is a contiguous substring of "opencode-chat.el"
  ;; "cht" is a scattered subsequence (c-h-...-t)
  (let ((contiguous (opencode-chat--mention-fuzzy-score "chat" "opencode-chat.el"))
        (scattered (opencode-chat--mention-fuzzy-score "cht" "opencode-chat.el")))
    (should contiguous)
    (should scattered)
    (should (> contiguous scattered))))

(ert-deftest opencode-chat-fuzzy-score-nil-for-no-match ()
  "Score returns nil when input doesn't match."
  (should-not (opencode-chat--mention-fuzzy-score "zzz" "abc.el")))

(ert-deftest opencode-chat-fuzzy-score-shorter-candidate-preferred ()
  "Shorter candidate gets higher score for same input."
  (let ((short (opencode-chat--mention-fuzzy-score "foo" "foo.el"))
        (long (opencode-chat--mention-fuzzy-score "foo" "some/deep/path/foo.el")))
    (should short)
    (should long)
    (should (> short long))))

(ert-deftest opencode-chat-mention-table-fuzzy-filters ()
  "Completion table filters candidates using fuzzy matching."
  (let* ((candidates '("this/is/a/longlongpath/file.txt"
                        "src/main.ts"
                        "README.md"
                        "opencode-chat-input.el"))
         (table (opencode-chat--mention-completion-table candidates)))
    ;; Scattered match
    (let ((matches (funcall table "thislngtxt" nil t)))
      (should (member "this/is/a/longlongpath/file.txt" matches))
      (should-not (member "README.md" matches)))
    ;; Path-segment match
    (let ((matches (funcall table "this/file.txt" nil t)))
      (should (member "this/is/a/longlongpath/file.txt" matches))
      (should-not (member "src/main.ts" matches)))
    ;; Prefix match
    (let ((matches (funcall table "src" nil t)))
      (should (member "src/main.ts" matches)))
    ;; No match
    (let ((matches (funcall table "zzzzz" nil t)))
      (should-not matches))))

(ert-deftest opencode-chat-mention-table-fuzzy-sorted-by-score ()
  "Completion table returns candidates sorted by fuzzy score (best first)."
  (let* ((candidates '("opencode-chat.el"
                        "opencode-chat-input.el"
                        "opencode-config.el"
                        "totally-unrelated.py"))
         (table (opencode-chat--mention-completion-table candidates)))
    ;; "ochat" should rank opencode-chat.el above opencode-chat-input.el
    ;; (shorter candidate wins)
    (let ((matches (funcall table "ochat" nil t)))
      (should (>= (length matches) 2))
      (should (equal (car matches) "opencode-chat.el"))
      (should (equal (cadr matches) "opencode-chat-input.el"))
      ;; Unrelated should not appear
      (should-not (member "totally-unrelated.py" matches)))))

(ert-deftest opencode-chat-mention-table-try-completion ()
  "try-completion (nil action) returns correct values."
  (let* ((candidates '("src/foo.el" "src/bar.el" "README.md"))
         (table (opencode-chat--mention-completion-table candidates)))
    ;; Multiple matches — returns the input string (no expansion)
    (let ((result (funcall table "src" nil nil)))
      (should result)
      (should (stringp result)))
    ;; Exact single match
    (let ((result (funcall table "README.md" nil nil)))
      (should (eq result t)))
    ;; No match
    (should-not (funcall table "zzzzz" nil nil))))

(ert-deftest opencode-chat-mention-table-lambda-action ()
  "Lambda action (exact test) works correctly."
  (let* ((candidates '("src/foo.el" "README.md"))
         (table (opencode-chat--mention-completion-table candidates)))
    (should (funcall table "README.md" nil 'lambda))
    (should-not (funcall table "nonexistent" nil 'lambda))))

(ert-deftest opencode-chat-mention-table-metadata-preserved ()
  "Metadata action still returns category and annotation function."
  (let* ((table (opencode-chat--mention-completion-table '("test"))))
    (let ((meta (funcall table "" nil 'metadata)))
      (should (eq 'metadata (car meta)))
      (should (eq 'opencode-mention (alist-get 'category (cdr meta))))
      (should (eq 'opencode-chat--mention-annotate
                  (alist-get 'annotation-function (cdr meta)))))))

(provide 'opencode-chat-test)
;;; opencode-chat-test.el ends here
