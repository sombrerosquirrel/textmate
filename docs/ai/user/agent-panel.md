---
title: Agent Panel — User Guide
updated: 2026-10-19
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

- **View ▸ Show Agent Panel** (⌃⇧⌘I) shows or hides it. With the panel open, the shortcut moves the focus to the message field.
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

Add context with **+** (current file, selection, open files, other files), by dragging files in, or by pasting images if the agent accepts them. Each appears as a chip you can remove.

The switch beside **+** decides whether the agent works in the open file. While it's on, a line above the field names the file, and requests like “add a comment here” edit it at the cursor.

From the editor:

- **Text ▸ Ask Agent About Selection** attaches the selection, or the cursor position, and moves to the panel.
- **Text ▸ Ask Agent at Caret…** (⌃⌥⌘I) is inline chat. A small field opens at the caret, and your request goes to the window's chat about the selection or the caret's line. The field shows what the agent is doing and asks for any approvals it needs, then lists the files that changed with **Keep**, **Undo** and **Show in Chat**. The panel doesn't need to be open.
- In the file browser, right-click files ▸ **Add to Agent Chat**.

## Replies

Replies are formatted Markdown. Code blocks are highlighted with the grammar for their language and your editor theme. Under each code block:

- **Copy**
- **Insert at Cursor** inserts it in the editor.
- **Apply in Editor** replaces the selection, or adds to the end, as one undoable change.

**Thinking** rows can be expanded. Tool rows show what the agent did, with diffs for edits and output for commands.

## Approvals and changes

When the agent asks for permission, a card shows what it wants to do (the command, or the diff of an edit) and its choices. With the message field empty, ↩ chooses the option marked ↩ (allow once) and ⎋ the one marked ⎋ (reject).

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
- **Agent Settings…**: fix the command, or use an API key.
- **Show Log**: see what happened.

**Window ▸ Agent Log** shows what TextMate and the agents sent each other: every message (→ sent, ← received), the agents' error output, and when they started and exited. You can filter by agent and kind, and search. **Copy** copies what's shown, for a bug report. The log keeps the last 5,000 entries and isn't saved.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌃⇧⌘I | Show the agent panel, or focus it |
| ⌃⇧⌘N | New agent chat |
| ⌃⌥⌘I | Ask agent at caret (inline chat) |
| ↩ / ⎋ (empty message field) | Allow / reject the open permission card |
