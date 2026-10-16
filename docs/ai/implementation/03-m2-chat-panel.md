---
title: M2 — Chat Panel
status: in progress
started: 2026-10-13
updated: 2026-10-14
tags: [textmate, implementation, agent, ui]
---

# M2 — Chat Panel

**Status:** 🔄 In progress. Implemented and pushed; the user is testing it. Marked complete after the user confirms.
**Branch:** `feature/agent`
**Design:** [agent-harness-design.md §4.2, §6, §6a](../plans/agent-harness-design.md)

## Goal
Chat with Copilot and Claude in a panel docked beside the editor, with the VS Code chat features that ACP supports (design §6a).

## Decisions (user)
- AppKit UI, not SwiftUI.
- Panel can sit on the left or right; it is stacked next to the editor, with the file browser outside.
- Include VS Code–style chat features (§6a).
- Shortcut ⌃⇧⌘I. ⌃⌘I (VS Code's) was used first, but the HTML bundle's Add Persistent Include has it for `text.html`, which includes Markdown, and bundle shortcuts win when the editor has focus. Changed 2026-10-14.

## Done

`Frameworks/AgentUI` (21 tests):

| Component | Responsibility |
|---|---|
| `AgentMarkdown` | Markdown renderer on `NSPresentationIntent`: headings, lists, code blocks with Copy / Insert footers, quotes, tables, links. |
| `AgentTranscript` | Transcript model: messages, thinking, tool calls, plan. |
| `AgentAttachment` | File, selection and image content blocks; unsaved document text is sent as shown. |
| `AgentTranscriptView` | TextKit 1 view with coalesced updates and `textmate-agent:` action links (Copy, Insert at Cursor, toggle thinking, open file). |
| `AgentPromptView` | ↩ sends, ⇧↩/⌥↩ newline, Esc stops, ↑/↓ history, `/` command list, attachment chips, drag files in, paste images. |
| `AgentCommandList` | Slash command list above the prompt, with descriptions. It never takes focus: ↩ sends the selected command, ⇥ completes it, ↑/↓ select, Esc closes. |
| `AgentEditorSplitView` | Auto Layout container `[editor | panel]` or `[panel | editor]` with a draggable divider. Not NSSplitView, because OakDocumentView needs constraint-based minimum widths. The panel width is a preference at priority 490. |
| `AgentPanelViewController` | Header (agent picker, New Chat), transcript, prompt, config-option popups (mode, model, effort…) and status/usage footer. |

TextMate integration (`Frameworks/DocumentWindow/src/DocumentWindowController+Agent.{h,mm}`): panel toggle, placement, Ask About Selection, insert as escaped snippet, open file at line. The main `DocumentWindowController` has four one-line hooks.

Menus: View ▸ Show/Hide Agent Panel (⌃⇧⌘I; focuses the panel if it's open but not focused), View ▸ Move Agent Panel to Left/Right Side, Text ▸ Ask Agent About Selection.

Defaults: `agentPanelPlacement` (right), `agentPanelWidth` (380), `agentPanelAgent` (copilot).

## Issues found in testing and fixed

| Report | Cause | Fix |
|---|---|---|
| Crash on Ask Agent; no status bar; black editor | Split view adopted the editor in `init`, then `ProjectLayoutView` removed it. NSSplitView frames conflicted with OakDocumentView constraints. A zero-frame NSBox separator collapsed the window. | Adopt in `viewDidMoveToSuperview`; constraint-based container; `AgentDividerView` (1418d472). |
| Panel dark in a light theme | macOS is in dark mode; the panel followed the system appearance; some areas had no background. Placeholder property name collided with a private NSTextView property (text drawn twice). | Backgrounds filled; renamed properties (9b5adbd9). Whole window now follows the theme (`fix/window-follows-theme`); panel inherits it (6da8258f). |
| Tabs too short; white line under tabs; white file browser | See [01-build-and-bug-fixes.md](01-build-and-bug-fixes.md#ui-fixes-added-2026-10-13-found-while-testing-m2) | `fix/tab-bar-height`, `fix/file-browser-background` |
| ⌃⌘I opened a broken `--informative-…` window instead of the panel | The HTML bundle's Add Persistent Include uses ⌃⌘I for `text.html` (so also Markdown, PHP, ERB); bundle shortcuts take priority over menu shortcuts in the editor. Its CocoaDialog file dialog doesn't work on current macOS. | Shortcut changed to ⌃⇧⌘I, which no bundle or menu item uses. |
| ↩ in the slash command list only closed it; a second ↩ was needed to send | On macOS 27, NSTextView's completion popup handles ↩ outside the app: it closes without calling `insertCompletion:` or passing the key on, so nothing in the app can react (5c1f55cd had no effect). | Own list, `AgentCommandList`, a child panel the prompt drives (feff8fdf). |
| Crash on ↩ in the new list | Closing cleared the commands without reloading the table; a pending layout asked for a removed row. | Reload on close, check the row (feff8fdf). |
| No slash commands at all; panel said only "Agent exited with status 1" | The user's shell setup had switched to Node 14, whose `npx` doesn't know `-y`. The agent's error output only goes to `NSLog`. | Not a TextMate bug, but the panel now shows the agent's last error lines when it fails to start or stops (`recentStandardError`, 3aa62947). |
| Panel filled the whole window, hiding the document; transcript white in a light theme | Mainly: the panel's background view filled the whole dirty rect, which (views no longer clip by default since the macOS 14 SDK) extended over the editor, so the editor drew underneath but was painted grey (fixed f8d58336; the container also clips panels, be2e00a6). Also, nothing kept the editor wider than its 100 pt text area, so a drag let the panel take the window and the width (942) was saved. The transcript used the text background. | Editor kept at least 320 × 150 (7b0f2cc3, `feature/markdown-preview`); saved width reset to 380. Panel and transcript use the file browser's background, `NSColor.tmSidebarBackgroundColor` (2c0aed39). |

## Commits
8ecd469e §6a plan · ffc740ac AgentUI + Markdown · 4d8c4a0d transcript model · 72b93fd9 attachments · 7723847e chat panel · d6d22909 project window integration · 1418d472 layout fix · 9b5adbd9 theme/backgrounds · 6da8258f inherit window appearance

## Remaining before M2 is complete
- [ ] User confirmation after testing.
- [ ] Not yet checked in the GUI: dragging the divider, Insert at Cursor, open-file links, switching between light and dark themes with the panel open.
- [ ] Update the design doc status to "M2 done" and sync Obsidian.

## Future work
- [ ] Commit 7723847e alone doesn't build (it removes the debug window files that AppController references until d6d22909). Regrouping needs a force-push of `feature/agent`; awaiting the user's decision.
- [ ] Exact theme colours and syntax-highlighted code blocks (M5).
- [ ] **Agent panel UX pass** (user, 2026-10-15: "ux of the panel needs some work but we'll tackle that at the end"). Scheduled after the Markdown preview and M3–M4; collect specifics from the user then.
