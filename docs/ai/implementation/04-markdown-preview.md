---
title: Markdown Preview Pane
status: in progress
started: 2026-10-14
updated: 2026-10-14
tags: [textmate, implementation, markdown, preview]
---

# Markdown Preview Pane

**Status:** 🔄 In progress. P1 and P3 confirmed; P2 done; P4 done (2026-10-15), awaiting user test before P5.
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
| P3. Preview pane, built-in renderer | ✅ Done, confirmed by the user (2026-10-15: "Works well") |
| P4. Optional GitHub renderer | ✅ Done (2026-10-15), awaiting user test |
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

## P4 — Optional GitHub renderer (cmark-gfm)

| Part | Responsibility |
|---|---|
| `MarkdownPreviewCmark` (4 tests) | Finds cmark-gfm: the path chosen with Locate… (`markdownPreviewCmarkPath`) if still executable, else the login shell's PATH (via `AgentEnvironment`), else `/opt/homebrew/bin`, `/usr/local/bin`. Builds the arguments (`--sourcepos`, extensions table, tasklist, strikethrough, autolink, footnotes; `--unsafe` only with Allow raw HTML). Pipes Markdown through a command off the main thread, writing and reading concurrently, with a 10 s timeout; reports stderr or the exit status. |
| `MarkdownPreviewHTMLView` (4 tests) | WKWebView with GitHub-like CSS for light and dark. Loads the page once per document and then only replaces its content, so typing keeps the scroll position. Content JavaScript is off (`allowsContentJavaScript = NO`); our scripts run in `WKContentWorld.defaultClientWorld`. Local files are served through the `x-txmt-preview:` scheme, only from below the read access folder. Link clicks go to the delegate (in-page `#` links, e.g. footnotes, scroll the page); other navigation, e.g. a refresh in raw HTML, is blocked. Non-persistent website data store. |
| `MarkdownPreviewViewController` (now 5 tests) | Header (26 pt) with a notice line plus optional button on the left, and a Built-in / GitHub popup on the right, bound to `markdownPreviewRenderer`. Shows the built-in text view, the HTML view or the placeholder. `scrollToSourceLine:fraction:`. |
| `MarkdownPreviewInstallController` | Sheet: "Install with Homebrew" runs `brew install cmark-gfm` (non-interactive) and shows its output; "Locate…" chooses a binary and saves it; without Homebrew it explains how to install. Cancelling during an install stops it. |
| `DocumentWindowController+MarkdownPreview` | With GitHub chosen, runs cmark-gfm (or `TM_MARKDOWN`) on the unsaved text and shows the HTML; falls back to built-in with a notice. Offers the install sheet when the user picks GitHub and cmark-gfm is missing; cancelling switches back to built-in. |
| Preferences ▸ Projects | "Markdown preview: Built-in / GitHub (cmark-gfm)" and "Allow raw HTML (GitHub renderer)". |

- **`TM_MARKDOWN`:** if set (Preferences ▸ Variables, `.tm_properties`, or a bundle's shell variables), the GitHub renderer runs it with `/bin/sh -c` instead of cmark-gfm, as the Markdown bundle does. Without `--sourcepos` in its output, scrolling falls back to proportional.
- **Read access:** the project folder, or the document's folder when it's outside the project. Untitled documents can't load local files.
- **Remote images** load in the GitHub renderer (as on GitHub); the built-in renderer still never fetches them.
- **Scroll sync:** the editor's first visible line (from `lineRecordForPosition:`, with the fraction within the line) goes to the top of the preview. The script finds the innermost element whose `data-sourcepos` contains the line, or interpolates across the gap between elements (blank lines). The built-in renderer still scrolls proportionally.
- **Defaults:** `markdownPreviewRenderer` (`builtin`, registered), `markdownPreviewAllowRawHTML`, `markdownPreviewCmarkPath`. Keys are in `Preferences/Keys.h`.
- **Tests:** `test_cmark_gfm` runs only when cmark-gfm is installed (it isn't on the dev machine yet, so the install flow can be tried first).

Not in P4: ⌘F find in the GitHub renderer; two-way scroll sync.

**Fixed after user testing (2026-10-15):** scrolling was jumpy. The editor's line record covers one soft-wrapped row, so the fraction within a line restarted on each row; it's now measured over the whole line. The page mapping now interpolates between element starts (continuous across margins and adjacent blocks), caches its anchors until the layout changes, and only one scroll request is in flight at a time.

**Fixed after more testing (2026-10-15):** still jumpy in both renderers. The line's end was taken at the column past its last character, which is the next line's start, so each line measured one row too tall and the preview jumped at every line; the line now ends where the next one starts. The built-in renderer scrolled by the editor's height fraction, which shifts as the editor lays out rows lazily; it now marks source lines (`OakMarkdownStyle.marksSourceLines`, Foundation's `appliesSourcePositionAttributes`) and maps lines to positions like the GitHub renderer.

**To test (user):** relaunch (`make run`), open a `.md` file and show the preview (⌃⇧⌘M).
1. Pick **GitHub** in the preview's header popup. The install sheet appears; try **Cancel** (back to Built-in), then pick GitHub again and **Install with Homebrew** (shows brew's output; the preview switches to GitHub styling when done).
2. Check a table, a task list, ~~strikethrough~~, a footnote (click it), a local image, a relative link and a web link.
3. Scroll the editor: the preview should follow line by line, including over long code blocks.
4. Type: the preview updates without jumping.
5. Switch light/dark themes.
6. Preferences ▸ Projects: switch the renderer there; turn on **Allow raw HTML** and check that `<b>bold</b>` renders (off: it's left out).

### Commits
fe9b98ca cmark-gfm runner · 5d2557e9 HTML view · 8583da4b header, notices, install sheet · a300b4d2 GitHub renderer in the preview, Preferences

## Future work
- [x] The `editorPanelsView` accessor lived in the agent category; moved to `DocumentWindowController+EditorPanels` (P3).
- [ ] Save the preview's (and agent panel's) visibility in the session.
- [ ] Two-way scroll sync (preview scrolls the editor).
- [x] Precise scroll sync by source line for the GitHub renderer (P4).
- [x] Precise scroll sync for the built-in renderer (source positions from Foundation's parser).
- [ ] ⌘F find in the GitHub renderer's web view.
