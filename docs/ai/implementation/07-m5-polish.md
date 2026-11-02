 ---
title: M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs
status: in progress
started: 2026-10-19
tags: [textmate, implementation, acp, agent]
---

# M5 — Polish: Theme, Errors, Log, Shortcuts, Inline Chat, Docs

**Status:** 🔄 Steps 1–6 implemented (2026-10-19), awaiting user check; step 7: preview scrolling and panels (7a–7c, 2026-10-20–22) and chat folding with editor code blocks (7d, 2026-10-24) done, awaiting user check; more panel UX waiting for the user's notes; step 8 deferred by the user ([To check](#to-check-user))
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
| 7. UX pass | The panel UX items the user deferred in M2 (to collect from the user) and the Markdown preview's scroll smoothness. Collected by feature in the [UX pass doc](08-ux-pass.md). | — |
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


### Step 7b — The editor follows the preview (2026-10-22)

The user asked for the editor to track the preview's scrolling as well.

| What | How |
|---|---|
| Same map, inverted | The editor y whose (smoothed) map gives the preview's y, found by bisection to ¼ pt (`MarkdownPreviewInverseMap`, `MarkdownPreviewScrollMap.h`). Since both directions use one map, scrolling the preview and then the editor (or the other way) doesn't make either jump. Without anchors, by fraction. |
| Only the user's scrolls | Built-in view: the clip view's bounds changes, except while the view scrolls itself (following the editor, re-rendering, clearing for the GitHub view) or is resized. Page: a `scroll` listener ignores positions the script set (`tmOwnScrollY`, also updated after content and size changes, which can clamp the page), cancels an editor jump's easing and the sub-pixel offset, and posts `tmScroll` `[y, fraction]`. Wheel, scroller, keys, find and in-page links all count. |
| No feedback | The window category sets `_scrollingEditor` while it scrolls the editor, and `editorDidScroll:` ignores those. The editor's position is rounded to device pixels. |
| In-page links | Footnotes and ↩ now move the editor too, in both renderers (before, preview only: the next editor scroll jumped the preview back). |

API: `markdownPreview:didScrollToPosition:fraction:` (preview delegate) and `HTMLView:didScrollToPosition:fraction:`. Tests: inverse map round trip and ends; the built-in view and the page each report the user's scrolls and not their own. MarkdownPreview 34 tests; `ctest` 28/28.


### Step 7c — Preview panels only for documents they can show (2026-10-22)

The user: the preview should only show while a Markdown document is selected; switching to another document closes it, switching back reopens it in the same position and size; the default for any preview panel.

| What | How |
|---|---|
| Suspended panels | `OakEditorPanel.suspended`: the container takes the panel's view and divider out of the layout (and out of hit testing and cursor rects) but keeps it in `panels`, so its edge, order on the edge, and size are unchanged when it's resumed. Removing and re-adding would put it innermost. A panel added while suspended isn't shown until resumed. This is the mechanism for any preview panel. |
| Markdown preview | The coordinator suspends its panel while the selected document is missing or isn't Markdown (on tab changes and grammar changes), moving focus to the editor if the preview had it, and doesn't follow the editor's scrolling meanwhile. `markdownPreviewVisible` (the user's choice) stays on, so the menu says Hide; Show is disabled for a non-Markdown document, rather than turning on a preview that wouldn't appear. The "isn't a Markdown document" placeholder is no longer seen. |

Tests: `suspended_panel_keeps_place_and_size` (OakEditorPanels 12). `ctest` 28/28.


### Step 7d — Folding in the chat; code blocks as editor views (2026-10-24)

The user (panel UX): code blocks and other message blocks can't be folded. Add `OakTextView` code blocks and folding; code blocks start folded under a line saying what they are and where they sit.

Decisions (user, 2026-10-24):
- The line over a code block: language, line count, and the file and lines it belongs to, e.g. `▸ Objective-C++ · 18 lines · AgentTranscriptView.mm:336–353`. The file comes from the fence (` ```swift Sources/File.swift`, `lang:path`, `title="path"`), a file named just before the block, or the files the turn's tool calls touched and the open documents; the lines by finding the code in that file. Without a match: the first line of code instead of the place.
- Every message block folds (your messages, replies, thinking, tool calls, plans). The current exchange stays open; earlier ones fold to one line when you send a new message. Code blocks always start folded.
- Code blocks are **read-only**. To change code, open the file (the place on the line is a link, like the changed-files links).

| Part | How |
|---|---|
| Read-only `OakTextView` | `readOnly`: typing, IME, editing actions, bundle items, paste, drops, undo/redo, Replace and snippets do nothing, and their menu items are disabled; moving, selecting, copying, find and folding still work. `naturalHeight`: the text's height without the viewport or scroll past end (`layout_t::natural_height`), KVO-observable, so a container can fit it. |
| `OakCodeView` (OakTextView) | A read-only `OakTextView` in a scroll view for a code snippet: grammar by file type, the window's theme, the font set for the grammar (not the current document's, which may be proportional, e.g. Markdown), no soft wrap (long lines scroll sideways), vertical wheel passed on to the enclosing scroll view, no gutter, no LSP or Copilot (it isn't opened as an editor document). |
| `OakMarkdown` | `OakMarkdownCodeBlock.info` (the whole fence info string); `language` is its first word. `OakMarkdownStyle.codeBlockReplacement` replaces a rendered code block (given the rendered text) with what the caller returns, e.g. the summary line and an attachment. |
| `AgentCodeLocation` (AgentUI) | Candidate paths from a fence's info string and the text before the block; finds a code block's lines in a file's text (lines compared without surrounding white space, in order, allowing elided lines such as `…`; after one, a line indented as in the code wins, so a closing `}` lands on the right brace). |
| Transcript | Each code block is a line: `▸`/`▾`, language (the grammar's name), line count, place (link to open the file at the line), and Copy while folded. Unfolded, an attachment holds an `OakCodeView` (from the panel's delegate) sized to its natural height; the views sit over the attachments after layout and are kept while the reply streams, with Copy / Insert at Cursor / Apply in Editor below. Message items get `▾`/`▸` and a one-line summary when folded (`AgentTranscriptItem.folded`). |
| Panel | Folds the earlier items when you send a message, and all but the last exchange when a chat is loaded. Provides the code views, grammar names for languages, and the text of files (open document or disk) for the places. |

AgentUI keeps no dependency on OakTextView: the window category makes the `OakCodeView`s.

Checked in the running app with a probe that adds a sample exchange to the panel and snapshots it: folded and unfolded blocks, the editor view at its natural height (9 lines, 169 pt) with the theme's highlighting, the place `AgentTranscript.mm:193–210`, and the one-line summaries after folding everything. Found there and fixed: the view took the current document's font (proportional for Markdown); no space under the actions line.

Tests: `t_code_view` (OakTextView, new suite: fitting height, partial replacement, read-only), `t_markdown` info string and replacement (OakMarkdown 30), `t_code_location` and `t_transcript_view` (AgentUI 30). `ctest` 29/29.

Found by the user with the test prompt (Claude in Manual mode, three new files), and fixed:

| Report | Cause | Fix |
|---|---|---|
| The files were empty although the chat showed their text | The writes were waiting for approval; the chat shows the proposed content. The `↳ geometry.py` link opened a new, empty document at the path (an older behaviour, M3). | Links to files that don't exist yet say "not created yet" and show the proposed content (the tool call's diff) instead of opening an empty document; the same when one is clicked before the transcript catches up. Code block places only use files on disk. |
| No permission card to allow | The card was there, but its options came after a 12-line diff preview, it was added above a later tool row, and the panel only follows new output when scrolled to the bottom: the options were out of view. | The options come right after the title, before the details, and a new open card scrolls its question and options into view. |
| The disclosure arrows were hard to hit; output kept coming after a card | The arrows were in the text's size. Updates after a permission request (e.g. a parallel tool call) were added below the card. | The arrows are 5 pt larger (every ▸ / ▾: messages, code blocks, Thinking). While a card waits, the panel holds what the agent sends, and another card, and shows them in order once it's answered (or cancelled), so the open card is always last. |
| The same diff twice, with the card between | The tool row and the card both showed the tool call's details; another tool call had arrived between them. | While a card is open, its tool call's row shows only the title and "waiting for approval"; once answered, the card drops the details and the row shows them. Test: `tool_call_details_shown_once` (AgentUI 37). |
| The answer appeared later, below another write | Cards were items at the end of the chat; the agent had already announced its next write. | The question and options sit in the tool call's row after its diff; answered, the answer shows on the row's line. A request without a tool row is still a card. Tests: `permission_question_in_its_tool_row`, `permission_without_tool_row_is_a_card`. |
| The next write showed below an open card | The agent announced the next tool call before it asked about the current one, so the panel's hold (which only holds updates that arrive while a card is open) didn't catch it. | The transcript view stops at the first open question's row and takes out what follows until it's answered. Test: `permission_question_in_its_tool_row` (AgentUI 40). |
| The end of the chat hidden under the prompt | The working line and the changed-files list made the chat area shorter without scrolling, so the last lines were under them and the chat no longer counted as at the end. | Following the end depends only on the user's scrolling; when the area gets shorter at the end, it stays at the end. Test: `stays_at_end_when_shorter` (AgentUI 39). |
| A file link sent the chat to the end | Opening a file switches documents, which sets the editor's theme again, even the same one; the panel redrew the whole chat, which emptied it (so it counted as at the end) and recreated its code views. | The window tells the panel only about a different theme, and a redraw keeps the text at the top where it was unless the chat follows the end. Test: `reload_keeps_scroll_position` (AgentUI 40). |

Tests: `links_to_files_not_created_yet`, `permission_card_options_first_and_in_view` (AgentUI 32). `ctest` 29/29.

### Step 7e — Smooth scrolling and the working line (2026-10-24)

The user: new text should scroll the chat up smoothly; a slowly blinking dot while the agent works, with elapsed time, tokens and other useful status. By feature in the UX doc, §10–§11.

| Part | How |
|---|---|
| Smooth scrolling | `AgentTranscriptView` glides the clip view's bounds origin on a display link (one motion that new text retargets, easing in over 0.12 s, at most 2400 pt/s unless that would take over 0.4 s; a lone move that fits in the panel just shows, moves within 0.4 s of each other glide as one; a prompt, from anywhere in the chat, goes to the end and leaves the end of the text halfway up the panel with room below, so a short reply prints without the text moving; 2026-11-01, was a 0.25 s ease-out restarted on every update, which rushed through bursts of text; scrolling during the glide stops it; a rebuild at the end, as when sending a prompt folds the earlier exchanges, goes straight to the end rather than gliding down from the top) to show the end, or a new permission card (whole if it fits, else its options). A scroll to the end still under way counts as being at the end. No animation outside a window or with Reduce motion. |
| Working line | `AgentActivityView` (AgentUI): dot (layer opacity animation, 1.2 s, autoreversing; orange and still while waiting), activity, elapsed time (1 s timer), tool calls, tokens. The panel shows it in place of hard-coded `working` changes (`setAgentWorking:`), and updates it on every update, card and usage report; tokens are `usage_update.used` minus its value when the message was sent. |

Tests: `new_text_scrolls_up_only_at_the_end`, `t_activity_view` (AgentUI 35). `ctest` 29/29.

Then (user): code blocks start open, and an icon in the header shows or folds every code block, now and in later replies, with a tooltip saying which. `AgentTranscriptView.foldsCodeBlocks` (blocks clicked open or folded are the exceptions, cleared when it's set); the panel keeps it in `agentPanelFoldsCodeBlocks` (default NO). Test: `toggle_shows_or_folds_all_code_blocks` (AgentUI 36). `ctest` 29/29. Since 2026-10-31 the icon folds and opens everything with an arrow, not only code blocks; a row with an open question stays open until it's answered. Prompts no longer have an arrow or fold.

### Step 7f — The GitHub preview scrolls like the built-in one (2026-11-01)

The user: the built-in preview scrolls a lot smoother than the GitHub one. After two attempts at smoothing it, still judder as scrolling slows: "why can't it just use the same algorithm?"

Both already used the same map; what differed was what it moved. The built-in view's scroll view moves in the app, in the same pass as the editor, so the two reach the screen together. A web view scrolls itself in its own process: each position crosses to it, is applied at the web process's next frame, and comes back to the app as a layer change. The result is frames behind the editor, unevenly, and with whole-pixel page scrolling plus a sub-pixel transform on top.

**Now the web view doesn't scroll.** It is as tall as the page, the document view of an `NSScrollView`, and the view controller drives that scroll view with the code it uses for the built-in view (`activeScrollView`): `scrollToPosition:animated:`, easing, `setScrollY:` on device pixels, `clipViewBoundsDidChange:` for the user's scrolls. The page scrolling script, `tmScroll` and the HTML view's scroll methods are gone.

| Moved from the page | Now |
|---|---|
| Height | The page reports it with its anchors (`{height, anchors}`), from `body`, not the document: the view is tall itself, so the document wouldn't shrink |
| Wheel | `MarkdownPreviewWebView` hands it to the scroll view; mostly sideways stays in the page for wide code blocks and tables |
| In-page links | Cancelled, and the scroll view moves to the target; the editor follows as with any scroll |
| Scrolling keys | WebKit takes them first and the page can't scroll, so they did nothing (found by the user). The page's `keydown` listener sends Page Up/Down, Space, arrows, Home/End and ⌘↑/↓ to the app as `tmScrollCommand`, unless focus is in a form control, `summary` or editable element (raw HTML). Space and ⌘↑/↓ were still taken before `keyDown:` in the app (not in a bare window; which view took them wasn't traced), so `MarkdownPreviewWebView` claims them in `performKeyEquivalent:` while it has focus, confirmed by the user. `MarkdownPreviewTextView` does the same in the built-in view, scrolling its clip view by the same amounts; plain Space isn't offered as a key equivalent, so it also handles `keyDown:`, where the read-only text view would ignore it; both use `MarkdownPreviewIsScrollKeyEquivalent` |
| Clamping when the page gets shorter | `isResizing`, so it doesn't count as the user scrolling |

Checked in a harness before the change: a full-height `WKWebView` in a scroll view, 138,000 pt (216 screens), scrolled at 6,000 pt/s with the visible area covered by layers in every frame; WebKit paints more of the page than is on screen, about 50 MB more in the GPU process (83 MB against 31). Not checked: real wheel and trackpad input, and very long documents' memory in daily use.

Rejected on the way, both keeping the web view scrolling itself: playing positions back on an even pace in the page (`requestAnimationFrame`), then in the app (display link). Both reduced uneven steps but still lagged the editor and couldn't put the two in one frame. **To measure a web view:** its layers are in the app process, so poll the scroll and content layers' positions every 1 ms and log changes; numbers from `window.scrollY` show what the page asked for, not what reached the screen. Commits land 12–13 ms after the display link's callback, so cut frames there.

Tests: `github_view_scrolls_as_the_built_in_one` (`t_preview`); `links_within_the_page_scroll_the_scroll_view`, `shorter_page_shrinks_the_web_view`, `web_view_follows_the_width`, `scrolling_keys_scroll_the_scroll_view`, `scrolling_key_equivalents` (`t_preview`), `reports_anchors_and_sizes_to_the_page` (`t_html_view`). `ctest` 29/29.

Focus (user): switching renderer with the preview focused left focus undetermined, because hiding the focused view hands it on. `render` and `showHTML:` keep it in the preview (`hasFocus`, `focus`). Tabs: `openAndSelectDocument:activate:` focuses the editor before the document changes, so tab switches (`selectTabDocument:`: tab bar, next/previous, Window menu) don't activate while the preview has focus; opening a file still goes to the editor. Going to a non-Markdown tab still moves focus to the editor, and coming back returns it to the preview if it's still in the editor, once there's content (`focus` waits for the placeholder to go). Test: `keeps_focus_when_switching_renderers`; the tab switches themselves have no test (no window controller tests).

Switching GitHub → built-in (user): the page lost its place. Measured in the app with a probe flipping the renderer: the *editor* went to the top too (y 490 → 0). `render` re-synced to the editor in `updateAnchors`, whose `setScrollY:` cleared `_settingScroll`; `render` then restored the empty text's position, which counted as the user scrolling, and the editor followed. Now it restores first and tells the delegate last. Test: `switching_back_from_github_follows_the_editor`.

## Commits
4752a0a7 agent log · 3c5b671c error states · 5e3198e7 theme highlighting · 98808424 permission keys, New Agent Chat · 3a2f3d1b inline chat

## To check (user)
1. ✅ Window ▸ Agent Log while chatting: messages appear live; filter by agent and kind, search, Copy, Clear. Agent popup ▸ Show Agent Log shows only that agent.
2. A reply with code (e.g. “show me a Python and a shell example”): code blocks in the editor theme's colours and highlighted; change the theme (View ▸ Theme) and they follow.
3. Claude in Manual mode, ask for an edit: with the message field empty, ↩ allows, ⎋ rejects; the card marks the options ↩ and ⎋.
4. ⌃⇧⌘N starts a new chat (also with the panel hidden).
5. Inline chat: select some code, ⌃⌥⌘I, ask e.g. “add a doc comment”. The popover shows progress (and Allow / Reject in Manual mode), then the changed file with Keep / Undo; Undo restores it; Show in Chat opens the panel with the exchange. Try with the panel hidden.
6. Error states without signing out: Preferences ▸ Agents, add an agent with command `env HOME=/tmp copilot --acp`, start a chat with it: “needs you to sign in” with Sign In (opens Terminal with `copilot login` — close it without signing in), Try Again, Agent Settings…. An agent with command `no-such-agent`: “Unable to find…” with Try Again and Agent Settings…. Remove the test agents afterwards.
7. Kill the agent (`pkill -f claude-agent-acp`): “stopped running” with Restart and Show Log; Restart continues the chat.
8. Read the [user guide](../user/agent-panel.md).
9. ✅ Markdown preview scrolling (both renderers, a document with images and long paragraphs): scroll slowly and quickly, and let it coast to a stop. The GitHub preview moves exactly with the editor, as the built-in one does (7f). No rush through images or long paragraphs; the top line drifts a little near them and lines up again after. Page Down / ⌘↓ / ⌘↑ in the editor: the preview glides there. Open a document whose images load after it's shown: the preview stays lined up without scrolling.
10. ✅ Scroll the **preview** (both renderers; wheel, scroller, and Page Down with the preview focused): the editor follows, and the caret doesn't move. Then scroll the editor: the preview carries on from where it is, no jump. Click a footnote: the editor follows the preview. Type near the end of the document: the editor doesn't move by itself.
11. ✅ With the preview shown and resized, switch to a non-Markdown tab: the preview closes and the editor takes the space. Switch back: it reopens on the same edge at the same size (also with the agent panel open on the same edge). View ▸ Show Markdown Preview is disabled on the non-Markdown tab; Hide works there and stays hidden when you return.
12. ✅ Ask for code from a file in the project (e.g. “show me the method that folds transcript items”): each code block is one line with its language, length and place (`File.mm:12–30`); click the place to open the file there. Click the line: an editor view with the code in your theme and font; long lines scroll sideways, the wheel scrolls the chat. Select, copy and find in it work; typing, paste and Undo do nothing. Click again to fold it.
13. ✅ With the header icon on closed, send a second message: the first exchange's replies and tool rows fold to one line (▸); your prompt stays whole, with no arrow. With the icon on open, nothing folds when you send. Click ▸ to open one again. Tool calls and the plan fold too. History ▸ load an earlier chat: only its last exchange is open.
14. ✅ Switch themes with a code block unfolded: it follows.
15. ✅ Claude in Manual mode, ask it to create a new file: the card's Yes / No are visible straight away (scroll up first to try); `↳ name` says "not created yet" and shows the proposed content; after Yes, it opens the file.
16. ✅ Ask Claude (Manual mode) to create two files: the second card and any tool rows appear only after you answer the first; each write's question sits under its diff in the tool row, and after you answer, the row's line says ✓ Yes; nothing ends up hidden under the working line or the changed files; the arrows are easy to click.
17. ✅ At the end of the chat, send a message that gets a long reply: the text slides up smoothly as it arrives. Scroll up while it streams: it stays put. With Reduce motion on, it moves without animating.
18. ✅ Right after you send, a line says “Waiting for <agent>” with a blinking marker and its time, until the agent's first update. The line being worked on (a running tool row, the Thinking line or the streaming reply): its marker blinks, faster than the working line's dot, and it shows that line's own time and tokens; both go when it's done. A row waiting on a question keeps blinking. The line above the message field is always there, so nothing prints over it. After a turn it says Done (or Stopped, or Failed) with the time, tool calls and tokens, and a new chat empties it. While the agent works, it has a slowly blinking dot, the activity (Thinking, a tool's title, Writing the reply), elapsed time, tool calls and "+N tokens"; at a permission card the dot is orange and still and the line says "Waiting for your approval". It disappears when the reply finishes or you stop it.
19. ✅ The header icon beside Previous Chats (tooltip says what it does) folds everything with an arrow: replies, tool rows, the plan, thoughts and code blocks, including ones opened by hand; click again to open them all. A row with an open question stays open with its diff until you answer. Prompts have no arrow and don't fold. What comes next follows the icon: on closed, tool rows arrive folded, and replies stream open and fold once two newer replies have come (unless you've opened one by hand). A chat loaded from Previous Chats doesn't follow the icon. The choice survives a relaunch.
20. ✅ Scroll up to a code block and click a link to a file: the file opens and the chat doesn't move or redraw.
21. ✅ Ask for an edit that adds or removes indented code: the diff's green and red are solid rectangles from the + or − to the panel edge, with no steps where the code indents.

## Future work
- Inline Undo restores a file to before the agent's first change in the chat, not just this request's change, when the file was already in the changed-files list.
- Inline chat shows the reply as plain text; Markdown and a diff preview in the popover would help.
- The log isn't saved; an option to write it to a file for long sessions.
- Code views in the chat: Find in the transcript doesn't search them, and a selection across one copies without its code; no gutter, so folding inside a block is by keyboard (F1) only.
