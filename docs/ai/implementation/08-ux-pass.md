---
title: UX Pass — Agent Panel and Markdown Preview
status: in progress
started: 2026-10-20
tags: [textmate, implementation, ux, agent, markdown]
---

# UX Pass — Agent Panel and Markdown Preview

**Status:** 🔄 In progress. §3–§11 are done, committed and confirmed by the user (M5 checks 9–21, 2026-11-02); the tab bar's stuck hover state is fixed (§13, 2026-11-02). What's left is in [§14](#14-to-do).
**Branch:** `feature/agent-polish`
**Implementation details:** [M5 step 7](07-m5-polish.md#step-7a--markdown-preview-scroll-smoothness-2026-10-20) (7a–7d). This document collects the UX work by feature: what the user asked for, how we compare with VS Code, what changed, and how to test it.

## Contents
1. [Where the chat lives: Copilot in VS Code compared with our panel](#1-where-the-chat-lives-copilot-in-vs-code-compared-with-our-panel)
2. [What the chat is built from: Copilot's UI compared with ours](#2-what-the-chat-is-built-from-copilots-ui-compared-with-ours)
3. [Markdown preview: scroll smoothness](#3-markdown-preview-scroll-smoothness)
4. [Markdown preview: the editor follows the preview](#4-markdown-preview-the-editor-follows-the-preview)
5. [Markdown preview: only for Markdown documents](#5-markdown-preview-only-for-markdown-documents)
6. [Chat: folding, and code blocks as editor views](#6-chat-folding-and-code-blocks-as-editor-views)
7. [Chat: links to files not created yet](#7-chat-links-to-files-not-created-yet)
8. [Chat: permission cards](#8-chat-permission-cards)
9. [Chat: disclosure arrows](#9-chat-disclosure-arrows)
10. [Chat: smooth scrolling to new text](#10-chat-smooth-scrolling-to-new-text)
11. [Chat: working indicator and status](#11-chat-working-indicator-and-status)
12. [Test prompt](#12-test-prompt)
13. [Tab bar: stuck hover state](#13-tab-bar-stuck-hover-state)
14. [To do](#14-to-do)

---

## 1. Where the chat lives: Copilot in VS Code compared with our panel

**GitHub Copilot in VS Code.** Copilot Chat is a view in the **Secondary Side Bar**: VS Code's second sidebar, on the right by default, opposite the Explorer. It belongs to the window rather than the editor area, sits outside the editor groups, and can hold other views as tabs. It can be hidden, resized and moved to the other side. It also appears as:
- a chat in an editor tab or its own window ("Open Chat in Editor" / "in New Window"), so several chats can be open side by side;
- **Quick Chat**, a floating box at the top of the window (⇧⌥⌘L);
- **inline chat** (⌘I) at the cursor, as its own session;
- several sessions at once, with a history list.

**Our agent panel.**
- A split inside the editor area, not a sidebar. `AgentEditorSplitView` wraps the editor as `[editor | panel]` or `[panel | editor]`, with its own Auto Layout divider. `ProjectLayoutView` is unchanged, so the file browser stays outside: `file browser | chat | editor`. The chat is always next to the code.
- Left or right (View ▸ Move Agent Panel…), resizable, width saved (default 380); the editor keeps at least 320 × 150.
- ⌃⇧⌘I toggles it (VS Code's ⌃⌘I is the HTML bundle's).
- One panel and one session per project window. No chat in an editor tab, no Quick Chat.
- Inline chat (⌃⌥⌘I, Ask Agent at Caret) sends to the same session as the panel, so the conversation and changed files stay in one place. It works with the panel closed.
- Chat history (list / load / resume): you switch chats inside the one panel.

| | VS Code Copilot | Ours |
|---|---|---|
| Where it lives | Window-level Secondary Side Bar | Split inside the editor area, next to the editor |
| Relation to the file tree | Opposite side (default) | Between the file tree and the editor, or on the far side |
| Chats at once | Several (sidebar + editor tabs + windows) | One per project window |
| Quick Chat | Yes | No |
| Inline chat | Separate session | Same session as the panel |
| Pickers (mode, model, etc.) | Built in | Set by the agent through ACP `configOptions` |

The controls inside the panel mostly match VS Code ([design §6a](../plans/agent-harness-design.md)):

| VS Code chat feature | TextMate | Milestone |
|---|---|---|
| Chat docked beside the editor, toggle shortcut | Docked panel, left or right (setting), stacked next to the editor (file browser outside), **⌃⇧⌘I** (⌃⌘I is taken by the HTML bundle), resizable, width remembered | M2 |
| Agent / mode / model pickers | Agent popup + generic config-option popups | M2 |
| New chat | New Chat button (new session) | M2 |
| Markdown replies with code blocks | Markdown renderer (headings, lists, code, quotes, tables, links) | M2 |
| Code block actions: Copy, Insert at Cursor | Same | M2 |
| Code block action: Apply in Editor | Same, via diff review | M3 |
| Thinking / reasoning display | Collapsed "Thinking" row, click to expand | M2 |
| Tool call progress | Tool rows with status | M2 (output and diffs: M3) |
| To-do list | Plan view | M2 |
| Multi-line input, Enter to send, Stop | ↩ sends, ⇧↩/⌥↩ newline, Esc/Stop cancels, ↑ recalls last prompt | M2 |
| `/` commands | Completion from the agent's commands | M2 |
| Add Context: file, selection, open editors, drag & drop, images | "+" menu, drag & drop files, paste images (if the agent supports images), removable chips | M2 |
| Ask about selection from the editor | Text ▸ Ask Agent About Selection | M2 |
| Token/request usage | Usage footer | M2 |
| Tool confirmations (Allow / Always allow / Deny) | Permission cards | M3 |
| Review edits: Keep / Undo per file, changed-files list | Diff review + working set | M3 |
| Terminal command output | Terminal output in tool rows | M3 |
| Chat history (previous chats) | Session list / load / resume (both agents support it) | M4 |
| MCP servers | One list for all agents, Preferences ▸ Agents | M4 |
| Inline chat in the editor (⌘I) | Inline prompt at the caret, ⌃⌥⌘I (⌘I is Italic in Markdown/HTML) | M5 |
| Syntax-highlighted code blocks | TextMate grammars + theme | M5 |
| Collapsible code blocks and messages | Folded code block lines with place; every message folds (§6) | UX pass |
| Code blocks as editor views | Read-only `OakTextView` per unfolded block (§6) | UX pass |
| Voice input | macOS Dictation works in the input field | M2 (built-in) |

The difference is in layout and how many chats you can have, not in the features.

## 2. What the chat is built from: Copilot's UI compared with ours

**Copilot Chat.** VS Code runs on Electron, so all of its UI is HTML in Chromium. Copilot Chat is **not a webview** (the sandboxed iframe extensions use, and VS Code's Markdown preview uses). The chat UI is part of VS Code (`src/vs/workbench/contrib/chat`), built from the same widgets as the rest of the window; the Copilot extension supplies the agent through the chat API.
- **`ChatViewPane`**: a normal view pane like Explorer or Search, in the Secondary Side Bar.
- **`ChatWidget`**: the conversation, a **virtualized list**. Each request or reply is a row, drawn by a renderer and created only when it scrolls into view.
- **Markdown replies**: rendered to HTML.
- **Code blocks**: each an **embedded read-only Monaco editor**, the main editor's component: real highlighting, the theme, Copy / Insert / Apply.
- **Input (`ChatInputPart`)**: also a Monaco editor, giving `/` and `#` completion and attachment decorations.

**Ours.** Mostly plain AppKit subclasses, not Oak views.

| Part | Copilot (VS Code) | Ours (AgentUI) |
|---|---|---|
| Panel | `ChatViewPane` (workbench view) | `AgentPanelViewController` (`NSViewController`) inside `AgentEditorSplitView` |
| Transcript | Virtualized list, one row per message | **One `NSTextView`** (TextKit 1) holding the whole conversation as one attributed string, with `textmate-agent:` action links |
| Markdown | Rendered to HTML | `OakMarkdown` → attributed string |
| Code blocks | Embedded Monaco editors | Before the UX pass: text coloured by TextMate grammars and the theme (M5 step 3). **Now: a folded line; unfolded, a read-only `OakTextView` (`OakCodeView`) in an attachment (§6).** |
| Input | Monaco editor | `AgentPromptTextView` (`NSTextView`) |
| `/` list | Editor's suggest widget | `AgentCommandList`, a child `NSPanel` with an `NSTableView` (the built-in completion popup is broken on macOS 27) |
| Changed files, permissions | List rows | `NSStackView` / `NSView` |

**The real difference.** VS Code puts its real editor inside the chat, for code blocks and the input. We used plain text views and borrowed only the grammars and theme, so code looked like the editor but didn't behave like it: no folding, no editor selection commands, no bundle shortcuts. §6 closes this gap for code blocks. The other difference remains: one text view rather than a list of rows means very long chats re-lay-out more text, and per-message controls (hover actions) are harder. The prompt as an `OakTextView` and a row-based transcript are still open (§11).

## 3. Markdown preview: scroll smoothness

**Asked (2026-10-15):** "Much smoother now, make a note to revisit this later … when doing UX". On 2026-10-20 the user asked for all four ideas from the preview's future work. Details: [M5 step 7a](07-m5-polish.md#step-7a--markdown-preview-scroll-smoothness-2026-10-20).

| Idea | Result |
|---|---|
| Tall paragraphs and images | The cause of the remaining speed-ups: a source line 20 pt tall in the editor and 400 pt in the preview made the preview move 20× faster. The editor → preview map now goes through anchor pairs and is averaged over ±¼ of the editor's height, so the preview never moves backwards and its speed changes gradually. |
| Live measurement | A probe loaded into the running app with lldb scrolls the editor at a constant speed and records the preview's position each frame. |
| Time-based easing | Easing every step made scrolling *less* even, because the editor already moves once per frame. Kept only for big jumps (Page Down, ⌘↓, Go to Line), which glide over about 20 frames. |
| Anchors after images load | The page reports its anchors after each content change and size change (images loading), and the editor re-syncs at once. |

Measured (speed-up: fastest 100 ms over mean speed, 1 = even; judder: mean change in per-frame step over the mean step):

| | Before | After |
|---|---|---|
| Built-in, 120 pt/s | speed-up 14.8, judder 0.19 | 2.3, 0.10 |
| Built-in, 1200 pt/s | 3.8, 0.45 | 2.5, 0.11 |
| GitHub, 120 pt/s | 11.3, 0.06 | 2.2, 0.02 |
| GitHub, 1200 pt/s | — (recorder bug in the baseline run) | 1.9, 0.05 |

**Status:** done (commit `18d0c678`), confirmed by the user (2026-11-02).

## 4. Markdown preview: the editor follows the preview

**Asked (2026-10-22):** the editor should track the preview's scrolling as well. Details: [M5 step 7b](07-m5-polish.md#step-7b--the-editor-follows-the-preview-2026-10-22).

| What | How |
|---|---|
| Same map, inverted | Both directions use one map, so scrolling one side then the other never jumps. |
| Only the user's scrolls | Wheel, scroller, keys, find and in-page links move the editor; the preview's own scrolls (following the editor, re-rendering) don't. |
| No feedback | Scrolls the editor makes to follow the preview don't move the preview again. |
| In-page links | Footnotes and ↩ now move the editor too. |

**Status:** done (commit `cf78658d`), confirmed by the user (2026-11-02).

## 5. Markdown preview: only for Markdown documents

**Asked (2026-10-22):** the preview should show only while a Markdown document is selected; switching away closes it, switching back reopens it in the same place and size; the default for any preview panel. Details: [M5 step 7c](07-m5-polish.md#step-7c--preview-panels-only-for-documents-they-can-show-2026-10-22).

| What | How |
|---|---|
| Suspended panels | A suspended panel leaves the layout but keeps its edge, order and size, so it comes back exactly where it was. Works for any preview panel. |
| Markdown preview | Suspended while the selected document isn't Markdown. The menu still says Hide; Show is disabled for a non-Markdown document. The "isn't a Markdown document" placeholder is gone. |

**Status:** done (commit `cf78658d`), confirmed by the user (2026-11-02).

## 6. Chat: folding, and code blocks as editor views

**Asked (2026-10-24):** "Not being able to fold code block and other message blocks was one of the ux issues I noticed. Please add OakTextView code blocks and folding to the chat. Automatically fold code blocks under a line describing it and where it sits." Details: [M5 step 7d](07-m5-polish.md#step-7d--folding-in-the-chat-code-blocks-as-editor-views-2026-10-24).

Decisions (user):

| Question | Choice |
|---|---|
| What the line over a code block says | Language, line count, and file + lines, e.g. `▸ Objective-C · 18 lines · Parser.mm:120–137` |
| What folds | Everything: your messages, replies, thinking, tool calls, plans. The latest exchange stays open; earlier ones fold when you send. Code blocks first started folded; changed 2026-10-24 to start open, with a header toggle (below). |
| Editable code blocks? | Read-only: "if it needs editing, this can be done in the editor window by bringing the file into view". The place on the line is a link to the file. |

What you see:
- **Folded code block:** one line with ▸, language (the grammar's name), line count, and the place as a link that opens the file at those lines, plus Copy. Without a known place, the block's first line of code.
- **How the place is found:** the file from a path in the fence (` ```swift Sources/A.swift`, `objc:path`, `title="path"`), a file named just before the block, files the exchange's tool calls touched, or your open documents (only files that exist on disk). The lines by finding the code in that file; placeholder lines like `// …` count as left-out code.
- **Unfolded:** a read-only editor view in your theme and the language's font. Long lines scroll sideways; the wheel scrolls the chat. Select, copy, find and fold (F1) work; typing, paste and undo don't. Copy / Insert at Cursor / Apply in Editor below. The view stays put while the reply streams.
- **Messages:** ▾ / ▸ on each; folded, a one-line summary (📎 count for attachments, "· N code blocks" for replies).

**Changed (2026-10-24):** "show the code (open disclosure arrow) instead of hiding. Put a toggle - just an icon that changes with the state in the top header bar with a tool tip about what this is. The toggle will either show all or hide all blocks that currently exist along with future blocks."

| What | How |
|---|---|
| Default | Code blocks start open (▾), showing the code. |
| Header toggle | An icon beside Previous Chats: `rectangle.expand.vertical` while code blocks are shown, `rectangle.compress.vertical` while they're folded. Its tooltip says which and what a click does. A click shows or folds every code block in the chat, including those opened or folded by hand, and sets how later replies' blocks start. Remembered (`agentPanelFoldsCodeBlocks`, default NO). Since 2026-10-31 the icon folds and opens everything with an arrow, not only code blocks; a row with an open question stays open until it's answered. Prompts no longer have an arrow or fold. |
| Per block | Clicking a block's line still opens or folds just that block, until the toggle is used again. |

Test: `toggle_shows_or_folds_all_code_blocks`.

Found in the app and fixed: the code view used the current document's font (proportional for Markdown); no space under the actions line; after a `// …` line the range ended one brace early.

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02).

## 7. Chat: links to files not created yet

**Reported (2026-10-24):** "why are the files empty even though you're showing text in the chat window?"

| Cause | Fix |
|---|---|
| In Manual mode the writes were waiting for approval; the chat showed the proposed content. Clicking `↳ geometry.py` opened a new, empty document at that path (M3 behaviour). | A link to a file that doesn't exist says "not created yet"; clicking it shows the proposed content (the tool call's diff) instead of opening an empty document. After the write, it opens the file as usual. Code block places only use files on disk. |

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02).

## 8. Chat: permission cards

**Reported (2026-10-24):** "there's no permission card to allow". Then: "When a Permission card is displayed, pause until it is answered then continue."

| Problem | Fix |
|---|---|
| The card was there, but Yes / No came after a 12-line diff preview. | The options come right after the card's title, before the details. |
| The card was added above a later tool row, and the panel only follows new output when scrolled to the bottom. | A new open card scrolls its question and options into view. |
| Output kept arriving below the card (e.g. a parallel tool call or a second card). | While a card waits, the panel holds what the agent sends, including further cards, and shows it in order once the card is answered or cancelled. The open card is always last. Stop, closing the chat or the agent exiting cancels waiting cards. |
| The same diff twice, with the card between (screenshot, 2026-10-24): the agent announces the write as a tool row (with its diff), then asks, and the card repeated the diff; another tool call ("Preparing file…") had arrived in between. | The details show once. While the card is open, the tool row is just its title with "waiting for approval", and the card has the diff. Once answered, the card keeps its title and outcome, and the row shows the diff again. |
| The answer showed up later, below another write (screenshots, 2026-10-24): a card was an item of its own at the end of the chat, and the agent had already announced its next write, so geometry.py's card and its "✓ Yes" sat after Widget.swift's row. | The user: put the question after the code. The question and options now sit inside the tool call's row, after its diff (one copy of the diff, replacing the fix above). Answered, the question goes and the answer shows on the row's line (`Write geometry.py  ·  ✓ Yes`). A request with no tool row of its own is still a card. |
| The next write showed below an open card (screenshot, 2026-10-27: format.sh's diff under Widget.swift's question): the agent announced it before asking, so the panel's hold came too late. | The chat itself stops at the first open question: rows that come after it, or were already shown, wait until it's answered; cancelling or stopping answers it. Test: `permission_question_in_its_tool_row`. |

↩ / ⎋ in the empty message field still answer the open card.

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02). The hold has no automated test (the panel controller has no test suite); check it with item 16 of the [M5 checklist](07-m5-polish.md#to-check-user).

## 9. Chat: disclosure arrows

**Asked (2026-10-24):** "Make the disclosure arrow a bit larger."

Every ▸ / ▾ (messages, code block lines, Thinking) is 5 pt larger than the text beside it and its own click target. Test: the arrow's font is larger than the title's.

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02).

## 10. Chat: smooth scrolling to new text

**Asked (2026-10-24):** "When text is added to the chat panel do a smooth scroll of the existing text upward so that the new text fits the bottom."

| What | How |
|---|---|
| Following the end | When you're at the end of the chat, new text (streamed replies, tool rows, cards) moves the existing text up in one continuous glide instead of jumping; a prompt, from anywhere in the chat, goes to the end and leaves the end of the text halfway up the panel, with room below for the reply. Text that arrives while it moves retargets the same motion, so streaming scrolls continuously. |
| Reading earlier text | Scrolled up, the chat stays where you are, as before. A scroll still under way counts as being at the end, so fast streaming doesn't lose the end. |
| Permission cards | A new card scrolls into view the same way: the whole card when it fits, else its question and options. |
| Reduce motion | With System Settings ▸ Accessibility ▸ Display ▸ Reduce motion, it moves without animating. |
| Shorter chat area | When the working line or the changed-files list appears, the chat area gets shorter; at the end, it now stays at the end instead of hiding the last lines under them (screenshot, 2026-10-24: the format.sh card's diff was under the prompt). Only your scrolling decides whether it follows the end, not resizing. Test: `stays_at_end_when_shorter`. |
| Clicking a file link | Scrolled up, clicking a link to a file opened it but sent the chat to the end, and its code blocks redrew a moment later (2026-10-25). Switching documents set the editor's theme again, and the panel redrew the whole chat for it. Now it redraws only for a different theme, and a redraw keeps the text at the top where it was (or stays at the end). Test: `reload_keeps_scroll_position`. |

Test: `new_text_scrolls_up_only_at_the_end` (outside a window, so without the animation).

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02).

## 11. Chat: working indicator and status

**Asked (2026-10-24):** "add a slowly blink dot to indicate that agent is still work and a status of (elapsed time, tokens used and anything else you see useful."

A line between the chat and the message field while the agent works (`AgentActivityView`), hidden otherwise:

`● Write geometry.py · 0:42 · 2 tool calls · +3.2k tokens`

| Part | What it shows |
|---|---|
| Dot | The accent colour, fading in and out every 1.2 s. Orange and still while a permission card waits. Still with Reduce motion. |
| Activity | What the turn's latest item is: "Starting Claude", "Thinking", "Writing the reply", "Planning", a running tool call's title, or "Working". "Waiting for your approval" while a card waits. |
| Elapsed time | Since the message was sent, updated every second (`0:42`, `1:05:03`). |
| Tool calls | How many the agent has made in this exchange. |
| Tokens | Growth of the context the agent reports (`usage_update`) since the message was sent; left out when the agent hasn't reported usage. The total and cost stay in the status text at the bottom right. |

Tests: `t_activity_view` (time strings; the line's text when working, with tools and tokens, and waiting; hidden when idle).

**Status:** done (commit `6ef4bfdd`), confirmed by the user (2026-11-02).

## 12. Test prompt

Creates new files only, inside `agent-fold-test/`. Use any project window; put the panel in Manual mode to also test permission cards (§7, §8). Watch the scrolling (§10) and the working line (§11) while it runs.

**Prompt 1** (code blocks and the "where it sits" line):

~~~~
Test task. Only create new files inside a new folder agent-fold-test/ at the project root. Do not modify, move or delete any existing file, and don't run commands other than creating those files.

First make a short plan (a to-do list), then create:
1. agent-fold-test/geometry.py: about 40 lines with a Point class, functions distance(a, b), midpoint(a, b) and area_of_polygon(points), and docstrings.
2. agent-fold-test/Widget.swift: a small struct Widget with a few properties and one method, plus one line longer than 200 characters (e.g. a long string literal).
3. agent-fold-test/format.sh: a 10-line shell script with a function that prints its arguments in columns.

When the files exist, reply with these code blocks, in this order:
a. The full distance function, with the fence written as ```python agent-fold-test/geometry.py
b. The Widget struct's method. Name the file Widget.swift in the sentence just before the block, but put only ```swift on the fence.
c. An excerpt of area_of_polygon with its middle lines replaced by a line "# ...". Don't name any file near this block.
d. A new Python function that isn't in any of the files (e.g. perimeter(points)), to show it isn't saved anywhere.
e. A one-line shell command that runs format.sh.
f. The long line from Widget.swift, alone in a swift block.
g. A bulleted list whose second item contains a short code block from format.sh.
~~~~

What to check:
- In Manual mode: each write's card shows Yes / No at once and is the last thing in the chat until answered; the next card appears only after that. `↳ geometry.py` says "not created yet" before approval and shows the proposed content.
- Each block shows its code under its line (▾); the header toggle folds them all to their lines (▸) and shows them again. a, b, c, f and g show a place such as `geometry.py:12–20` that opens the file at that line; d and e show their first line of code. c's range covers the whole function despite the left-out lines.
- Click a line to unfold: editor font and theme; f scrolls sideways; the wheel over a block scrolls the chat; typing, ⌘V and ⌘Z do nothing; ⌘A, ⌘C and ⌘F work; F1 folds inside a block.
- The tool calls and the plan have ▾ / ▸, and the arrows are easy to click.
- While it works: the text slides up as it arrives (if you're at the end); the line above the message field blinks and shows the activity (e.g. a Write's title), elapsed time, tool calls and tokens; at a card the dot turns orange and says "Waiting for your approval". The line goes when the reply is done.

**Prompt 2** (send after the first reply; auto-fold):

~~~~
Create one more new file, agent-fold-test/README.md, describing the three files in a few lines, and show its contents in a markdown code block with the fence ```markdown agent-fold-test/README.md
~~~~

What to check:
- Sending folds the first exchange to one line per item: your message (📎 if files were attached), the reply with "· 7 code blocks", the tool calls, the plan.
- ▸ reopens an item.
- History ▸ load this chat again: only the last exchange is open.
- Switch themes with a block unfolded: it follows.

Delete `agent-fold-test/` afterwards.

## 13. Tab bar: stuck hover state

**Asked (2026-11-02):** "The tabs show 3 different colours, what is the dark grey one for." Then: "fix the stuck hover state".

The tabs have three shades: white for the selected tab, light grey for the others, and dark grey for the tab under the pointer, which also shows its × (`OakTabView`, background alpha 0 / 0.1 / 0.2). The screenshot had two dark grey tabs with the pointer over neither.

| Cause | Fix |
|---|---|
| A tab checked whether the pointer was over it against its `visibleRect`, which in the document window covers the whole window (2556 × 1320) rather than the tab (250 × 29), found with a probe in the running app. Any tab that re-checked while the pointer was in the window turned dark grey and stayed so. The tab bar's own tracking area made the same check. | Clip the check to the view's bounds: `NSIntersectionRect(bounds, visibleRect)`, in all four places. |
| Tabs miss `mouseExited:` when their frames change under the pointer (tabs opening or closing, the panel resizing the bar). | The tab bar works out the tab under the pointer and sets every tab's hover state to match (`updateMouseInsideForTabViews`), on mouse moves, enter and exit (its tracking area now includes `NSTrackingMouseMoved`) and after each layout change. Skipped while dragging a tab. |

To check: open and close tabs and resize the agent panel with the pointer over the tab bar. At most one tab is dark grey, and none once the pointer leaves the bar.

**Status:** done (commit `ad706720`), confirmed by the user (2026-11-02).

## 14. To do

Collected 2026-11-02 for us to work through. Ticked when done.

**Agent panel**
- [ ] **The user's list of panel issues** (asked for 2026-10-20; folding was the first). This is the main remaining part of the UX pass.
- [ ] **"Claude Code stopped running"**: the panel showed this error (screenshot, 2026-11-02). Find out why, if it happens again.

**Code views in the chat** (§6)
- [ ] Find in the chat doesn't search inside them.
- [ ] A selection across one copies without its code.
- [ ] No gutter, so folding inside a block is keyboard-only (F1).

**Larger changes** (to decide)
- [ ] The prompt field as an `OakTextView` (bundle shortcuts, editor commands), as VS Code uses Monaco for its input.
- [ ] A row-based transcript (per-message hover actions, less re-layout for long chats).
- Several chats per window, chat in an editor tab, Quick Chat (§1): not planned unless the user asks.

**Elsewhere** (tracked in the [implementation status](README.md#future-work))
- [ ] M5 step 8, the `pr/agent` port for upstream: deferred by the user.
- [ ] `feature/agent` doesn't build at `7723847e` (it deletes the M1 debug window files that `AppController` uses until `d6d22909`). Fixing it needs a force-push: the user's decision.
- [ ] Optional clean-up: upstream's leftover branches on the fork (`10_7`, `gh-pages`, `no-copy-of-scopes`), local `backup/pre-trailer-removal/*` branches and `refs/original`.
