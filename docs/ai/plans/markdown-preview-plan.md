---
title: Markdown Support and Native Preview Pane — Plan
created: 2026-10-14
status: approved — in progress
tags: [textmate, plan, markdown, preview]
---

# Markdown Support and Native Preview Pane — Plan

> Implementation status: [docs/ai/implementation/](../implementation/README.md)

## 1. Context

TextMate can already preview Markdown through the Markdown bundle, but:
- the preview depends on `Markdown.pl` and a `ruby18` shim;
- it handles only classic Markdown (no GitHub tables, task lists, footnotes);
- it's an HTML command output pane, separate from the editor layout used by the agent panel.

This plan:
1. Documents the existing support (Part A).
2. Adds a native preview pane with two renderers (Part B):
   - **Built-in** (default): reuses the agent panel's Markdown renderer. No new dependencies.
   - **GitHub** (optional): `cmark-gfm` in a web view, installable and switchable from the TextMate UI so it can be tried out.

**Placement (user decision):** by default the preview goes opposite the agent panel. A setting moves it to the left, right, top or bottom of the document view.

## 2. Part A — Existing Markdown support

How to use what's there today:

- **Preview:** open a `.md` file, press **⌃⌥⌘P** (Bundles ▸ Markdown ▸ Markdown Preview). It refreshes as you type (`autoRefresh = DocumentChanged`); no need to save.
- **Docked beside the file:** Preferences ▸ Projects ▸ show command output **Right of Document** or **Below Document** (`htmlOutputPlacement` = `right` / `bottom`; default `window`). It uses TextMate's HTML output pane in `ProjectLayoutView`.
- **GitHub-flavoured output:** `brew install cmark-gfm`, then in `.tm_properties`:
  ```
  TM_MARKDOWN = "/opt/homebrew/bin/cmark-gfm --extension table --extension tasklist --extension strikethrough --extension autolink"
  ```
- **Requirements:** the `ruby18` shim in `Bundle Support.tmbundle/Support/shared/bin` (installed with the bundles), which downloads ruby 1.8.7 on first use. Verified (2026-10-15): the conversion runs, and with `TM_MARKDOWN` set to cmark-gfm it renders tables.
- **User guide** for the native preview: [docs/ai/user/markdown-preview.md](../user/markdown-preview.md).

## 3. Part B — Native preview pane

### P1 — Shared side-panel container (no behaviour change)
- Generalise `Frameworks/AgentUI/src/AgentEditorSplitView.{h,mm}` into an editor container that holds several panels.
- Each panel sits on one edge (left, right, top or bottom). Each has its own divider, size preference and minimum size.
- Keep the existing design:
  - Auto Layout constraints, not NSSplitView (OakDocumentView needs constraint-based minimum sizes).
  - Preferred size at priority 490, so the editor's minimum always wins and the window doesn't grow.
  - Editor adopted in `viewDidMoveToSuperview` (`ProjectLayoutView` removes it otherwise).
  - Plain divider view with no intrinsic size.
- Move it into a small neutral framework (`Frameworks/OakEditorPanels`, done), so the agent panel and preview don't depend on each other.
- Re-host the agent panel on it. The `DocumentWindowController+Agent.mm` hooks stay one-liners.
- Nesting: top/bottom panels span the editor column only. For example, `file browser | [preview | editor | chat]`, or `file browser | [editor over preview | chat]`.

### P2 — Shared Markdown renderer
- Extract `AgentMarkdownRenderer` / `AgentMarkdownStyle` (`Frameworks/AgentUI/src/AgentMarkdown.{h,mm}`) into a framework both features use (`Frameworks/OakMarkdown`, done). AgentUI uses it from there.
- Additions a document preview needs:
  - Local images resolved relative to the file (NSTextAttachment, scaled to the pane width).
  - Task-list markers (☐ / ☑) where Apple's parser exposes them.
  - Horizontal rules.
  - Links: http(s) opens in the browser; relative `.md` and other files open in TextMate (same as the agent panel's `openFile` delegate).
- Move the AgentUI Markdown tests with it and extend them.

Known limits of the built-in renderer: no raw HTML, footnotes or exact GitHub styling. That's what the optional GitHub renderer is for.

### P3 — Preview pane with the built-in renderer
- New `Frameworks/MarkdownPreview` with a `MarkdownPreviewViewController`:
  - TextKit 1 text view, read-only, selectable and searchable.
  - Follows the selected tab.
  - Shows a placeholder for non-Markdown documents (scope `text.html.markdown`).
- **Live update:**
  - Observe `OakDocumentContentDidChangeNotification` (`Frameworks/document/src/OakDocument.h`).
  - Debounce at about 150 ms and render from `document.content`, so unsaved text is shown.
  - Keep the scroll position across re-renders.
- **Scroll sync v1:** proportional (editor visible fraction ↔ preview). Precise sync comes with the GitHub renderer (P4), and later for built-in.
- **Appearance:** from the window, which follows the editor theme (`fix/window-follows-theme`).
- **Menus:**
  - View ▸ Show/Hide Markdown Preview, **⌃⇧⌘M** (user decision). ⌃⌥⌘P is the bundles' Show Preview and ⌃⇧⌘P is Bundle Development's Show Scope; no bundle or menu item uses ⌃⇧⌘M.
  - View ▸ Markdown Preview Position ▸ Automatic (opposite the agent panel) / Left / Right / Top / Bottom.
- **Defaults:** `markdownPreviewPlacement` (`auto`), `markdownPreviewWidth` / `markdownPreviewHeight` (saved by OakEditorPanels), `markdownPreviewRenderer` (`builtin`).
- **Hooks (done):** a `DocumentWindowController+MarkdownPreview.{h,mm}` category, plus one-line hooks in `DocumentWindowController.mm` (setup, placement, shutdown, menu validation), as for the agent panel.

### P4 — Optional GitHub renderer (cmark-gfm + WKWebView)
- **Binary:** an external `cmark-gfm` binary, so no new vendor dependency.
  - Found on the login-shell PATH via `AgentEnvironment` (`Frameworks/AgentClient/src/`), moved to a shared spot or reused.
  - `TM_MARKDOWN` from `.tm_properties` overrides the command, matching the bundle.
- **Command:** `cmark-gfm --sourcepos --extension table --extension tasklist --extension strikethrough --extension autolink --extension footnotes`.
  - Raw HTML stays escaped unless **Allow raw HTML** (`--unsafe`) is turned on.
- **Display (WKWebView):**
  - GitHub-style CSS for light and dark, following the window appearance.
  - JavaScript off except our scroll-sync script.
  - `loadFileURL:allowingReadAccessToURL:` scoped to the project folder, so local images load.
  - Links go through a navigation delegate (same rules as P2).
- **Precise scroll sync** via `data-sourcepos`: editor line ↔ preview.
- **Install and enable from the UI:**
  - Renderer popup in the pane header (Built-in / GitHub), and a matching Preferences option.
  - If `cmark-gfm` isn't found, an **Install cmark-gfm…** sheet:
    - With Homebrew: runs `brew install cmark-gfm` with visible progress and output.
    - Without: shows manual install steps and a **Locate…** button for a custom binary path (`markdownPreviewCmarkPath`).
  - If the binary fails, falls back to built-in with a notice.

### P5 — Docs, tests, polish
- Tests:
  - Renderer unit tests (OakMarkdown).
  - Container layout tests: all four edges, minimum sizes, two panels at once.
  - cmark-gfm runner tests, skipped when it isn't installed (like the hg/svn tests).
- User documentation.
- Update the implementation docs and Obsidian.
- Portability rules as for the agent harness: new frameworks, small separate hook commits, no dependency on tectiv3 internals.

## 4. Branching
`feature/markdown-preview`, branched from `feature/agent` (P1 reworks the agent panel container). Merged into `main` with the agent work. Each phase ends with a checkpoint for the user to test.

## 5. Open questions
- Later: whether the bundle's Markdown Preview command should open the native pane when it's enabled.

## 6. Critical files

| File | Change |
|---|---|
| `Frameworks/AgentUI/src/AgentEditorSplitView.{h,mm}` | Generalise into the shared container (P1) |
| `Frameworks/AgentUI/src/AgentMarkdown.{h,mm}` | Extract into the shared renderer (P2) |
| `Frameworks/DocumentWindow/src/DocumentWindowController+Agent.mm` | Re-host the agent panel; pattern for the preview category |
| `Frameworks/DocumentWindow/src/DocumentWindowController.mm` | One-line hooks |
| `Frameworks/DocumentWindow/src/ProjectLayoutView.{h,mm}` | Unchanged; the HTML output pane stays separate |
| `Frameworks/document/src/OakDocument.h` | `OakDocumentContentDidChangeNotification` for live update |
| `Frameworks/AgentClient/src/AgentEnvironment` | PATH lookup for `cmark-gfm` |

## 7. Verification (per phase)
- `make debug` builds with no new warnings; `ctest` passes.
- Manual checks in TextMate-dev (tell the user before driving the app):
  - Open a `.md` file and toggle the preview.
  - Type and watch it update.
  - Move it to each edge.
  - Use it together with the agent panel.
  - Switch to the GitHub renderer, including the install flow when `cmark-gfm` is missing.
  - Check scroll sync, images and links.
