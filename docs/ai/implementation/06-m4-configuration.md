---
title: M4 — Configuration: Preferences, Keychain, Project Overrides, Chat History, MCP
status: awaiting user check
started: 2026-10-18
tags: [textmate, implementation, acp, agent]
---

# M4 — Configuration: Preferences, Keychain, Project Overrides, Chat History, MCP

**Status:** 🔄 Implemented 2026-10-19, awaiting user check ([To check](#to-check-user))
**Branch:** `feature/agent-config` (from `feature/agent-tools`)
**Design:** [agent-harness-design.md §5.1, §5.5–§5.8, §6, §6a](../plans/agent-harness-design.md)

## Goal
All configuration in design §5 works (design §6, M4): agents are configured in Preferences, API keys live in the Keychain, a project can pick or override its agent in `.tm_properties`, previous chats can be listed and resumed, and MCP servers are passed to the agents.

## What both agents support (checked 2026-10-18)

| | Copilot CLI 1.0.97 | Claude Agent ACP 0.90.0 |
|---|---|---|
| `loadSession` | ✅ | ✅ |
| `sessionCapabilities` | `list`, `close` | `list`, `close`, `delete`, `fork`, `resume`, `additionalDirectories` |
| `session/list` with `cwd` | ✅ `{ sessionId, cwd, title, updatedAt }` | ✅ same fields |
| `mcpCapabilities` | `http`, `sse` (stdio is always supported) | `http`, `sse` |
| Token from the environment | `COPILOT_GITHUB_TOKEN` (before `GH_TOKEN`, `GITHUB_TOKEN`) | `ANTHROPIC_API_KEY` |

Plan view and Ask Agent About Selection, listed under M4 in design §6, were done in M2.

## Plan

| Step | What | Where |
|---|---|---|
| 1. Agent configuration | Agents are the two built-in ones plus the user's own, each with name, command line (quoted like `lspCommand`), environment variables, and on/off. Built-in agents can be edited and restored, not removed. Stored in user defaults; a notification tells open panels to refresh the agent picker. | `AgentClient/AgentRegistry` |
| 2. Project overrides | `.tm_properties` keys `agentName` (which configured agent the project uses) and `agentCommand` (replaces that agent's command line; if `agentName` names no configured agent, the picker gets a project agent of that name, or “Project Agent”). Read for the project folder when the panel starts a session. | `DocumentWindowController+Agent`, `AgentPanelViewController` |
| 3. Keychain | Per agent: an API key kept in the Keychain and the variable it's passed in (defaults `ANTHROPIC_API_KEY` for Claude Code, `COPILOT_GITHUB_TOKEN` for Copilot). Used only while “Use API key” is on, so Claude can switch between the subscription login and an API key. | `AgentClient/AgentKeychain`, `AgentRegistry` |
| 4. Preferences ▸ Agents | Pane with two tabs. Agents: list (on/off, name), + / −, and for the selected agent its name, command, environment, API key. MCP Servers: list (on/off, name, type, command or URL), + / −, environment or headers. | `Preferences/AgentsPreferences` |
| 5. MCP servers | One list for all agents (each agent also reads its own MCP configuration). Sent in `session/new` and `session/load`: stdio servers with the command resolved on the login-shell `PATH`; http/sse servers only to agents that announce them, with a notice naming any left out. | `AgentRegistry`, `AgentSession` |
| 6. Chat history | A history button in the panel header lists this project's previous chats (`session/list` with `cwd`; title and date) and loads one (`session/load`; the agent replays it into the transcript). When the agent stops and is started again, the chat is loaded back without replaying it. | `AgentSession`, `AgentPanelViewController` |
| 7. Context actions | File browser ▸ Add to Agent Chat: attaches the selected files. | `FileBrowser`, `DocumentWindowController+Agent` |

Tests: CxxTest for command line splitting, configuration (defaults, edits, restore, removal, overrides), MCP server conversion and filtering, session/list and session/load against the fake agent (replay, sessionId), Keychain round-trip with a test-only service.

## Decisions
- One MCP server list shared by all agents, instead of one per agent (design §6a). Both agents also read their own MCP configuration (`~/.claude.json`, `.mcp.json`, `~/.copilot/mcp-config.json`), so TextMate's list is for servers to add from TextMate.
- No separate “default agent” setting: the picker remembers the last agent used, and `agentName` sets it per project.
- `AgentClient` stays Foundation-only: command lines are split by its own parser (same quoting rules as `path::unescape`), and `.tm_properties` is read on the TextMate side and passed in.

## Done

`Frameworks/AgentClient`:

| Component | Responsibility |
|---|---|
| `AgentRegistry` | Built-in and user agents in user defaults (`agents`); built-in ones store only changed settings, so new defaults still apply; left-out built-ins are added back. `makeAgent`, `defaultAgentWithIdentifier:`, `AgentRegistryDidChangeNotification`. `agentsForProjectWithAgentName:command:projectAgent:` applies `.tm_properties` (by name or identifier, any case; a disabled agent named by the project is included). `AgentArgumentsFromCommandLine` splits command lines. MCP servers in `agentMCPServers`. `makeSessionForAgent:` adds the agent's environment and Keychain key (read off the main thread) and the enabled MCP servers. |
| `AgentMCPServer` | Name, type, command line or URL, environment or headers; `ACPRepresentationWithEnvironment:` resolves a stdio command on the login-shell `PATH` (nil if not found or incomplete). |
| `AgentKeychain` | Generic passwords, service “TextMate Agent API Key”, account = agent identifier. |
| `AgentSession` | `mcpServers` / `skippedMCPServerNames` (http/sse left out unless `mcpCapabilities` says so); `canListSessions`, `canLoadSessions`; `listSessionsWithCompletion:` (`session/list` with `cwd`); `loadSession:completion:` on a ready session (closes the previous chat if `session/close` is supported); `sessionIdToLoad` for start, falling back to `session/new` with `loadError`; new state `AgentSessionStateLoading`. |

`Frameworks/Preferences`: `AgentsPreferences` (Agents and MCP Servers tabs), registered between Formatters and Terminal; `-[Preferences showWindowWithPaneIdentifier:]`. The pane sizes itself from its constraints: the preferences window pins each pane to its frame, and a frame that didn't match the constraints aborted the debug build when switching panes.

`Frameworks/AgentUI` (`AgentPanelViewController`): picker built from `agentsForProject…`, with Agent Settings… (sends `showAgentPreferences:`); refreshed on `AgentRegistryDidChangeNotification`, the running chat keeps its agent until the next start. History button (clock) in the header: up to 30 chats with relative dates, the current one checked, disabled until the agent is ready and hidden for agents without `session/list`. Loading clears the transcript and changed-files list, then the replay fills the transcript (edits in the replay aren't tracked). After the agent stops, the next message starts it with `sessionIdToLoad` and the replay is skipped; if loading fails, a notice says the agent lost the earlier context. `-addFilesAtPaths:`.

TextMate integration: `agentSettingsForAgentPanel:` reads `agentName` / `agentCommand` with `settings_for_path` for the project folder. File browser ▸ Add to Agent Chat sends `addFilesToAgentChat:` up the responder chain; the window shows the panel and attaches the files.

Checked in the running app (2026-10-19, via a probe): the Agents pane renders and switching panes no longer aborts; the panel lists Claude Code's 17 chats for this folder; loading “Test comment” replays its 5 items and later prompts go to it.

Tests: AgentClient 66 (new: registry 8 incl. Keychain round-trip, sessions 9: list, load, load at start and fallback, MCP filtering). The fake agent learned `--sessions` and `mcp`. `ctest` 28/28.

## Commits
344317b2 configuration, Keychain, MCP, list and load · 364513ce Agents pane · 402ec2be register pane, Agent Settings… · 7649ae25 picker, history, restore · 2267d3b6 `.tm_properties`, Add to Agent Chat

## To check (user)
1. Preferences ▸ Agents: both agents listed; edit Claude's command (e.g. add `--debug`), Restore Defaults brings it back. Add an agent, give it a command, check it appears in the panel's picker; remove it.
2. Turn an agent off: it leaves the picker (stays while its chat is open).
3. API key: for Claude, tick “Use an API key”, paste a key, start a New Chat; the agent should use it (Claude's `/status` or usage shows API billing). Untick to go back to the subscription. The key is in Keychain Access under “TextMate Agent API Key”.
4. `.tm_properties` in a project: `agentName = "Claude Code"` makes new windows of that project start with Claude; `agentCommand` with an unknown `agentName` adds that agent to the picker.
5. MCP Servers tab: add a stdio server (e.g. `npx -y @modelcontextprotocol/server-everything`), New Chat, ask the agent to list its MCP tools. A server with a wrong command gives a notice in the chat.
6. History button: lists earlier chats with dates; choosing one shows it and continues it. Check how replayed user messages look (attachments appear as Markdown links; the current-file note may show).
7. Quit the agent's process (e.g. `pkill -f claude-agent-acp`), send a message: the chat continues with its context, without duplicating the transcript.
8. File browser: select files ▸ right-click ▸ Add to Agent Chat: chips appear in the prompt.
9. Agent picker ▸ Agent Settings… opens Preferences on the Agents pane.

## Future work
- Replayed user messages show the prompt as sent, including attachment links and the current-file note; strip TextMate's own additions when replaying.
- More than the first page of `session/list` (`nextCursor`); delete chats (`session/delete`, Claude only).
- Import MCP servers from a JSON file in the common `mcpServers` format.
- Per-agent MCP server selection, if one shared list turns out to be too coarse.
- Sign-in flow for agents that report `authMethods` (e.g. run `copilot login` in Terminal) — M5 error states.
