---
title: TextMate AI — Implementation Status
updated: 2026-10-14
tags: [textmate, implementation, status]
---

# TextMate AI — Implementation Status

Each phase of work has its own document, created when the phase starts and updated as it progresses. The plans these phases follow are in [`../plans/`](../plans/):

- [textmate-ai-plan.md](../plans/textmate-ai-plan.md): goals, repository organisation, overall approach
- [agent-harness-design.md](../plans/agent-harness-design.md): agent harness design and milestones M1–M5

## Phases

| Phase | Document | Status |
|---|---|---|
| 0. Repository setup | [00-repository-setup.md](00-repository-setup.md) | ✅ Complete (2026-10-13) |
| 1. Build and bug fixes | [01-build-and-bug-fixes.md](01-build-and-bug-fixes.md) | ✅ Complete (2026-10-13) |
| M1. AgentClient core | [02-m1-agent-client.md](02-m1-agent-client.md) | ✅ Complete (2026-10-13) |
| M2. Chat panel | [03-m2-chat-panel.md](03-m2-chat-panel.md) | 🔄 In progress: implemented, being tested by the user |
| M3. Tools: files, permissions, diff review, terminal | — | ⏳ Not started |
| M4. Preferences, Keychain, session history, MCP | — | ⏳ Not started |
| M5. Polish, inline chat, docs, `pr/agent` port | — | ⏳ Not started |

## Current state (2026-10-14)

- **Branches:** `main` = `pr-1467` + all `fix/*` branches. `feature/agent` = `main` + agent harness (M1, M2). All pushed to `origin` (`sombrerosquirrel/textmate`).
- **Build:** `make debug` builds cleanly with Xcode 27 / Swift 6.4 on macOS 27. No new warnings. Known remaining warnings are listed in [01-build-and-bug-fixes.md](01-build-and-bug-fixes.md#future-work).
- **Tests:** `ctest` passes 23/23 on `main`, 25/25 on `feature/agent` (adds AgentClient and AgentUI suites).
- **Next:** user confirms M2, then M3 starts. Checkpoints with the user after each milestone.

## Future work

Work not yet assigned to a phase document. Items move into a phase document when started, and are marked done here when completed.

- [ ] **M3 — Tools:** `fs/read_text_file` and `fs/write_text_file` through OakDocument (unsaved edits respected, undoable), permission cards (Allow / Always allow / Deny), diff review with Keep / Undo per file and a changed-files list, `terminal/*` with output in tool rows, Apply in Editor for code blocks.
- [ ] **M4 — Configuration:** Preferences ▸ Agents pane, API key in the Keychain, `.tm_properties` overrides, chat history (session list / load / resume), MCP servers per agent, plan view.
- [ ] **M5 — Polish:** theme colours and syntax-highlighted code blocks, inline chat at the caret, error states, log view, user documentation, `pr/agent` port onto `master`.
- [ ] Fix the commit grouping on `feature/agent`: 7723847e deletes the M1 debug window files while AppController still references them until d6d22909, so 7723847e alone doesn't build. Needs a force-push; awaiting the user's decision.
- [ ] Optional clean-up: delete upstream's leftover branches on the fork (`10_7`, `gh-pages`, `no-copy-of-scopes`) and local `backup/pre-trailer-removal/*` branches and `refs/original`.
