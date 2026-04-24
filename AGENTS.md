# AGENTS.md — opencode.el

Emacs 30 frontend for the OpenCode AI coding agent.
Talks to the OpenCode HTTP REST API (`http://127.0.0.1:<port>`) and SSE event stream.

## Built-in Commands

These client-side commands are available via `C-p` (opencode-command-select) in the chat buffer:

| Command | Description | API Call |
|---|---|---|
| `/compact` | Summarize session history to save tokens | `POST /session/:id/summarize` |
| `/rename` | Rename the current session | `PATCH /session/:id` (body: `{title}`) |
| `/fork` | Fork the session to a new history | `POST /session/:id/fork` |
| `/share` | Generate a shareable URL | `POST /session/:id/share` |
| `/unshare` | Revoke the shareable URL | `POST /session/:id/unshare` |
| `/undo` | Revert to the previous user message | `POST /session/:id/revert` |
| `/redo` | Restore the reverted message | `POST /session/:id/unrevert` |

## Build & Test

```bash
make test              # Run all 711 ERT tests
make compile           # Byte-compile all .el files (MUST be warning-free)
make lint              # Run checkdoc on all source files
make clean             # Remove *.elc

# Run one test file:
make TEST=test/opencode-chat-test.el test

# Run a single test by name:
emacs -Q -batch -L . -L test -l test/test-helper.el \
  -l test/opencode-chat-test.el \
  -eval '(ert-run-tests-batch-and-exit "opencode-chat-on-part-updated-streaming")'

# Run tests matching a prefix:
emacs -Q -batch -L . -L test -l test/test-helper.el \
  -l test/opencode-chat-test.el \
  -eval '(ert-run-tests-batch-and-exit "opencode-chat-render")'
```

**Verification rule**: `make compile` MUST produce zero warnings (ignore the pre-existing `opencode-pkg.el` no-lexical-binding warning). Run before any commit.

## Architecture

```
opencode.el          Entry point, requires all modules, keymaps, defgroup
opencode-server.el   Server subprocess lifecycle, health check, port parsing
opencode-api.el      HTTP client (url.el), JSON parse/serialize, prompt body builder
opencode-api-cache.el  Cache facade: micro-cache (agents/config/providers), session stale-on-timeout, startup-safe load/retry
opencode-sse.el      SSE transport via curl subprocess (--no-buffer), event dispatch to global hooks
opencode-chat.el     Chat buffer, SSE event routing, session state, refresh orchestration, queued indicator lifecycle
opencode-chat-state.el  Consolidated buffer-local state struct + accessors (busy, queued, pending-msg-ids, tokens, agent/model)
opencode-chat-input.el  Input area, @-mention/slash CAPF, chips, clipboard paste, history, footer, send/abort commands
opencode-chat-message.el  Message store + renderer (CRUD by msg-id, streaming, part rendering, diff cache)
opencode-session.el  Session CRUD, session list buffer
opencode-agent.el    Agent list, manual cache (no TTL — SSE-only invalidation), cycling
opencode-todo.el     Session todo list display (read-only, GET /session/:id/todo)
opencode-diff.el     Inline diff display, patch parsing, revert (GET/POST /session/:id/diff)
opencode-permission.el  SSE-driven permission request popup (POST /permission/:id/reply)
opencode-popup.el    Shared popup infrastructure (find-chat-buffer, inline region, queue drain, dual-dispatch purge helpers)
opencode-question.el    SSE-driven question popup with multi-question support
opencode-status.el   Server status popup (MCP, LSP, Formatter) with toggle support
opencode-faces.el    All face definitions (inherit from standard Emacs faces)
opencode-ui.el       Section system, navigation, read-only regions
opencode-window.el   display-buffer rules (side, float, split, full)
opencode-sidebar.el  Per-project session sidebar (treemacs-based, SSE-driven refresh)
opencode-util.el     Shared helpers (time-ago, file-status-char, diff-stats, right-align, json-parse)
opencode-log.el      Debug logging to *opencode: debug* buffer (leaf module, zero dependencies)
```

### Module Boundary: api.el ↔ api-cache.el

```
┌─────────────────────────────────────────────────────────────┐
│  opencode-api.el (HTTP Client)                              │
│                                                             │
│  Owns: HTTP request/response, JSON parse/serialize,         │
│        URL construction, headers, error handling,           │
│        prompt body builder                                  │
│                                                             │
│  Requires opencode-api-cache.el (delegates all caching)     │
│                                                             │
│  Must NOT own: cache state, micro-cache definitions,        │
│                cache invalidation, session cache             │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  opencode-api-cache.el (Cache Facade)                       │
│                                                             │
│  Owns: micro-cache macro + instances (agents, config,       │
│        providers), session stale-on-timeout read,           │
│        startup-safe load state (loaded/failed/unloaded),    │
│        lazy retry via ensure-loaded, cache invalidation     │
│                                                             │
│  Does NOT require opencode-api (uses declare-function)      │
│  Leaf-ish: requires only cl-lib and opencode-log            │
│                                                             │
│  Public API:                                                │
│    opencode-api-invalidate-all-caches ()                    │
│    opencode-api-cache-prewarm ()                            │
│    opencode-api-cache-ensure-loaded ()                      │
│    opencode-api-cache-load-failed-p ()                      │
│    opencode-api-cache-get-session (session-id callback)     │
│    opencode-api-cache-put-session (session-id session)      │
│    opencode-api-cache-invalidate-session (session-id)       │
│    opencode-api-cache-valid-agent-p (agent-name)            │
│    opencode-api--agents (&key block cache callback)         │
│    opencode-api--server-config (&key block cache callback)  │
│    opencode-api--providers (&key block cache callback)      │
└─────────────────────────────────────────────────────────────┘
```

### Module Boundary: chat.el ↔ chat-state.el ↔ chat-input.el ↔ chat-message.el

`opencode-chat.el`, `opencode-chat-input.el`, `opencode-chat-message.el`,
and `opencode-chat-state.el` form a four-layer architecture:

```
┌─────────────────────────────────────────────────────────────┐
│  opencode-chat-state.el (State Struct — bottom of tree)     │
│                                                             │
│  Owns: cl-defstruct with all buffer-local display state:    │
│        session-id, session, agent, model-id, provider-id,   │
│        variant, context-limit, tokens, update-available,    │
│        busy, queued, pending-msg-ids                        │
│                                                             │
│  Provides: accessors (--session-id, --busy, --queued, etc.) │
│            setters (--set-busy, --set-queued, etc.)         │
│            state-init, state-ensure, effective-agent/model   │
│                                                             │
│  Must NOT own: any logic, SSE handling, UI rendering,       │
│                or lifecycle decisions                        │
│                                                             │
│  Requires: opencode-api, opencode-agent, opencode-config    │
│  Required by: chat.el, chat-input.el, chat-message.el       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  opencode-chat.el (SSE Router + Session Controller)         │
│                                                             │
│  Owns: refresh-timer, streaming-assistant-info,             │
│        refresh-state (single state machine),                │
│        queued-overlay                                        │
│                                                             │
│  SSE handlers: on-session-*, on-message-*, on-part-updated  │
│  Orchestration: refresh, render-messages, schedule-refresh   │
│  State transitions: busy/queued/pending lifecycle            │
│  Queued UI: show-queued-indicator, hide-queued-indicator     │
│  UI: header-line                                            │
│                                                             │
│  RULE: chat.el is the ONLY module that mutates busy/queued/ │
│        pending-msg-ids state. Input and message modules      │
│        read state but never write it.                        │
│                                                             │
│  Calls ──────────────────────────────────────────────────►   │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  opencode-chat-input.el (Input Area + Completion)            │
│                                                             │
│  Owns: input-start, input-history, mention-cache,           │
│        input-map keymap                                      │
│                                                             │
│  Send: opencode-chat--send builds prompt body + calls        │
│        opencode-api-post. Returns the msg-id to chat.el      │
│        via opencode-chat-on-message-sent-hook.               │
│        Does NOT mutate busy/queued state.                    │
│  Abort: opencode-chat-abort calls session-abort API.         │
│         Does NOT mutate busy/queued state.                   │
│                                                             │
│  Input area: render-input-area, input-text, clear-input,     │
│              input-content-start/end, in-input-area-p,       │
│              goto-latest, kill-whole-line                     │
│  Footer: render-footer-info, refresh-footer,                 │
│          render-update-notification, insert-shortcut          │
│  Chips: chip-create, chip-delete, chip-backspace,            │
│         chip-modification-hook                               │
│  CAPF: mention-capf, slash-capf, mention-candidates,         │
│        mention-exit, slash-annotate                           │
│  Fuzzy: mention-fuzzy-match-p, fuzzy-substr-p,                │
│         mention-fuzzy-score (built into completion table)     │
│  History: input-history-push/prev/next/seed/replace          │
│  Clipboard: clipboard-image-bytes, image-to-data-url,        │
│             paste-image, attach                              │
│  Attachments: input-attachments                              │
│                                                             │
│  Does NOT require opencode-chat (no circular dependency)     │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  opencode-chat-message.el (Message Store + Renderer)        │
│                                                             │
│  Owns: parts, messages-end, streaming-msg-id,               │
│        streaming-fontify-timer, streaming-region-start,      │
│        diff-cache, diff-shown, section-overlay-map,          │
│        current-message-id, child-parent-cache,               │
│        tool-renderers                                        │
│                                                             │
│  Public API:                                                 │
│    opencode-chat-message-insert (msg)                        │
│    opencode-chat-message-append-delta (msg-id part-id delta) │
│    opencode-chat-message-upsert-part (msg-id part)           │
│    opencode-chat-message-clear-all ()                        │
│    opencode-chat-message-clear-streaming ()                  │
│    opencode-chat-message-messages-end ()                     │
│    opencode-chat-message-init-messages-end (pos)             │
│    opencode-chat-message-invalidate-diffs ()                 │
│    opencode-chat-message-prefetch-diffs (session-id)         │
│    opencode-chat-message-child-parent-get (child-session-id) │
│    opencode-chat-message-render-all (messages)               │
│    opencode-chat-register-tool-renderer (tool-name fn)       │
│                                                             │
│  Internal: all opencode-chat--render-*, streaming,           │
│            tool body renderers, format helpers                │
│                                                             │
│  Must NOT own: queued overlay, session state, SSE knowledge  │
│  Does NOT require opencode-chat (no circular dependency)     │
└─────────────────────────────────────────────────────────────┘
```

**Key design rules:**
- Message module is a "DB" — CRUD by message-id, no knowledge of SSE events or session state
- Input module is self-contained — rendering, CAPF, history, chips, send/abort commands
- Input module does NOT mutate busy/queued state — chat.el handles all state transitions
- chat.el is the sole owner of busy/queued/pending lifecycle (state transitions + queued UI)
- `opencode-chat--` prefix preserved for all moved internal functions (zero rename)
- New public API uses `opencode-chat-message-` prefix (message) / `opencode-chat--` (input, kept for compatibility)
- No callbacks from message→chat or input→chat — return values only
- `streaming-assistant-info` stays in chat.el (SSE routing state)
- `input-start` and input history state live in chat-input.el

### Queued Indicator Lifecycle

```
  User presses C-c C-c (opencode-chat--send in chat-input.el)
      │
      ├─ Optimistic insert user message (msg-id = "msg_xxx")
      ├─ Run opencode-chat-on-message-sent-hook with msg-id
      ├─ POST /session/:id/prompt_async (async)
      │
      v
  chat.el receives hook → opencode-chat--on-message-sent
      │
      ├─ (opencode-chat--set-busy t)
      ├─ Add msg-id to pending-msg-ids set
      ├─ (opencode-chat--set-queued t)
      ├─ Insert QUEUED badge at messages-end (queued-overlay)
      │
      v
  SSE: message.updated (role=assistant, id="msg_yyy")
      │
      ├─ If msg-id >= any pending-msg-id:
      │     remove that pending-msg-id from set
      │     if set is now empty:
      │       (opencode-chat--set-queued nil)
      │       remove QUEUED badge overlay
      │
      v
  SSE: session.idle / session.error / abort
      │
      ├─ Clear ALL pending-msg-ids
      ├─ (opencode-chat--set-queued nil)
      ├─ Remove QUEUED badge overlay
      └─ (opencode-chat--set-busy nil)
```

### Chat Buffer Layout (markers, overlays, text properties)

```
Buffer: *opencode: project/Session Title*
header-line-format: [Title (left)                    busy/idle (right)]

Position  Content                                    Markers & Overlays
────────  ─────────────────────────────────────────  ──────────────────────────
1         \n                                         ← render-message leading \n
2         ▼ You  14:30:25                            ┐ section overlay (type:message, id:msg_user1)
          │ help me commit                           │ part marker (prt_user_text) → end of text
          │ _                                        │
          │                                          ┘
          ··········································  ← separator (dotted)
          ─────────────────────────────────────────  ← separator (solid)
          \n                                         ← render-message leading \n
          ▼ Assistant Agent claude-opus-4-6 14:30:28 ┐ section overlay (type:message, id:msg_asst1)
          │  ▶ bash ($ git status)  ⏳               │ ┐ section overlay (type:tool, id:prt_tool1)
          │  [collapsed]                             │ ┘ part marker (prt_tool1) → end of tool
          │  _                                       │
          │                                          │
          │  I'll help you commit. Let me check...   │ part marker (prt_text1) → end of text
          │  ⬆3 ⬇12 · 1.2s                          │ ← footer (opencode-message-footer-line)
          │                                          ┘

          *** messages-end marker (insertion type t) ***  ← after footer \n

          ─────────────────────────────────────────  ← input separator
          > ▯                                        ← input prompt + editable space
              ▲
          *** input-start marker ***
              ▼
          \n
          ─────────────────────────────────────────  ← footer-info separator
          [claude-opus-4-6] Agent Name               ┐ tagged with 'opencode-footer-info
           Tokens: 1,437  (⬆0 ⬇1,437  cache: ...)  │ (for cheap refresh-footer updates)
           Context: ████░░░░░░  0.7%  (1,437/200k)  │
          ─────────────────────────────────────────  ┘
          C-c C-c send  C-c C-k abort  TAB agent    ← shortcut help line
          \n
```

**Text properties:**
- `point-min` → `messages-end`: `keymap=opencode-chat-message-map`, `read-only=t`
- Input prompt `"> "`: `read-only=t`, `front-sticky`
- Input area `" "`: `face=opencode-input-area`, `opencode-input=t` (editable!)
- Post-input → `point-max`: `read-only=t`

**Marker behavior:**

| Marker | Insertion Type | Purpose |
|--------|---------------|---------|
| `messages-end` | `t` (temporarily `nil` during `message-insert`) | Boundary between messages and input area. `nil` during insert prevents collision with part markers |
| `input-start` | default | Start of editable input region |
| `parts[part-id]` | `t` | End of each part's rendered content; streaming deltas insert here and marker advances |
| `streaming-region-start` | `nil` | Start of current streaming region (for deferred markdown fontification) |

**Section overlays** (`opencode-section` property):
- Cover entire message or tool/part region
- Used for collapse/expand (TAB) and O(1) lookup via `opencode-chat--section-overlay-map`
- Nested: message overlay contains tool overlays

**CRITICAL: `message-insert` marker dance** — When inserting a new message at `messages-end`, the function temporarily switches `messages-end` to `nil` insertion type. Without this, `messages-end` (type `t`) advances into the message body during rendering and collides with part markers (also type `t`). After rendering, `messages-end` is explicitly moved to `(point)` and restored to type `t`. This prevents streaming text from appearing below the input area.

## Naming Convention

```elisp
;; Public API (user-facing commands, customizable variables):
opencode-chat          ; M-x command
opencode-server-port   ; defcustom

;; Internal (used across or within modules — always double-dash):
opencode-chat--find-buffer    ; cross-module internal
(opencode-chat--refresh-timer) ; buffer-local state accessor (struct slot)
```

**Rule**: `opencode-<MODULE>--name` for internal. `opencode-name` for public. Never single-dash for internal functions.

## Code Style

- **lexical-binding**: Every file MUST have `; -*- lexical-binding: t; -*-`
- **JSON parsing**: Always use `:object-type 'plist`, `:array-type 'array`, `:null-object nil`, `:false-object :false`
- **JSON false**: Parsed as `:false` (keyword symbol), NOT `nil`. Check with `(eq val :false)`, not `(not val)`
- **UI rendering**: All visual styling via `defface`. No raw ANSI. No ASCII box-drawing (`─│┌┐`). Use face properties (`:box`, `:overline`, `:underline`, `:weight`). Prefer face-styled buttons (`opencode-popup-option`, `opencode-popup-option-selected`) over bracket-key hints (`[a]`, `[r]`). Interactive popups (question, permission) render **inline in the chat buffer input area**, not in separate windows/frames.
- **Header/Footer layout**: `header-line-format` shows **title (left) + status (right)** only. Session details (model, agent, tokens, context percentage) are rendered in a **footer section above the input area** via `opencode-chat--render-footer-info`. This keeps the header minimal while providing full session info near where the user types. Footer updates on every refresh to show latest token counts and context usage.
- **Error handling**: `condition-case` for recovery, `user-error` for user messages. No empty `(condition-case nil ... (error nil))`
- **Buffer-local vars**: Declare with `defvar-local`. Initialize in mode function
- **Cross-module refs**: Use `(declare-function ...)` to avoid byte-compile warnings without circular requires
- **Right-alignment**: Use `(space :align-to (- right N))` display property. `mode-line-format-right-align` does NOT work in `header-line-format` (Emacs bug #71835)
- **Marker insertion types**: When creating markers that must stay before subsequently-inserted content (e.g. `messages-end` before the input area), use `nil` insertion type initially, render surrounding content, THEN switch to `t` with `set-marker-insertion-type`

### Keymap Customization (User Overrides)

`opencode-chat-mode` has three active keymaps (see "Chat Buffer Layout" and "Common Mistakes" #22):

| Keymap | Installed as | Region |
|---|---|---|
| `opencode-chat-mode-map` | Major-mode map | Whole buffer (fallback) |
| `opencode-chat-message-map` | Text property `'keymap` | Read-only message area |
| `opencode-chat-input-map` | Text property `'keymap` | Editable input area |

Emacs resolves text-property `'keymap` entries **before** major- and minor-mode maps, so rebinding only the mode-map is insufficient. Package code keeps this split load-bearing because the input area needs `self-insert-command` while the read-only region needs single-letter navigation (`q`, `g`, `G`, `TAB`).

**Two public extension points** let users override bindings consistently across all three regions:

1. **`opencode-chat-user-keymap`** — a parent keymap installed as `set-keymap-parent` of all three internal maps. Any binding added here propagates to all three regions whenever the child map doesn't have an explicit binding for the same key. This is the right place for *additive* bindings (new keys that don't collide with package defaults).

2. **`opencode-chat-unbound-keys`** — a `defcustom` listing keys to remove from every internal map. The apply helper uses `keymap-unset MAP KEY t` (the `remove` flag), which truly deletes the binding so the parent/global map resolves it. Defaults to `nil`. Runtime-reactive via a custom `:set` handler that re-applies unbinds on live buffers. Defaults are captured at load time into `opencode-chat--default-bindings-alist` so changes are fully reversible.

**Canonical example — recover `C-p` to `previous-line`:**

```elisp
(setq opencode-chat-unbound-keys '("C-p"))
(keymap-set opencode-chat-user-keymap "C-c p" #'opencode-command-select)
```

**Complete `use-package` example** (recommended form):

```elisp
(use-package opencode
  ;; `:bind-keymap' is the correct idiom for binding a prefix to a keymap.
  ;; Using bare `:bind' with a keymap on the right side is unreliable
  ;; across use-package versions.
  :bind-keymap ("C-c c o" . opencode-command-map)
  :custom
  ;; Works via :custom because the defcustom is registered in
  ;; opencode-autoloads.el via `custom-autoload', so the :set handler
  ;; fires during library load via `custom-initialize-reset'.
  (opencode-chat-unbound-keys '("C-p"))
  (opencode-window-display 'side)
  (opencode-window-side 'right)
  ;; CAVEAT: `opencode-keymap-prefix' is consumed once at `defvar' time
  ;; and cannot be changed via :custom after load.  Use `:bind-keymap'
  ;; above with your desired prefix instead; ignore this variable unless
  ;; you `setq' it BEFORE requiring opencode.  (Tracked separately as
  ;; the `fix-keymap-prefix-reactive' OpenSpec change.)
  :config
  ;; Add user bindings AFTER load so the parent-keymap wiring is complete.
  (keymap-set opencode-chat-user-keymap "C-c c o p"
              #'opencode-command-select))
```

**Why the split between `:custom` and `:config`?**

- `:custom` values go through `customize-set-variable`, which invokes
  the defcustom's `:set` handler.  For `opencode-chat-unbound-keys`,
  the autoloaded `custom-autoload` registration combined with the
  `:set`-handler guard (no-op when the apply helper isn't yet defined)
  makes pre-load configuration safe.
- `:config` runs AFTER the library has been loaded, which means
  `opencode-chat-user-keymap` is fully wired as the parent of all
  three chat keymaps.  Add custom bindings to it here — they will
  resolve correctly from the input area, message area, and mode-map
  fallback regions.

For package-internal bindings, keep them in the child maps (mode/message/input) — the user-keymap is for users, not for us. New internal bindings that genuinely span all three regions are rare; when they exist, prefer placing them in the child map closest to their region and let users opt in via the override points above.

## OpenCode Server Architecture

opencode.el implements the equivalent of `opencode attach` — an external client connecting
to an already-running OpenCode server over HTTP + SSE.

### Client Modes in the OpenCode Ecosystem

| Mode | API Transport | Event Transport | SSE Endpoint |
|---|---|---|---|
| TUI (default) | In-process RPC → `Server.App().fetch()` | RPC from Worker thread | `GET /event` (per-dir) |
| TUI (`--port`) | Real HTTP to localhost | Real SSE | `GET /global/event` |
| `opencode attach` | Real HTTP to URL | Real SSE | `GET /global/event` |
| Web App | Real HTTP to URL | Real SSE | `GET /global/event` |
| **opencode.el** | Real HTTP via curl/url.el | Real SSE via curl | `GET /global/event` |

### How the TUI Starts the Server

The TUI uses a two-thread architecture:
- Main thread (`thread.ts`): TUI rendering (Ink/React), communicates with worker via RPC
- Worker thread (`worker.ts`): Runs `Server.App()` (Hono), handles `GlobalBus` events

By default, NO HTTP server is started. The TUI calls `Server.App().fetch()` directly
(in-process, no network). HTTP listener is only started with `--port`/`--hostname`.

### SSE Endpoints

Two SSE endpoints exist:
- `GET /global/event` — ALL events from ALL directories. Wraps in `{directory, payload}`.
  Used by: Web App, `opencode attach`, opencode.el
- `GET /event?directory=X` — Per-directory events. Flat format.
  Used by: TUI worker (in-process)

### Why Emacs Requires HTTP (Cannot Use In-Process RPC)

The TUI avoids HTTP by running `Server.App()` (a Hono app) in a Bun Worker thread
and calling `.fetch()` directly via inter-thread RPC. This is a **Bun-specific optimization**
that Emacs cannot replicate:

| Requirement | TUI (Bun) | Emacs |
|-------------|-----------|-------|
| Run JavaScript/TypeScript | ✅ Native | ❌ No JS runtime |
| Import `Server.App()` | ✅ Same process | ❌ Cannot import TS modules |
| Worker threads with RPC | ✅ `new Worker()` + `postMessage` | ❌ No equivalent |
| Call Hono `.fetch()` directly | ✅ In-memory | ❌ Must use HTTP |

**TUI in-process pattern** (`packages/opencode/src/cli/cmd/tui/`):
```typescript
// worker.ts — runs Server.App().fetch() directly, no HTTP
const response = await Server.App().fetch(request)

// thread.ts — wraps RPC as fetch() for the SDK
customFetch = createWorkerFetch(client)  // RPC → worker → Server.App().fetch()
```

**Emacs pattern** (this codebase):
```
Emacs ──HTTP──► opencode serve --port 0 ──► Server.listen() ──► Bun.serve()
```

This architectural constraint is fundamental — Emacs has no JavaScript runtime and cannot
call TypeScript functions in-process. The HTTP overhead is minimal (localhost TCP) and
matches how `opencode attach` and the Web App work.

**Implementation in `opencode-server.el`**:
- **Managed mode**: Spawn `opencode serve --port 0`, parse port from stdout, use HTTP
- **Connect mode**: Attach to existing server via `opencode-server-port`, use HTTP

### Event Reconnection

SSE reconnection is a transport-level concern, not application-level:
- `server.instance.disposed` / `global.disposed` → SSE stays connected. Re-fetch data only.
- Server actually dies (curl process exits) → SSE transport handles reconnect with backoff.
- Web App SDK has built-in retry with exponential backoff (3s → 6s → ... cap 30s).
- opencode.el uses `opencode-sse-auto-reconnect` when curl process sentinel fires.

## SSE Event Types & Hooks

| Server Event | Emacs Hook | Session ID Path |
|---|---|---|
| `session.updated` | `opencode-sse-session-updated-hook` | `properties.info.id` |
| `session.deleted` | `opencode-sse-session-deleted-hook` | `properties.info.id` |
| `session.status` | `opencode-sse-session-status-hook` | `properties.sessionID` |
| `session.idle` | `opencode-sse-session-idle-hook` | `properties.sessionID` (deprecated) |
| `session.error` | `opencode-sse-session-error-hook` | `properties.sessionID` (optional) |
| `session.diff` | `opencode-sse-session-diff-hook` | `properties.sessionID` |
| `session.compacted` | `opencode-sse-session-compacted-hook` | `properties.sessionID` |
| `message.updated` | `opencode-sse-message-updated-hook` | `properties.info.sessionID` |
| `message.part.updated` | `opencode-sse-message-part-updated-hook` | `properties.part.sessionID` |
| `message.removed` | `opencode-sse-message-removed-hook` | `properties.info.sessionID` |
| `message.part.removed` | `opencode-sse-message-part-removed-hook` | `properties.part.sessionID` |
| `todo.updated` | `opencode-sse-todo-updated-hook` | `properties.sessionID` |
| `permission.asked` | `opencode-sse-permission-asked-hook` | `properties.sessionID` |
| `permission.replied` | `opencode-sse-permission-replied-hook` | `properties.sessionID` |
| `question.asked` | `opencode-sse-question-asked-hook` | `properties.sessionID` |
| `question.replied` | `opencode-sse-question-replied-hook` | `properties.sessionID` |
| `question.rejected` | `opencode-sse-question-rejected-hook` | `properties.sessionID` |
| `server.instance.disposed` | `opencode-sse-server-instance-disposed-hook` | N/A (directory-scoped, broadcast to all buffers) |

### SSE Architecture (full data flow)

```
OpenCode Server (:4096)
    |
    | GET /global/event (no X-OpenCode-Directory header needed)
    v
curl -s -N -H "Accept: text/event-stream" http://127.0.0.1:4096/global/event
    |  (started by opencode-sse-connect, called from opencode--on-connected)
    |  (opencode--on-connected runs on EVERY server connection: start & connect mode)
    |
    |  raw bytes: "data: {\"payload\":{\"type\":\"session.idle\",...}}\n\n"
    v
opencode-sse--filter (process filter, NO buffer context)
    |  accumulates bytes in opencode-sse--buffer
    |  splits on \n, feeds complete lines to:
    v
opencode-sse--process-line
    |  SSE protocol: "data: ..." accumulates, empty line dispatches
    v
opencode-sse--dispatch-event (event-type, data-string)
    |  1. JSON parse data-string
    |  2. Unwrap global format: {directory, payload: {type, properties}} → {type, properties, directory}
    |  3. run-hook-with-args 'opencode-sse-event-hook (catch-all)
    |  4. Map type → specific hook via opencode-sse--hook-for-type
    v
opencode-sse-<type>-hook (GLOBAL hooks, e.g. opencode-sse-session-idle-hook)
    |
    |  Chat events:                    Permission/Question events:
    |  12 dispatch wrappers            Direct handlers (no buffer context needed)
    v                                  v
opencode-chat--on-<type>-dispatch    opencode-permission--on-asked
    |                                opencode-question--on-asked
    v
opencode--dispatch-to-chat-buffer (O(1) registry lookup by session-id)
    |  hash-table lookup: session-id → buffer
    |  fallback: inline buffer-list scan if buffer not registered
    v
opencode-chat--on-<type> (runs IN the chat buffer)
    |  buffer-local vars now accessible:
    |    opencode-chat--session-id  (filters: is this event for me?)  [chat.el]
    |    opencode-chat--busy        (busy/idle state)                 [chat.el]
    |    opencode-chat--parts       (streaming marker hash table)     [chat-message.el]
    |    opencode-chat--messages-end (insertion point marker)         [chat-message.el]
    v
  Actions:
    - on-session-status  → set opencode-chat--busy
    - on-session-idle    → clear busy, clear queued + pending-msg-ids, clear streaming, trigger refresh
    - on-message-updated → if assistant msg-id >= any pending-msg-id: clear that pending, maybe clear queued; bootstrap streaming
    - on-message-removed → schedule-refresh (debounced 0.3s)
    - on-part-updated   → insert streaming text (if delta); finalized text/reasoning are no-ops (content already streamed); tool/step parts schedule-refresh
    - on-session-updated → update session metadata, update session cache
    - on-session-diff    → schedule-refresh
    - on-session-error   → clear queued + pending-msg-ids, clear busy (unless MessageAbortedError)
    - on-session-compacted → clear streaming state, immediate refresh (history rewrite)
    - on-server-instance-disposed → clear queued + pending-msg-ids; if busy: mark stale; if idle+visible: debounced 2s refresh; if hidden: mark stale
```

**Key invariants:**
- SSE uses curl subprocess, NOT url.el (url.el buffers the entire response)
- ALL SSE hooks are GLOBAL (curl filter has no buffer context)
- Chat handlers use O(1) registry lookup via `opencode--dispatch-to-chat-buffer`
- Each chat handler filters by `opencode-chat--session-id` internally
- `opencode--on-connected` (not `opencode-start`) triggers SSE connect

### Chat Buffer State Machine (`opencode-chat.el`)

```
                         ┌──────────────────────────────────────────────────────┐
                         │              CHAT BUFFER LIFECYCLE                   │
                         └──────────────────────────────────────────────────────┘

    opencode-chat-open(session-id, directory)
        │
        ├─ register in opencode--chat-registry
        ├─ set buffer-local: session-id, directory
        ├─ opencode-chat--refresh (async: GET messages + GET session → render)
        │
        v
  ┌──────────┐   session.status(busy)   ┌──────────┐
  │          │ ──────────────────────>   │          │
  │   IDLE   │                          │   BUSY   │
  │          │ <──────────────────────   │          │
  └──────────┘   session.status(idle)   └──────────┘
       │              session.idle            │
       │                                     │
       │   ┌─────────────────────────────────┘
       │   │  while BUSY: streaming via message.part.updated
       │   │
       │   v
       │   STREAMING DELTA ROUTING (on-part-updated with delta field):
       │   │
       │   ├─ Case 1: messages-end marker valid + part in hash table
       │   │           → insert delta text at streaming marker (real-time)
       │   │
       │   ├─ Case 2: messages-end marker valid + part NOT in hash table
       │   │           → create new marker, insert, add to parts hash table
       │   │
       │   └─ Case 3: messages-end marker nil (refresh in progress)
       │               → schedule-refresh (deferred, safe)
       │
       │   NON-DELTA PARTS (on-part-updated without delta):
       │   ├─ finalized text/reasoning (has :end time) → no-op (already streamed)
       │   ├─ bootstrap (no delta, no :end time) → no-op (empty part placeholder)
       │   └─ tool/step-start/step-finish → schedule-refresh
       │
  ┌────┴────────────────────────────────────────────────┐
  │  REFRESH STATE MACHINE (single variable)            │
  │                                                     │
  │  `(opencode-chat--refresh-state)' (struct slot)     │
  │    has four values:                                 │
  │    nil                — idle                        │
  │    'stale             — refresh deferred (busy/hid) │
  │    'in-flight         — fetch chain running         │
  │    'in-flight-pending — fetch running AND retry     │
  │                         already requested           │
  │                                                     │
  │  schedule-refresh (debounce 0.3s timer)             │
  │       │                                             │
  │       v                                             │
  │  (opencode-chat--refresh)                           │
  │       │                                             │
  │       ├─ busy? → (--mark-stale) — state becomes     │
  │       │         `stale', no HTTP, return.           │
  │       │                                             │
  │       ├─ (--refresh-begin) — pcase on state:        │
  │       │    nil | stale          → in-flight; fetch  │
  │       │    in-flight            → in-flight-pending │
  │       │                            (return, coalesced)│
  │       │    in-flight-pending    → no change         │
  │       │                            (return, coalesced)│
  │       │                                             │
  │       v (only if refresh-begin returned t)          │
  │  GET /session/:id/message (async) →                 │
  │  GET /session/:id (via cache) →                     │
  │  render-messages (erase + rebuild) →                │
  │  (opencode-chat--refresh-end) — pcase on state:     │
  │     in-flight-pending → nil; return t → re-fire     │
  │                          opencode-chat--refresh     │
  │     otherwise         → nil; return nil             │
  └──────────────────────────────────────────────────────┘

  RULE: Never call `opencode-chat--set-refresh-state' directly.  Use
        `--mark-stale', `--refresh-begin', `--refresh-end', or
        `--force-clear-refresh-guard' (terminal event handlers only).

  ┌──────────────────────────────────────────────────────┐
  │  VISIBILITY GUARD (saves HTTP for hidden buffers)    │
  │                                                      │
  │  SSE event arrives for hidden buffer                 │
  │       │                                              │
  │       v                                              │
  │  buffer visible? ──YES──> refresh immediately        │
  │       │                                              │
  │      NO                                              │
  │       │                                              │
  │       v                                              │
  │  (opencode-chat--mark-stale) — state becomes `stale' │
  │  (deferred to window-buffer-change-functions hook)   │
  │       │                                              │
  │       v (when buffer becomes visible)                │
  │  opencode-chat--on-window-buffer-change              │
  │  (--stale-p)? ──YES──> call --refresh, which         │
  │                        transitions stale → in-flight │
  └──────────────────────────────────────────────────────┘

  SPECIAL EVENTS:
  ├─ session.compacted   → clear streaming state, immediate refresh (history rewrite)
  ├─ session.deleted     → show deletion msg, disable input, refresh sidebar
  ├─ session.error       → show error in chat buffer (skip MessageAbortedError)
  ├─ server.instance.disposed → broadcast: clear ALL state, immediate refresh
  │                             (visibility guard applies — hidden buffers defer)
  └─ installation.update-available → inline footer notification

  KEY STATE VARIABLES:
  ┌───────────────────────────┬──────────────────────────────────────────┐
  │ Variable                  │ Purpose                          (module)│
  ├───────────────────────────┼──────────────────────────────────────────┤
  │ --session-id              │ Filters SSE events to this buffer(state) │
  │ --busy                    │ Tracks busy/idle for header display(st.) │
  │ --queued                  │ True while pending msgs unacknowledg(st.)│
  │ --pending-msg-ids         │ Set of sent-but-unacked msg IDs    (st.) │
  │ --streaming-assistant-info│ Cached assistant info for bootstrap(chat)│
  │ --refresh-state           │ Single state machine:               (ch) │
  │                           │   nil/stale/in-flight/in-flight-pending  │
  │                           │   (replaces --stale + --refresh-in-flight│
  │                           │    + --refresh-pending).  Access ONLY    │
  │                           │   via --mark-stale, --refresh-begin,     │
  │                           │   --refresh-end, --force-clear-refresh-  │
  │                           │   guard.                                 │
  │ --queued-overlay          │ Overlay for QUEUED badge after msgs(chat)│
  │ --input-start (marker)    │ Start of editable input region   (input) │
  │ --input-history (ring)    │ Previously sent messages         (input) │
  │ --mention-cache           │ Cached @-mention candidates      (input) │
  │ --store (hash table)      │ msg-id → {msg,overlay,parts,diff}  (msg) │
  │ --messages-end (marker)   │ Insertion point for streaming text (msg) │
  │ --diff-cache (hash table) │ messageID → diff data for edits    (msg) │
  │ --child-parent-cache      │ GLOBAL child-session→parent map.   (msg) │
  │                           │ Used by opencode--dispatch-popup-event   │
  │                           │ for popup routing.  Capped at           │
  │                           │ opencode-chat-message--max-session-depth │
  │                           │ hops; cycles are detected and broken.    │
  │ --section-overlay-map     │ part-id → overlay for O(1) lookup  (msg) │
  └───────────────────────────┴──────────────────────────────────────────┘
```

### TUI State Machine (TypeScript — `tui/`)

The TUI is a SolidJS terminal application with a two-thread architecture.
State is managed through SolidJS stores and reactive contexts.

```
                         ┌──────────────────────────────────────────────────────┐
                         │                TUI ARCHITECTURE                      │
                         └──────────────────────────────────────────────────────┘

  THREAD MODEL:
  ┌─────────────────────┐      RPC       ┌─────────────────────┐
  │    Main Thread       │◄────────────►  │   Worker Thread      │
  │  (thread.ts)         │               │  (worker.ts)          │
  │  SolidJS TUI render  │               │  Server.App() (Hono)  │
  │  Ink-like terminal   │               │  GlobalBus events     │
  │  User input          │               │  fetch/reload/shutdown│
  └─────────────────────┘               └─────────────────────┘

  PROVIDER NESTING (outer → inner):
    Args → Exit → KV → Toast → Route → SDK → Sync → Theme →
    Local → Keybind → PromptStash → Dialog → Command →
    Frecency → PromptHistory → PromptRef → <App>

                         ┌──────────────────────────────────────────────────────┐
                         │            SYNC STATE MACHINE (sync.tsx)             │
                         └──────────────────────────────────────────────────────┘

    onMount → bootstrap()
        │
        v
  ┌──────────┐
  │ LOADING  │  status = "loading"
  │          │  (initial state — all stores empty)
  └────┬─────┘
       │  await Promise.all(blocking requests):
       │    - config.providers()     → store.provider, store.provider_default
       │    - provider.list()        → store.provider_next
       │    - app.agents()           → store.agent
       │    - config.get()           → store.config
       │    - session.list()         (only if --continue flag)
       │
       v
  ┌──────────┐
  │ PARTIAL  │  status = "partial"
  │          │  (providers, agents, config loaded — UI can render)
  └────┬─────┘
       │  Promise.all(non-blocking requests):
       │    - session.list()         (if NOT --continue)
       │    - command.list()         → store.command
       │    - lsp.status()           → store.lsp
       │    - mcp.status()           → store.mcp
       │    - resource.list()        → store.mcp_resource
       │    - formatter.status()     → store.formatter
       │    - session.status()       → store.session_status
       │    - provider.auth()        → store.provider_auth
       │    - vcs.get()              → store.vcs
       │    - path.get()             → store.path
       │
       v
  ┌──────────┐
  │ COMPLETE │  status = "complete"
  │          │  (all data loaded, full UI available)
  └──────────┘
       │
       │  server.instance.disposed → re-run bootstrap()
       │  (status goes back to "partial" if already "complete",
       │   otherwise stays at current level)
       v
  ┌──────────┐
  │ ERROR    │  bootstrap catch → exit(e)
  │          │  (fatal — TUI exits)
  └──────────┘

  SESSION SYNC (on-demand, per-session):
    sync.session.sync(sessionID)
        │  (idempotent — skips if already fullSynced)
        │  Promise.all:
        │    - session.get()    → update store.session[index]
        │    - session.messages() → store.message[sessionID]
        │    - session.todo()   → store.todo[sessionID]
        │    - session.diff()   → store.session_diff[sessionID]
        v
    fullSyncedSessions.add(sessionID)

                         ┌──────────────────────────────────────────────────────┐
                         │             ROUTE STATE MACHINE (route.tsx)          │
                         └──────────────────────────────────────────────────────┘

  ┌──────────┐  navigate({type:"session",sessionID})  ┌──────────────┐
  │          │ ─────────────────────────────────────>  │              │
  │   HOME   │                                        │   SESSION    │
  │          │ <─────────────────────────────────────  │              │
  └──────────┘  navigate({type:"home"})                └──────────────┘
       │              session.deleted on current             │
       │              /new command                           │
       │                                                    │
       │  Renders:                                          │  Renders:
       │  - Logo                                            │  - Header (title, context, cost)
       │  - Prompt (with initial text if any)               │  - ScrollBox of messages
       │  - Tips (dismissible)                              │  - Permission/Question prompts
       │  - MCP status in footer                            │  - Prompt input
       │                                                    │  - Optional sidebar (wide mode)
       │                                                    │  - Footer (directory, LSP, MCP)
       │                                                    │
       │  Auto-navigate on --continue flag:                 │  Auto-navigate on task tool:
       │  sync reaches "partial" → find most recent         │  plan_exit → agent.set("build")
       │  root session → navigate to it                     │  plan_enter → agent.set("plan")

                         ┌──────────────────────────────────────────────────────┐
                         │         SSE EVENT → STORE DISPATCH (sync.tsx)        │
                         └──────────────────────────────────────────────────────┘

  sdk.event.listen() routes events to SolidJS store updates:

  ┌──────────────────────────┬────────────────────────────────────────────────┐
  │ SSE Event                │ Store Update                                   │
  ├──────────────────────────┼────────────────────────────────────────────────┤
  │ server.instance.disposed │ re-run bootstrap() (full re-fetch)             │
  │ session.updated          │ upsert store.session[] (binary search by id)   │
  │ session.deleted          │ splice from store.session[]                     │
  │ session.status           │ store.session_status[sessionID] = status       │
  │ session.diff             │ store.session_diff[sessionID] = diff           │
  │ message.updated          │ upsert store.message[sessionID][]              │
  │                          │ (cap at 100 messages per session — evicts old) │
  │ message.removed          │ splice from store.message[sessionID][]         │
  │ message.part.updated     │ upsert store.part[messageID][]                 │
  │ message.part.removed     │ splice from store.part[messageID][]            │
  │ permission.asked         │ upsert store.permission[sessionID][]           │
  │ permission.replied       │ splice from store.permission[sessionID][]      │
  │ question.asked           │ upsert store.question[sessionID][]             │
  │ question.replied/rejected│ splice from store.question[sessionID][]        │
  │ todo.updated             │ store.todo[sessionID] = todos                  │
  │ lsp.updated              │ re-fetch lsp.status() → store.lsp             │
  │ vcs.branch.updated       │ store.vcs = {branch}                           │
  └──────────────────────────┴────────────────────────────────────────────────┘

  All store updates use Binary.search() for O(log n) sorted insertion/lookup.
  Events are batched in sdk.tsx (16ms debounce) for single-render updates.

  APP-LEVEL EVENT HANDLERS (app.tsx):
  ├─ session.deleted     → navigate(home) + toast if current session
  ├─ session.error       → toast (skip MessageAbortedError)
  ├─ installation.update-available → toast (10s duration)
  └─ TuiEvent.SessionSelect → navigate to session

                         ┌──────────────────────────────────────────────────────┐
                         │          LOCAL STATE MACHINE (local.tsx)             │
                         └──────────────────────────────────────────────────────┘

  Agent State:                      Model State:
  ┌────────────────┐                ┌─────────────────────────────┐
  │ agent.current   │                │ model.current (derived)     │
  │ (name: string)  │                │ = agent-specific override   │
  │                 │ ──triggers──>  │   ?? agent.model            │
  │ agent.list()    │  auto-update   │   ?? --model arg            │
  │ agent.move(±1)  │                │   ?? config.model           │
  │ agent.set(name) │                │   ?? first recent valid     │
  │ agent.color()   │                │   ?? first provider default │
  └────────────────┘                └─────────────────────────────┘
                                     model.set() / model.cycle()
                                     model.variant.cycle()
                                     model.favorite / model.recent
                                     (persisted to state/model.json)
```

### Buffer Registry

SSE dispatch uses two hash-table registries for O(1) buffer lookup:

| Registry | Key | Value | Defined in |
|----------|-----|-------|------------|
| `opencode--chat-registry` | session-id (string) | chat buffer | `opencode.el` |
| `opencode--sidebar-registry` | project-dir (normalized via `expand-file-name`) | sidebar buffer | `opencode.el` |

**Lifecycle:**
- **Register**: Chat buffers register in `opencode-chat-open` (after setting `opencode-chat--session-id`). Sidebar buffers register in `opencode-sidebar--get-or-create-buffer`.
- **Deregister**: Both use buffer-local `kill-buffer-hook` to deregister on kill.
- **Auto-cleanup**: Every lookup checks `buffer-live-p`. Dead buffers are auto-deregistered and return nil.
- **Reset**: Both registries are cleared in `opencode-cleanup`.

**Dispatch functions:**
- `opencode--dispatch-to-chat-buffer (session-id handler event)` — O(1) lookup, single buffer
- `opencode--dispatch-to-all-chat-buffers (handler event)` — iterates registered chat buffers only
- `opencode--dispatch-to-sidebar-buffer (project-dir handler event)` — O(1) lookup, single buffer
- `opencode--dispatch-to-all-sidebar-buffers (handler event)` — iterates registered sidebar buffers only

**Fallback**: Dispatch wrappers in `opencode-chat.el` and `opencode-sidebar.el` include inline `(buffer-list)` fallback paths for graceful degradation when registry functions are not yet loaded.

### CRITICAL: OpenCode Streaming via `message.part.updated`

OpenCode does NOT have a separate `message.part.delta` event.
Streaming uses `message.part.updated` with an OPTIONAL `delta` field:

- `message.part.updated` with `delta` field at properties level → streaming text chunk
- `message.part.updated` WITHOUT `delta` and WITH `part.time.end` → finalized part
- `message.part.updated` WITHOUT `delta` and WITHOUT `part.time.end` → bootstrap (empty part)

Streaming flow: `part.updated (empty)` → N × `part.updated (with delta)` → `part.updated (finalized with :end time)`

**CRITICAL: `message.updated` always arrives BEFORE `message.part.updated`** — The server guarantees this ordering. When a new assistant message is created, the `message.updated` event (with role, agent, model info) arrives first, followed by `message.part.updated` events for each part. This means the `on-message-updated` handler can cache the assistant message info (`opencode-chat--streaming-assistant-info`) before `on-part-updated` needs it for streaming bootstrap (Case 2). If `on-part-updated` fires without cached info, it constructs a minimal fallback — but this should never happen in practice due to the guaranteed ordering.

Properties structure for streaming: `{part: {sessionID, id, type, text, time}, delta: "chunk text"}`
Properties structure for finalized: `{part: {sessionID, id, type, text, time: {start, end}}}`

## Key API Endpoints

All requests require `Accept: application/json` header (without it, the SPA fallback returns HTML).
All session-scoped requests (`/session/:id/*`) require `X-OpenCode-Directory` header matching the project directory that created the session. The server hashes this header into a `projectID` to locate session storage on disk — a mismatched directory causes `NotFoundError` (silent 204 on `prompt_async`, empty responses on GET).

```
GET  /session                  List sessions
POST /session                  Create session
GET  /session/:id              Get session details
GET  /session/:id/message      Get messages (array of {info, parts})
POST /session/:id/prompt_async Fire-and-forget prompt (returns 204)
POST /session/:id/abort        Abort in-progress generation
GET  /session/:id/todo         Get session todos (read-only)
GET  /session/:id/diff         Get session diffs
POST /session/:id/revert       Revert changes (body: {messageID, partID})
POST /session/:id/summarize    Compact session history (triggered by /compact)
PATCH /session/:id             Rename session (triggered by /rename, body: {title})
GET  /agent                    List agents (fetched once on connect; cache-only after)
GET  /provider                 Provider info ({connected: [ids]})
GET  /config                   Server config (model, provider, plugins)
GET  /permission               List pending permissions
POST /permission/:id/reply     Reply to permission (body: {reply, message?})
GET  /question                 List pending questions
POST /question/:id/reply       Reply to question (body: {answers: [[...]]})
POST /question/:id/reject      Reject question
GET  /global/event              SSE stream (Accept: text/event-stream)
```

### PITFALL: `prompt_async` Requires `model` Field

Full request body as sent by the OpenCode web UI:

```json
{
  "agent": "build",
  "model": {"modelID": "claude-opus-4-6", "providerID": "anthropic"},
  "messageID": "msg_c70ee57f30018RbPxe9hupvVUW",
  "parts": [{"id": "prt_c70ee57f3002QUkrtmCS8JQzSY", "type": "text", "text": "hello again"}]
}
```

- `agent` and `model` are **required** — without `model`, the server returns 204 but silently does nothing (no error, no SSE events).
- `messageID` is the **new user message's own ID** (pre-generated client-side for optimistic UI). The server uses it as `id: input.messageID ?? Identifier.ascending("message")` when creating the user message record. The assistant message's `parentID` is then automatically set to this user message ID server-side. Optional — the server generates one if omitted. Format: `msg_<timestamp_hex><random_base62>` (30 chars), generated by `Identifier.ascending("message")`. In Emacs: `(opencode-util--generate-id "msg")`.
- `parts[].id` is optional but recommended — pre-generated client-side as `prt_<timestamp_hex><random_base62>`. In Emacs: `(opencode-util--generate-id "prt")`.
- The `"build"` agent is `"native": true` and `"mode": "primary"` — do NOT filter out native agents when selecting the agent for `prompt_async`.

### CRITICAL: Message/Part ID Generation and Ordering

**Why generate IDs client-side?** The server uses timestamp-embedded IDs for message ordering. If a client sends a message with an ID whose timestamp is older than the latest message in the session, **the server silently ignores it** (no error, no SSE events). This prevents race conditions and duplicate processing.

**ID Format**: `<prefix>_<12 hex timestamp><14 base62 random>` (30 chars total)

```
msg_c70ee57f30018RbPxe9hupvVUW
│   │            │
│   │            └─ 14 random base62 chars (collision avoidance)
│   └─ 12 hex chars = (milliseconds × 4096) & 0xFFFFFFFFFFFF
└─ prefix: "msg" for messages, "prt" for parts
```

**Timestamp encoding**: The server computes `(Date.now() * 4096 + counter) & 0xFFFFFFFFFFFF`. Multiplying by 4096 (2^12) shifts the millisecond timestamp left by 12 bits, leaving the lower 12 bits for a per-prefix counter. This allows up to 4096 ordered IDs per millisecond per prefix:

```
msg_c70ee57f3001...  ← ms * 4096 + 1 (first msg this ms)
msg_c70ee57f3002...  ← ms * 4096 + 2 (second msg this ms)
prt_c70ee57f3001...  ← ms * 4096 + 1 (first prt this ms, separate counter)
```

The counter resets each millisecond. This ensures strict ordering even for rapid-fire ID generation.

**Emacs implementation** (`opencode-util.el`):

```elisp
(defvar opencode-util--id-counter 0)
(defvar opencode-util--id-last-ms 0)

(defun opencode-util--generate-id (&optional prefix)
  "Generate ID matching OpenCode server format.
PREFIX is \"msg\" or \"prt\"."
  (let* ((ms (floor (* (float-time) 1000))))
    ;; Reset or increment counter based on millisecond
    (if (= ms opencode-util--id-last-ms)
        (setq opencode-util--id-counter (1+ opencode-util--id-counter))
      (setq opencode-util--id-last-ms ms
            opencode-util--id-counter 0))
    (let* ((timestamp-val (logand (+ (* ms 4096) opencode-util--id-counter)
                                  #xFFFFFFFFFFFF))
           (time-hex (format "%012x" timestamp-val))
           (random-suffix (opencode-util--random-string 14)))
      (if prefix
          (format "%s_%s%s" prefix time-hex random-suffix)
        (format "%s%s" time-hex random-suffix)))))

;; Usage:
(opencode-util--generate-id "msg")  ; → "msg_c70ee57f30018RbPxe9hupvVUW"
(opencode-util--generate-id "prt")  ; → "prt_c70ee57f3002QUkrtmCS8JQzSY"
```

**When to generate**:
- Generate `messageID` immediately before calling `prompt_async` — never cache/reuse
- Generate `parts[].id` for each part in the same request
- Stale IDs (from minutes/hours ago) will be silently rejected

**Failure mode**: If you see `prompt_async` return 204 but no SSE events arrive and the message doesn't appear, check:
1. Is `model` field present? (most common cause)
2. Is the `messageID` freshly generated? (stale ID = silent rejection)
3. Is `X-OpenCode-Directory` header correct for this session?

### Quick API test script

```bash
#!/usr/bin/env bash
# Save as test-api.sh — poke a running OpenCode server
HOST="http://127.0.0.1:4096"
DIR="/Users/$(whoami)/your-project"
H=(-H "Accept: application/json" -H "Content-Type: application/json" -H "X-OpenCode-Directory: $DIR")

# Health check
curl -s "${H[@]}" "$HOST/global/health" | python3 -m json.tool

# List sessions
curl -s "${H[@]}" "$HOST/session?limit=3" | python3 -m json.tool

# Get agent info (find model for prompt_async)
curl -s "${H[@]}" "$HOST/agent" | python3 -c "
import json,sys
for a in json.load(sys.stdin):
  if a.get('mode')=='primary' and a.get('model'):
    print(json.dumps({'name':a['name'],'model':a['model']},indent=2))
    break"

# Send a message (replace SES_ID)
# curl -s "${H[@]}" -X POST "$HOST/session/SES_ID/prompt_async" \
#   -d '{"parts":[{"type":"text","text":"hello"}],"agent":"AgentName","model":{"modelID":"claude-opus-4-6","providerID":"anthropic"}}'
# Returns: 204 No Content (track response via SSE)

# Watch SSE events (Ctrl-C to stop)
# curl -s -N -H "Accept: text/event-stream" "$HOST/global/event"
```

### Example: Real API response shapes

**`GET /config`** — Server configuration (model in `"provider/model-id"` format):
```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-anthropic-auth@latest"],
  "model": "anthropic/claude-opus-4-6",
  "small_model": "MyCodeX/gpt-5.2",
  "provider": {},
  "mcp": {}
}
```

**`GET /agent`** — Agent list (native agents have no model; custom agents may):
```json
[
  {"name": "build", "description": "The default agent. Executes tools based on configured permissions.", "mode": "primary", "native": true},
  {"name": "plan", "description": "Plan mode. Disallows all edit tools.", "mode": "primary", "native": true},
  {"name": "general", "description": "General-purpose agent for researching complex questions...", "mode": "subagent", "native": true},
  {"name": "explore", "description": "Fast agent specialized for exploring codebases...", "mode": "subagent", "native": true},
  {"name": "compaction", "mode": "primary", "native": true, "hidden": true},
  {"name": "title", "mode": "primary", "native": true, "hidden": true},
  {"name": "summary", "mode": "primary", "native": true, "hidden": true}
]
```

**`GET /provider`** — Provider info:
```json
{
  "connected": ["anthropic", "opencode"],
  "all": [{"id": "anthropic", "models": {"claude-opus-4-6": {...}, ...}}, ...]
}
```

**`GET /session?limit=1`** — Session list:
```json
[{
  "id": "ses_38f602d51ffeEq4Be9q7n3K24U",
  "slug": "tidy-orchid",
  "projectID": "40ded7c65dd84f0064adae7391c0a746d66564c5",
  "directory": "/Users/bytedance/Documents/opencode.el",
  "title": "New session - 2026-02-18T12:00:48.303Z",
  "version": "1.2.6",
  "summary": {"additions": 43, "deletions": 30, "files": 4},
  "time": {"created": 1771416048303, "updated": 1771421611660}
}]
```

**`GET /session/:id/message`** — Message with parts:
```json
[{
  "info": {
    "id": "msg_c70ee5813001XR4QNtXtWXexq2",
    "sessionID": "ses_38f33901bffeVim2YChvQJMWwu",
    "role": "assistant",
    "parentID": "msg_c70ee57f30018RbPxe9hupvVUW",
    "modelID": "claude-opus-4-6", "providerID": "anthropic",
    "agent": "build", "mode": "build",
    "time": {"created": 1771421194259, "completed": 1771421196891},
    "cost": 0, "tokens": {"total": 17689, "input": 3, "output": 12, "reasoning": 0,
      "cache": {"read": 17640, "write": 34}},
    "finish": "stop",
    "path": {"cwd": "/Users/bytedance/Documents/opencode.el", "root": "/Users/bytedance/Documents/opencode.el"}
  },
  "parts": [
    {"id": "prt_c70ee6152001yU5fdc4dAOb1zG", "type": "step-start", "snapshot": "88147a8e..."},
    {"id": "prt_c70ee6153001W1Ttn8zL167Dhz", "type": "text", "text": "Hey! What can I do for you?",
     "time": {"start": 1771421196771, "end": 1771421196771}},
    {"id": "prt_c70ee6218001iuChFiU94H7Snp", "type": "step-finish", "reason": "stop",
     "cost": 0, "tokens": {"total": 17689, "input": 3, "output": 12, "reasoning": 0,
       "cache": {"read": 17640, "write": 34}}}
  ]
}]
```

**Tool parts** — nested `state` plist with `status`, `input`, `output`:
```json
{"id": "prt_...", "type": "tool", "tool": "bash", "callID": "toolu_...",
 "sessionID": "ses_...", "messageID": "msg_...",
 "state": {
   "status": "completed",
   "input": {"command": "make compile 2>&1", "description": "Byte-compile"},
   "output": "No warnings\n"
 }}
```

**CRITICAL**: Tool parts use `:tool` for the name (NOT `:toolName`), and `:state` is a **plist** (NOT a string). The `:state` contains `:status` (string: "pending"/"running"/"completed"/"error"), `:input` (plist of tool args), and `:output` (string result). Different tools have different input keys:
- `bash`: `{command, description, workdir, timeout}`
- `read`/`write`: `{filePath, ...}`
- `edit`: `{filePath, oldString, newString}`
- `glob`/`grep`: `{pattern, path, include}`
- `task`: `{category, description, prompt, ...}`

**Note**: Timestamps are in **milliseconds** (> 1e12). Divide by 1000 for `seconds-to-time`.

### Example: Real SSE event stream

Captured from `curl -N -H "Accept: text/event-stream" http://127.0.0.1:4096/global/event` during a `prompt_async "reply with exactly: hello world"`:

```
data: {"payload":{"type":"server.connected","properties":{}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.updated","properties":{"info":{"id":"msg_c709b987f001...","sessionID":"ses_38f646bdbffe...","role":"user","time":{"created":1771415771263},"agent":"build","model":{"providerID":"anthropic","modelID":"claude-opus-4-6"}}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709b9875002...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b9875001...","type":"text","text":"reply with exactly: hello world"}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"session.status","properties":{"sessionID":"ses_38f646bdbffe...","status":{"type":"busy"}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.updated","properties":{"info":{"id":"msg_c709b98820010...","sessionID":"ses_38f646bdbffe...","role":"assistant","time":{"created":1771415771266},"parentID":"msg_c709b987f001...","modelID":"claude-opus-4-6","providerID":"anthropic","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be09e001...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"step-start","snapshot":"8edaa204d6d3..."}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be0a0001...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"text","text":"","time":{"start":1771415789728}}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be0a0001...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"text","text":"hello","time":{"start":1771415789728}},"delta":"hello"}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be0a0001...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"text","text":"hello world","time":{"start":1771415789728}},"delta":" world"}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be0a0001...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"text","text":"hello world","time":{"start":1771415789728,"end":1771415789728}}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.part.updated","properties":{"part":{"id":"prt_c709be0a00024...","sessionID":"ses_38f646bdbffe...","messageID":"msg_c709b98820010...","type":"step-finish","reason":"stop","cost":0,"tokens":{"total":28332,"input":3,"output":5,"reasoning":0,"cache":{"read":16594,"write":11730}}}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"message.updated","properties":{"info":{"id":"msg_c709b98820010...","sessionID":"ses_38f646bdbffe...","role":"assistant","time":{"created":1771415771266,"completed":1771415789775},"cost":0,"tokens":{"total":28332,"input":3,"output":5,"reasoning":0,"cache":{"read":16594,"write":11730}},"finish":"stop"}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"session.status","properties":{"sessionID":"ses_38f646bdbffe...","status":{"type":"idle"}}}}

data: {"directory":"/Users/bytedance/Documents/opencode.el","payload":{"type":"session.idle","properties":{"sessionID":"ses_38f646bdbffe..."}}}

data: {"payload":{"type":"server.heartbeat","properties":{}}}
```

**Parsing note**: There is no SSE `event:` field — only `data:`. The event type is inside the JSON payload as `type`. Our `opencode-sse--dispatch-event` extracts `type` from the parsed JSON.

**Global vs Instance events**: Use `GET /global/event` (NOT `/event`). Global events wrap
the payload in `{"directory": "...", "payload": {"type": "...", "properties": {...}}}`.
The `directory` field identifies which project the event belongs to. Server-level events
(like `server.connected` and `server.heartbeat`) have no `directory` field.

**Full streaming lifecycle**:
1. `server.connected` — initial handshake
2. `message.updated(role:user)` — user message created
3. `message.part.updated(text:"reply with...")` — user's text part
4. `session.status(busy)` — generation begins
5. `message.updated(role:assistant)` — assistant message created (empty)
6. `message.part.updated(step-start)` — step begins
7. `message.part.updated(text:"")` — empty text part (bootstrap)
8. N × `message.part.updated(delta:"hello")` — **streaming text chunks** (delta at properties level)
9. `message.part.updated(text:"hello world", end:...)` — finalized text part
10. `message.part.updated(step-finish, tokens:...)` — step with cost/tokens
11. `message.updated(completed:..., finish:"stop")` — assistant message finalized
12. `session.status(idle)` + `session.idle` — generation complete

## Per-Project Sidebar

Each project gets its own sidebar buffer showing all sessions with expandable file diffs.
The sidebar is treemacs-based and auto-refreshes via SSE events scoped to the project directory.

### Quick Start

```elisp
;; Toggle the sidebar for the current project:
M-x opencode-window-toggle-sidebar

;; Or bind it:
(keymap-set opencode-mode-map "C-c C-s" #'opencode-window-toggle-sidebar)
```

### Sidebar Keybindings

| Key | Command | Description |
|-----|---------|-------------|
| `RET` | `opencode-sidebar--ret-wrapper` | Open session chat / view file diff |
| `TAB` | `opencode-sidebar--toggle-node` | Expand/collapse session node |
| `g` | `opencode-sidebar--refresh` | Refresh session list from server |
| `c` | `opencode-sidebar--new-session` | Create new session and open chat |
| `d` | `opencode-sidebar--delete-session` | Delete session at point |
| `R` | `opencode-sidebar--rename-session` | Rename session at point |
| `w` | `opencode-sidebar--set-width` | Resize sidebar width |
| `q` | `opencode-sidebar--quit` | Close sidebar window |

### Per-Project Buffer Isolation

Sidebar buffers are named per-project: `*opencode: sidebar</absolute/project/path>*`.
SSE events are filtered by the `directory` field — each sidebar only refreshes when
events arrive for its project. This means multiple projects can have independent sidebars.

```
Project A (/path/to/A)  ->  *opencode: sidebar</path/to/A>*  ->  sessions for A only
Project B (/path/to/B)  ->  *opencode: sidebar</path/to/B>*  ->  sessions for B only
```

### Sidebar Tree Structure

```
v Session: "Fix login bug" (ses_abc...)     <- session node
    src/auth.ts  +12 -3                      <- file diff node
    src/login.ts  +5 -1                      <- file diff node
> Session: "Add dark mode" (ses_def...)      <- collapsed session
```

- **Session nodes** show title + truncated session ID. RET opens the chat buffer.
- **File diff nodes** show filename + additions/deletions summary. RET opens the diff view.
- The tree auto-refreshes on `session.idle` and `session.updated` SSE events.

### Window Layout

The sidebar always appears on the **left** side (slot -1, width 35 columns),
separate from chat windows which use `opencode-window-display` settings:

```elisp
;; Sidebar: always left, 35 cols (hardcoded in opencode-window-toggle-sidebar)
(display-buffer-in-side-window buf '((side . left) (slot . -1) (window-width . 35)))

;; Chat: configurable via defcustom
(setq opencode-window-display 'side)   ; side | float | split | full
(setq opencode-window-side 'right)     ; left | right | bottom
(setq opencode-window-width 80)        ; columns
```

## Sub-Agent (Child Session) Architecture

OpenCode supports sub-agents: child sessions spawned by a parent session's `task` tool call.
Each child session has a `:parentID` field linking it to its parent.

### Key Concepts

- **Parent session**: A normal chat session that spawns sub-agents via the `task` tool
- **Child session**: A session with `:parentID` set; users can send messages to the sub-agent
- **Task tool part**: A tool part with `"tool": "task"` and optional `metadata.sessionId` pointing to the child session

### Helper Functions (`opencode-chat.el`)

```elisp
(opencode-chat--child-session-p)          ; Non-nil if buffer-local session has :parentID
(opencode-chat--parent-session-id)        ; Returns :parentID from buffer-local session
(opencode-chat--child-sessions session-id) ; Returns child sessions of SESSION-ID from server
(opencode-chat--session-parent-id sid)    ; Fetches :parentID for SID via opencode-session-get
```

### Child Session Buffer

Child session buffers have full input areas — users can send messages to sub-agents:

```
[Sub-agent]  ← header badge (opencode-chat--header-line)


... messages ...

─────────────────────────────────────
Sub-agent session  [Parent]  ← footer indicator
```

Key implementation details:
- Child sessions render the SAME input area as normal sessions (can send messages)
- An additional indicator line "Sub-agent session [Parent]" is appended below the input
- `opencode-chat--render-child-indicator` handles the indicator rendering
- `opencode-chat-goto-parent` navigates back to the parent session
- `opencode-chat--quit-or-goto-parent` checks `opencode-chat--child-session-p` for dispatch

### Navigation (Parent ↔ Child)

All parent↔child navigation replaces the current window (no new splits):

```elisp
;; opencode-chat-open accepts optional display-action:
(opencode-chat-open session-id directory 'replace)
;; → (pop-to-buffer buf '(display-buffer-same-window))

;; Callers that pass 'replace:
;;   - [Open Sub-Agent] button in task tool rendering
;;   - opencode-chat-goto-parent (bound to q in child-mode)
;;   - [Parent] button in child session footer

;; Callers that do NOT pass display-action (sidebar, session list):
;;   - Default (pop-to-buffer buf) behavior unchanged
```

### Task Tool Rendering

Task tool parts render an `[Open Sub-Agent]` button when `metadata.sessionId` is present:

```
▶ task [completed]
   3 tool calls
   model: claude-opus-4-6
   [Open Sub-Agent]
```

The button action: `(opencode-chat-open child-session-id directory 'replace)`

### Permission/Question Bubbling

Popup dispatch is driven by `opencode--dispatch-popup-event', which walks the **global** child→parent cache (`opencode-chat-message--child-parent-cache') using union-find with path compression.  The dispatcher sends the event to the originating session's buffer (if open) AND to the root parent buffer, so the popup appears in both places and is dismissed together.

Two guards keep this safe:

1. **`opencode-chat-message--max-session-depth` (default 8)** — `find-root-session' walks at most this many hops before giving up and breaking the offending cache link.  Guards against corrupted server metadata creating cycles (`A → B → A`).
2. **`opencode--dispatch-popup-max-walk` (default 8)** — the async retry loop (which fetches `/session/:id` one level at a time on cache miss) bails at this depth.  A `depth` argument is threaded through each recursive call.

The cache is populated in **three** places — keep all three in sync:

- `opencode-chat--set-session` — called whenever a session plist with `:parentID' is installed on a buffer (the most common, proactive path).
- Task tool rendering in `opencode-chat-message.el' — when a parent's task tool part mentions a child session ID.
- `opencode--dispatch-popup-event' — async walk when the cache is cold.

When a popup is answered, the buffer that owns the answer MUST purge duplicates from every OTHER buffer's `--pending' queue — otherwise `opencode-popup--cleanup' will `show-next' a stale duplicate.  Use the dedicated helpers in `opencode-popup.el':

```elisp
;; Remove all requests with :id REQUEST-ID from the PENDING-SYM queue
;; in every live buffer.
(opencode-popup--purge-pending-by-id 'opencode-permission--pending request-id)

;; Dismiss any displayed popup with that :id in every live buffer, running
;; CLEANUP-FN inside the matching buffer.
(opencode-popup--dismiss-current-in-all-buffers
  'opencode-permission--current request-id
  (lambda () ...cleanup code...))
```

**DO NOT** re-roll a bare `(dolist (buf (buffer-list)) ...)` purge loop in `permission.el' or `question.el'.  Those duplicated loops drift; consolidate into the shared helpers above.

```elisp
;; opencode-popup.el: find-chat-buffer with parent fallback
(defun opencode-popup--find-chat-buffer (request)
  ;; 1. Try exact match by :sessionID
  ;; 2. If not found, check opencode-chat-message-child-parent-get (in-memory cache)
  ;; 3. Fall back to opencode-chat--session-parent-id (sync HTTP)
  ;; 4. Return parent buffer if found
  ...)

;; opencode-chat--drain-popup-queue also matches child requests:
;; Processes queued permissions/questions for child sessions in the parent buffer
```

### Sidebar Nesting

Child sessions appear as sub-nodes under their parent in the sidebar:

```
v Session: "Parent Task" (ses_abc...)
    ▶ Sub-agent: "Sub-agent" (ses_child...)   ← child session node
> Session: "Other Task" (ses_def...)
```

- `opencode-sidebar-session-limit` defcustom (default 100) controls max sessions: fetched
- Root session list filters out child sessions (`seq-remove` by `:parentID`)
- Child nodes expand to show their own file diffs

### Common Mistakes

22. **Text-property keymaps override minor-mode keymaps** — In Emacs's keymap lookup chain, text-property `'keymap` has HIGHER priority than minor-mode keymaps. The `opencode-chat-message-map` (applied via text property on all rendered message text) will always shadow bindings. Fix: Use a dispatcher function (`opencode-chat--quit-or-goto-parent`) in the text-property keymap that checks `opencode-chat--child-session-p` and routes to either `opencode-chat-goto-parent` or `quit-window`.

23. **Child sessions are fully editable and support message sending** — Child sessions render the same input area as normal sessions and users can send messages to the sub-agent. They have an additional indicator line "Sub-agent session [Parent]" below the input, rendered by `opencode-chat--render-child-indicator`. The indicator uses text-property `read-only` to protect itself; the buffer itself is NOT `buffer-read-only`.
24. **`opencode-chat-open` display-action is opt-in** — Callers that don't pass `display-action` (sidebar, session list) get the default `(pop-to-buffer buf)` behavior. Only navigation callers (task tool button, `[Parent]` button, `q` via `goto-parent`) pass `'replace`. Never change the default behavior.
25. **`opencode-popup--find-chat-buffer` needs `declare-function`** — The popup module calls `opencode-chat--session-parent-id` (defined in `opencode-chat.el`) without requiring it. Add `(declare-function opencode-chat--session-parent-id "opencode-chat")` to `opencode-popup.el` to avoid byte-compile warnings without creating a circular require.

26. **`opencode-chat--messages-end` must be nil during `render-messages` re-render** — The `render-edit-body` function calls `opencode-diff--fetch` → `opencode-api-get-sync` → `url-retrieve-synchronously`, which internally loops on `accept-process-output`. This allows the SSE curl process filter to fire DURING `render-messages`, causing `apply-streaming-delta` to run with a stale `messages-end` marker (pointing to position 1 after `erase-buffer`). Result: streaming text inserts after the input area. Fix: set `opencode-chat--messages-end` to nil immediately after `erase-buffer` in `render-messages`, BEFORE the rendering loop. This forces any re-entrant SSE delta to hit Case 3 (no marker → `schedule-refresh`) instead of inserting at a garbage position. The marker is properly re-created later at the correct position.

27. **Tool input summary should prioritize `$ command` over description for bash** — The tool header (collapsed view) for bash tools should show the actual command being run (prefixed with `$`), not just the description. Users need to see what command executed at a glance. Description is the fallback when command is nil. Similarly, grep tool summaries should include the `:include` file glob filter (e.g. `"*.el"`) when present, formatted as `pattern  in: path  [*.el]`.

28. **Agent/provider resolution in `state-init`** — `opencode-chat--state-init` resolves agent/model/provider from message history first (last assistant message), then config defaults, then first available. History values are trusted without re-validation (server already used them). No "preserve existing state" for agent/model — refresh always re-resolves. Forward-declares `opencode-chat--messages` with `defvar` to avoid require cycle.

29. **Broadcast SSE events must not refresh hidden buffers** — `server.instance.disposed` is broadcast to ALL registered chat buffers via `opencode--dispatch-to-all-chat-buffers`. If N chat buffers are open but hidden (e.g. user switched to another buffer), each fires an async `opencode-chat--refresh` → 2N HTTP requests (messages + session) that nobody sees. Fix: check `(get-buffer-window (current-buffer))` in the handler. Visible buffers refresh immediately; hidden buffers call `(opencode-chat--mark-stale)` which sets `opencode-chat--refresh-state` to `'stale' and defer to the `window-buffer-change-functions` hook (`opencode-chat--on-window-buffer-change`) which refreshes when the buffer becomes visible. `opencode-chat--refresh` itself clears the stale bit by transitioning through `'in-flight'.

30. **Async refresh needs a state machine, not three independent flags** — `opencode-chat--refresh` fires two chained async HTTP requests (messages → session → render). Without coordination, rapid SSE events (e.g. multiple `schedule-refresh` timers firing, `session.idle` + `session.compacted` arriving simultaneously) cause N overlapping request chains (2N HTTP requests racing), potentially rendering stale data over fresh data. Fix: a single buffer-local variable `opencode-chat--refresh-state` is a four-value state machine (`nil`, `'stale`, `'in-flight`, `'in-flight-pending`). All transitions go through `opencode-chat--mark-stale`, `opencode-chat--refresh-begin`, `opencode-chat--refresh-end`, and `opencode-chat--force-clear-refresh-guard` — **never** setq the var directly. `--refresh-begin` returns non-nil only when a new fetch should actually fire; `--refresh-end` returns non-nil when the pending flag requires a retry (at which point the caller re-invokes `--refresh`, which transitions `nil → in-flight`). At most two HTTP request chains can overlap (current + one retry). The state is hard-reset by `--force-clear-refresh-guard` in `on-session-idle`, `on-session-error`, `on-session-compacted`, and `on-server-instance-disposed` so a lost callback can never permanently lock out refreshes. The `schedule-refresh` debounce timer is the first line of defense (coalesces rapid events into one call); the state machine is the second (prevents overlapping HTTP chains when debounce isn't enough).

31. **Agent cache is fetch-once, invalidate-on-SSE-only** — `opencode-agent.el` uses a manual cache (`opencode-agent--cache`) with NO TTL and NO periodic timer. The cache is populated on first access (`opencode-agent--ensure-cache`) and invalidated only by SSE rebootstrap (`opencode-agent-invalidate` called from `opencode-sse--do-rebootstrap` / `opencode-refresh`). All consumers (`opencode-api--fetch-agent-info`, `opencode-api--valid-agent-p`, `opencode-chat--cycle-agent`, agent color/list functions) read from cache — never HTTP. The removed `opencode-api--valid-agent-names` variable was a redundant parallel cache; all validation now goes through `opencode-agent--find-by-name`. Data flow: first connect → `ensure-cache` → `GET /agent` → cache populated. SSE rebootstrap → `invalidate` (sets cache nil) → next access re-fetches. All other access → cache hit (zero HTTP).

32. **Refresh must skip during busy state** — `opencode-chat--refresh` fetches `GET /session/:id/message` which is slow when the server is actively streaming (it waits for the current tool to finish). Calling refresh during busy state freezes Emacs for seconds. Fix: `opencode-chat--refresh` checks `opencode-chat--busy` first. If busy, it calls `(opencode-chat--mark-stale)` which sets `opencode-chat--refresh-state` to `'stale` and returns immediately. The deferred refresh happens on `session.idle` (via `--force-clear-refresh-guard` + a normal refresh call). This busy guard also protects against `server.instance.disposed` events that arrive mid-streaming — the disposed handler preserves the busy flag so the subsequent rebootstrap refresh hits the guard.

33. **Popup `find-chat-buffer` must use child-parent cache, not sync HTTP** — When a permission/question arrives for a child session that has no open buffer, `opencode-popup--find-chat-buffer` needs the parent session ID. Uses `opencode-chat-message-child-parent-get` (in-memory cache lookup via `opencode-chat-message.el`, populated by task tool rendering) first. Only falls back to `opencode-chat--session-parent-id` (synchronous HTTP) on cache miss. The cache is buffer-local on the parent chat buffer, owned by the message module.

34. **SSE rebootstrap must not issue sync HTTP** — `opencode-sse--do-rebootstrap` originally called `opencode-agent-fetch` (sync `GET /agent`) during SSE event handling. Since the SSE process filter runs inside `accept-process-output`, a sync HTTP call blocks Emacs until completion. Fix: call `opencode-agent-invalidate` (sets cache to nil, zero cost) instead. Lazy re-fetch happens on next access via `opencode-agent--ensure-cache`. Also call `opencode-chat--refresh` directly (which has the busy guard) instead of `schedule-refresh` (debounced timer that bypasses the guard).

35. **Popup pipeline needs input-area-valid-p guard** — Four bugs in the permission/question popup pipeline: (1) `opencode-popup--save-input` calls `opencode-chat--input-text` which accesses `opencode-chat--input-start` — nil in child sessions (no input area), causing crash. (2) `opencode-popup--drain-popup-queue` popped the first queue item regardless of session match, causing cross-session deadlock. (3) Error in `opencode-popup--save-input` left `opencode-popup--inline-p` stuck at t. (4) `opencode-popup--restore-input` ran in wrong buffer when `opencode-popup--rendered-buffer` was stale. Fix: `opencode-popup--input-area-valid-p` guard checks marker validity before any input area access. `opencode-popup--show-matching` pops the correct item by session ID. `condition-case` wraps save-input with cleanup on error. `opencode-popup--rendered-buffer` tracks which buffer actually rendered the popup.

36. **Image paste requires data URL encoding and chip lifecycle management** — Clipboard images are captured via `gui-get-selection` (CLIPBOARD target, image/png or image/jpeg MIME). Images are base64-encoded into data URLs for the prompt body. Each pasted image creates a "chip" overlay in the input area with `opencode-image-data` overlay property linking to `opencode-chat--pending-images`. Chip deletion (backspace, C-w, modification hooks) must call `opencode-chat--image-chip-on-delete` to remove the corresponding entry from `opencode-chat--pending-images`, preventing stale image data from being sent. The API layer (`opencode-api--prompt-body`) converts images to `{type: "image", source: {type: "base64", ...}}` parts in the prompt body. Max image size is controlled by `opencode-chat-image-max-size` defcustom (default 10 MB). Keybinding: `C-c C-v` in the input area.

37. **Tests MUST NOT make real HTTP/network calls** — Any test that calls functions which internally perform HTTP requests (e.g. `opencode-server--stop` sends `POST /global/dispose`) MUST stub the network layer with `cl-letf`. A test that sets `opencode-server--port` to 4096 and calls `opencode-server--stop` without stubbing `url-retrieve-synchronously` will send a real `POST http://127.0.0.1:4096/global/dispose` — **killing any running OpenCode server**. The 5-second test duration is the HTTP timeout, not slow logic. Fix: wrap with `(cl-letf (((symbol-function 'url-retrieve-synchronously) (lambda (&rest _) nil))) ...)`. Audit checklist for new tests: grep for `url-retrieve`, `url-retrieve-synchronously`, `make-network-process`, `open-network-stream`, and any function that internally calls these (like `opencode-server--stop`, `opencode-api--request`). If found without a stub, the test is dangerous.

38. **Message-level state lives in `opencode-chat-message.el`, not `opencode-chat.el`** — After the extraction refactor, all message rendering state (`--store`, `--messages-end`, `--diff-cache`, `--diff-shown`, `--section-overlay-map`, `--current-message-id`, `--streaming-msg-id`, `--streaming-fontify-timer`, `--streaming-region-start`, `--child-parent-cache`, `--tool-renderers`) is defined in `opencode-chat-message.el`. Chat.el accesses these through the public API (`opencode-chat-message-*` functions). Do NOT add `defvar-local` for these vars back into chat.el — they are available via `(require 'opencode-chat-message)`. The only streaming var that stays in chat.el is `--streaming-assistant-info` (SSE routing state, not message state). Similarly, all input-related state (`--input-start`, `--input-history`, `--input-history-index`, `--input-history-saved`, `--mention-cache`) lives in `opencode-chat-input.el`. **The `--store` hash table is the single source of truth for a message** — each entry is a plist `(:msg MSG :overlay OV :parts PARTS-HASH :diff DIFF)`, and `opencode-chat-message-info' / `opencode-chat-message-sorted-ids' traverse it for cold-start operations like `opencode-chat--recompute-cached-tokens-from-store' (O(N) in messages — use the `-from-event' variant for per-SSE updates).

39. **@-mention `search-backward "@"` must skip existing chip overlays** — Both `mention-capf` and `mention-exit` search backward for the `@` character that triggered the current completion. If an earlier `@mention` chip exists in the input area (e.g. `@test/`), a naive `(search-backward "@")` finds the `@` inside the chip instead of the one the user just typed. This causes the second chip to cover the wrong region, produce incorrect text (e.g. `test/fixtures/` instead of `@test/fixtures/`), or fail entirely. Fix: use `opencode-chat--search-backward-at-sign` which loops `search-backward "@"` and skips positions covered by an `opencode-mention` overlay. The helper is used in both `mention-capf` (to find the CAPF trigger point) and `mention-exit` (to find where to create the chip). Scenario test: `opencode-scenario-mention-sequential-folder-chips` verifies two sequential folder mentions each produce their own chip with correct text.

40. **`opencode-chat--input-start` marker MUST be cleared before `erase-buffer` in `render-messages`** — The buffer-local `after-change-functions` hook `opencode-chat--input-after-change` rewrites the `keymap` text property to `opencode-chat-input-map` on any change region whose `beg >= opencode-chat--input-start`.  After `erase-buffer`, the marker collapses to point-min, so every subsequent insert during `render-all` is seen by the hook as "inside the input area" and its keymap is forcibly clobbered.  The visible symptom was: RET on an edit tool's clickable file path fell through to `newline` after a full refresh.  Fix: `opencode-chat--render-messages` calls `(set-marker opencode-chat--input-start nil)` and `(setq opencode-chat--input-start nil)` immediately after `erase-buffer`, before `render-all`.  `render-input-area` later re-initializes the marker at the correct position.

41. **`opencode-chat--apply-message-props` must not overwrite sub-region keymaps** — The edit tool body sets its own `keymap` text property (`opencode-chat-message-file-map') so RET opens the edited file.  `apply-message-props' is called over the full message region at the end of `render-messages' and per-message in `insert-message-at-end'; if it blanket-`put-text-property'd `keymap', the file-map would be wiped.  The canonical opt-out is the `opencode-file-path' text property: `apply-message-props' walks `next-single-property-change' on `opencode-file-path' and only assigns `opencode-chat-message-map' to ranges that DO NOT have the file-path property.  Any new click-able sub-region must set `opencode-file-path' (or a similar opt-out property wired through `apply-message-props').  Do NOT use the `keymap-parent' trick — that was a failed patch-on-patch attempt (see commit that removed `opencode-chat-message--ensure-file-map-parent').

42. **Server status popup (`M-x opencode-server-status`)** — lives in `opencode-status.el' and shows MCP, LSP, and Formatter sections with navigable rows.  Rendering goes through `opencode-status--render-entry' (one shared row renderer) + three per-type helpers (`--render-mcp-entry', `--render-lsp-entry', `--render-formatter-entry') to avoid the 3× copy-paste that first-draft implementations fall into.  HTTP calls are synchronous via `opencode-api-get-sync' / `opencode-api-post-sync' because the popup is opened interactively and the blocking cost is bounded to one round-trip.  `SPC` on an MCP row toggles connect/disconnect; LSP and formatter rows are read-only.

43. **@-mention fuzzy matching is built into the completion table, not `completion-styles`** — `opencode-chat--mention-completion-table` implements its own fuzzy filtering in the `t` (all-completions) and `nil` (try-completion) actions, so `@thislngtxt` matches `this/is/a/longlongpath/file.txt` regardless of the user's `completion-styles` or completion frontend (corfu, vertico, company, default). Two match modes: (1) **single-segment** — scattered subsequence matching across the full candidate string (`opencode-chat--fuzzy-substr-p`); (2) **path-segment** — when input contains `/`, splits on `/` and matches each segment against the candidate's path components in order, with gaps allowed (`@this/file.txt` → `this/is/a/longlongpath/file.txt`). Scoring (`opencode-chat--mention-fuzzy-score`) ranks exact-prefix > contiguous-substring > scattered, with shorter candidates ranked higher. The `completion-category-overrides` with `(styles basic partial-completion flex)` is kept as a fallback for edge cases and slash-command completion.

44. **Sidebar child nodes MUST use `:async? t`** — `treemacs-update-async-node` (called during re-entry when a parent async node is updated via `treemacs-update-node`) invokes the `:children` function of ALL expanded descendants with 3 args `(btn item callback)`, regardless of whether the child extension itself has `:async?` set.  If a child node type is defined without `:async? t`, its children lambda only accepts 2 args → `wrong-number-of-arguments` error → `treemacs-update-node` silently fails → sidebar stops updating entirely (no new sessions appear, `g` refresh does nothing).  Fix: `opencode-sidebar-child` must use `:async? t` and call `(funcall callback items)` even though the computation is synchronous.  This is a treemacs design flaw (it should check `treemacs-extension->async?` before passing the callback arg), but we must work around it.

45. **`opencode-popup--find-chat-buffer` must prefer `current-buffer`** — When `--show` is called from `--show-next` or `--drain-queue`, the current buffer IS the target (popup events are dispatched per-buffer, pending queues are buffer-local).  Re-looking-up by `:sessionID` in the request finds the CHILD session's buffer — even when the popup was dispatched to the PARENT buffer — causing the popup to render in the wrong place or silently fail.  Fix: `find-chat-buffer` checks if `current-buffer` is a chat buffer first (via `opencode-chat--state` being non-nil) and returns it directly; only falls back to session-id lookup when called outside a chat buffer context (standalone show, tests, etc.).

46. **`url-request-data` and every `url-request-extra-headers` value MUST be unibyte (Bug#23750)** — `url-http-create-request' builds the outgoing request by `concat'ing the header block with `url-http-data' and then asserts `(= (string-bytes request) (length request))'.  The assertion is a proxy for "this string is unibyte".  If ANY piece — a header value, the body, a user-agent fragment — is multibyte, `concat' promotes the whole request to multibyte, the byte/length counts disagree, and url.el signals `"Multibyte text in HTTP request"'.  A previous workaround escaped every non-ASCII char in the JSON body as `\\uXXXX` via `opencode-api--json-escape-non-ascii', which bloated CJK payloads ~10× and left multibyte header values (e.g. `X-OpenCode-Directory: /Users/项目`) still broken.  The canonical fix lives in `opencode-api.el`: a single `opencode-api--to-unibyte' helper runs `encode-coding-string ... 'utf-8 t' iff the input is multibyte (unibyte inputs pass through untouched).  `opencode-api--build-headers' coerces EVERY header value through it; `opencode-api--request' coerces the serialized body (which is already unibyte from `json-serialize', but the belt-and-braces call costs nothing).  `json-serialize' itself is documented to return a unibyte UTF-8 byte sequence — do NOT add another escape layer.  Guarded by `opencode-api-to-unibyte-idempotent', `opencode-api-json-serialize-returns-unibyte-utf8', `opencode-api-headers-values-are-unibyte', and the end-to-end `opencode-api-request-survives-url-http-create-request' which feeds a multibyte directory header through the real `url-http-create-request'.

47. **User chat-mode keybinding overrides must go through `opencode-chat-user-keymap` and `opencode-chat-unbound-keys` — not per-map hooks** — `opencode-chat-mode' has THREE active keymaps (major-mode `opencode-chat-mode-map', plus `opencode-chat-message-map' and `opencode-chat-input-map' installed as text-property `keymap').  Text-property keymaps win over mode maps (see #22), so unbinding C-p in `opencode-chat-mode-hook' does NOTHING when point is on read-only message text or in the input area.  The canonical extension surface is: (a) `opencode-chat-user-keymap' — public parent keymap of all three internal maps; any additive binding added here propagates to all three regions; (b) `opencode-chat-unbound-keys' defcustom — listed keys are truly removed (via `keymap-unset MAP KEY t', the REMOVE flag) from all three maps so the parent/global binding takes over.  The `:set' handler on the defcustom makes runtime changes immediately visible in live buffers, and `opencode-chat--default-bindings-alist' (captured at load time) lets the apply pass restore defaults so unbind toggles are reversible.  Do NOT re-invent per-map override logic in user-facing code or docs — route users at these two symbols.  When adding new package-internal bindings, keep them in the child maps (mode/message/input); the user-keymap is reserved for users.

## Debug Logging
All debug tracing goes to a dedicated `*opencode: debug*` buffer, NOT `*Messages*`.
Controlled by a single defcustom — disabled by default.

```elisp
;; Enable debug logging:
(setq opencode-debug t)

;; View the debug buffer:
M-x opencode-show-debug-log

;; Clear it:
M-x opencode-clear-debug-log

;; Auto-truncation (default 10,000 lines):
(setq opencode-debug-max-lines 10000)
```

**Writing debug messages** — use `opencode--debug` (NOT `message`):

```elisp
;; Good — goes to *opencode: debug* when enabled, zero cost when disabled:
(opencode--debug "opencode-chat: received delta partID=%s" part-id)

;; Bad — pollutes *Messages*:
(message "opencode-chat: received delta partID=%s" part-id)
```

`opencode--debug` is safe to call anywhere — it wraps in `condition-case` so a format error never crashes the caller.
Current debug log points (prefix-based, grep-friendly):
- `opencode-api:` — every HTTP request (`>>>`) and response (`<<<`), method/url/body/status
- `opencode-api: !!!` — error responses with raw body
- `opencode-sse:` — raw SSE events, parsed event dispatch, filter bytes, curl lifecycle
- `opencode-chat:` — all SSE handlers (message-updated, message-removed, part-updated, session-status, session-diff, idle, session-deleted, session-error, session-compacted, server-instance-disposed), send, refresh, image paste
- `opencode-session:` — session create/abort
- `opencode-permission:` — permission reply
- `opencode-question:` — question reply/reject
- `opencode-diff:` — revert operations
- `opencode-config:` — config fetch

**Note**: Error diagnostics and user-facing messages still use `(message ...)` and appear in `*Messages*`.
The `*opencode: log*` buffer (server subprocess output) is a separate system managed by `opencode-server.el`.

## Testing Patterns

```elisp
;; Temp buffer with auto-cleanup:
(opencode-test-with-temp-buffer "*test-name*"
  (opencode-chat-mode)
  (setq opencode-chat--session-id "ses_test")
  ;; ... test body ...)

;; Stub network calls:
(cl-letf (((symbol-function 'opencode-chat--refresh)
           (lambda () nil)))
  ;; ... code that triggers refresh ...)

;; Assertions:
(should (opencode-test-buffer-contains-p "expected text"))
(should (opencode-test-has-face-p "text" 'opencode-user-header))

;; Simulate SSE events — call handler directly:
(opencode-chat--on-part-updated
 (list :type "message.part.updated"
       :properties (list :part (list :sessionID "ses_1" :id "prt_1"
                                     :type "text" :text ""
                                     :time (list :start 1700000000000))
                        :delta "hello")))
```

**Rule**: Every `ert-deftest` MUST include a docstring explaining (1) why the test exists and (2) what behavior it verifies. Without context, tests become opaque and unmaintainable.

Every docstring should answer two questions:
1. **Why does this test exist?** — What bug or invariant does it guard against?
2. **What breaks if this fails?** — What's the user-visible consequence?

```elisp
;; Good — docstring explains the "why" and "what":
(ert-deftest opencode-chat-on-part-updated-streaming ()
  "Verify that a part.updated event with a delta field inserts streaming text
at the correct marker position, so real-time text appears in the chat buffer."
  (opencode-test-with-temp-buffer "*test*"

;; Bad — no context, reader has no idea what this guards against:
(ert-deftest opencode-chat-on-part-updated-streaming ()
  (opencode-test-with-temp-buffer "*test*"
    ...))
```

### Scenario Replay Framework (`test/opencode-scenario-test.el`)

Record-and-replay test framework for chat buffer rendering. Reads scenario
files containing sequences of OpenCode operations and replays them against
a mocked chat buffer. Lives entirely in `test/opencode-scenario-test.el`
(no production code dependency).

**Scenario file format** (line-based, prefix-driven):

```
# Comments start with #
:session ses_abc123                    — set the session ID (required)
:directory /path/to/project            — set the project directory (optional)
:sse {"directory":"/proj","payload":{"type":"session.status",...}}
                                       — deliver an SSE event (global or flat JSON)
:refresh multi-tool-messages.json      — load message JSON file and re-render buffer
:refresh [{...inline JSON...}]         — inline message JSON and re-render
:api GET /path 200 {"key":"val"}       — register a mock API response
:wait 500                              — pause (interactive only; no-op in batch)
:assert-contains hello world           — assert buffer contains text
:assert-not-contains error             — assert buffer does NOT contain text
:assert-busy                           — assert session is busy
:assert-idle                           — assert session is idle
```

Multi-line JSON: continuation lines that don't start with `:` or `#` are
appended to the previous line's JSON payload.

**Key directives:**

| Directive | Purpose |
|-----------|---------|
| `:sse` | Replays an SSE event through the real chat handler (`on-message-updated`, `on-part-updated`, etc.) |
| `:refresh` | Loads `/session/:id/message` response JSON, sets `opencode-chat--messages`, calls `render-messages` — full buffer re-render |

**`:refresh` resolves filenames** by checking `test/fixtures/` first (via
`opencode-test--fixtures-dir`), then falling back to relative path. Use
`.json` suffix to indicate a file; anything else is parsed as inline JSON.

**Entry points:**

```elisp
;; Interactive — opens buffer, leaves it open for inspection
(opencode-scenario-run-file "test/fixtures/refresh-scenario.txt")
M-x opencode-scenario-replay-file    ;; with :wait pauses

;; ERT batch — returns assertion results, kills buffer after
(opencode-scenario-run-string ":session s\n:sse {...}\n:assert-contains hello\n")

;; ERT macro — replay then run arbitrary assertions in the buffer
(opencode-scenario-with-replay "scenario string..."
  (should (opencode-test-buffer-contains-p "hello"))
  (should opencode-chat--busy))
```

**What gets stubbed** (via `opencode-scenario--with-stubs` macro):
`opencode-chat--refresh`, `opencode-chat--schedule-refresh`,
`opencode-chat--render-footer-info`, `opencode-chat--header-line`,
`opencode-chat--drain-popup-queue`, `opencode-chat--schedule-streaming-fontify`,
`opencode--register-chat-buffer`, `opencode--deregister-chat-buffer`,
`opencode-agent--default-name`, `opencode-api-get`, `opencode-api-post`.

**Per-event error isolation** — each SSE handler call is wrapped in its own
`condition-case`, so a crash in one event (e.g. `step-start` upsert when
no overlay exists) does not corrupt markers for subsequent events (e.g.
streaming deltas). This matches real-world behavior where the dispatch
wrapper in `opencode.el` also catches handler errors.

**Fixture files** in `test/fixtures/`:

| File | Content |
|------|---------|
| `sample-scenario.txt` | Simple streaming hello world (SSE-only) |
| `multi-tool-scenario.txt` | Full session: text + bash + permission + question (SSE-only) |
| `refresh-scenario.txt` | Full buffer render via `:refresh` from API response |
| `multi-tool-messages.json` | Saved `/session/:id/message` response for `:refresh` |

**Capturing new fixtures:**

```bash
# Save a session's message history for :refresh scenarios
curl -s 'http://127.0.0.1:4096/session/SESSION_ID/message?limit=200' \
  -H 'Accept: application/json' \
  -H 'x-opencode-directory: /path/to/project' \
  | python3 -m json.tool > test/fixtures/my-scenario-messages.json

# Then use it in a scenario file:
# :refresh my-scenario-messages.json
# :assert-contains expected text
```

**Testing input-area interactions with `:eval`:**

The `:eval` directive runs arbitrary elisp in the chat buffer context.
This enables testing CAPF, chip creation, and input-area mutations that
are not SSE-driven. Example: simulating sequential @-mentions:

```elisp
(ert-deftest opencode-scenario-mention-sequential-folder-chips ()
  "Two sequential @-mentions must each produce their own chip overlay."
  (opencode-scenario-with-replay
      (concat
       ":session ses_mention_test\n"
       ;; Step 1: type @test/ and complete → chip "@test/"
       ":eval (goto-char (opencode-chat--input-content-start))\n"
       ":eval (insert \"@test/\")\n"
       ":eval (opencode-chat--mention-exit \"test/\" 'finished)\n"
       ;; Step 2: type @test/fixtures/ after chip and complete → chip "@test/fixtures/"
       ":eval (goto-char (opencode-chat--input-content-end))\n"
       ":eval (insert \" @test/fixtures/\")\n"
       ":eval (opencode-chat--mention-exit \"test/fixtures/\" 'finished)\n")
    ;; Verify 2 chip overlays with correct text
    (let* ((input-start (opencode-chat--input-content-start))
           (input-end (opencode-chat--input-content-end))
           (chips (seq-filter (lambda (ov) (overlay-get ov 'opencode-mention))
                              (overlays-in input-start input-end))))
      (should (= 2 (length chips))))))
```

Key `:eval` patterns for input-area tests:
- `(goto-char (opencode-chat--input-content-start))` — move point to start of editable area
- `(goto-char (opencode-chat--input-content-end))` — move point to end of editable area
- `(insert "text")` — insert text at point (simulates typing)
- `(opencode-chat--mention-exit "candidate" 'finished)` — simulate CAPF completion
- `(opencode-chat--chip-create START END TYPE NAME PATH)` — create a chip overlay directly

## Elisp Pitfalls (language-level traps)

These are Emacs Lisp gotchas that don't involve any opencode-specific code.
If you're unfamiliar with Elisp, read this section first.

1. **`string<=` does not exist** — Emacs has `string<` (`string-lessp`) and `string=`, but NOT `string<=`. Use `(not (string> a b))` instead. Similarly, `string>=` doesn't exist — use `(not (string< a b))`.

2. **`delete` is destructive on lists** — `(delete elt list)` mutates the list in place using `eq`. Always capture the return value: `(setq list (delete elt list))`. For non-destructive removal use `(remove elt list)` (uses `equal`).

3. **`member` uses `equal`, `memq` uses `eq`** — For string comparisons in lists, use `member`. For symbol comparisons, `memq` is faster.

4. **`defvar-local` does not re-initialize** — Once a buffer-local variable exists, re-evaluating `defvar-local` does NOT change its value. Use `setq` in mode functions to reset state. This is why `opencode-chat-mode` doesn't rely on defvar-local defaults.

5. **Marker insertion types matter** — `(set-marker-insertion-type marker t)` means the marker advances when text is inserted AT the marker position. `nil` means it stays put. Getting this wrong causes streaming text to appear in wrong positions, overlays to grow unexpectedly, or messages-end to advance past the input area.

6. **`overlay-start`/`overlay-end` can return nil** — After `delete-overlay` or if the overlay's buffer is killed. Always guard with `when` before `delete-region`.

7. **`run-hook-with-args` vs `run-hooks`** — `run-hooks` passes NO arguments. `run-hook-with-args` passes ONE argument to each function. For buffer-local hooks (added with `add-hook ... nil t`), both work — but the hook function's signature must match.

8. **`plist-get` returns nil for missing keys** — No error, no distinction between "key absent" and "key present with nil value". Use `plist-member` when you need to distinguish.

## Cross-Module Communication Patterns

How modules communicate without circular dependencies:

### Hook-based (chat-input.el → chat.el)

`opencode-chat-input.el` cannot `require` `opencode-chat.el` (circular). Instead:

```
chat-input.el defines:   (defvar-local opencode-chat-on-message-sent-hook nil)
chat-input.el fires:     (run-hook-with-args 'opencode-chat-on-message-sent-hook info)
chat.el registers:       (add-hook 'opencode-chat-on-message-sent-hook
                                   #'opencode-chat--on-message-sent nil t)
```

The hook is buffer-local (`nil t`), registered in `opencode-chat-mode`.
This pattern lets input fire events without knowing who handles them.

### Declare-function (leaf → parent)

When a leaf module needs to call a parent function without requiring it:

```elisp
;; In opencode-chat-message.el (leaf):
(declare-function opencode-chat--schedule-refresh "opencode-chat" ())
;; Can now call (opencode-chat--schedule-refresh) — no require needed.
;; Byte-compiler won't warn. Runtime resolves via autoload or prior require.
```

### Require chain (parent → child)

```
opencode-chat.el
  ├─ requires opencode-chat-state.el    (struct)
  ├─ requires opencode-chat-message.el  (message DB)
  ├─ requires opencode-chat-input.el    (input area)
  └─ requires opencode-api.el
       └─ requires opencode-api-cache.el (cache facade)
```

**Rule**: requires flow downward. Upward references use `declare-function`.
Circular `require` causes infinite loop at load time — Emacs hangs.

## Adding a Feature

A checklist for adding a new feature or public API.  Prefer extending an
existing module over creating a new one — the fewer modules, the fewer
boundaries to defend.  Three similar helpers is better than a premature
split.

### 1. Pick the module

| Change | Module |
|--------|--------|
| New chat-buffer behavior | `opencode-chat.el` |
| New per-chat-buffer state | `opencode-chat-state.el` (struct slot + accessors) |
| New read-only rendering / message handling | `opencode-chat-message.el` |
| Input area, CAPF, history, commands | `opencode-chat-input.el` |
| New SSE-driven popup | pattern after `opencode-question.el` / `opencode-permission.el`, reuse `opencode-popup.el` infra |
| Agent/provider/config query & cache | `opencode-api-cache.el` via `opencode--define-micro-cache` |
| Cross-session UI (sidebar, session list) | `opencode-sidebar.el` / `opencode-session.el` |
| Standalone feature (new top-level buffer) | new `opencode-foo.el`; requires must flow downward |

### 2. Name it

- **Public API** — commands, `defcustom`, cross-module entry points
  - Commands: `opencode-foo` (interactive, M-x target)
  - Settings: `opencode-foo-delay` (always `opencode-<module>-` prefix)
  - Functions called from outside the module: `opencode-foo-refresh`
  - Hooks: `opencode-foo-on-bar-hook`
- **Internal** — always double-dash
  - Helpers / handlers: `opencode-foo--on-event`, `opencode-foo--helper`
  - Buffer-local state: `opencode-foo--name`

Never add a single-dash private.  Never invent a new top-level namespace.

### 3. Store state in the right place

- **Per chat buffer** → struct slot.  Add a line to `opencode-chat-state.el`:
  ```elisp
  (cl-defstruct (opencode-chat-state ...) ... (new-slot nil :documentation "..."))
  (opencode-chat-state--define-slot new-slot)
  ```
  Read via `(opencode-chat--new-slot)`, write via
  `(opencode-chat--set-new-slot value)`.  Never introduce a new
  `defvar-local` in `chat.el`, `chat-input.el`, or `chat-message.el` —
  the struct is the single source of truth (see "Module Boundary").
- **Per non-chat buffer** (sidebar, session list, status) → `defvar-local`
  in that module.  Each module owns its own buffer-local state.
- **Global / singleton** → `defvar` (internal) or `defcustom` (if the user
  might override).
- **Server-side data cached locally** → `opencode--define-micro-cache`
  in `opencode-api-cache.el` for anything SSE invalidates.
- **Debounced timer** → `opencode--debounce` (accepts a symbol OR a
  `(GETTER . SETTER)` cons — use the cons form for struct-backed timers).

### 4. Wire it in

- **Bind a key** — public keys go in `opencode-chat-mode-map` (input area)
  or attach via text-property `keymap` for message-area-only bindings.
  Three-layer architecture: mode-map, message-map (text prop),
  input-map (text prop).  See "Keymap Architecture" in memory.  Package
  bindings live in the child maps; do NOT put them in
  `opencode-chat-user-keymap' — that symbol is reserved for user
  overrides.  New keys that genuinely span all three regions are rare;
  prefer placing them in the child closest to their region.
- **React to an SSE event** — add a handler in the right module, subscribe
  via global hook (SSE dispatch is global, not buffer-local).  Handler
  must filter by `(opencode-chat--session-id)` before acting.  See "SSE
  Event Types & Hooks".
- **Cross-module signal (child → parent)** — fire a buffer-local hook
  (`run-hook-with-args`), let the parent register with `add-hook ... nil t`.
  The child never `require`s the parent.

### 5. Tests are mandatory

Every new feature lands with tests.  `make test` must stay green.

- **Logic / rendering** — unit test in `test/opencode-<module>-test.el`.
  Use `opencode-test-with-temp-buffer` for buffer tests; `cl-letf` with
  `symbol-function` to stub I/O.
- **SSE-driven behavior** — scenario test in
  `test/opencode-scenario-test.el` or a fixture under `test/fixtures/`.
  The scenario replay framework drives real SSE events through the
  production dispatch path — this is the only way to catch two-buffer /
  cross-session bugs.
- **Before-the-fix test** — if the feature is a bug fix, write the
  failing test first to prove the bug, then fix.

### 6. Autoloads

If the function is user-facing (interactive command used outside of a
chat buffer, or callable from external config), annotate with
`;;;###autoload` AND manually add the cookie to `opencode-autoloads.el`.
The Makefile does not regenerate it.

### 7. Update the docs

- If you add a new module or new public API → one-liner in the module
  list under "Architecture".
- If you change state ownership or cross-module communication → update
  the matching Module Boundary diagram.
- If you found a subtle pitfall → append a numbered entry to
  "Common Mistakes (Lessons Learned)".
- If you add a new SSE event or change handling → update "SSE Event
  Types & Hooks" and the "Complete Event Behavior Reference" table.

### 8. Commit hygiene

Break work into small reviewable commits (~100–300 lines).  A typical
feature sequence:

1. Add data (struct slot + accessors, fixtures)
2. Add behavior (commands, handlers, renderers)
3. Wire into SSE / keymap / mode
4. Tests
5. Docs

Every commit must compile clean and pass all tests — not just the last
one.  Before committing, `rm *.elc test/*.elc && make compile test`.

## Cache Architecture

### Micro-cache (`opencode-api-cache.el`)

Generated by the `opencode--define-micro-cache` macro. Each invocation creates:

| Symbol | Type | Purpose |
|--------|------|---------|
| `opencode-api--NAME-cache` | defvar | Cached response (plist/vector or nil) |
| `opencode-api--NAME-refreshing` | defvar | Non-nil while async fetch in-flight |
| `opencode-api--NAME` | cl-defun | Accessor with `:block`, `:cache`, `:callback` modes |
| `opencode-api--NAME-invalidate` | defun | Reset cache + refreshing flag to nil |

**Three cache instances**: `agents` (`/agent`), `server-config` (`/config`), `providers` (`/provider`).

**Access modes** (mutually exclusive, first match):
- `:cache t` — return current cache, never HTTP. May return nil.
- `:block t` — sync HTTP if nil. Blocks Emacs.
- `:callback fn` — async HTTP if nil. Calls fn with result. Also returns current cache.
- `(default)` — return cache. Kick off background refresh if nil.

**Cache lifetime**: No TTL. Invalidated by `opencode-api-invalidate-all-caches` (called on every server connect). SSE `server.instance.disposed` triggers re-bootstrap which re-fetches.

### Session cache with stale-on-timeout

`opencode-api-cache-get-session` adds a **0.5s timeout fallback** for session reads:

```
Has cached session?
  ├─ YES → start async fetch with 0.5s timer
  │        ├─ fetch completes in time → callback(fresh), update cache
  │        └─ timer fires first → callback(stale cached value)
  └─ NO  → start async fetch, no timeout (wait for result)
```

**Only for reads** — write operations (POST/PATCH/DELETE) never use timeout fallback.

### Startup resilience

```
opencode--on-connected
    │
    ├─ opencode-api-invalidate-all-caches()    ← clear stale data
    ├─ opencode-api-cache-ensure-loaded()       ← non-fatal prewarm
    │      │
    │      ├─ state=unloaded → do-load (prewarm agents + config)
    │      │     ├─ success → state=loaded
    │      │     └─ error → state=failed (logged, not thrown)
    │      ├─ state=loaded → no-op
    │      └─ state=failed → reset to unloaded, retry do-load
    │
    └─ opencode-sse-connect()

opencode-chat-open / opencode-sidebar--ensure-buffer
    │
    └─ opencode-api-cache-ensure-loaded()      ← lazy retry on next open
```

**Guarantee**: cache load failure never blocks chat/sidebar open flows or breaks default agent/provider initialization.

## Test Infrastructure (`test/test-helper.el`)

### Mock HTTP

`opencode-test-with-mock-api` intercepts `opencode-api--request` (the single
internal entry point for all HTTP) so no real network calls happen:

```elisp
(opencode-test-with-mock-api
  ;; Register mock responses
  (opencode-test-mock-response "GET" "/session/ses_1" 200
    '(:id "ses_1" :title "Test Session"))
  (opencode-test-mock-response "POST" "/session/ses_1/prompt_async" 200
    '(:ok t))

  ;; Code under test — HTTP calls hit mocks
  (opencode-api-cache-get-session "ses_1" (lambda (data) ...))

  ;; Inspect what was called
  (should (= 1 (opencode-test-request-count)))
  (let ((req (opencode-test-last-request)))
    (should (string= (car req) "GET"))))
```

**Mock matching**: exact path first, then prefix match (for `/session/:id` patterns).
Query params are stripped before matching.

### Buffer test pattern

```elisp
(opencode-test-with-temp-buffer "*test*"
  (opencode-chat-mode)
  ;; Set up buffer-local state
  (opencode-chat--set-session-id "ses_test")
  (opencode-chat--state-init)
  ;; ... test body ...
  ;; Assertions
  (should (opencode-test-buffer-contains-p "expected"))
  (should (opencode-test-has-face-p "text" 'expected-face)))
```

## Common Mistakes (Lessons Learned)

1. **Streaming uses `message.part.updated` with optional `delta` field** — OpenCode does NOT have a separate `message.part.delta` event. The `delta` field appears at properties level (NOT inside the part). The `on-part-updated` handler checks for delta first (streaming insert), then checks part type: finalized text/reasoning parts are intentional no-ops (content was already streamed via deltas; canonical refresh happens on `session.idle`), while tool/step-start/step-finish parts trigger `schedule-refresh`. Parts without delta or `:end` time are treated as bootstrap (empty part).

2. **`prompt_async` needs `model` in body** — Without it: 204 returned, nothing happens. No error. Silent failure. Custom agents from `/agent` MAY carry `model` fields (e.g. `{"providerID":"anthropic","modelID":"claude-opus-4-6"}`), but native agents do not. The fallback is `GET /config` which returns `{"model": "anthropic/claude-opus-4-6", ...}` in `"provider/model-id"` format.

3. **JSON `false` → `:false`, not `nil`** — `(not :false)` is nil (truthy!). Use `(eq val :false)` or `(eq val t)`.

4. **`render-messages` must clear streaming state** — After `erase-buffer`, call `(opencode-chat-message-clear-all)` which nils messages-end, clears the parts hash table, cancels streaming timers, and resets section overlay map. Old markers are invalid. The message module owns all cleanup; chat.el just calls the single API function.

5. **`messages-end` marker must survive input area rendering** — Create with `nil` insertion type, render input area, THEN switch to `t`. Otherwise the marker advances past the input area and streaming/optimistic inserts go to the wrong place.

6. **Optimistic user message** — Insert at `messages-end` immediately on send, don't wait for `message.updated` SSE event. The server refresh replaces it with the real data.

7. **SSE uses curl, not url.el** — `url-retrieve` buffers entire response. Use `curl --no-buffer` subprocess with process filter.

8. **`Accept: application/json` required** — Without it, the SPA catch-all returns HTML instead of JSON on all routes.

9. **Provider ID casing** — `/agent` and `/provider` may return different casing. Always compare with `downcase`.

10. **SSE endpoint is `/global/event`, NOT `/event`** — The `/event` endpoint only receives heartbeats. The `/global/event` endpoint receives ALL events (message updates, streaming deltas, session status, etc.) wrapped in `{"directory": "...", "payload": {...}}`. Using `/event` causes streaming to silently fail — prompts return 204 but no SSE events arrive.

11. **`/global/event` does NOT need `X-OpenCode-Directory` header** — Unlike REST API calls, the global SSE endpoint broadcasts all events for all directories. The `directory` field inside each event identifies the project.

12. **Tool parts use `:tool`, not `:toolName`** — The server sends `{"type": "tool", "tool": "bash", "state": {"status": "completed", "input": {...}, "output": "..."}}`. The `:state` is a plist, NOT a string. Input args are in `:state :input` as a plist, NOT a JSON string in `:args`.

13. **SSE connect must happen on EVERY server connection, not just `opencode-start`** — Users can connect via `opencode-server-port` (connect mode) without calling `opencode-start`. SSE connect lives in `opencode--on-connected` (fired by `opencode-server-connected-hook`), NOT as a one-shot hook added in `opencode-start`. If SSE only connects in `opencode-start`, connect-mode users get no streaming.

14. **SSE hooks must be GLOBAL, not buffer-local** — The curl SSE process filter runs outside any buffer context. Buffer-local hooks (`add-hook ... nil t`) will NEVER fire from SSE dispatch. Use global hooks with registry-based dispatch (`opencode--dispatch-to-chat-buffer` for O(1) lookup by session-id, with inline buffer-list fallback). Each chat handler filters by `opencode-chat--session-id` internally.

15. **`opencode-chat-mode` must NOT derive from `special-mode`** — `special-mode` binds all printable keys to suppress `self-insert-command`. Even with `buffer-read-only nil`, users cannot type in the input area because `special-mode-map` intercepts every letter. Derive from `nil` (fundamental) and manage read-only via text properties.

16. **Face `:box :line-width (W . H)` cons form may not work** — The asymmetric `(WIDTH . HEIGHT)` form for `:line-width` in `:box` face attribute can fail with `Invalid face box` on some Emacs builds. Use plain integer `:line-width N` for compatibility.

17. **POST requests must always send a body** — Even when the body plist is empty/nil, `url-request-data` must be `"{}"` (not nil) for POST/PATCH/DELETE. In Elisp, `'()` is `nil`, so `(let ((body '())) ... (if body ...))` treats an empty body as nil. The `opencode-api--request` function handles this, but callers should be aware.

18. **Section collapse on messages** — The section system (`opencode-ui.el`) hides bodies with a `'invisible 'opencode-section` text property; `opencode-chat-mode` calls `(add-to-invisibility-spec 'opencode-section)` so the invisibility engages. Two keymaps bind TAB differently: `opencode-chat-mode-map` binds TAB to `opencode-chat--cycle-agent` (input area), while `opencode-chat-message-map` binds TAB to `opencode-ui--toggle-section` (read-only message area, applied via the `keymap` text property). User and assistant message headers emit the `▼`/`▶` collapse icon via `opencode-ui--insert-icon`, which marks the glyph with `'opencode-collapse-icon t` so `swap-collapse-icon` can flip it. On collapse, a `[collapsed]` indicator appended to the header line signals the hidden body; re-expanding deletes the indicator and removes `'invisible` from the body region. Pinned by `opencode-chat-assistant-message-collapse-roundtrip` in the unit tests.

19. **New streaming text/reasoning parts need a newline separator** — `message.part.delta` for a brand-new part ID lands at `message-insert-pos` (right before the footer or at the message overlay's end).  If the previous streaming part's last delta ended mid-line (LLM deltas often do), the first delta for the new part would glue directly onto that tail — e.g. the reasoning's `"...design issues."` followed by the assistant's `"I'll perform..."` on the same visual line.  `opencode-chat-message-update-part` Case 2 (and the no-delta sibling) insert a `"\n"` at the insertion point when not at `bolp` so each part starts on its own line.  Pinned by `opencode-chat-streaming-new-part-breaks-line`.

19. **Edit tool input uses `oldString`/`newString`, not an `edits` array** — The production server sends edit tool input as `{"filePath": "/path/to/file", "oldString": "text being replaced", "newString": "replacement text"}`. Do NOT assume an `edits` array format. The `oldString`/`newString` fields contain the actual before/after text for the specific edit operation, which can be used to generate inline diffs. Discovered via `curl` against a live OpenCode server (v1.2.6).

20. **`X-OpenCode-Directory` must match the session's project for ALL session API calls** — The server computes a `projectID` hash from this header to locate session files on disk (`~/.local/share/opencode/storage/session/{projectID}/`). If the header points to project B but the session was created under project A, the server returns `NotFoundError` — which manifests as silent 204 on `prompt_async` (no error, no SSE events) or empty responses on `GET /session/:id`. This is a cross-project problem: e.g. user starts the server in `opencode.el` but opens a session created in `mcp_server`. Fix: `opencode-chat-open` accepts `&optional directory` — callers pass the session's known directory so the buffer-local `opencode-api-directory` is pinned before the first API call. The async `GET /session/:id` callback refines it from the server's authoritative `:directory` field. **All callers must pass the correct directory**: `opencode-new-session` passes `(plist-get session :directory)`, sidebar passes `opencode-sidebar--project-dir`, session list passes `opencode-session--project-dir`, and `opencode-chat` extracts the directory from the session object returned by `opencode--read-session` (which returns `(id . directory)` cons, not just an ID). The header priority chain in `opencode-api--build-headers` is: `opencode-api-directory` (buffer-local) → `opencode-default-directory` (global) → `default-directory` (Emacs built-in). Only chat buffers set `opencode-api-directory`; sidebar operations bind `opencode-default-directory` to `opencode-sidebar--project-dir` via `let` before API calls.

21. **Sidebar `opencode-sidebar--new-session` must refresh in sidebar buffer context** — After `(select-window target-win)` and `(opencode-new-session ...)`, the current buffer switches to the new chat buffer. Calling `opencode-sidebar--refresh` at that point runs in the wrong buffer — `opencode-sidebar--project-dir` is nil, the API query returns wrong results, and the sidebar header stays at "(0)". Fix: save `(current-buffer)` as `sidebar-buf` before switching windows, then wrap the refresh in `(with-current-buffer sidebar-buf ...)`.

## Complete Event Behavior Reference

> Source of truth for event handling. Compare TUI (TypeScript) vs Emacs (Elisp) behavior.
> TUI code: packages/opencode/src/cli/cmd/tui/context/sync.tsx + app.tsx
> SDK types: packages/sdk/js/src/v2/gen/types.gen.ts

### Events We Handle (must match TUI/Web App behavior)

| Event | TUI Behavior | Emacs Behavior | Status |
|---|---|---|---|
| `session.updated` | Update session in store | Refresh chat header + sidebar | ✅ Correct |
| `session.deleted` | Remove from store, navigate home if current | Show deletion msg, disable input, refresh sidebar | ✅ Implemented |
| `session.status` | Set busy/idle/retry per session | Set `opencode-chat--busy`, update header | ✅ Correct |
| `session.idle` | (deprecated, handled same as status.idle) | Clear busy, schedule refresh | ✅ Correct (kept for compat) |
| `session.error` | Show toast (skip MessageAbortedError) | Show error in chat buffer | ✅ Implemented |
| `session.diff` | Update diff store | Schedule refresh (diff rendering) | ✅ Correct |
| `session.compacted` | Refresh messages for session | Clear streaming state, immediate refresh (history rewrite) | ✅ Implemented |
| `message.updated` | Update message in store | Schedule refresh | ✅ Correct |
| `message.part.updated` | Update part, handle streaming delta | Insert streaming text (delta); finalized text/reasoning are no-ops; tool/step parts schedule refresh | ✅ Correct |
| `message.removed` | Remove message from store | Schedule refresh | ✅ Implemented |
| `message.part.removed` | Remove part from store | (not needed — refresh covers it) | ⬜ Skipped |
| `todo.updated` | Update todos in store | Refresh todo buffer | ✅ Implemented |
| `permission.asked` | Show permission popup | Show inline popup in chat | ✅ Correct |
| `permission.replied` | Remove from store | Dismiss popup if matching | ✅ Implemented |
| `question.asked` | Show question popup | Show inline popup in chat | ✅ Correct |
| `question.replied` | Remove from store | Dismiss popup if matching | ✅ Implemented |
| `question.rejected` | Remove from store | Dismiss popup if matching | ✅ Implemented |
| `server.instance.disposed` | Full bootstrap() re-fetch | Re-bootstrap (agents, config, refresh all) | ✅ Implemented |
| `global.disposed` | Web App: bootstrap() re-fetch. TUI: not handled | Re-bootstrap all (SSE stays connected) | ✅ Implemented |
| `installation.update-available` | Web App: info toast (10s) | Inline footer in chat buffer | ✅ Implemented |

### Events We Skip (TUI-only, no Emacs use case)

| Event | TUI Behavior | Why Skip |
|---|---|---|
| `lsp.updated` | Update LSP state in store | No LSP UI in Emacs client |
| `vcs.branch.updated` | Update VCS branch info | No VCS UI in Emacs client |
| `file.edited` | Update file edit tracking | No file tracking UI |
| `file.watcher.updated` | Update file watcher state | No file watcher UI |
| `mcp.tools.changed` | Update MCP tool list | No MCP tool UI |
| `command.executed` | (not in TUI sync) | Internal server event |
| `pty.*` | Terminal emulator events | No PTY in Emacs client |
| `worktree.*` | Worktree management | No worktree UI |
| `tui.*` | TUI-specific events | Not applicable |
| `project.updated` | Update project metadata | No project settings UI |
| `session.created` | Add to store | Handled by sidebar refresh |
