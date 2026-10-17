---
title: TextMate Agent Harness — Design
created: 2026-10-13
status: approved 2026-10-13 — M1 done, M2 done (2026-10-16), M3 implemented (2026-10-16)
branch: feature/agent
related: textmate-ai-plan.md
---

# TextMate Agent Harness — Design

> Implementation status: [docs/ai/implementation/](../implementation/README.md)

Lets AI coding agents — **GitHub Copilot** and **Claude Code** first, any other ACP agent later — *drive coding* inside TextMate: chat, read and edit files, run commands, with the user approving actions and reviewing diffs.

## 1. Decisions in one place

| # | Decision | Choice | Status |
|---|---|---|---|
| D1 | Protocol | **Agent Client Protocol (ACP) v1** over stdio | Decided (plan) |
| D2 | Copilot backend | `copilot --acp` (Copilot CLI, native ACP) | Verified 2026-10-13 |
| D3 | Claude backend | `@agentclientprotocol/claude-agent-acp` adapter (Claude Agent SDK) | Verified 2026-10-13 |
| D4 | JSON | Foundation `NSJSONSerialization` (no new dependency) | Proposed |
| D5 | UI toolkit | **AppKit** (Objective-C++) | Decided 2026-10-13 |
| D6 | Panel placement | Docked panel in the project window, **left or right side (user setting)**, toggled from the View menu | Decided 2026-10-13 |
| D7 | Session scope | One agent session per project window (cwd = project folder) | Proposed |
| D8 | Agent configuration | Preferences pane + optional `.tm_properties` override | Proposed |

## 2. What was verified on this machine

Both agents answered an ACP `initialize` handshake with protocol version 1:

| | Copilot CLI 1.0.63 | Claude Agent ACP adapter 0.90.0 |
|---|---|---|
| Command | `copilot --acp` | `npx -y @agentclientprotocol/claude-agent-acp` |
| Resume sessions (`loadSession`) | ✅ | ✅ (also list, fork, resume, close, delete) |
| Images in prompts | ✅ | ✅ |
| Embedded file context | ✅ | ✅ |
| MCP servers (http/sse) | ✅ | ✅ |
| Auth | `authMethods`: "Log in with Copilot CLI" (terminal: `copilot login`) | Already signed in — sent `_auth/status_update` reporting the **Claude Pro** account |

Notes:
- The deprecated adapter names `@zed-industries/claude-code-acp` and `@zed-industries/claude-agent-acp` must not be used.
- Copilot is installed under **nvm** (`~/.nvm/versions/node/v24.14.0/bin`). Apps launched from the Dock don't get the shell's `PATH`, so agent commands must be resolved through the user's login shell (see §5.5).

## 3. ACP in brief

- **Transport:** agent is a subprocess; JSON-RPC 2.0 over stdin/stdout; **one message per line** (`\n`-delimited, no embedded newlines, UTF-8). Agent stderr is free-form logging.
- **Client → agent:** `initialize`, `authenticate`, `session/new`, `session/load`, `session/prompt`, `session/set_mode`, `session/cancel` (notification).
- **Agent → client requests:** `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`, `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`.
- **Agent → client notifications:** `session/update` with `sessionUpdate` ∈ `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`, `available_commands_update`, `current_mode_update`, `config_option_update`, `session_info_update`, `usage_update` (+ `notice`, compaction updates if the client opts in).
- **Prompt turn ends** with a `stopReason`: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`.
- **Cancellation:** client sends `session/cancel`, answers any pending permission requests with `cancelled`, keeps accepting late updates; agent replies to `session/prompt` with `cancelled`.
- Vendor extensions arrive as `_`-prefixed methods / `_meta` fields (e.g. Claude's `_auth/status_update`); unknown ones are ignored.
- **In practice (checked 2026-10-16):** Claude Code and Copilot CLI don't call `fs/*` or `terminal/*`; they edit and run commands themselves. M3 therefore also tracks edits from tool calls and shows Claude's `_meta` terminal output; see [05-m3-tools.md](../implementation/05-m3-tools.md).

## 4. Architecture

```
┌──────────────────────── TextMate (main thread) ────────────────────────┐
│  DocumentWindowController ── AgentPanelController (AgentUI)             │
│        │                        │  chat transcript, input, tool calls,   │
│        │                        │  permission prompts, diff review       │
│        ▼                        ▼                                       │
│   OakDocument(s) ◄──── AgentSession (AgentClient) ─────► AgentTerminal  │
│   (open buffers)       │  session state, turn state      (NSTask per     │
│                        │  routes fs/*, terminal/*,        terminal/create)│
│                        │  permission requests                           │
│                        ▼                                                │
│                  AgentConnection  — JSON-RPC, id matching, framing      │
│                        │  (I/O on background queue, callbacks on main)  │
└────────────────────────┼────────────────────────────────────────────────┘
                         │ stdin/stdout (NDJSON)   stderr → log
                 ┌───────┴────────┐
                 │  agent process │  copilot --acp  |  claude-agent-acp  | …
                 └────────────────┘
```

### 4.1 `Frameworks/AgentClient` — protocol layer (no UI)

| Class | Responsibility |
|---|---|
| `AgentConnection` | Spawn/terminate process (NSTask), line framing, JSON-RPC request/response matching, notifications, incoming requests, stderr capture. All pipe I/O on a private serial queue; delegate callbacks on the main queue. |
| `AgentSession` | `initialize` → (`authenticate`) → `session/new`/`session/load` → prompt turns. Holds the transcript model, current tool calls, plan, modes, usage. Dispatches agent requests to the client-side handlers below. |
| `AgentFileSystem` | `fs/read_text_file` / `fs/write_text_file` against **open OakDocuments first** (so unsaved edits are seen and edits are undoable), disk otherwise. Enforces the project-root boundary. |
| `AgentTerminal` | `terminal/*`: runs commands in the project folder with the resolved environment, captures output with the agent-requested byte limit, exit status, kill/release. |
| `AgentRegistry` | Known agents (name, command, args, env), defaults for Copilot and Claude, user additions, `.tm_properties` override, PATH resolution. |

Transcript model types (`AgentMessage`, `AgentToolCall`, `AgentPlan`, …) are plain Objective-C objects so the UI layer binds to them directly.

### 4.2 `Frameworks/AgentUI` — panel

| Component | Responsibility |
|---|---|
| `AgentPanelController` | Docked panel: agent picker, session status, transcript, prompt field, Stop button. |
| Transcript view | Messages rendered from Markdown (`NSAttributedString` Markdown support, macOS 12+), code blocks in the theme's font; collapsible "thinking"; tool-call rows with status and output. |
| Permission prompt | Inline card showing the tool call (title, kind, command or diff) with the agent's options (`allow_once`, `allow_always`, `reject_once`, `reject_always`). |
| Diff review | For edit tool calls carrying `diff` content (`path`, `oldText`, `newText`): side-by-side or unified view; "Open in editor" jumps to the file. Uses vendored **xdiff** (already in the repo) for hunks. |
| Plan view | Checklist of plan entries with status. |

### 4.3 Hook points into existing TextMate code (kept small, separate commits)

1. **View ▸ Show Agent Panel** menu item + shortcut — `Applications/TextMate/src/AppController.mm` (menus are built in code with MenuBuilder).
2. **Panel slot** in the project window — `Frameworks/DocumentWindow/src/ProjectLayoutView.{h,mm}` gets an `agentView` alongside `fileBrowserView`/`htmlOutputView`; `DocumentWindowController` owns the `AgentPanelController`.
3. **Preferences ▸ Agents** pane — `Frameworks/Preferences` (registered in `Preferences.mm`).
4. **Context actions** — "Ask Agent About Selection" / "Send File to Agent" in the Text or contextual menu.
5. **CMake** — `add_subdirectory` for the two new frameworks; link from the TextMate target.

## 5. Behaviour details

### 5.1 Starting a session
1. User opens the panel (or sends a selection) → pick agent (remembered per project).
2. `AgentRegistry` resolves the command and environment; `AgentConnection` launches it.
3. `initialize` with `clientInfo {name: "textmate", title: "TextMate", version}` and capabilities `fs.readTextFile`, `fs.writeTextFile`, `terminal: true`.
4. If the agent lists `authMethods` and isn't signed in: show "Sign in" with the method's description; terminal-auth methods (e.g. `copilot login`) open in Terminal.app.
5. `session/new` with `cwd` = project folder (absolute), `mcpServers: []` initially.

### 5.2 Prompt turn
- Prompt = text + optional context blocks: current selection or file as an embedded `resource` (if `embeddedContext`), otherwise a `resource_link`.
- Stream `agent_message_chunk` into the transcript; `tool_call`/`tool_call_update` create/update rows; `plan` updates the checklist.
- **Stop** sends `session/cancel` and resolves pending permission prompts as `cancelled`.

### 5.3 File access
- **Read:** open document → its current buffer text (honours `line`/`limit`); else read from disk. Paths outside the project root (and outside `additionalDirectories`) are refused.
- **Write:** open document → replace content as one undoable edit and mark dirty (the user saves); not open → write to disk; the file browser/SCM status refreshes as usual.
- Writes only happen after the agent obtained permission per its own policy; TextMate additionally refuses writes outside the project root.

### 5.4 Permissions
- Default: **ask** for every request. "Always allow" choices are the agent's own options; TextMate does not auto-approve anything by itself in v1.
- Pending prompts are visible in the panel and the window's status; closing the window cancels the turn.

### 5.5 Environment and PATH
- Agent processes get the user's **login shell environment** (resolved once by running `$SHELL -l -c env`, cached), plus TextMate's project variables, plus agent-specific variables (e.g. `ANTHROPIC_API_KEY` from Keychain if configured).
- This fixes the known issue that TextMate's subprocesses don't see Homebrew/nvm paths.

### 5.6 Claude authentication options
1. **Claude subscription** (default) — the adapter uses the existing Claude Code login (`claude /login`). Verified working (Claude Pro).
2. **Anthropic API key** — stored in the **Keychain**, passed as `ANTHROPIC_API_KEY` to the agent process.
3. **Claude Code CLI login flow** — if the adapter reports it isn't signed in, offer to run `claude /login` in Terminal.app.

### 5.7 Lifecycle and robustness
- One process per project-window session; terminated on window close and app quit (`terminate`, then `SIGKILL` after a grace period).
- Agent crash → session marked failed with stderr tail shown; "Restart" re-creates it (and `session/load` when supported).
- Never block the main thread (no `dispatch_*_wait` on main — see the main-thread-blocking audit in `.serena/memories`).
- No process-global side effects (e.g. don't call `signal(SIGPIPE, …)` per connection — write errors are handled via `EPIPE`).
- Agent stderr and raw JSON-RPC traffic go to a log view (reuse the pattern of the LSP Debug Panel).

### 5.8 Configuration
- **Preferences ▸ Agents:** list of agents (name, command, arguments, environment), default agent, Claude auth mode/API key.
- **Defaults:** "GitHub Copilot" → `copilot --acp`; "Claude Code" → `npx -y @agentclientprotocol/claude-agent-acp`.
- **Per project:** `.tm_properties` keys `agentName` (pick a configured agent) and `agentCommand` (full override), mirroring the existing `lspCommand`.

## 6. Milestones (each ends with a demo you can test)

| | Milestone | Done when |
|---|---|---|
| **M1** | `AgentClient` core: connection, framing, JSON-RPC, session handshake, prompt streaming, cancel | CxxTest suite passes against a scripted fake agent; a debug command can chat with Copilot and Claude and print the reply to the log |
| **M2** | Panel v1: open/close, pick agent, chat transcript (Markdown), Stop | You can chat with both agents in a project window |
| **M3** | Tools: `fs/*` via OakDocument, permission prompts, diff review, `terminal/*` | An agent can read, edit (with approval) and run commands in a project; edits are undoable |
| **M4** | Preferences ▸ Agents, Keychain API key, `.tm_properties` override, session resume, plan view, context actions | All §5 configuration works |
| **M5** | Polish: theme integration, keyboard shortcuts, error states, log view, documentation | Ready for daily use; `pr/agent` port branch prepared |

## 6a. Chat panel features (VS Code–style) — added 2026-10-13

The chat panel aims to match VS Code's chat view where ACP makes it possible. Many controls are **driven by the agent** rather than hard-coded, so they work with any ACP agent:

- **Config options** (`configOptions` in `session/new`, `session/set_config_option`, `config_option_update`) → one popup per option in the panel header. Verified: Copilot sends Mode (Agent/Plan/Autopilot), Model, Reasoning Effort, Allow All; Claude sends Mode (Manual/Accept edits/Plan/Auto/Bypass permissions), Model, Effort, Fast mode. Fallback to the older `modes` field when `configOptions` is absent.
- **Slash commands** (`available_commands_update`) → completion list when typing `/` (Copilot: 33 commands, Claude: ~80 incl. skills). Invoked by sending `/name args` as prompt text.
- **Usage** (`usage_update`: tokens used/size, optional cost) → footer indicator.
- **Plans** (`plan`) → to-do list with status.

| VS Code chat feature | TextMate | Milestone |
|---|---|---|
| Chat docked beside the editor, toggle shortcut | Docked panel, left or right (setting), stacked next to the editor (file browser outside), **⌃⇧⌘I** (⌃⌘I is taken by the HTML bundle), resizable, width remembered | M2 |
| Agent / mode / model pickers | Agent popup + generic config-option popups | M2 |
| New chat | New Chat button (new session) | M2 |
| Markdown replies with code blocks | Markdown renderer (headings, lists, code, quotes, tables, links) | M2 |
| Code block actions: Copy, Insert at Cursor | Same | M2 |
| Code block action: Apply in Editor | Same, via diff review | M3 |
| Thinking / reasoning display | Collapsed “Thinking” row, click to expand | M2 |
| Tool call progress | Tool rows with status | M2 (output and diffs: M3) |
| To-do list | Plan view | M2 |
| Multi-line input, Enter to send, Stop | ↩ sends, ⇧↩/⌥↩ newline, Esc/Stop cancels, ↑ recalls last prompt | M2 |
| `/` commands | Completion from the agent's commands | M2 |
| Add Context: file, selection, open editors, drag & drop, images | “+” menu, drag & drop files, paste images (if the agent supports images), removable chips | M2 |
| Ask about selection from the editor | Text ▸ Ask Agent About Selection | M2 |
| Token/request usage | Usage footer | M2 |
| Tool confirmations (Allow / Always allow / Deny) | Permission cards | M3 |
| Review edits: Keep / Undo per file, changed-files list | Diff review + working set | M3 |
| Terminal command output | Terminal output in tool rows | M3 |
| Chat history (previous chats) | Session list / load / resume (both agents support it) | M4 |
| MCP servers | Configured per agent | M4 |
| Inline chat in the editor (⌘I) | Inline prompt at the caret | M5 |
| Syntax-highlighted code blocks | TextMate grammars + theme | M5 |
| Voice input | macOS Dictation works in the input field | M2 (built-in) |

Not applicable: VS Code chat participants (`@workspace`, `@terminal`) — the agents' own slash commands and tools cover these; thumbs-up/down feedback — not part of ACP.

### M2 layout
- The editor area is wrapped in a split view: `[chat | editor]` or `[editor | chat]`. `ProjectLayoutView` (upstream code) is unchanged; with the file browser on the same side the result is `file browser | chat | editor` — chat always next to the editor.
- One panel and session per project window, working in the project folder.
- Settings: `agentPanelPlacement` (`left`/`right`, default right), `agentPanelWidth`.

## 7. Review outcome (2026-10-13)

**Q1 — UI toolkit: AppKit.** Chosen for chat-specific strengths: one continuous, selectable and searchable transcript (TextKit), smooth handling of long conversations, code blocks highlighted with TextMate's own grammars and themes, no dependency on OakSwiftUI or the Swift build step, and year-to-year stability. Markdown: macOS's built-in parser labels block structure; an M2 renderer turns it into fonts, indentation, code-block backgrounds and tables in one text view. The UI stays a thin layer over `AgentClient` so parts could move to SwiftUI later. Note: upstream `master` targets macOS 10.12, so an upstream PR would need a raised minimum or a Markdown fallback.

**Q2 — Panel placement: docked, user chooses left or right side.** Resizable and hideable. Behaviour when it shares a side with the file browser is designed in M2.

**Q3 — Scope of v1: everything in §5** (files, permissions, diffs, terminals) by M3.

## 8. Testing approach
- **Unit tests (CxxTest)** in `Frameworks/AgentClient/tests`: framing (partial lines, large messages, invalid JSON), request/response matching, notification dispatch, cancellation, permission flow, fs boundary checks — using a small fake agent written in Ruby (`tests/fake_agent.rb`; Ruby is already a build requirement via `bin/gen_test`).
- **Integration (manual, per milestone):** Copilot CLI and Claude adapter on a scratch project; stderr captured per `.serena/memories/dev_testing_workflow.md`.
- Build and full `ctest` stay green on every merge to `main`.

## 9. Branching
- Work happens on `feature/agent`, now based on `main` (so it builds on current macOS with the `fix/*` changes).
- Hook-point commits (§4.3) stay separate from new-framework commits so the feature can be ported to upstream `master` later as `pr/agent` by cherry-picking.

## 10. Sources
- ACP overview, transports, initialization, session setup, prompt turn — https://agentclientprotocol.com/protocol/overview
- Claude adapter — npm `@agentclientprotocol/claude-agent-acp`
- Copilot CLI — `copilot --help` (`--acp`)
- TextMate code: `Frameworks/lsp/src/LSPClient.mm` (process/JSON-RPC patterns), `Applications/TextMate/src/AppController.mm` (menus), `Frameworks/DocumentWindow/src/ProjectLayoutView.h` (panels), `.serena/memories/*`
