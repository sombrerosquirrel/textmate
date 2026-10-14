---
title: Markdown Preview Pane
status: in progress
started: 2026-10-14
updated: 2026-10-14
tags: [textmate, implementation, markdown, preview]
---

# Markdown Preview Pane

**Status:** 🔄 In progress. P1 done; waiting for the user to test before P2.
**Branch:** `feature/markdown-preview` (from `feature/agent`)
**Plan:** [markdown-preview-plan.md](../plans/markdown-preview-plan.md)

## Goal
A native Markdown preview docked beside the editor on any edge, with a built-in renderer and an optional GitHub renderer (cmark-gfm) that can be installed from the TextMate UI.

## Decisions (user)
- Both renderers; the GitHub renderer is optional and installable from the UI.
- By default the preview goes opposite the agent panel; a setting moves it to the left, right, top or bottom.
- Shortcuts: ⌃⇧⌘M for the preview; the agent panel moves from ⌃⌘I to ⌃⇧⌘I (2026-10-14). ⌃⌘I belongs to the HTML bundle's Add Persistent Include in HTML and Markdown files, and ⌃⇧⌘P (first proposed for the preview) to Bundle Development's Show Scope.

## Phases

| Phase | Status |
|---|---|
| P1. Shared editor panels container | ✅ Done (2026-10-14), awaiting user test |
| P2. Shared Markdown renderer | ⏳ Not started |
| P3. Preview pane, built-in renderer | ⏳ Not started |
| P4. Optional GitHub renderer | ⏳ Not started |
| P5. Docs, tests, polish | ⏳ Not started |

## P1 — Shared editor panels container

`Frameworks/OakEditorPanels` (10 tests) replaces `AgentUI/AgentEditorSplitView`:

| Class | Responsibility |
|---|---|
| `OakEditorPanel` | One docked panel: view, edge (left, right, top, bottom), preferred width and height, minimum sizes (200 × 100), optional `autosaveName` that saves sizes as ‹name›Width / ‹name›Height. |
| `OakEditorPanelsView` | Holds the editor and its panels. Left and right panels span the full height; top and bottom panels span the editor column. Panels on the same edge are ordered outermost first. Each panel has a 1 pt divider that can be dragged. |

Design kept from the agent split view: Auto Layout rather than NSSplitView, preferred size at priority 490 so the editor's minimum always wins, editor adopted in `viewDidMoveToSuperview`, plain divider view with no intrinsic size.

The container keeps the editor at least 320 × 150 pt (`minimumEditorSize`, priority 491), so a large saved size or a long drag can't push the editor out of view. Found in testing: the agent panel had been dragged to 942 pt and saved (7b0f2cc3).

The agent panel now uses it (`DocumentWindowController+Agent.mm`). Its width is still saved as `agentPanelWidth` (autosave name `agentPanel`), and placement as `agentPanelPlacement`. No change in behaviour.

Tests run on the main thread (`RunOnMainThread` in `t_editor_panels.mm`), because the test runner runs tests on background threads and AppKit layout must happen on the main thread.

**To test (user):** show the agent panel (⌃⇧⌘I), drag its divider, move it left and right, close and reopen it; it should behave as before.

### Commits
dca8eb08 OakEditorPanels framework · c67c610d agent panel hosted in it · 7b0f2cc3 minimum editor size

## Future work
- [ ] The `editorPanelsView` accessor lives in the agent category; move it somewhere shared when the preview category is added (P3).
