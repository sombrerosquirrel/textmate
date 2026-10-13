---
title: TextMate AI — Project Plan
created: 2026-10-13
status: active
tags: [textmate, plan, acp, copilot, claude-code, lsp]
---

# TextMate AI — Project Plan

## 1. Goals

In priority order:

1. **Modern build** — TextMate builds with CMake + Ninja on the newest macOS.
2. **Bug fixes** — crashes, deprecations, macOS 26 UI issues.
3. **Autocomplete** — via LSP and/or other mechanisms (e.g. Copilot ghost text).
4. **Full-featured AI agent harness** — GitHub Copilot and Claude Code can *drive coding* inside TextMate (chat, multi-file edits, diff review, terminal commands, permission prompts), not just inline suggestions.

Constraints:

- `textmate/textmate` is the **original codebase** and is treated as the canonical upstream.
- `tectiv3/textmate` (PR [#1467](https://github.com/textmate/textmate/pull/1467)) is treated as a **feature PR** on top of upstream.
- The new AI agent harness should be an **eventual PR to `textmate/textmate`**, while staying **compatible with tectiv3's branch**.
- Avoid dead ends: the architecture should stay flexible as agents and protocols evolve.

## 2. Situation assessment

### Upstream: `textmate/textmate`
- Default branch: `master`.
- Last push: **May 2024**. Effectively dormant — no one is actively reviewing PRs.
- Build system: custom **Rave** build, depends on Boost, ragel, google-sparsehash, Cap'n Proto, multimarkdown.

### PR #1467: `tectiv3/textmate:develop` → `textmate/textmate:master`
- Status: open. **604 files, ~95,300 additions.**
- Contents:
  - **Build:** Rave → CMake + Ninja, debug (ASan) and release (LTO) presets; removes Boost, ragel, sparsehash, Cap'n Proto, multimarkdown. Requires `git submodule update --init --recursive`.
  - **Dead code removal:** SoftwareUpdate, CrashReporter, network framework, self-updater, SyntaxMate, `bl` CLI; dialog plugins inlined.
  - **Native LSP client:** JSON-RPC client + manager, completions popup (SwiftUI), go-to-definition, references, rename, code actions, diagnostics, hover, formatting (incl. format-on-save), file watching, indexing status, LSP log panel.
  - **Command palette** (Cmd+P) with frecency ranking.
  - **Copilot:** inline ghost-text suggestions via `copilot-language-server`, auth flow, status indicator. *No chat/agent mode.*
  - **Preferences:** Formatters pane, Advanced pane.
  - **Fixes:** deprecations, retain cycles, regex overread, bundle editor crash, macOS 26 tab bar; minimum target macOS 14.
  - New **OakSwiftUI** framework (Swift Package).

### Coverage of our goals by #1467

| Goal | In #1467? |
|---|---|
| CMake/Ninja on newest macOS | ✅ Yes |
| Bug fixes | ✅ Yes |
| Autocomplete via LSP | ✅ Yes |
| Copilot | ⚠️ Ghost text only — no chat/agent |
| Claude Code / agent harness | ❌ No — this is our new work |

## 3. Decision: build on tectiv3, keep our work independent

**Decision:** Do not start fresh. Use tectiv3's branch as the base for daily use, and build the agent harness as a self-contained layer that does not depend on tectiv3's internals.

**Why not start fresh from `master`?**
- Would mean re-doing goals 1–3 ourselves. The CMake migration alone is large because it is entangled with removing Boost/ragel/Cap'n Proto/etc.
- The main argument for fresh — small, reviewable upstream PRs — has little payoff while upstream is dormant.

**Risks of building on tectiv3 and mitigations:**

| Risk | Mitigation |
|---|---|
| Code was written quickly with AI assistance; rough edges likely | Fix as found; we'd be debugging either way |
| tectiv3 stops maintaining it | We own our fork; `pr-1467` simply stops moving |
| Upstreaming is harder | Agent harness is self-contained and portable to `master` on its own |

## 4. Repository organization

### GitHub
- **Delete** the old `sombrerosquirrel/textmate` (it was a fork of tectiv3's fork).
- **Re-fork directly from `textmate/textmate`**, so the fork's parent is the original repo and PRs default to `textmate/textmate`.
- Previous local attempts (`textmate_aborted`, `textmate_aborted_2`, `textmate-just-copilot`) are ignored and left untouched.

### Local clone
Location: `/Volumes/Little/Projects/me/textmate`

```
origin    sombrerosquirrel/textmate   (our fork)
upstream  textmate/textmate           (the original)
tectiv3   tectiv3/textmate            (PR #1467 source)
```

### Branches

```
upstream/master ─────────────────────────────►  master        (mirror, never edited)
     \
      tectiv3/develop ───────────────────────►  pr-1467       (mirror, never edited)
            \
             feature/agent ──(our commits)──►  merged into main
                                                main = pr-1467 + our features   ← default branch, daily use
     \
      pr/agent  (feature commits ported onto master)  → eventual PR to textmate/textmate
```

| Branch | Purpose | Rules |
|---|---|---|
| `master` | Mirror of `textmate/textmate:master` | Never commit; fast-forward only |
| `pr-1467` | Mirror of `tectiv3/develop` | Never commit; fast-forward when tectiv3 updates |
| `main` | **Default branch.** `pr-1467` + our work | What we build and use daily; merge `pr-1467` in periodically |
| `fix/*` | Bug fixes, branched from `pr-1467` | Merged into `main`; each can be offered to tectiv3 on its own |
| `feature/*` | New features, branched from `main` (needs the `fix/*` build fixes to compile) | Merged into `main`; ported to `master` later by cherry-picking |
| `pr/agent` | Created later: feature commits ported onto `master` | Opened as PR to `textmate/textmate` |

All branches are created with normal pushes — no force-pushes needed.

#### Git terms (reference)
- **Push:** upload local commits to a branch on GitHub, *adding* to its history.
- **Force-push:** make the GitHub branch match the local branch exactly, even if that *discards* commits on GitHub. Used to reset/rewrite a branch; avoided in this plan.

## 5. Agent harness architecture

### Protocol: Agent Client Protocol (ACP)
ACP (started by Zed) is an emerging standard: the **editor is the client**; the **agent runs as a subprocess** speaking JSON-RPC over stdio. The editor provides UI (chat, diffs, permission prompts, file read/write, terminals); the agent does the driving.

- **GitHub Copilot CLI** — native ACP support (public preview since ~Jan 2026).
- **Claude Code** — via an ACP adapter (e.g. Zed's adapter built on the Claude Agent SDK).
- Others (Codex CLI, Gemini CLI, OpenCode) work for free.
- **Fallback:** if ACP falls short for Claude, drive `claude -p --output-format stream-json` directly behind the same internal interface.

**Why ACP:** one client implementation, any agent. Avoids the dead end of hard-coding per-vendor integrations.

### Claude authentication (all three supported)
Auth lives in the agent process, not TextMate:
1. **Anthropic API key** — passed as environment variable to the agent.
2. **Claude subscription** — via Claude Code login.
3. **Claude Code CLI** — the adapter uses the installed CLI/SDK.

### Components

```
Frameworks/AgentClient/   ACP transport (stdio JSON-RPC), session & message model — no UI, no LSP dependency
Frameworks/AgentUI/       Chat panel, diff review, permission prompts, tool-call log (AppKit)
Preferences: Agents pane  Agent command lines, environment/keys, default agent
```

### Capabilities to deliver ("full features")
- Chat panel per project/window with streaming responses.
- Agent reads/writes files through TextMate (so edits respect open, unsaved documents).
- Diff review: accept/reject per file or hunk.
- Permission prompts for tool calls (edit, run command, etc.).
- Terminal/command execution with captured output.
- Context: current file, selection, project root.
- Session management: new, resume, cancel.
- Agent picker: Copilot CLI, Claude Code, others.

### Relationship to existing Copilot code
tectiv3's Copilot ghost text (inline completion via LSP) stays as-is. The agent harness is a **separate feature**; Copilot gains full agent mode through Copilot CLI over ACP.

### Portability rules (keep upstream PR possible)
1. **Mostly new files.** Edits to existing files are confined to a few small, separate "hook" commits (menu item, window/panel registration, preferences pane).
2. **No dependency on tectiv3 internals** (LSPClient, OakSwiftUI). ACP framing differs from LSP's anyway.
3. **Both build files:** `CMakeLists.txt` (tectiv3) and Rave `target` (upstream).
4. **AppKit / Obj-C++ UI** by default, since upstream `master` can't easily build Swift. Alternative: SwiftUI + declare the upstream PR as stacked on #1467.

## 6. Plan of work

### Part A — GitHub
1. Grant `delete_repo` scope: `gh auth refresh -h github.com -s delete_repo`.
2. Delete `sombrerosquirrel/textmate`.
3. Fork `textmate/textmate` → `sombrerosquirrel/textmate`.

### Part B — Local clone
4. Clone to `/Volumes/Little/Projects/me/textmate`; add `upstream` and `tectiv3` remotes.

### Part C — Branches
5. Create `master`, `pr-1467`, `main`, `feature/agent`; push all; set `main` as default branch on GitHub.

### Part D — Verify base
6. `git submodule update --init --recursive`; build `pr-1467` with CMake/Ninja on current macOS; record any fixes as separate commits on a `fix/*` branch.

### Part E — Agent harness
7. Design doc: `docs/plan/agent-harness-design.md` (milestones M1–M5 replace steps 8–11 below).
8. `AgentClient`: ACP transport + session model, tested against Copilot CLI and Claude Code adapter.
9. `AgentUI`: chat panel, diff review, permissions.
10. Agents preferences pane.
11. Hook commits into TextMate (menu, window, prefs).
12. Later: port to `master` as `pr/agent`.

## 7. Sources
- [PR #1467](https://github.com/textmate/textmate/pull/1467)
- [Zed: Agent Client Protocol](https://zed.dev/acp)
- [ACP as universal AI coding editor standard (2026)](https://www.noqta.tn/en/blog/agent-client-protocol-acp-universal-ai-coding-editor-standard-2026)
- [What Is the Agent Client Protocol?](https://www.morphllm.com/agent-client-protocol)
- [CodeCompanion ACP adapters](https://codecompanion.olimorris.dev/configuration/adapters-acp)
- [ACP in Microsoft Terminal](https://codex.danielvaughan.com/2026/06/10/agent-client-protocol-microsoft-intelligent-terminal-codex-cli-multi-agent-ide-ecosystem/)
