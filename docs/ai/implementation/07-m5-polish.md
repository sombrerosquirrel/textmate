---
title: M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs
status: in progress
started: 2026-10-19
tags: [textmate, implementation, acp, agent]
---

# M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs

**Status:** 🔄 Steps 1–6 implemented (2026-10-19), awaiting user check; step 7: scroll smoothness done (2026-10-20), awaiting user check, panel UX waiting for the user's notes; step 8 deferred by the user ([To check](#to-check-user))
**Branch:** `feature/agent-polish` (from `feature/agent-config`)
**Design:** [agent-harness-design.md §5.1, §5.6, §5.7, §6, §6a](../plans/agent-harness-design.md)

## Goal
Ready for daily use (design §6, M5): code looks like it does in the editor, failures say what to do next, the agent's traffic can be inspected, common actions have shortcuts, an agent can be asked from the caret, and there is a user guide. Then the deferred UX pass and the `pr/agent` port.

## Plan

| Step | What | Where |
|---|---|---|
| 1. Log view | Window ▸ Agent Log: one window listing, per project and agent, the JSON-RPC messages (→ sent, ← received) and the agent's standard error, with time stamps. Search, filter (messages / errors), Copy, Clear; keeps the last 5,000 entries. Replaces the `NSLog` of standard error. Panel ▸ status menu ▸ Show Log opens it on the current session. | `AgentUI/AgentLog`, `AgentLogWindowController` |
| 2. Error states | Clear messages with a next step for: the command isn't found (Agent Settings…), the agent needs signing in (`authMethods`, or an `auth_required` error: Sign In runs the method's terminal command, e.g. `copilot login`, in Terminal; Claude: `claude /login`), the agent exits while starting or during a chat (its last output, Restart, Show Log), a request fails. Buttons in the transcript instead of “send a message to start it again”. | `AgentPanelViewController`, `AgentTranscript(View)`, `AgentSession` |
| 3. Theme | Code blocks in replies are highlighted with TextMate's grammars and the window's theme (theme background and text colours, the fence language mapped to a grammar: scope, file type or name, plus common aliases such as `js`, `sh`, `py`). Re-rendered when the theme changes. | `OakMarkdown` (highlighter hook), `DocumentWindowController+Agent` (grammar + theme) |
| 4. Keyboard shortcuts | Permission cards: ↩ allows once, ⎋ rejects (when the prompt is empty). View ▸ New Agent Chat (⌃⇧⌘N). Checked against menus and every bundle's `keyEquivalent`. | `AgentPromptView`, `AgentPanelViewController`, `AppController` |
| 5. Inline chat | Text ▸ Ask Agent at Caret (⌃⌥⌘I; ⌘I is Italic in Markdown/HTML): a small prompt field under the caret. The request goes to the window's agent chat with the selection (or current line) attached and the instruction to edit there; the field shows progress and Stop, then the files changed with Keep / Undo and a link to the reply in the panel. The panel doesn't need to be open. | `AgentUI/AgentInlinePrompt`, `OakTextView` (caret rect), `DocumentWindowController+Agent` |
| 6. Documentation | User guide for the agent panel: setup, agents and API keys, `.tm_properties`, MCP, chat history, permissions and changed files, inline chat, shortcuts, troubleshooting with the log. | `docs/ai/user/agent-panel.md` |
| 7. UX pass | The panel UX items the user deferred in M2 (to collect from the user) and the Markdown preview's scroll smoothness. | — |
| 8. `pr/agent` | Port onto upstream `master` (needs a decision: upstream builds with rave, not CMake, and targets macOS 10.12). Deferred by the user (2026-10-20: "can wait for now, there's still more work to do first"). | — |

Steps 1–6 are independent of the user's UX notes; 7 and 8 need the user first.

## Decisions
- Inline chat sends to the same agent chat as the panel (one session per window, design D7), so the conversation and changed files stay in one place; VS Code's separate inline sessions would need a second agent process.
- Highlighting stays out of `AgentUI` and `OakMarkdown`: `OakMarkdownStyle` gets a block that colours a code block, and the window supplies it with its grammar lookup and theme.

## Done

| Step | What | Where |
|---|---|---|
| 1. Log view | `AgentLog` (shared, last 5,000 entries, one change notification per run loop cycle) records each panel's JSON-RPC messages, standard error (no longer `NSLog`ged) and events: starting with the command line, started with version and session, not started, exited with status, closed. Window ▸ Agent Log: agent and kind filters, search (summary, JSON, source), Copy, Clear; appends as entries arrive, follows the end when scrolled there. Agent popup ▸ Show Agent Log opens it on that agent. | `AgentUI/AgentLog`, `AgentLogWindowController`, `AppController` |
| 2. Error states | Checked 2026-10-19 with an empty `HOME`: Copilot answers `session/new` with `-32000 Authentication required` and an auth method whose `_meta.terminal-auth` is `copilot login`; Claude Code starts, sends `_auth/status_update` `{kind: none}`, and fails prompts with the same error (signed in, it sends `kind: account`). Errors and notices carry action links: **Sign In** (the agent's terminal-auth command, ACP `type: terminal`, or the built-in `claude auth login` / `copilot login`, run from a `.command` file in Terminal), **Try Again** (restarts the agent if needed and resends the failed message), **Restart** (after the agent stopped; continues the chat), **Agent Settings…**, **Show Log**. A missing built-in command says how to install it. | `AgentClient` (`AgentErrorIsAuthenticationRequired`, `signInArguments`, `installHint`), `AgentTranscript` (item actions), `AgentPanelViewController` |
| 3. Theme | `OakMarkdownStyle` gains code block background and text colours and a highlighter block; the window supplies its theme's colours and highlights with `OakTextView`'s hover highlighter, the fence language mapped to a grammar (aliases, then grammar name, file type, `source.‹lang›`; cached). Highlighted blocks are cached while replies stream; re-rendered on theme changes. | `OakMarkdown`, `AgentTranscriptView`, `AgentPanelViewController`, `DocumentWindowController+Agent` |
| 4. Shortcuts | ↩ / ⎋ in an empty prompt answer the oldest open permission card (allow_once / reject_once, else the first allow / reject option), marked ↩ and ⎋ on the card. View ▸ New Agent Chat ⌃⇧⌘N. | `AgentPromptView`, `AgentTranscript`, `AppController` |
| 5. Inline chat | Text ▸ Ask Agent at Caret… ⌃⌥⌘I: popover at the caret with the selection (or caret position) as context; the request is a normal message in the window's chat with the open file as the place to edit. The popover shows the running tool call, permission requests (Allow ↩ / Reject ⎋), then the files changed in that turn with Keep / Undo / Show in Chat, or the reply. Busy agents are refused with a message. | `AgentInlinePromptController`, `AgentPanelViewController`, `DocumentWindowController+Agent` |
| 6. Documentation | [Agent panel user guide](../user/agent-panel.md). | `docs/ai/user/agent-panel.md` |

Checked in the running app (2026-10-19, via a probe): a reply with Python, Objective-C and unknown-language code blocks renders in the theme's colours; sign-in and other errors show their links; the log lists the start, messages, standard error and `_auth/status_update`; the log window's controls lay out.

Tests: AgentClient adds sign-in arguments, install hints and the auth error check; AgentUI adds the log (summaries, detail, search, trimming) and permission keyboard options; OakMarkdown adds the highlighter and code block colours. `ctest` 28/28.

### Step 7a — Markdown preview scroll smoothness (2026-10-20)

The user asked for all four ideas from the Markdown preview's future work. Measured in TextMate-dev with a probe (below) on a test document with long paragraphs (one source line each, many lines in the preview), a 400 pt image, code blocks, lists and tables.

| Idea | Result |
|---|---|
| Tall paragraphs and images | The cause of the remaining speed-ups. The editor mapped its position linearly between anchors, so a source line 20 pt tall in the editor and 400 pt in the preview made the preview move 20× faster for that line. `MarkdownPreviewScrollMap.h` now maps editor y → preview y through (editor y, preview y) anchor pairs and averages that map over a window of ±¼ of the editor's height (exact integral of the piecewise-linear map; the window shrinks at the ends so the top and bottom still map exactly). The preview never moves backwards, its speed changes gradually, and where editor and preview have the same proportions nothing changes. Replaces the monotone cubic in both C++ and the page script. |
| Live measurement of the GitHub renderer | A probe library loaded into the running app with lldb (not in the repo): the editor scrolls itself at a constant speed from a display link; a `requestAnimationFrame` recorder in the page (or the built-in view's clip view) logs the preview's position each frame; results go to a file, nothing waits inside lldb. Lessons: lldb passes literal numbers as `int`, so doubles must be cast (`(double)120`) or the function reads garbage; a probe's frames only fire while its window is on screen (the probe floats it above other windows during a run); give each probe build its own entry point name. |
| Time-based easing | Implemented (display link in the built-in view, `requestAnimationFrame` in the page; exponential, 40 ms) and measured: easing every step made scrolling *less* even (judder 0.09–0.12 against 0.02–0.06 for the page; also tried 20 ms and a critically damped spring), because the editor already delivers one step per frame. Kept only for jumps of more than half the preview's height (Page Down, ⌘↓, Go to Line), which now glide over about 20 frames instead of cutting; once easing, it follows the editor to the end. Re-syncs after rendering never animate. |
| Anchors after images load | The page reports its anchors to the app (`tmAnchors` script message, from the client world) after each content change and whenever `#content` changes size (`ResizeObserver`: images loading, width changes), and the editor re-syncs at once. Before, the page only noticed on the next scroll, and the editor's map never learned the new positions. |

Measured (speed-up: the fastest 100 ms over the mean speed, 1 = even; judder: mean change in per-frame step over the mean step, normal-length frames only):

| | Before | After |
|---|---|---|
| Built-in, 120 pt/s | speed-up 14.8, judder 0.19 | 2.3, 0.10 |
| Built-in, 1200 pt/s | 3.8, 0.45 | 2.5, 0.11 |
| GitHub, 120 pt/s | 11.3, 0.06 | 2.2, 0.02 |
| GitHub, 1200 pt/s | — (recorder bug in the baseline run) | 1.9, 0.05 |

The remaining speed-up of about 2 is the tall paragraph and image spread over the window; with a wider window it would be lower but the preview would drift further from the editor's top line.

API: the preview reports `anchors` (NSPoint: source line, preview y) and takes `scrollToPosition:animated:` / `scrollToFraction:animated:` instead of `anchorLines` and `scrollToSourceLine:fraction:`; the window category does the mapping. Tests: `t_scroll_map` (7, replaces `t_interpolation`), the HTML view reports anchors and re-reports them when the layout changes, the built-in view's anchors and positions. MarkdownPreview 31 tests; `ctest` 28/28.

## Commits
4752a0a7 agent log · 3c5b671c error states · 5e3198e7 theme highlighting · 98808424 permission keys, New Agent Chat · 3a2f3d1b inline chat

## To check (user)
1. Window ▸ Agent Log while chatting: messages appear live; filter by agent and kind, search, Copy, Clear. Agent popup ▸ Show Agent Log shows only that agent.
2. A reply with code (e.g. “show me a Python and a shell example”): code blocks in the editor theme's colours and highlighted; change the theme (View ▸ Theme) and they follow.
3. Claude in Manual mode, ask for an edit: with the message field empty, ↩ allows, ⎋ rejects; the card marks the options ↩ and ⎋.
4. ⌃⇧⌘N starts a new chat (also with the panel hidden).
5. Inline chat: select some code, ⌃⌥⌘I, ask e.g. “add a doc comment”. The popover shows progress (and Allow / Reject in Manual mode), then the changed file with Keep / Undo; Undo restores it; Show in Chat opens the panel with the exchange. Try with the panel hidden.
6. Error states without signing out: Preferences ▸ Agents, add an agent with command `env HOME=/tmp copilot --acp`, start a chat with it: “needs you to sign in” with Sign In (opens Terminal with `copilot login` — close it without signing in), Try Again, Agent Settings…. An agent with command `no-such-agent`: “Unable to find…” with Try Again and Agent Settings…. Remove the test agents afterwards.
7. Kill the agent (`pkill -f claude-agent-acp`): “stopped running” with Restart and Show Log; Restart continues the chat.
8. Read the [user guide](../user/agent-panel.md).
9. Markdown preview scrolling (both renderers, a document with images and long paragraphs): scroll slowly and quickly. No rush through images or long paragraphs; the top line drifts a little near them and lines up again after. Page Down / ⌘↓ / ⌘↑ in the editor: the preview glides there. Open a document whose images load after it's shown: the preview stays lined up without scrolling.

## Future work
- Inline Undo restores a file to before the agent's first change in the chat, not just this request's change, when the file was already in the changed-files list.
- Inline chat shows the reply as plain text; Markdown and a diff preview in the popover would help.
- The log isn't saved; an option to write it to a file for long sessions.
