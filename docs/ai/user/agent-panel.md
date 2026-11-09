---
title: Agent Panel — User Guide
updated: 2026-11-02
tags: [textmate, user-guide, agent, acp]
---

# Agent Panel — User Guide

The agent panel lets an AI coding agent work in your project from inside TextMate: you chat with it, and it reads and edits files and runs commands, asking you first where its settings say so. TextMate works with **GitHub Copilot** and **Claude Code** out of the box, and with any other agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP).

Each project window has its own panel and its own agent, working in the project folder.

## Setting up

You need at least one of these:

| Agent | Install | Sign in |
|---|---|---|
| GitHub Copilot | `npm install -g @github/copilot` (Node.js) | `copilot login`, or a token in Preferences ▸ Agents |
| Claude Code | Nothing: TextMate runs it with `npx` (Node.js) | Your Claude Code login (`claude auth login`), or an API key in Preferences ▸ Agents |

TextMate starts agents with your login shell's environment, so tools installed with Homebrew or nvm are found even when TextMate was opened from the Dock.

If an agent isn't signed in, the chat says so and offers **Sign In**, which runs the agent's sign-in command in Terminal. When you're done, choose **Try Again**.

## The panel

- **View ▸ Show Agent Panel** (⌃⌥⌘I) shows or hides it. With the panel open, the shortcut moves the focus to the message field.
- **View ▸ Move Agent Panel to Left/Right Side** picks the side. Drag the divider to resize it.
- **View ▸ New Agent Chat** (⌃⇧⌘N) starts a new chat. So does the pencil button at the top of the panel.
- The popup at the top left picks the agent. It also has **Agent Settings…** and **Show Agent Log**.
- The clock button lists earlier chats in this project, newest first. Choose one to see it again and carry on with it.
- The popups below the message field are the agent's own settings, e.g. mode (ask before editing, accept edits, plan), model and effort. The text at the bottom right shows the agent and version, or how much of its context the chat uses.

## Sending a message

| Key | In the message field |
|---|---|
| ↩ | Send |
| ⇧↩ or ⌥↩ | New line |
| ⎋ | Stop the agent |
| ↑ / ↓ | Earlier messages, on the first or last line |
| / | The agent's commands; ↩ sends the selected one, ⇥ completes it |
| /clear | Starts a new chat, like the New Chat button (unless the agent has its own /clear). A command is sent as typed, without attachments |

Add context with **+** (current file, selection, open files, other files), by dragging files in, or by pasting images if the agent accepts them. Each appears as a chip you can remove.

The switch beside **+** decides whether the agent works in the open file. While it's on, a line above the field names the file, and requests like “add a comment here” edit it at the cursor.

From the editor:

- **Text ▸ Ask Agent About Selection** attaches the selection, or the cursor position, and moves to the panel.
- **View ▸ Ask Agent at Caret…** (⌃⇧⌘I) is inline chat. A small field opens at the caret, and your request goes to the window's chat about the selection or the caret's line. The field shows what the agent is doing and asks for any approvals it needs, with the diff of a proposed edit, then shows what changed in each file with **Keep**, **Undo** and **Show in Chat**. When the agent answers with code instead of editing, the reply is shown formatted, with **Copy** and **Replace Selection** (or **Insert at Cursor** when nothing was selected). The popover stays open afterwards: the button becomes **Insert After**, which adds more on the lines after what you just inserted. With more than one code block, a checkbox for each picks which ones the buttons use (the first is checked to start with; checked blocks go in one after another). Selecting text in the reply uses just that instead, e.g. a block without its example line. Code from Replace Selection and Insert After is listed with the agent's changes, so you can review or undo it; ⌘Z undoes any of them. **Undo** there takes back only that request's edits; earlier ones stay in the changed-files list. The panel doesn't need to be open.
- In the file browser, right-click files ▸ **Add to Agent Chat**.

### Where agents search

Every message tells the agent that the folder at the top of the File Browser is its search area. When it needs to find a file, document or anything else, it searches that folder first and stays inside it. Before it searches anywhere else (a parent folder, the rest of the project, your home folder) it must ask you, say where and why, and wait for your answer. Files you name or attach can still be read where they are.

To widen or narrow the search, move the File Browser to another folder before sending. The folder is read when the message is sent, so Try Again uses wherever the File Browser is then. Without a File Browser folder (closed, or showing Favorites or SCM status), the project folder is used.

This rule is an instruction to the agent, so it applies to every agent. TextMate can't block the agent's own search tools: anything that needs your approval still shows an approval card.

### Where agents start

An agent starts in the first of these folders:

1. **The project folder**, if one was chosen: a folder you opened as a project, or `projectDirectory` in `.tm_properties`. The agent finds the project's `.claude` settings (and `CLAUDE.md`) there.
2. **The document's folder**, if the document has been saved. An untitled document doesn't count, even though TextMate keeps a backup of it somewhere.
3. **The folder at the top of the File Browser**, if the File Browser is visible. Turn this off in Preferences ▸ Agents ("Without a project or saved document, start agents in the File Browser's folder").
4. **Your home folder.**

The folder is chosen when the agent starts. Moving the File Browser afterwards changes the search rule above but not where the agent runs; start a **New Chat** to move the agent too. An agent that restarts mid-chat continues in the folder the chat began in.

Claude Code asks before reading or editing outside the folder it runs in ("Yes, allow reading from `dir/` during this session", "Yes, allow all edits in `dir/` during this session"). When it starts in the File Browser's folder, that question enforces the search rule; inside a project it only covers leaving the project.

## Replies

Replies are formatted Markdown, in the built-in style of the Markdown preview or, with **Preferences ▸ Agents ▸ Chat text style: GitHub**, styled like GitHub: its fonts, colours and link blue, roomier spacing, a line under the two largest heading levels, wider quote bars, and tables with rounded corners and shaded alternate rows. The change applies to open chats at once. Code blocks keep your editor theme either way.

Each code block has a line over it: its language, how many lines it has, and where it sits, e.g. `▸ Objective-C · 18 lines · Parser.mm:120–137`. Click the place to open the file at those lines. The place is found when the reply names the file (in the code fence, or just before the block), or when the code is in a file the agent touched or one you have open; otherwise the line shows the block's first line of code.

Below the line, the code shows in a small read-only editor with your theme, the font for its language, and the editor's selection, copying, find and keyboard folding. Long lines scroll sideways. To change the code, open the file from its place. Click the line to fold the block to just that line, and again to show it.

The icon at the top of the panel, beside Previous Chats, folds or opens everything with an arrow at once: replies, tool calls, the plan, thoughts and code blocks. When it's on closed, tool calls arrive folded, and replies stream open and fold once two newer replies have come; chats you load from Previous Chats don't follow it, and a tool call waiting on your answer stays open; its tooltip says which it does. TextMate remembers the choice.

Below a block that's showing:

- **Copy** (also on the folded line)
- **Insert at Cursor** inserts it in the editor.
- **Apply in Editor** replaces the selection, or adds to the end, as one undoable change.

Replies and tool calls fold: click ▾ to fold one to a line and ▸ to open it again. Your own prompts stay whole. With the header icon on closed, the earlier exchanges fold when you send a message, so the current one is easy to follow. Loading an earlier chat leaves only its last exchange open.

**Thinking** rows can be expanded. Tool rows show what the agent did, with diffs for edits and output for commands.

New text slides into view at the bottom while you're at the end of the chat; scroll up to read and it stays where you are.

Right after you send, a “Waiting for <agent>” line shows in the chat until the agent's first update. The line being worked on (a running tool call, Thinking, or the reply as it streams) has a blinking marker with its own time and tokens.

The line above the message field is always there. While the agent works it shows a slowly blinking dot, what the agent is doing (thinking, writing the reply, or the tool it's running), the time since you sent the message, the tool calls so far and the tokens this exchange used (when the agent reports them). While a permission card waits for you, the dot turns orange and stops blinking, and the line says “Waiting for your approval”. After the exchange it says **Done**, **Stopped** or **Failed**, with the same figures. A new chat empties it.

## Approvals and changes

When the agent asks for permission, the question and its choices appear in the tool call's row, right after what it's about (the command, or the diff of an edit). Once you answer, the question goes and your answer shows on the row's line, e.g. `✓ Write geometry.py  ·  ✓ Yes`. With the message field empty, ↩ chooses the option marked ↩ (allow once) and ⎋ the one marked ⎋ (reject). While a card is open, nothing else is added after it: what the agent does next, and any further card, shows once you've answered.

Files the agent changes are listed above the message field. For each file you can open it, see the diff, **Keep** the change or **Undo** it, or use **Keep All** / **Undo All**. Undo restores the file as it was before the agent changed it; if you've edited the file since, TextMate asks first.

## Configuration

**Preferences ▸ Agents ▸ Agents** lists the agents in the panel's popup:

- **Command:** the agent's command line, with arguments, quoted as in a shell.
- **Environment:** extra variables, one `NAME=value` per line.
- **API key:** kept in the Keychain (“TextMate Agent API Key”) and passed in the variable shown, only while **Use an API key from the Keychain** is on. For Claude Code, turning it off goes back to your subscription login.
- **+** adds an agent, **−** removes one you added. **Restore Defaults** resets a built-in agent.

Changes apply the next time the agent starts (New Chat, switching agents, or after it stopped).

**Preferences ▸ Agents ▸ MCP Servers** lists [MCP](https://modelcontextprotocol.io) servers to give every agent, in addition to the agent's own MCP configuration:

- A local server is a command, e.g. `npx -y @modelcontextprotocol/server-everything`.
- An HTTP or SSE server is a URL.
- Below the list: environment variables for a command (`NAME=value`), or headers for a URL (`Name: value`), one per line.

If a server can't be passed to an agent, the chat says why.

### Per project

In the project's `.tm_properties`:

```
agentName    = "Claude Code"                  # the agent new windows of this project use
agentCommand = "my-agent --acp"               # this project's command for that agent
```

If `agentName` names no configured agent, the panel offers a project agent of that name with `agentCommand`.

## When something goes wrong

The chat explains failures and offers what to do next:

- **Sign In**: the agent needs you to sign in.
- **Try Again**: start the agent again and resend your message.
- **Restart**: the agent stopped; restart it and carry on with the chat.

After **Restart**, or **Try Again** with no message to resend, a blinking “Starting <agent>” line shows in the chat and above the message field until the agent is up. The chat then says it's running again (or ready), and the line above the field says **Started**, or **Not started** with the error.
- **Agent Settings…**: fix the command, or use an API key.
- **Show Log**: see what happened.

**Window ▸ Agent Log** shows what TextMate and the agents sent each other: every message (→ sent, ← received), the agents' error output, and when they started and exited. You can filter by agent and kind, and search. The agent filter lists only agents that have run since TextMate started. **Copy** copies what's shown, for a bug report. The log keeps the last 5,000 entries and isn't saved.

### A stuck agent

⎋ (or the stop button) stops what the agent is doing. If the agent itself hangs, quit its process in Terminal; the chat then says it stopped running, and **Restart** carries on with the chat:

```sh
pkill -f claude-agent-acp   # Claude Code
pkill -f 'copilot --acp'    # GitHub Copilot
```

These quit that agent in every TextMate window, and the Copilot one also quits any `copilot --acp` you started yourself.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌃⌥⌘I | Show the agent panel, or focus it |
| ⌃⇧⌘N | New agent chat |
| ⌃⇧⌘I | Ask agent at caret (inline chat) |
| ↩ / ⎋ (empty message field) | Allow / reject the open permission card |
