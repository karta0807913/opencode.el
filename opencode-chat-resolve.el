;;; opencode-chat-resolve.el --- Agent/model default resolution -*- lexical-binding: t; -*-

;; Copyright (C) 2025 opencode.el contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Pure resolution policy for "which agent/model should this chat use?"
;; extracted from opencode-chat-state.el's `--state-init'.
;;
;; The function `opencode-chat--resolve-defaults' implements the 5-step
;; priority cascade:
;;
;;   1. MESSAGES — last assistant message from the API response.
;;   2. Existing state — agent/model set previously (by SSE handlers).
;;   3. Agent's default model — from the agent definition's :model.
;;   4. Config defaults — `opencode-config--current-model'.
;;   5. First available — first connected provider's first model.
;;
;; Agent names are validated against `opencode-api-cache-valid-agent-p'
;; at steps 1 and 2; invalid names fall through.  Model IDs from the
;; agent definition are validated against `opencode-config--model-info'.
;;
;; This module is pure: it reads from existing caches (agent list,
;; provider list, config) but never mutates state.  The caller applies
;; the returned plist via the setters in opencode-chat-state.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'opencode-agent)
(require 'opencode-api-cache)
(require 'opencode-config)

(defun opencode-chat--resolve-defaults (messages existing-agent existing-model-id existing-provider-id)
  "Resolve effective agent/model/provider via the 5-step cascade.

MESSAGES is a vector of message plists (from a /message API response)
or nil.  EXISTING-AGENT / EXISTING-MODEL-ID / EXISTING-PROVIDER-ID are
the values already on the struct (possibly nil) — used as step 2 of
the cascade.

Returns a plist:
  (:agent NAME
   :agent-color HEX-OR-NIL
   :model-id STRING-OR-NIL
   :provider-id STRING-OR-NIL
   :context-limit INT-OR-NIL)

Invariant: `:model-id' and `:provider-id' are either both non-nil or
both nil — if one resolves without the other, neither is returned."
  (let* (;; Step 1: MESSAGES → last assistant message
         (msg-asst-info (when messages
                          (let ((last nil))
                            (seq-doseq (msg messages)
                              (when-let* ((info (plist-get msg :info))
                                          ((equal (plist-get info :role) "assistant")))
                                (setq last info)))
                            last)))
         (msg-agent-raw (plist-get msg-asst-info :agent))
         (msg-agent (and msg-agent-raw
                         (opencode-api-cache-valid-agent-p msg-agent-raw)
                         msg-agent-raw))
         (msg-model-id (plist-get msg-asst-info :modelID))
         (msg-provider-id (plist-get msg-asst-info :providerID))

         ;; Step 2: Existing state (validated)
         (existing-agent-validated
          (and existing-agent
               (opencode-api-cache-valid-agent-p existing-agent)
               existing-agent))

         ;; Resolve agent: messages → existing → default
         (agent (or msg-agent
                    existing-agent-validated
                    (opencode-agent--default-name)))
         (color (when agent
                  (plist-get (opencode-agent--find-by-name agent) :color)))

         ;; Step 3: Agent's default model (only if prior steps gave no model)
         (agent-model-raw (unless (or msg-model-id existing-model-id)
                            (when agent
                              (plist-get (opencode-agent--find-by-name agent) :model))))
         (agent-model (when (and agent-model-raw
                                 (opencode-config--model-info
                                  (plist-get agent-model-raw :providerID)
                                  (plist-get agent-model-raw :modelID)))
                        agent-model-raw))

         ;; Step 4: Config default
         (config-model (opencode-config--current-model))

         ;; Step 5: First available connected model
         (first-model (unless (or msg-model-id existing-model-id
                                  agent-model config-model)
                        (car (opencode-config--all-models))))

         ;; Resolve model/provider with full priority chain
         (model-id (or msg-model-id
                       existing-model-id
                       (plist-get agent-model :modelID)
                       (plist-get config-model :modelID)
                       (plist-get first-model :model-id)))
         (provider-id (or msg-provider-id
                          existing-provider-id
                          (plist-get agent-model :providerID)
                          (plist-get config-model :providerID)
                          (plist-get first-model :provider-id)))
         ;; Enforce pairing: if one resolved without the other, drop both.
         (paired-p (and model-id provider-id))
         (ctx-limit (when paired-p
                      (opencode-config--model-context-limit
                       provider-id model-id)))
         (out-model-id (and paired-p model-id))
         (out-provider-id (and paired-p provider-id)))
    ;; Invariant: model-id and provider-id must be both non-nil or both
    ;; nil — a half-resolved pair would produce API calls missing
    ;; either the model or provider field.
    (cl-assert (eq (and out-model-id t) (and out-provider-id t)) t
               "resolve-defaults must return model-id/provider-id paired")
    (list :agent agent
          :agent-color color
          :model-id out-model-id
          :provider-id out-provider-id
          :context-limit ctx-limit)))

(provide 'opencode-chat-resolve)
;;; opencode-chat-resolve.el ends here
