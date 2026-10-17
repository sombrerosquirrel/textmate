---
title: Markdown Preview — User Guide
updated: 2026-10-16
tags: [textmate, user-guide, markdown, preview]
---

# Markdown Preview — User Guide

TextMate shows a live preview of the Markdown document you're editing, docked beside the editor in the project window. It updates as you type, without saving, and scrolls with the editor.

## Showing the preview

- **View ▸ Show Markdown Preview** (⌃⇧⌘M) shows or hides it.
- It follows the selected tab. For a document that isn't Markdown, it says so and waits.
- A document counts as Markdown if its grammar is Markdown (scope `text.html.markdown…`) or, before a grammar is picked, if its extension is `md`, `markdown`, `mdown`, `mkd` or `mkdn`.
- Drag the divider to resize it. The size is remembered (separately for side and top/bottom positions).

## Position

**View ▸ Markdown Preview Position:**

| Position | Where |
|---|---|
| Automatic (default) | Opposite the agent panel: left, unless the agent panel is on the left |
| Left / Right | Beside the editor, full height |
| Top / Bottom | Above or below the editor, as wide as the editor |

The preview and the agent panel can be shown together.

## Renderers

Pick one in the popup at the top right of the preview, or in **Preferences ▸ Projects ▸ Markdown preview**.

| | Built-in (default) | GitHub (cmark-gfm) |
|---|---|---|
| Needs | Nothing | `cmark-gfm`, installed from the preview |
| Looks like | TextMate's agent chat | GitHub |
| Tables, task lists, strikethrough, bare URLs as links | Yes | Yes |
| Footnotes | Yes | Yes |
| Raw HTML (`<b>`, `<details>`, …) | Shown as text | Safe tags rendered, as on GitHub; all of it with **Render all HTML** |
| Local images | Yes | Yes, from the project folder (or the document's folder if it's outside the project) |
| Remote images | Never loaded; shown as a link | Loaded, as on GitHub |
| Find (⌘F) | Yes | Not yet |

### Installing cmark-gfm

When you choose **GitHub** and cmark-gfm can't be found, a sheet offers:

- **Install with Homebrew:** runs `brew install cmark-gfm` and shows its output. The preview switches to the GitHub renderer when it's done.
- **Locate…:** choose a `cmark-gfm` binary you already have. TextMate remembers it.
- **Cancel:** goes back to the built-in renderer.

Without Homebrew, the sheet explains how to install cmark-gfm.

TextMate looks for cmark-gfm in this order: the binary chosen with Locate…, your login shell's `PATH`, then `/opt/homebrew/bin` and `/usr/local/bin`.

If cmark-gfm fails, the preview shows the built-in rendering with a notice explaining why.

### Render all HTML

Off by default: like GitHub, the GitHub renderer keeps safe HTML (`<b>`, `<i>`, `<kbd>`, `<sup>`, `<details>`, `<summary>`, `<br>`, `<img>`, tables, …) and removes the rest, such as forms, styles, scripts and event attributes; the text inside removed tags still shows. Links must be web, mail or relative links. Turn on **Render all HTML** in **Preferences ▸ Projects** to show all HTML as written, for documents you trust. Scripts in the document never run either way, and the preview never navigates away from the document.

To show HTML tags as text instead, in either renderer, put them in backticks: `` `<b>bold</b>` `` shows `<b>bold</b>` in code style. A fenced code block (```` ``` ````) does the same for several lines of HTML.

### Your own Markdown command (`TM_MARKDOWN`)

If `TM_MARKDOWN` is set (in **Preferences ▸ Variables** or a `.tm_properties` file), the GitHub renderer runs that command instead of cmark-gfm, as the Markdown bundle does. It gets the Markdown on standard input and must print HTML. For example, in `.tm_properties`:

```
[ *.md ]
TM_MARKDOWN = "/opt/homebrew/bin/cmark-gfm --sourcepos --extension table --extension footnotes"
```

Include `--sourcepos` (or any `data-sourcepos` attributes) for line-by-line scrolling; without it, the preview scrolls in proportion to the editor.

## Scrolling

The line at the top of the editor is kept at the top of the preview. Headings, paragraphs, lists, code blocks and tables line up; in between, the preview scrolls smoothly.

The preview doesn't scroll the editor (one-way only).

## Links

- **Web and mail links** open in your browser or mail app.
- **Links to files**, including relative ones like `[guide](docs/guide.md)`, open in TextMate in the same project window. Links to folders open in Finder. A missing file beeps.
- **In-page links** (footnotes and their ↩) scroll the preview, not the editor. The next time you scroll the editor, the preview follows it again.

## Light and dark

The preview follows the window's appearance, which follows the editor theme.

## The Markdown bundle's preview

The Markdown bundle's own preview still works and is separate:

- **Bundles ▸ Markdown ▸ Markdown Preview** (⌃⌥⌘P) opens it in an HTML output window and refreshes as you type.
- **Preferences ▸ Projects ▸ Show command output: Right of Document / Below Document** docks it in the project window.
- It renders classic Markdown (no tables or task lists) unless `TM_MARKDOWN` is set, e.g. to cmark-gfm with extensions.
- It uses ruby 1.8 through the Bundle Support `ruby18` shim, which downloads it on first use.

## Settings

All in the TextMate-dev / TextMate user defaults (`defaults write com.macromates.TextMate …`):

| Key | Values | Set by |
|---|---|---|
| `markdownPreviewPlacement` | `auto`, `left`, `right`, `top`, `bottom` | View ▸ Markdown Preview Position |
| `markdownPreviewRenderer` | `builtin`, `github` | Preview popup, Preferences ▸ Projects |
| `markdownPreviewAllowRawHTML` | `YES` / `NO` | Preferences ▸ Projects |
| `markdownPreviewCmarkPath` | Path to `cmark-gfm` | Locate… in the install sheet |
| `markdownPreviewWidth`, `markdownPreviewHeight` | Points | Dragging the divider |

## Not yet

- The preview's visibility isn't restored when a project reopens.
- Scrolling the preview doesn't scroll the editor.
- Find (⌘F) in the GitHub renderer.
