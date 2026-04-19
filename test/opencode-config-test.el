;;; opencode-config-test.el --- Tests for opencode-config.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the config, provider, and command data layer module.

;;; Code:

(require 'ert)
(require 'test-helper nil t)
(require 'opencode-config)

;;; --- Config cache tests ---

(ert-deftest opencode-config-get-returns-cache ()
  "Config get returns cached config plist.
Verifies cache hit path — avoids unnecessary API calls when config data is already present."
  (let ((opencode-api--server-config-cache (opencode-test-fixture "config")))
    (let ((config (opencode-config--get)))
      (should (listp config))
      (should (plist-get config :model))
      (should (string= (plist-get config :default_agent) "build")))))

(ert-deftest opencode-config-invalidate-clears-all ()
  "Invalidate clears all config, provider, and command caches.
Verifies manual invalidation — user can force a fresh fetch when server state changes."
  (let ((opencode-api--server-config-cache (list :model "test"))
        (opencode-api--providers-cache (list :connected ["anthropic"]))
        (opencode-config--commands-cache (vector (list :name "init")))
        (opencode-config--commands-cache-time (float-time)))
    (opencode-config-invalidate)
    (should (null opencode-api--server-config-cache))
    (should (null opencode-api--providers-cache))
    (should (null opencode-config--commands-cache))
    (should (= opencode-config--commands-cache-time 0))))

;;; --- Model format tests ---

(ert-deftest opencode-config-current-model-string-format ()
  "Current model parses string format \"provider/model-id\".
Verifies model format parsing — the server GET /config returns model as \"provider/model\" string."
  (let ((opencode-api--server-config-cache (list :model "anthropic/claude-opus-4-6")))
    (let ((model (opencode-config--current-model)))
      (should (listp model))
      (should (string= (plist-get model :providerID) "anthropic"))
      (should (string= (plist-get model :modelID) "claude-opus-4-6")))))

(ert-deftest opencode-config-current-model-plist-format ()
  "Current model returns plist format as-is.
Verifies plist model format handling — config can also have a plist model from custom agents."
  (let ((opencode-api--server-config-cache
         (list :model (list :providerID "anthropic"
                            :modelID "claude-sonnet-4-20250514"))))
    (let ((model (opencode-config--current-model)))
      (should (listp model))
      (should (string= (plist-get model :providerID) "anthropic"))
      (should (string= (plist-get model :modelID) "claude-sonnet-4-20250514")))))

(ert-deftest opencode-config-current-model-nil ()
  "Current model returns nil when model field is nil.
Verifies defensive nil check — prevents crash if config has no model set."
  (let ((opencode-api--server-config-cache (list :default_agent "build")))
    (should (null (opencode-config--current-model)))))

;;; --- Provider cache tests ---

(ert-deftest opencode-config-providers-returns-cache ()
  "Providers returns cached provider data.
Verifies provider cache hit path — avoids unnecessary API calls for provider info."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((data (opencode-config--providers)))
      (should (listp data))
      (should (plist-get data :all))
      (should (plist-get data :connected)))))

(ert-deftest opencode-config-connected-providers ()
  "Connected providers returns the :connected list.
Verifies provider extraction — used to show which providers are available in the UI."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((connected (opencode-config--connected-providers)))
      (should connected)
      (should (vectorp connected))
      (should (string= (aref connected 0) "anthropic")))))

;;; --- Variant tests ---

(ert-deftest opencode-config-variant-keys-4-key-model ()
  "Variant keys for claude-opus-4-6 returns 4 keys.
Verifies effort-level picker — shows correct options (low/medium/high/max) for opus model."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((keys (opencode-config--variant-keys "anthropic" "claude-opus-4-6")))
      (should (listp keys))
      (should (length= keys 4))
      (should (member "low" keys))
      (should (member "medium" keys))
      (should (member "high" keys))
      (should (member "max" keys)))))

(ert-deftest opencode-config-variant-keys-2-key-model ()
  "Variant keys for claude-sonnet returns 2 keys.
Verifies model-specific variants — different models expose different effort levels (high/max only for sonnet)."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((keys (opencode-config--variant-keys "anthropic" "claude-sonnet-4-20250514")))
      (should (listp keys))
      (should (length= keys 2))
      (should (member "high" keys))
      (should (member "max" keys)))))

(ert-deftest opencode-config-variant-keys-no-variant-model ()
  "Variant keys for haiku returns nil (empty variants).
Verifies graceful handling — models without variants must return nil, not error."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((keys (opencode-config--variant-keys "anthropic" "claude-haiku-4-5")))
      (should (null keys)))))

(ert-deftest opencode-config-model-variants-full-map ()
  "Model variants returns the full variants plist for a model.
Verifies data shape — downstream code reads :effort from each variant plist entry."
  (let ((opencode-api--providers-cache (opencode-test-fixture "providers")))
    (let ((variants (opencode-config--model-variants "anthropic" "claude-opus-4-6")))
      (should variants)
      (should (plist-get variants :low))
      (should (plist-get variants :max))
      (should (string= (plist-get (plist-get variants :high) :effort) "high")))))

;;; --- Command cache tests ---

(ert-deftest opencode-config-commands-returns-cache ()
  "Commands returns cached command vector.
Verifies slash command cache hit — avoids unnecessary API calls for command list."
  (let ((opencode-config--commands-cache (opencode-test-fixture "commands"))
        (opencode-config--commands-cache-time (float-time)))
    (let ((commands (opencode-config--commands)))
      (should (vectorp commands))
      (should (length= commands 3))
      (should (string= (plist-get (aref commands 0) :name) "init")))))

(ert-deftest opencode-config-command-names-extraction ()
  "Command names extracts list of name strings.
Verifies completion candidates extraction — used for /command input completion in minibuffer."
  (let ((opencode-config--commands-cache (opencode-test-fixture "commands"))
        (opencode-config--commands-cache-time (float-time)))
    (let ((names (opencode-config--command-names)))
      (should (listp names))
      (should (length= names 3))
      (should (member "init" names))
      (should (member "compact" names))
      (should (member "bug" names)))))

(ert-deftest opencode-config-execute-command-sends-post ()
  "Execute command sends POST with correct body.
Verifies API contract — command/arguments/agent/model must all be present in request body."
  (let ((captured-path nil)
        (captured-body nil))
    (cl-letf (((symbol-function 'opencode-api-post)
               (lambda (path body _callback)
                 (setq captured-path path
                       captured-body body))))
      (opencode-config-execute-command "ses_test" "init" "arg1" "build"
                                       (list :providerID "anthropic"
                                             :modelID "claude-opus-4-6"))
      (should (string= captured-path "/session/ses_test/command"))
      (should (string= (plist-get captured-body :command) "init"))
      (should (string= (plist-get captured-body :arguments) "arg1"))
      (should (string= (plist-get captured-body :agent) "build"))
      (should (plist-get captured-body :model)))))

;;; --- Current agent accessor ---

(ert-deftest opencode-config-current-agent ()
  "Current agent returns the default_agent from config.
Verifies agent selection — used in prompt_async to determine which agent runs the request."
  (let ((opencode-api--server-config-cache (list :default_agent "plan")))
    (should (string= (opencode-config--current-agent) "plan")))
  (let ((opencode-api--server-config-cache (list :default_agent "build")))
    (should (string= (opencode-config--current-agent) "build"))))

;;; --- Find command tests ---

(ert-deftest opencode-config-find-command-by-name ()
  "Find command returns the correct command plist by name.
Verifies command lookup — retrieves command metadata before execution."
  (let ((opencode-config--commands-cache (opencode-test-fixture "commands"))
        (opencode-config--commands-cache-time (float-time)))
    (let ((cmd (opencode-config--find-command "init")))
      (should cmd)
      (should (listp cmd))
      (should (string= (plist-get cmd :name) "init"))
      (should (string= (plist-get cmd :agent) "build"))
      (should (string= (plist-get cmd :description) "Initialize AGENTS.md")))))

(ert-deftest opencode-config-find-command-missing-returns-nil ()
  "Find command returns nil for a command name that doesn't exist.
Verifies defensive handling — prevents crash on unknown command names."
  (let ((opencode-config--commands-cache (opencode-test-fixture "commands"))
        (opencode-config--commands-cache-time (float-time)))
    (let ((cmd (opencode-config--find-command "nonexistent")))
      (should (null cmd)))))

(provide 'opencode-config-test)
;;; opencode-config-test.el ends here
