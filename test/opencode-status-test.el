;;; opencode-status-test.el --- Tests for opencode-status.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the server status popup module.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'opencode-status)

;;; --- Test: Status buffer creation and mode ---

(ert-deftest opencode-status-buffer-mode ()
  "Verify status buffer uses `opencode-status-mode'."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (eq major-mode 'opencode-status-mode))
          (should (derived-mode-p 'special-mode)))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: MCP status rendering ---

(ert-deftest opencode-status-renders-mcp-servers ()
  "Verify MCP servers appear in the status buffer with correct status text."
  (opencode-test-with-mock-api
    (opencode-test-mock-response
     "GET" "/mcp/status" 200
     '(:github-mcp (:status "connected")
       :slack-mcp (:status "failed" :error "timeout")
       :fs-mcp (:status "disabled")))
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (opencode-test-buffer-contains-p "github-mcp"))
          (should (opencode-test-buffer-contains-p "connected"))
          (should (opencode-test-buffer-contains-p "slack-mcp"))
          (should (opencode-test-buffer-contains-p "failed"))
          (should (opencode-test-buffer-contains-p "timeout"))
          (should (opencode-test-buffer-contains-p "fs-mcp"))
          (should (opencode-test-buffer-contains-p "disabled")))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: LSP status rendering ---

(ert-deftest opencode-status-renders-lsp-servers ()
  "Verify LSP servers appear in the status buffer."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response
     "GET" "/lsp/status" 200
     (vector (list :id "tsserver" :name "typescript-ls"
                   :root "/tmp/project" :status "connected")))
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (opencode-test-buffer-contains-p "typescript-ls"))
          (should (opencode-test-buffer-contains-p "connected"))
          (should (opencode-test-buffer-contains-p "/tmp/project")))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: Formatter status rendering ---

(ert-deftest opencode-status-renders-formatters ()
  "Verify formatters appear in the status buffer."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response
     "GET" "/formatter/status" 200
     (vector (list :name "prettier" :extensions [".ts" ".tsx"] :enabled t)
             (list :name "gofmt" :extensions [".go"] :enabled :json-false)))
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (opencode-test-buffer-contains-p "prettier"))
          (should (opencode-test-buffer-contains-p "enabled"))
          (should (opencode-test-buffer-contains-p ".ts"))
          (should (opencode-test-buffer-contains-p "gofmt"))
          (should (opencode-test-buffer-contains-p "disabled")))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: Empty status ---

(ert-deftest opencode-status-empty-state ()
  "Verify empty state shows (none) for each section."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (opencode-test-buffer-contains-p "MCP Servers"))
          (should (opencode-test-buffer-contains-p "LSP Servers"))
          (should (opencode-test-buffer-contains-p "Formatters"))
          ;; At least one "(none)" should appear
          (should (opencode-test-buffer-contains-p "(none)")))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: Keymap bindings ---

(ert-deftest opencode-status-keymap-bindings ()
  "Verify all expected keybindings are active."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (should (eq (key-binding (kbd "n")) 'opencode-status--next))
          (should (eq (key-binding (kbd "p")) 'opencode-status--prev))
          (should (eq (key-binding (kbd "SPC")) 'opencode-status--toggle))
          (should (eq (key-binding (kbd "g")) 'opencode-status--refresh))
          (should (eq (key-binding (kbd "q")) 'opencode-status--quit)))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: Navigation ---

(ert-deftest opencode-status-navigation ()
  "Verify n/p navigation moves between entries."
  (opencode-test-with-mock-api
    (opencode-test-mock-response
     "GET" "/mcp/status" 200
     '(:server-a (:status "connected") :server-b (:status "disabled")))
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          ;; Should start on first entry
          (should (get-text-property (point) 'opencode-status-name))
          (let ((first-name (get-text-property (point) 'opencode-status-name)))
            ;; Move to next
            (opencode-status--next)
            (should (get-text-property (point) 'opencode-status-name))
            (should (not (equal first-name
                                (get-text-property (point) 'opencode-status-name))))
            ;; Move back
            (opencode-status--prev)
            (should (equal first-name
                           (get-text-property (point) 'opencode-status-name)))))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: MCP toggle disconnect ---

(ert-deftest opencode-status-toggle-mcp-disconnect ()
  "Verify SPC on a connected MCP server calls /mcp/disconnect."
  (opencode-test-with-mock-api
    (opencode-test-mock-response
     "GET" "/mcp/status" 200
     '(:github-mcp (:status "connected")))
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-test-mock-response "POST" "/mcp/disconnect" 200 '())
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          ;; Navigate to github-mcp entry
          (goto-char (point-min))
          (search-forward "github-mcp")
          (beginning-of-line)
          ;; Toggle
          (opencode-status--toggle)
          ;; Verify disconnect was called
          (let ((found nil))
            (dolist (req opencode-test--mock-requests)
              (when (and (equal (nth 0 req) "POST")
                         (string-match-p "disconnect" (nth 1 req)))
                (setq found t)))
            (should found)))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: MCP toggle connect ---

(ert-deftest opencode-status-toggle-mcp-connect ()
  "Verify SPC on a disabled MCP server calls /mcp/connect."
  (opencode-test-with-mock-api
    (opencode-test-mock-response
     "GET" "/mcp/status" 200
     '(:slack-mcp (:status "disabled")))
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-test-mock-response "POST" "/mcp/connect" 200 '())
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (goto-char (point-min))
          (search-forward "slack-mcp")
          (beginning-of-line)
          (opencode-status--toggle)
          (let ((found nil))
            (dolist (req opencode-test--mock-requests)
              (when (and (equal (nth 0 req) "POST")
                         (string-match-p "connect" (nth 1 req))
                         (not (string-match-p "disconnect" (nth 1 req))))
                (setq found t)))
            (should found)))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

;;; --- Test: Quit closes buffer ---

(ert-deftest opencode-status-quit-kills-buffer ()
  "Verify q closes the status buffer."
  (opencode-test-with-mock-api
    (opencode-test-mock-response "GET" "/mcp/status" 200 '())
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (should (get-buffer "*opencode: status*"))
    (with-current-buffer "*opencode: status*"
      (opencode-status--quit))
    (should-not (get-buffer "*opencode: status*"))))

;;; --- Test: Text properties on entries ---

(ert-deftest opencode-status-text-properties ()
  "Verify entries have correct text properties for navigation and toggle."
  (opencode-test-with-mock-api
    (opencode-test-mock-response
     "GET" "/mcp/status" 200
     '(:my-server (:status "connected")))
    (opencode-test-mock-response "GET" "/lsp/status" 200 [])
    (opencode-test-mock-response "GET" "/formatter/status" 200 [])
    (opencode-server-status)
    (unwind-protect
        (with-current-buffer "*opencode: status*"
          (goto-char (point-min))
          (search-forward "my-server")
          (should (equal (get-text-property (match-beginning 0) 'opencode-status-type) 'mcp))
          (should (equal (get-text-property (match-beginning 0) 'opencode-status-name) "my-server")))
      (when-let ((buf (get-buffer "*opencode: status*")))
        (kill-buffer buf)))))

(provide 'opencode-status-test)
;;; opencode-status-test.el ends here
