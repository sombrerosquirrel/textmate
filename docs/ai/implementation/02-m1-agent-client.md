---
title: M1 — AgentClient Core
status: complete
started: 2026-10-13
completed: 2026-10-13
tags: [textmate, implementation, acp, agent]
---

# M1 — AgentClient Core

**Status:** ✅ Complete (2026-10-13)
**Branch:** `feature/agent`
**Design:** [agent-harness-design.md §4.1, §5, §6](../plans/agent-harness-design.md)

## Goal
A UI-free framework that speaks the Agent Client Protocol (ACP v1: newline-delimited JSON-RPC over stdio) to agent subprocesses. Tested against a fake agent; it can chat with Copilot and Claude.

## Done

`Frameworks/AgentClient`:

| Component | Responsibility |
|---|---|
| `AgentConnection` | Launches the agent with `NSTask`; NDJSON framing; separate read and write queues; `F_SETNOSIGPIPE` so a dead agent can't kill TextMate. |
| `AgentSession` | `initialize` / `session/new` handshake, prompt streaming, cancel, permission requests (defaults to "cancelled" until M3), `configOptions`, `modes`, `availableCommands`, `setConfigOption:`, `setMode:`. |
| `AgentEnvironment` | Captures the user's login-shell environment (`-l -i`) so agents installed via nvm, Homebrew and similar are found; PATH lookup. |
| `AgentRegistry` | Descriptors for Copilot and Claude; `makeSessionForAgent`. |

Agents:
- **Copilot:** `copilot --acp` (Copilot CLI installed under nvm; reports 1.0.97).
- **Claude:** `npx -y @agentclientprotocol/claude-agent-acp` (0.90.0). The `@zed-industries` package names are deprecated. Signed in with the user's Claude Pro account; API key and Claude Code CLI login are also supported (auth lives in the agent process).

Tests: 27 CxxTest cases against a scripted Ruby fake agent (`Frameworks/AgentClient/tests/fake_agent.rb`).

A temporary Text ▸ Agent debug window (c00cc1b6) was used to chat with both agents. It was removed in M2.

## Commits
0790474d design doc · 6ae4f274 AgentClient framework · c00cc1b6 debug window · 516f16dc design decisions · 77a69b8e config tracking + AgentRegistry

## Future work
- [x] Permission requests answer "cancelled" by default; real prompts arrive in M3. Done in [05-m3-tools.md](05-m3-tools.md).
- [x] `fs/*` and `terminal/*` client capabilities are not advertised yet (M3). Done in [05-m3-tools.md](05-m3-tools.md).
