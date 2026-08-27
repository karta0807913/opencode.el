;;; opencode-backend.el --- Backend facade for opencode.el -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Compatibility facade.  Generic backend users may require
;; `opencode-backend-core' to avoid loading the OpenCode HTTP API/cache.
;; Requiring `opencode-backend' preserves the historical behavior by also
;; loading and registering the built-in OpenCode adapter.

;;; Code:

(require 'opencode-backend-core)
(require 'opencode-backend-opencode)

(provide 'opencode-backend)
;;; opencode-backend.el ends here
