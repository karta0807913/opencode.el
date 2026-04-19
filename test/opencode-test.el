;;; opencode-test.el --- Tests for opencode.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the entry point module: minor mode, keymap,
;; commands, modeline, start/stop flow.

;;; Code:

(require 'test-helper nil t)
(require 'opencode)

;;; --- Version ---

(ert-deftest opencode-version-defined ()
  "Verify `opencode-version` is a valid semver string.
Package version metadata — needed by package managers and user-facing version displays."
  (should (stringp opencode-version))
  (should (string-match-p "^[0-9]+\\.[0-9]+\\.[0-9]+$" opencode-version)))

;;; --- Customization group ---

(ert-deftest opencode-group-exists ()
  "Verify the `opencode` customization group is registered.
`M-x customize-group opencode` must work — all defcustom variables live under this group."
  (should (get 'opencode 'custom-group)))

;;; --- Minor mode ---

(ert-deftest opencode-mode-defined ()
  "Verify `opencode-mode` is defined and callable.
The global minor mode must be a callable command for `M-x opencode-mode` to work."
  (should (fboundp 'opencode-mode)))

(ert-deftest opencode-mode-enables ()
  "Verify `opencode-mode` can be enabled and disabled.
Basic minor mode lifecycle — enable sets variable, disable clears it."
  (unwind-protect
      (progn
        (opencode-mode 1)
        (should opencode-mode)
        (opencode-mode -1)
        (should-not opencode-mode))
    (opencode-mode -1)))

(ert-deftest opencode-mode-updates-modeline ()
  "Verify enabling `opencode-mode` sets a modeline string containing \"OC:\".
Modeline indicator — users see connection status in their modeline."
  (unwind-protect
      (progn
        (opencode-mode 1)
        (should (stringp opencode--modeline-string))
        (should (string-search "OC:" opencode--modeline-string)))
    (opencode-mode -1)))

(ert-deftest opencode-mode-modeline-off ()
  "Verify modeline shows \"off\" when server status is nil.
Correct status display when disconnected — users know the server is not running."
  (let ((opencode-server--status nil))
    (opencode--modeline-update)
    (should (string-search "off" opencode--modeline-string))))

(ert-deftest opencode-mode-modeline-connected ()
  "Verify modeline shows \"connected\" when server is connected.
Correct status display when connected — users see confirmation of active connection."
  (let ((opencode-server--status 'connected)
        (opencode-server--port 12345))
    (opencode--modeline-update)
    (should (string-search "connected" opencode--modeline-string))))

(ert-deftest opencode-mode-modeline-starting ()
  "Verify modeline shows \"starting\" when server is starting.
Correct status display during startup — users see feedback during the boot process."
  (let ((opencode-server--status 'starting))
    (opencode--modeline-update)
    (should (string-search "starting" opencode--modeline-string))))

;;; --- Command map ---

(ert-deftest opencode-command-map-is-keymap ()
  "Verify `opencode-command-map` is a valid keymap object.
Prefix key dispatch — `C-c o` (or similar) must be a keymap for subcommands."
  (should (keymapp opencode-command-map)))

(ert-deftest opencode-command-map-bindings ()
  "Verify all expected keys (o, c, l, n, a, t, q, r) are bound to commands.
Keybinding completeness — no dead keys in the command map."
  (should (commandp (keymap-lookup opencode-command-map "o")))
  (should (commandp (keymap-lookup opencode-command-map "c")))
  (should (commandp (keymap-lookup opencode-command-map "l")))
  (should (commandp (keymap-lookup opencode-command-map "n")))
  (should (commandp (keymap-lookup opencode-command-map "a")))
  (should (commandp (keymap-lookup opencode-command-map "t")))
  (should (commandp (keymap-lookup opencode-command-map "q")))
  (should (commandp (keymap-lookup opencode-command-map "r"))))

(ert-deftest opencode-command-map-correct-commands ()
  "Verify each key binds to the correct function (e.g., \"o\" → `opencode-start`, \"r\" → `opencode-refresh`).
Keybinding correctness — keys must invoke the right command."
  (should (eq (keymap-lookup opencode-command-map "o") #'opencode-start))
  (should (eq (keymap-lookup opencode-command-map "c") #'opencode-chat))
  (should (eq (keymap-lookup opencode-command-map "l") #'opencode-list-sessions))
  (should (eq (keymap-lookup opencode-command-map "n") #'opencode-new-session))
  (should (eq (keymap-lookup opencode-command-map "a") #'opencode-abort))
  (should (eq (keymap-lookup opencode-command-map "t") #'opencode-toggle-sidebar))
  (should (eq (keymap-lookup opencode-command-map "q") #'opencode-disconnect))
  (should (eq (keymap-lookup opencode-command-map "r") #'opencode-refresh)))

;;; --- Interactive commands ---

(ert-deftest opencode-commands-interactive ()
  "Verify all user-facing commands are interactive.
`M-x` discoverability — all commands must be interactive for `M-x` completion."
  (should (commandp 'opencode-start))
  (should (commandp 'opencode-chat))
  (should (commandp 'opencode-list-sessions))
  (should (commandp 'opencode-new-session))
  (should (commandp 'opencode-abort))
  (should (commandp 'opencode-toggle-sidebar))
  (should (commandp 'opencode-disconnect))
  (should (commandp 'opencode-cleanup))
  (should (commandp 'opencode-refresh)))

;;; --- Current chat buffer ---

(ert-deftest opencode-current-chat-buffer-nil ()
  "Verify `opencode--current-chat-buffer` returns nil when no chat buffers exist.
Safe fallback when no chat is open — prevents errors in abort/navigation commands."
  (opencode-test-cleanup)
  (should (null (opencode--current-chat-buffer))))

(ert-deftest opencode-current-chat-buffer-finds-chat ()
  "Verify `opencode--current-chat-buffer` returns the chat buffer when one exists.
Chat buffer lookup — used by abort, send, focus commands to find the active chat."
  (opencode-test-with-temp-buffer "*opencode: test/chat*"
    (opencode-chat-mode)
    (should (buffer-live-p (opencode--current-chat-buffer)))))

;;; --- Read session ---

(ert-deftest opencode-read-session-propagates-error ()
  "Verify `opencode--read-session` propagates connection errors instead of swallowing them.
Error visibility — users see \"connection refused\", not silent failure."
  (cl-letf (((symbol-function 'opencode-session--list)
             (lambda (&optional _) (error "Connection refused"))))
    (should-error (opencode--read-session "Test: ") :type 'error)))

(ert-deftest opencode-read-session-includes-new-option ()
  "Verify session picker always includes a \"new session\" option.
UX — users can always create a new session from the picker even when no sessions exist."
  (cl-letf (((symbol-function 'opencode-session--list)
             (lambda (&optional _) nil))
            ((symbol-function 'completing-read)
             (lambda (_prompt candidates &rest _)
               (caar candidates))))
    (should (eq (opencode--read-session "Test: ") 'new))))

;;; --- Abort without chat ---

(ert-deftest opencode-abort-no-chat-buffer ()
  "Verify `opencode-abort` messages gracefully when no chat buffer exists.
Graceful degradation — no error thrown, user gets informative message."
  (opencode-test-cleanup)
  (let ((msg nil))
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
      (opencode-abort)
      (should (string-search "No active chat" msg)))))

;;; --- Disconnect ---

(ert-deftest opencode-disconnect-calls-stop ()
  "Verify `opencode-disconnect` stops both SSE and server.
Clean shutdown — both subsystems are torn down when disconnecting."
  (let ((sse-stopped nil)
        (server-stopped nil))
    (cl-letf (((symbol-function 'opencode-sse--disconnect) (lambda () (setq sse-stopped t)))
              ((symbol-function 'opencode-server--stop) (lambda () (setq server-stopped t)))
              ((symbol-function 'message) #'ignore))
      (opencode-disconnect)
      (should sse-stopped)
      (should server-stopped))))

;;; --- Cleanup ---

(ert-deftest opencode-cleanup-kills-buffers ()
  "Verify `opencode-cleanup` kills all `*opencode:*` buffers.
Resource cleanup — no stale buffers after disconnect polluting the buffer list."
  (let ((buf (get-buffer-create "*opencode: test-cleanup*")))
    (unwind-protect
        (cl-letf (((symbol-function 'opencode-sse--disconnect) #'ignore)
                  ((symbol-function 'opencode-server--stop) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (opencode-cleanup)
          (should-not (buffer-live-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; --- SSE auto-connect on server connected ---

(ert-deftest opencode-on-connected-starts-sse ()
  "Verify SSE connect is called when server connects.
Auto-SSE — streaming starts automatically on server connection for real-time updates."
  (let ((sse-connected nil))
    (cl-letf (((symbol-function 'opencode-sse-connect)
               (lambda () (setq sse-connected t)))
              ((symbol-function 'opencode--modeline-update) #'ignore)
              ((symbol-function 'opencode-config-prewarm) #'ignore)
              ((symbol-function 'opencode-api--fetch-agent-info) #'ignore))
      (let ((opencode-server--port 4096))
        (opencode--on-connected)
        (should sse-connected)))))

(ert-deftest opencode-on-connected-starts-sse-connect-mode ()
  "Verify SSE connect fires via `opencode-server-connected-hook` in connect mode.
Connect-mode support — users connecting to an existing server still get SSE streaming."
  (let ((sse-connected nil))
    (cl-letf (((symbol-function 'opencode-sse-connect)
               (lambda () (setq sse-connected t)))
              ((symbol-function 'opencode--modeline-update) #'ignore)
              ((symbol-function 'opencode-config-prewarm) #'ignore)
              ((symbol-function 'opencode-api--fetch-agent-info) #'ignore))
      ;; opencode-mode adds opencode--on-connected to the hook
      (unwind-protect
          (progn
            (opencode-mode 1)
            (let ((opencode-server--port 4096))
              (run-hooks 'opencode-server-connected-hook)
              (should sse-connected)))
        (opencode-mode -1)))))

;;; --- ensure-directory ---

(ert-deftest opencode-ensure-directory-sets-when-nil ()
  "Verify `opencode--ensure-directory` sets `opencode-default-directory` when nil.
Fallback directory resolution — API headers get a valid directory even without a project.
The directory is normalized (no trailing slash) for consistent API query params."
  (let ((opencode-default-directory nil)
        (default-directory "/tmp/fallback/"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (opencode--ensure-directory)
      (should (string= opencode-default-directory "/tmp/fallback")))))

(ert-deftest opencode-ensure-directory-uses-project-root ()
  "Verify `opencode--ensure-directory` prefers project root over `default-directory`.
Correct project detection — API `X-OpenCode-Directory` header uses the right directory.
The directory is normalized (no trailing slash) for consistent API query params."
  (let ((opencode-default-directory nil)
        (default-directory "/Users/bytedance/"))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) '(vc Git "/home/user/my-project/")))
              ((symbol-function 'project-root)
               (lambda (_proj) "/home/user/my-project/")))
      (opencode--ensure-directory)
      (should (string= opencode-default-directory "/home/user/my-project")))))

(ert-deftest opencode-ensure-directory-noop-when-set ()
  "Verify `opencode--ensure-directory` does not overwrite an already-set directory.
Stability — once set, the directory persists and won't be unexpectedly changed."
  (let ((opencode-default-directory "/home/user/existing-project/"))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) '(vc Git "/home/user/other/")))
              ((symbol-function 'project-root)
               (lambda (_proj) "/home/user/other/")))
      (opencode--ensure-directory)
      (should (string= opencode-default-directory "/home/user/existing-project/")))))

(ert-deftest opencode-chat-calls-ensure-directory ()
  "Verify `opencode-chat` resolves project directory before prompting.
Pre-prompt directory resolution — API calls during chat use the correct project directory."
  (let ((opencode-default-directory nil)
        (default-directory "/home/user/my-project/")
        (ensure-called nil))
    (cl-letf (((symbol-function 'opencode-server-ensure) #'ignore)
              ((symbol-function 'opencode--ensure-directory)
               (lambda () (setq ensure-called t)))
              ((symbol-function 'opencode--read-session)
               (lambda (_prompt) nil)))
      (unwind-protect
          (progn
            (opencode-mode 1)
            (opencode-chat)
            (should ensure-called))
        (opencode-mode -1)))))

(ert-deftest opencode-new-session-calls-ensure-directory ()
  "Verify `opencode-new-session` resolves project directory before creating.
Pre-create directory resolution — new sessions are correctly associated with the project."
  (let ((opencode-default-directory nil)
        (default-directory "/home/user/my-project/")
        (ensure-called nil))
    (cl-letf (((symbol-function 'opencode-server-ensure) #'ignore)
              ((symbol-function 'opencode--ensure-directory)
               (lambda () (setq ensure-called t)))
              ((symbol-function 'opencode-session-create)
               (lambda (&optional _title)
                 (list :id "ses_test" :title "test")))
              ((symbol-function 'opencode-chat-open) #'ignore))
      (unwind-protect
          (progn
            (opencode-mode 1)
            (opencode-new-session "test")
            (should ensure-called))
        (opencode-mode -1)))))

(ert-deftest opencode-chat-ensure-directory-sets-for-api ()
  "Verify `opencode-chat` sets directory that API headers use (full integration).
End-to-end: directory flows from project root → API `X-OpenCode-Directory` header.
The directory is normalized (no trailing slash) for consistent API query params."
  (let ((opencode-default-directory nil)
        (default-directory "/home/user/my-project/"))
    (cl-letf (((symbol-function 'opencode-server-ensure) #'ignore)
              ((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'opencode--read-session)
               (lambda (_prompt) nil)))
      (unwind-protect
          (progn
            (opencode-mode 1)
            (opencode-chat)
            ;; After opencode-chat, the directory should be set (normalized, no trailing slash)
            (should (string= opencode-default-directory "/home/user/my-project"))
            ;; And API headers should use it
            (let ((headers (opencode-api--build-headers)))
              (should (string= (cdr (assoc "X-OpenCode-Directory" headers))
                               "/home/user/my-project"))))
        (opencode-mode -1)
        (setq opencode-default-directory nil)))))

;;; --- Buffer registry tests ---

(ert-deftest opencode-registry-sidebar-register-and-lookup ()
  "Registered sidebar buffer is returned by project-dir lookup.
Without this, the O(1) sidebar dispatch path cannot find the
correct buffer for incoming SSE events."
  (require 'opencode)
  (let ((dir (expand-file-name "test-sidebar-reg"
                               temporary-file-directory)))
    (unwind-protect
        (opencode-test-with-temp-buffer "*opencode: sidebar-reg-lookup*"
          (opencode--register-sidebar-buffer dir (current-buffer))
          (should (eq (current-buffer)
                      (opencode--sidebar-buffer-for-project dir))))
      (opencode--deregister-sidebar-buffer dir))))

(ert-deftest opencode-registry-sidebar-deregister-clears ()
  "Deregistered project-dir returns nil on lookup.
Without deregister, killed sidebar buffers would leave stale
entries that point to dead buffers."
  (require 'opencode)
  (let ((dir (expand-file-name "test-sidebar-dereg"
                               temporary-file-directory)))
    (unwind-protect
        (opencode-test-with-temp-buffer "*opencode: sidebar-dereg*"
          (opencode--register-sidebar-buffer dir (current-buffer))
          (opencode--deregister-sidebar-buffer dir)
          (should-not (opencode--sidebar-buffer-for-project dir)))
      (opencode--deregister-sidebar-buffer dir))))

(ert-deftest opencode-registry-sidebar-dead-buffer-auto-deregisters ()
  "Lookup auto-deregisters killed sidebar buffer and returns nil."
  (require 'opencode)
  (let ((buf (get-buffer-create "*opencode: sidebar-dead*"))
        (orig opencode--sidebar-buffer))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (opencode--register-sidebar-buffer))
          (kill-buffer buf)
          (should-not (opencode--sidebar-buffer-for-project)))
      (setq opencode--sidebar-buffer orig)
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-sidebar-nil-dir-skipped ()
  "Global sidebar register/deregister works without project-dir."
  (require 'opencode)
  (let ((orig opencode--sidebar-buffer))
    (unwind-protect
        (opencode-test-with-temp-buffer "*opencode: sidebar-nil*"
          (opencode--register-sidebar-buffer)
          (should (eq (current-buffer) opencode--sidebar-buffer))
          (opencode--deregister-sidebar-buffer)
          (should-not opencode--sidebar-buffer))
      (setq opencode--sidebar-buffer orig))))

(ert-deftest opencode-registry-all-sidebar-buffers ()
  "all-sidebar-buffers returns the single global sidebar if live."
  (require 'opencode)
  (let ((orig opencode--sidebar-buffer)
        (buf (get-buffer-create "*opencode: sidebar-all*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (opencode--register-sidebar-buffer))
          (let ((all (opencode--all-sidebar-buffers)))
            (should (= 1 (length all)))
            (should (eq buf (car all)))))
      (setq opencode--sidebar-buffer orig)
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-dispatch-to-all-chat-calls-all ()
  "dispatch-to-all-chat-buffers invokes handler in every registered buffer.
Without this, broadcast events would skip some chat buffers."
  (require 'opencode)
  (let ((buf-a (get-buffer-create "*opencode: all-chat-a*"))
        (buf-b (get-buffer-create "*opencode: all-chat-b*"))
        (called-in nil))
    (unwind-protect
        (progn
          (with-current-buffer buf-a (opencode-chat-mode))
          (with-current-buffer buf-b (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_all_a" buf-a)
          (opencode--register-chat-buffer "ses_all_b" buf-b)
          (opencode--dispatch-to-all-chat-buffers
           (lambda (_event) (push (current-buffer) called-in))
           '(:test t))
          (should (memq buf-a called-in))
          (should (memq buf-b called-in)))
      (opencode--deregister-chat-buffer "ses_all_a")
      (opencode--deregister-chat-buffer "ses_all_b")
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(ert-deftest opencode-registry-dispatch-to-all-sidebar-calls-all ()
  "dispatch-to-all-sidebar-buffers invokes handler in the global sidebar."
  (require 'opencode)
  (let ((orig opencode--sidebar-buffer)
        (buf (get-buffer-create "*opencode: all-sb*"))
        (called-in nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (opencode--register-sidebar-buffer))
          (opencode--dispatch-to-all-sidebar-buffers
           (lambda (_event) (push (current-buffer) called-in))
           '(:test t))
          (should (memq buf called-in)))
      (setq opencode--sidebar-buffer orig)
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-dispatch-handler-error-doesnt-crash ()
  "Handler error in dispatch does not propagate to caller.
Without condition-case, a single misbehaving handler would crash
the entire SSE dispatch pipeline and drop all subsequent events."
  (require 'opencode)
  (let ((buf (get-buffer-create "*opencode: dispatch-err*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_err" buf)
          ;; Handler that signals an error
          (should-not
           (condition-case nil
               (progn
                 (opencode--dispatch-to-chat-buffer
                  "ses_err"
                  (lambda (_event) (error "Boom"))
                  '(:test t))
                 nil) ; no error propagated = success
             (error t)))) ; if error propagated, test fails
      (opencode--deregister-chat-buffer "ses_err")
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-dispatch-sidebar-handler-error-doesnt-crash ()
  "Handler error in sidebar dispatch does not propagate to caller."
  (require 'opencode)
  (let ((orig opencode--sidebar-buffer)
        (buf (get-buffer-create "*opencode: sb-dispatch-err*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local opencode-sidebar--status-store (make-hash-table :test 'equal))
            (setq-local opencode-sidebar--known-project-dirs nil)
            (setq-local opencode-sidebar--refresh-timer nil)
            (opencode--register-sidebar-buffer))
          ;; Stub the handler to error
          (cl-letf (((symbol-function 'opencode-sidebar--on-session-event)
                     (lambda (_event) (error "Sidebar boom"))))
            (should-not
             (condition-case nil
                 (progn
                   (opencode-event--dispatch-sidebar
                    #'opencode-sidebar--on-session-event
                    '(:type "session.idle" :directory "/proj"))
                   nil)
               (error t)))))
      (setq opencode--sidebar-buffer orig)
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-cleanup-clears-both ()
  "opencode-cleanup clears chat registry and sidebar buffer.
Without cleanup, stale entries from a previous server session
would persist and cause mis-dispatch on reconnect."
  (require 'opencode)
  (let ((buf-c (get-buffer-create "*opencode: cleanup-chat*"))
        (buf-s (get-buffer-create "*opencode: cleanup-sidebar*"))
        ;; Save original state
        (orig-chat (copy-hash-table opencode--chat-registry))
        (orig-sidebar opencode--sidebar-buffer))
    (unwind-protect
        (progn
          (with-current-buffer buf-c (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_cleanup" buf-c)
          (with-current-buffer buf-s
            (opencode--register-sidebar-buffer))
          ;; Both should be populated
          (should (opencode--chat-buffer-for-session "ses_cleanup"))
          (should (opencode--sidebar-buffer-for-project))
          ;; Cleanup (stub server-stop to avoid side effects)
          (cl-letf (((symbol-function 'opencode-server-stop) #'ignore)
                    ((symbol-function 'opencode-sse-disconnect) #'ignore))
            (opencode-cleanup))
          ;; Both should be empty
          (should-not (opencode--chat-buffer-for-session "ses_cleanup"))
          (should-not (opencode--sidebar-buffer-for-project)))
      ;; Restore original state
      (setq opencode--chat-registry orig-chat)
      (setq opencode--sidebar-buffer orig-sidebar)
      (when (buffer-live-p buf-c) (kill-buffer buf-c))
      (when (buffer-live-p buf-s) (kill-buffer buf-s)))))

(ert-deftest opencode-registry-dispatch-to-dead-buffer-noop ()
  "Dispatch to a killed buffer is a no-op and auto-deregisters.
Without auto-deregister on dispatch, stale entries would
cause repeated failed dispatch attempts."
  (require 'opencode)
  (let ((buf (get-buffer-create "*opencode: dead-dispatch*"))
        (called nil))
    (unwind-protect
        (progn
          (with-current-buffer buf (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_dead_d" buf)
          (kill-buffer buf)
          ;; Dispatch should be silent no-op
          (opencode--dispatch-to-chat-buffer
           "ses_dead_d"
           (lambda (_event) (setq called t))
           '(:test t))
          (should-not called)
          ;; Entry should be auto-cleaned
          (should-not (opencode--chat-buffer-for-session "ses_dead_d")))
      (opencode--deregister-chat-buffer "ses_dead_d")
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest opencode-registry-chat-re-register-overwrites ()
  "Re-registering a session-id overwrites the old buffer.
Without overwrite, opening a new chat buffer for the same session
would dispatch to the stale old buffer."
  (require 'opencode)
  (let ((buf-old (get-buffer-create "*opencode: re-reg-old*"))
        (buf-new (get-buffer-create "*opencode: re-reg-new*")))
    (unwind-protect
        (progn
          (with-current-buffer buf-old (opencode-chat-mode))
          (with-current-buffer buf-new (opencode-chat-mode))
          (opencode--register-chat-buffer "ses_rereg" buf-old)
          (opencode--register-chat-buffer "ses_rereg" buf-new)
          (should (eq buf-new (opencode--chat-buffer-for-session "ses_rereg"))))
      (opencode--deregister-chat-buffer "ses_rereg")
      (when (buffer-live-p buf-old) (kill-buffer buf-old))
      (when (buffer-live-p buf-new) (kill-buffer buf-new)))))

;;; --- Provide ---

(ert-deftest opencode-provides-feature ()
  "Verify the `opencode` feature is provided.
`(require 'opencode)` must succeed -- package loading depends on this."
  (should (featurep 'opencode)))

(provide 'opencode-test)
;;; opencode-test.el ends here
