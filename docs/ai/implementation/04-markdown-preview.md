---
title: Markdown Preview Pane
status: in progress
started: 2026-10-14
updated: 2026-10-14
tags: [textmate, implementation, markdown, preview]
---

# Markdown Preview Pane

**Status:** 🔄 In progress. P1 confirmed; P2 done; P3 done (2026-10-15), awaiting user test before P4.
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
| P1. Shared editor panels container | ✅ Done, confirmed by the user (2026-10-15) |
| P2. Shared Markdown renderer | ✅ Done (2026-10-15), awaiting user check |
| P3. Preview pane, built-in renderer | ✅ Done (2026-10-15), awaiting user test |
| P4. Optional GitHub renderer | ⏳ Not started |
| P5. Docs, tests, polish | ⏳ Not started |

## P1 — Shared editor panels container

`Frameworks/OakEditorPanels` (11 tests) replaces `AgentUI/AgentEditorSplitView`:

| Class | Responsibility |
|---|---|
| `OakEditorPanel` | One docked panel: view, edge (left, right, top, bottom), preferred width and height, minimum sizes (200 × 100), optional `autosaveName` that saves sizes as ‹name›Width / ‹name›Height. |
| `OakEditorPanelsView` | Holds the editor and its panels. Left and right panels span the full height; top and bottom panels span the editor column. Panels on the same edge are ordered outermost first. Each panel has a 1 pt divider that can be dragged. |

Design kept from the agent split view: Auto Layout rather than NSSplitView, preferred size at priority 490 so the editor's minimum always wins, editor adopted in `viewDidMoveToSuperview`, plain divider view with no intrinsic size.

The container keeps the editor at least 320 × 150 pt (`minimumEditorSize`, priority 491), so a large saved size or a long drag can't push the editor out of view. Found in testing: the agent panel had been dragged to 942 pt and saved (7b0f2cc3).

Panels are clipped to their bounds (`clipsToBounds`), because views no longer clip by default and the agent panel's background had painted over the editor (be2e00a6).

The agent panel now uses it (`DocumentWindowController+Agent.mm`). Its width is still saved as `agentPanelWidth` (autosave name `agentPanel`), and placement as `agentPanelPlacement`. No change in behaviour.

Tests run on the main thread (`RunOnMainThread` in `t_editor_panels.mm`), because the test runner runs tests on background threads and AppKit layout must happen on the main thread.

**To test (user):** show the agent panel (⌃⇧⌘I), drag its divider, move it left and right, close and reopen it; it should behave as before.

### Commits
dca8eb08 OakEditorPanels framework · c67c610d agent panel hosted in it · 7b0f2cc3 minimum editor size · be2e00a6 clip panels

## P2 — Shared Markdown renderer

`Frameworks/OakMarkdown` (15 tests) holds the renderer used by the agent chat and, from P3, the preview. `AgentMarkdown*` became `OakMarkdown*` (`OakMarkdownStyle`, `OakMarkdownRenderer`, `OakMarkdownCodeBlock`, `OakMarkdownCodeBlockAttributeName`); AgentUI links it.

Added for documents:

| Feature | How |
|---|---|
| Relative links and images | New `baseURL:` parameter (the document's file URL); links are stored as absolute URLs. |
| Local images | `NSTextAttachment`, scaled down to `style.maximumImageWidth` keeping the aspect ratio; alt text as tooltip. |
| Remote or missing images | Never fetched (previewing a file doesn't reach the network); shown as `[alt]` linking to the image URL. |
| Task lists | `- [ ]` / `- [x]` become ☐ / ☑. Foundation's parser doesn't support them and leaves the marker in the text. |
| Horizontal rules | A full-width 1 pt line (bottom border of a text block). |

Found and fixed along the way (also affect agent chat):
- Horizontal rules showed `⸻⸻`: the parser emits its own ⸻ and the renderer added another.
- Block quotes collapsed to one character per line: their text block had no width.
- Code backgrounds weren't drawn: a system colour made translucent with `colorWithAlphaComponent:` isn't drawn as a text block background. Now an explicit light/dark colour.
- Intermittent crash when rendering on several threads (seen as a flaky OakMarkdown test run): the named dynamic code colour was created on every call, and creating it concurrently corrupts memory. Now created once. Bold/italic use font descriptors instead of `NSFontManager` (main thread only). Verified with a 20,000-document concurrent stress tool; a unit test couldn't reproduce the race.

Checked visually by rendering a sample document offscreen (headings, inline styles, task list, rule, local and remote image, quote, table, code block).

Not supported by the built-in renderer (as planned; the GitHub renderer in P4 covers them): raw HTML (shown as text), footnotes.

**To test (user):** the preview pane comes in P3. Meanwhile the agent chat uses the new renderer: ask the agent for a reply with a block quote, a code block, a task list, a table and a horizontal rule.

### Commits
b4ef2342 move to OakMarkdown · 79aa34e9 images, task lists, rules, base URL · 2377dd86 concurrent rendering crash

## P3 — Preview pane with the built-in renderer

| Part | Responsibility |
|---|---|
| `Frameworks/MarkdownPreview` — `MarkdownPreviewViewController` (3 tests) | Read-only, selectable TextKit 1 view (find bar enabled) or a placeholder. Keeps the scroll position across re-renders; re-renders when its width changes so images refit; `scrollFraction` for syncing; link clicks go to its delegate. Knows nothing about documents or windows. |
| `DocumentWindowController+MarkdownPreview` | A coordinator per window: follows `selectedDocument` (KVO), re-renders 150 ms after `OakDocumentContentDidChangeNotification` from `document.content` (unsaved text), re-renders when the grammar (`fileType`) changes, and scrolls with the editor (proportional, from the editor clip view's bounds changes). |
| `DocumentWindowController+EditorPanels` | The shared panels container, moved out of the agent category. |

- **Markdown documents:** grammar scope `text.html.markdown…`, or extension md, markdown, mdown, mkd, mkdn. Other documents show a placeholder.
- **Links:** files open in TextMate (in this project's window); folders and web or mail links open in their apps; missing files beep.
- **Look:** document-like text background (white in light themes), 16 pt margins, 14 pt text; follows the window's light/dark appearance.
- **Menus:** View ▸ Show/Hide Markdown Preview (⌃⇧⌘M); View ▸ Markdown Preview Position ▸ Automatic / Left / Right / Top / Bottom.
- **Defaults:** `markdownPreviewPlacement` (`auto`: opposite the agent panel's side, even when the agent panel is hidden), `markdownPreviewWidth` / `markdownPreviewHeight`.
- **Hooks in `DocumentWindowController.mm`:** `setupEditorPanels` (replaces `setupAgentPanelSupport`), `shutdownMarkdownPreview`, `updateMarkdownPreviewPlacement`, menu validation.

Not in P3: the preview's visibility isn't saved in the session (nor is the agent panel's); scrolling the preview doesn't scroll the editor; the renderer popup in the header (P4).

**To test (user):** open a `.md` file, press ⌃⇧⌘M; type and watch it update; scroll the editor; try each position, also with the agent panel open; switch tabs to a non-Markdown file; click a relative link and a web link; switch between light and dark themes.

### Commits
11cf3a4a MarkdownPreview framework · 444f4fdb shared panels container · 91d4a20d preview in the project window

## Future work
- [x] The `editorPanelsView` accessor lived in the agent category; moved to `DocumentWindowController+EditorPanels` (P3).
- [ ] Save the preview's (and agent panel's) visibility in the session.
- [ ] Two-way scroll sync (preview scrolls the editor); precise sync by source line (P4, later for built-in).
