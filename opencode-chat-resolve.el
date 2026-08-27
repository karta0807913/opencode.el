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
;; Agent names are validated against the backend agent cache at steps
;; 1 and 2; invalid names fall through.  Model IDs from the
;; agent definition are validated against `opencode-config--model-info'.
;;
;; This module is pure: it reads from existing caches (agent list,
;; provider list, config) but never mutates state.  The caller applies
;; the returned plist via the setters in opencode-chat-state.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'opencode-agent)
(require 'opencode-config)

(defun opencode-chat-resolve--agent (name backend)
  "Return agent NAME from BACKEND metadata, preserving nil-backend arity."
  (if backend
      (opencode-agent--find-by-name name backend)
    (opencode-agent--find-by-name name)))

(defun opencode-chat-resolve--valid-agent-p (name backend)
  "Return non-nil when agent NAME is valid for BACKEND."
  (if backend
      (opencode-agent-valid-p name backend)
    (opencode-agent-valid-p name)))

(defun opencode-chat-resolve--default-agent (backend)
  "Return BACKEND's default agent, preserving nil-backend arity."
  (if backend
      (opencode-agent--default-name backend)
    (opencode-agent--default-name)))

(defun opencode-chat-resolve--model-info (provider-id model-id backend)
  "Return model metadata for PROVIDER-ID and MODEL-ID from BACKEND."
  (if backend
      (opencode-config--model-info provider-id model-id backend)
    (opencode-config--model-info provider-id model-id)))

(defun opencode-chat-resolve--current-model (backend)
  "Return BACKEND's configured model, preserving nil-backend arity."
  (if backend
      (opencode-config--current-model backend)
    (opencode-config--current-model)))

(defun opencode-chat-resolve--all-models (backend)
  "Return BACKEND's models, preserving nil-backend arity."
  (if backend
      (opencode-config--all-models backend)
    (opencode-config--all-models)))

(defun opencode-chat-resolve--context-limit (provider-id model-id backend)
  "Return model context limit from BACKEND metadata."
  (if backend
      (opencode-config--model-context-limit provider-id model-id backend)
    (opencode-config--model-context-limit provider-id model-id)))

(defun opencode-chat--resolve-defaults
    (messages existing-agent existing-model-id existing-provider-id
              &optional existing-variant backend)
  "Resolve effective agent/model/provider via the 5-step cascade.

MESSAGES is a vector of message plists (from a /message API response)
or nil.  EXISTING-AGENT / EXISTING-MODEL-ID / EXISTING-PROVIDER-ID are
the values already on the struct (possibly nil) — used as step 2 of
the cascade.  EXISTING-VARIANT is the current model variant, when any.

Returns a plist:
  (:agent NAME
    :agent-color HEX-OR-NIL
    :model-id STRING-OR-NIL
    :provider-id STRING-OR-NIL
    :variant STRING-OR-NIL
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
                          (opencode-chat-resolve--valid-agent-p
                           msg-agent-raw backend)
                          msg-agent-raw))
         (msg-model-id (plist-get msg-asst-info :modelID))
         (msg-provider-id (plist-get msg-asst-info :providerID))
         (msg-variant (plist-get msg-asst-info :variant))

         ;; Step 2: Existing state (validated)
         (existing-agent-validated
          (and existing-agent
               (opencode-chat-resolve--valid-agent-p existing-agent backend)
               existing-agent))

         ;; Resolve agent: messages → existing → default
         (agent (or msg-agent
                    existing-agent-validated
                     (opencode-chat-resolve--default-agent backend)))
         (color (when agent
                   (plist-get
                    (opencode-chat-resolve--agent agent backend) :color)))

         ;; Step 3: Agent's default model (only if prior steps gave no model)
         (agent-model-raw (unless (or msg-model-id existing-model-id)
                            (when agent
                               (plist-get
                                (opencode-chat-resolve--agent agent backend)
                                :model))))
         (agent-model (when (and agent-model-raw
                                  (opencode-chat-resolve--model-info
                                   (plist-get agent-model-raw :providerID)
                                   (plist-get agent-model-raw :modelID)
                                   backend))
                         agent-model-raw))
         (agent-variant
          (when agent
             (plist-get
              (opencode-chat-resolve--agent agent backend) :variant)))

         ;; Step 4: Config default
         (config-model (opencode-chat-resolve--current-model backend))

         ;; Step 5: First available connected model
         (first-model (unless (or msg-model-id existing-model-id
                                  agent-model config-model)
                        (car (opencode-chat-resolve--all-models backend))))

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
                       (opencode-chat-resolve--context-limit
                        provider-id model-id backend)))
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
          :variant (or msg-variant existing-variant agent-variant)
          :context-limit ctx-limit)))

(provide 'opencode-chat-resolve)
;;; opencode-chat-resolve.el ends here
