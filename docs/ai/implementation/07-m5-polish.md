---
title: M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs
status: in progress
started: 2026-10-19
tags: [textmate, implementation, acp, agent]
---

# M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs

**Status:** 🔄 In progress (started 2026-10-19)
**Branch:** `feature/agent-polish` (from `feature/agent-config`)
**Design:** [agent-harness-design.md §5.1, §5.6, §5.7, §6, §6a](../plans/agent-harness-design.md)

## Goal
Ready for daily use (design §6, M5): code looks like it does in the editor, failures say what to do next, the agent's traffic can be inspected, common actions have shortcuts, an agent can be asked from the caret, and there is a user guide. Then the deferred UX pass and the `pr/agent` port.

## Plan

| Step | What | Where |
|---|---|---|
| 1. Log view | Window ▸ Agent Log: one window listing, per project and agent, the JSON-RPC messages (→ sent, ← received) and the agent's standard error, with time stamps. Search, filter (messages / errors), Copy, Clear; keeps the last 5,000 entries. Replaces the `NSLog` of standard error. Panel ▸ status menu ▸ Show Log opens it on the current session. | `AgentUI/AgentLog`, `AgentLogWindowController` |
| 2. Error states | Clear messages with a next step for: the command isn't found (Agent Settings…), the agent needs signing in (`authMethods`, or an `auth_required` error: Sign In runs the method's terminal command, e.g. `copilot login`, in Terminal; Claude: `claude /login`), the agent exits while starting or during a chat (its last output, Restart, Show Log), a request fails. Buttons in the transcript instead of “send a message to start it again”. | `AgentPanelViewController`, `AgentTranscript(View)`, `AgentSession` |
| 3. Theme | Code blocks in replies are highlighted with TextMate's grammars and the window's theme (theme background and text colours, the fence language mapped to a grammar: scope, file type or name, plus common aliases such as `js`, `sh`, `py`). Diff previews and terminal output use the theme's font. Re-rendered when the theme changes. | `OakMarkdown` (highlighter hook), `DocumentWindowController+Agent` (grammar + theme) |
| 4. Keyboard shortcuts | Permission cards: ↩ allows once, ⎋ rejects (when the prompt is empty). New Chat, Show History, and Show Log in the panel's menus with shortcuts while the panel has focus. Checked against menus and every bundle's `keyEquivalent`. | `AgentPromptView`, `AgentPanelViewController`, `AppController` |
| 5. Inline chat | Text ▸ Ask Agent at Caret (⌃⌥⌘I; ⌘I is Italic in Markdown/HTML): a small prompt field under the caret. The request goes to the window's agent chat with the selection (or current line) attached and the instruction to edit there; the field shows progress and Stop, then the files changed with Keep / Undo and a link to the reply in the panel. The panel doesn't need to be open. | `AgentUI/AgentInlinePrompt`, `OakTextView` (caret rect), `DocumentWindowController+Agent` |
| 6. Documentation | User guide for the agent panel: setup, agents and API keys, `.tm_properties`, MCP, chat history, permissions and changed files, inline chat, shortcuts, troubleshooting with the log. | `docs/ai/user/agent-panel.md` |
| 7. UX pass | The panel UX items the user deferred in M2 (to collect from the user) and the Markdown preview's scroll smoothness. | — |
| 8. `pr/agent` | Port onto upstream `master` (needs a decision: upstream builds with rave, not CMake, and targets macOS 10.12). | — |

Steps 1–6 are independent of the user's UX notes; 7 and 8 need the user first.

## Decisions
- Inline chat sends to the same agent chat as the panel (one session per window, design D7), so the conversation and changed files stay in one place; VS Code's separate inline sessions would need a second agent process.
- Highlighting stays out of `AgentUI` and `OakMarkdown`: `OakMarkdownStyle` gets a block that colours a code block, and the window supplies it with its grammar lookup and theme.

## Done

## Commits

## To check (user)

## Future work
