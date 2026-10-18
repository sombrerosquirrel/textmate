---
title: M3 — Tools: Files, Permissions, Diff Review, Terminal
status: in progress
started: 2026-10-16
tags: [textmate, implementation, acp, agent]
---

# M3 — Tools: Files, Permissions, Diff Review, Terminal

**Status:** 🔄 Implemented (2026-10-16); awaiting the user's testing
**Branch:** `feature/agent-tools` (from `feature/markdown-preview`, which has the M2 fixes)
**Design:** [agent-harness-design.md §4.1, §5.3, §5.4, §6a](../plans/agent-harness-design.md)

## Goal
An agent can read, edit (with approval) and run commands in a project; edits are undoable (design §6, M3).

## Plan

| Step | What | Where |
|---|---|---|
| 1. Files | `fs/read_text_file` and `fs/write_text_file`. Open documents first: reads see unsaved edits; writes replace only the changed range as one undoable edit and leave the document unsaved. Other files are read from and written to disk. Paths outside the project folder are refused. Every write is recorded as a file change (original text, current text). | `AgentClient/AgentFileSystem`; TextMate side in `DocumentWindowController+Agent` |
| 2. Permissions | `session/request_permission` becomes a card in the transcript: the tool call's title, kind, command or diff, and one link per agent option (Allow, Always Allow, Reject…). Stop and closing the window answer “cancelled”. The status line shows “Waiting for approval”. | `AgentTranscript`, `AgentTranscriptView`, `AgentPanelViewController` |
| 3. Diff review | Tool calls with `diff` content show a unified diff (xdiff), long diffs collapsed. A changed-files list above the prompt shows each file the agent changed in this chat with +/− line counts, and Keep / Undo per file plus Keep All / Undo All. Undo restores the original text (undoable in an open document; new files go to the Trash). Clicking a file opens it; “Diff” opens the change as a diff document. | `AgentClient/AgentDiff` (xdiff wrapper), `AgentUI/AgentChangesView` |
| 4. Terminal | `terminal/create`, `output`, `wait_for_exit`, `kill`, `release`. Commands run in the project folder with the login-shell environment; a command without `args` runs through the user's shell. Output keeps the newest `outputByteLimit` bytes, cut at a character boundary. Tool rows with `terminal` content show live output, the exit status, and a Stop link while running; output stays after release. | `AgentClient/AgentTerminal` |
| 5. Apply in Editor | Code blocks get an “Apply” link next to Copy / Insert: it replaces the selection, or the whole document if nothing is selected, as one undoable edit, and records it in the changed-files list so it can be reviewed and undone like an agent edit. | `AgentTranscriptView`, `DocumentWindowController+Agent` |
| 6. Current file and cursor (added 2026-10-17 at the user's request) | Every prompt names the file open in the editor and the cursor's line and column, as the file meant unless the prompt says otherwise; its contents aren't sent. Attaching the current file (attach menu, or Ask About Selection with nothing selected) also carries the cursor. While the agent panel has focus, the editor's caret keeps blinking where it was. | `AgentAttachment`, `AgentPanelViewController`, `OakTextView`, `DocumentWindowController+Agent` |

Tests: CxxTest against the fake agent and a fake document provider: read with `line`/`limit`, read from an open document, write to an open document vs. disk, project boundary (including `..` and symlinks), change tracking and revert, terminal output, truncation at character boundaries, exit status, kill, release, wait for exit; diff hunks and counts.

## Decisions
- `AgentClient` stays free of TextMate's document classes: open documents are reached through an `AgentDocumentProvider` protocol, which the project window implements with `OakDocument`.
- TextMate doesn't approve anything itself; “Always allow” is the agent's own option (design §5.4).
- Undo after the user has edited the file further asks before discarding those edits.
- Apply in Editor with no selection replaces the whole document (undoable, and listed with the changes). To be confirmed by the user.
- The cursor position is the start of the selection (TextMate doesn't keep a selection's direction in `selectedRange`); with text selected, attaching Selection gives the agent the exact lines. Columns count characters (a tab is one).
- The editor's caret keeps blinking only while focus is inside the agent panel, not when other views (file browser, find) have it. A faint underline under the caret's line was tried first; the user preferred the caret itself.
- The current file is named in a text note at the end of the prompt (path and cursor) rather than attached, so its contents aren't sent with every prompt. Captured when the prompt is sent; untitled documents aren't named.

## Finding: today's agents don't use `fs/*` or `terminal/*`
Checked in the installed packages (2026-10-16): **Claude Code** (`claude-agent-acp` 0.90) and **Copilot CLI** (1.0.97) only define the client methods; neither calls them. Both edit files on disk and run commands themselves. Claude's Edit diffs carry only the edited snippet (`old_string` / `new_string`), not the whole file.

So M3 also covers agents that act on their own:
- **Edits:** every edit tool call (kind `edit`/`delete`/`move`, or with `diff` content) snapshots the named files from disk when it starts and compares them when it ends; the change joins the changed-files list. Undo writes the original back to disk, and open documents reload as for any outside change (an unmodified document can also be undone with ⌘Z). Changes written through `fs/write_text_file` aren't recorded twice.
- **Command output:** TextMate opts into the Claude adapter's terminal extension (`clientCapabilities._meta.terminal_output` / `terminal_output_delta`); the adapter then sends `terminal` content plus `_meta.terminal_output_delta` and `terminal_exit`, shown like a TextMate-run terminal. Text output in tool rows (presumably how Copilot reports it; not checked yet) shows 12 lines with Show all.
- The `fs/*` and `terminal/*` client side is complete and tested, ready for agents that use it (e.g. Gemini CLI, Zed-style agents).

## Done

`Frameworks/AgentClient`:

| Component | Responsibility |
|---|---|
| `AgentFileSystem` | `fs/read_text_file` (with `line`/`limit`) and `fs/write_text_file`; open documents first via `AgentDocumentProvider`; project boundary, including `..` and symbolic links; change list (original and current text), keep, undo (Trash for created files), “changed since” check; snapshots for edits agents make themselves. |
| `AgentTerminal` | `terminal/create`, `output`, `wait_for_exit`, `kill`, `release`. `posix_spawn` with its own process group, `/dev/null` stdin, stdout and stderr together, `TERM=dumb`, login-shell environment plus the request's `env`. Output keeps the newest `outputByteLimit` bytes on a character boundary; invalid UTF-8 becomes U+FFFD. Kill: SIGTERM, then SIGKILL after 3 s. |
| `AgentDiff` | xdiff (histogram) wrapper: hunks with line numbers, +/− counts, unified diff text. |
| `AgentSession` | `fileSystem` and `terminals` properties: route `fs/*` and `terminal/*` and advertise the capabilities; commands are killed when the session ends. |

`Frameworks/AgentUI`:

| Component | Responsibility |
|---|---|
| Permission cards | `AgentTranscriptItemKindPermission`: title, command, files, diff, one link per option; outcome kept on the card. Stop, end of turn, New Chat and agent exit answer open cards as cancelled. Status line “Waiting for your approval”; Dock bounce when TextMate is in the background. |
| Diffs in tool rows | Changed lines with one line of context, +/− counts, file link, “Diff” (opens a `source.diff` document); 12 lines until expanded. |
| `AgentChangesView` | Changed-files list above the prompt: file (opens it), +/−, Diff, Keep, Undo; Keep All, Undo All. Undo asks first if the file was edited after the agent. |
| Terminal output | Command line, last 12 lines (escape sequences removed, `\r` progress lines collapsed), exit status, Stop while a TextMate-run command runs. Output stays after release. |
| Apply in Editor | Third code block link, next to Copy and Insert at Cursor. |
| Cursor position | `+fileAttachmentWithPath:text:cursorLine:column:`: chip `main.c:42:7`; the prompt gets the file plus “The cursor is at line 42, column 7 of /path/main.c.” |
| Current file by default | `+promptWithText:attachments:currentFile:promptCapabilities:` ends the prompt with “The user has /path/main.c open in the editor, with the cursor at line 42, column 7. Unless they say otherwise, “this file”, “here” and requests that don't name a file refer to it.” Left out when the current file is attached with its cursor. Checked with Claude: “add a comment here” with nothing attached edits the right line. |

TextMate integration (`DocumentWindowController+Agent.mm`): `AgentDocumentProvider` over `OakDocumentController.openDocuments`; writes replace only the changed byte range (on UTF-8 boundaries) through `-[OakDocument performReplacements:]`, one undo group, document left unsaved. Apply in Editor; diff documents. The current-file attachment carries the cursor position. A `firstResponder` observer turns on `OakTextView.showsCaretWhenInactive` while the agent panel has focus; the text view then keeps drawing and blinking its caret while its window is active, though it isn't first responder.

Tests: AgentClient 50 (new: file system 12, diff 3, terminal 6), AgentUI adds permission items and terminal `_meta`. The fake agent learned `read`, `write` and `run`. `ctest` 28/28.

## Commits
2e168c35 files · 77272237 permission cards · da684e5e diffs and changed files · e48ed75c terminals, Apply in Editor · f50d8cdb agent-side edits and Claude terminal output · 710997f1 terminal clean-up

## To check (user)
- [ ] Claude in Manual mode: an edit shows a permission card with the diff; Allow / Reject work; the card keeps the outcome.
- [ ] After an edit: the tool row shows the diff; “Diff” opens a diff document; the file appears in the changed-files list.
- [ ] Keep / Undo / Keep All / Undo All. Undo on an open, unmodified file reloads it; Undo after editing the file yourself asks first.
- [ ] A created file is listed as new; Undo moves it to the Trash.
- [ ] Claude runs a command (e.g. “run the tests”): output appears live in the tool row with the exit code.
- [ ] Copilot: the same edits and commands (its permission cards, changed files, text output).
- [ ] Apply in Editor with a selection, and without one (whole document); ⌘Z undoes it; the file is listed.
- [ ] Stop while a permission card is open: the card shows Cancelled.
- [ ] Click in the prompt: the editor's caret keeps blinking where it was; it stops when another app is active, and focus in the file browser hides it as before.
- [ ] With nothing attached, “add a comment here” edits the open file at the cursor.
- [ ] Ask About Selection (or attach Current File) with nothing selected: the chip reads `file:line:column`.

## Future work
- [ ] Files changed by shell commands (e.g. `sed -i`, code generators) aren't in the changed-files list; only edit tool calls are tracked. Could compare `git status` before and after a turn.
- [ ] A file whose path only appears when its tool call finishes can't be snapshotted, so it isn't listed.
- [ ] Apply in Editor replaces text literally; a smarter merge (like VS Code's) would need the agent.
- [ ] Permission cards have no keyboard shortcuts yet (e.g. ↩ Allow, ⎋ Reject); for the UX pass.
