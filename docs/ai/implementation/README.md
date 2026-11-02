---
title: TextMate AI — Implementation Status
updated: 2026-11-02
tags: [textmate, implementation, status]
---

# TextMate AI — Implementation Status

Each phase of work has its own document, created when the phase starts and updated as it progresses. The plans these phases follow are in [`../plans/`](../plans/):

- [textmate-ai-plan.md](../plans/textmate-ai-plan.md): goals, repository organisation, overall approach
- [agent-harness-design.md](../plans/agent-harness-design.md): agent harness design and milestones M1–M5
- [markdown-preview-plan.md](../plans/markdown-preview-plan.md): existing Markdown support and the native preview pane (P1–P5)

User guides are in [`../user/`](../user/): [markdown-preview.md](../user/markdown-preview.md), [agent-panel.md](../user/agent-panel.md).

## Phases

| Phase | Document | Status |
|---|---|---|
| 0. Repository setup | [00-repository-setup.md](00-repository-setup.md) | ✅ Complete (2026-10-13) |
| 1. Build and bug fixes | [01-build-and-bug-fixes.md](01-build-and-bug-fixes.md) | ✅ Complete (2026-10-13) |
| M1. AgentClient core | [02-m1-agent-client.md](02-m1-agent-client.md) | ✅ Complete (2026-10-13) |
| M2. Chat panel | [03-m2-chat-panel.md](03-m2-chat-panel.md) | ✅ Complete (2026-10-16) |
| M3. Tools: files, permissions, diff review, terminal | [05-m3-tools.md](05-m3-tools.md) | ✅ Complete (2026-10-18) |
| M4. Preferences, Keychain, project overrides, chat history, MCP | [06-m4-configuration.md](06-m4-configuration.md) | ✅ Complete (2026-10-19) |
| M5. Polish, inline chat, docs, `pr/agent` port | [07-m5-polish.md](07-m5-polish.md) | ✅ Steps 1–7 complete, all 23 checks confirmed by the user (2026-11-02); step 8, the `pr/agent` port, deferred |
| Markdown preview pane (P1–P5) | [04-markdown-preview.md](04-markdown-preview.md) | 🔄 In progress: P1–P5 done (2026-10-15); P5 awaiting user check |
| UX pass: agent panel and Markdown preview | [08-ux-pass.md](08-ux-pass.md) | 🔄 Preview scrolling and panels, chat folding, editor code blocks, file links, permission cards, smooth scrolling and the working line done and confirmed by the user (M5 checks 9–21, 2026-11-02); the user's further panel notes and the [open items](08-ux-pass.md#13-open-items) remain |

## Current state (2026-11-02)

- **Branches:** `main` = `pr-1467` + all `fix/*` branches. `feature/agent` = `main` + agent harness (M1, M2). `feature/markdown-preview` = `feature/agent` + Markdown preview work. `feature/agent-tools` = `feature/markdown-preview` + M3. All pushed to `origin` (`sombrerosquirrel/textmate`). `feature/agent-config` = `feature/agent-tools` + M4 (local only). `feature/agent-polish` = `feature/agent-config` + M5 and the UX pass, on `origin` (local commits since 2026-11-02 not pushed yet).
- **Build:** `make debug` builds cleanly with Xcode 27 / Swift 6.4 on macOS 27. No new warnings. Known remaining warnings are listed in [01-build-and-bug-fixes.md](01-build-and-bug-fixes.md#future-work).
- **Tests:** `ctest` passes 23/23 on `main`, 25/25 on `feature/agent` (adds AgentClient and AgentUI suites), 28/28 on `feature/markdown-preview` (adds OakEditorPanels, OakMarkdown and MarkdownPreview; AgentUI's Markdown tests moved to OakMarkdown) and on `feature/agent-tools` (AgentClient grows to 50 tests) and `feature/agent-config` (AgentClient 66); 29/29 on `feature/agent-polish`.
- **Next:** user checks P5 (user guide, tests); then the Markdown preview is complete. M2 is complete (its UX pass is deferred to the end). M3 is complete on `feature/agent-tools`, pushed 2026-10-18 (tested against the [checklist](05-m3-tools.md#to-check-user)). M4 is complete on `feature/agent-config` (local only). M5 is complete on `feature/agent-polish`: log, error states, theme, shortcuts, inline chat with diffs, user guide, and the UX pass work (step 7), all checked by the user ([checklist](07-m5-polish.md#to-check-user)). Next: the user's further panel UX notes, then the deferred `pr/agent` port. Checkpoints with the user after each milestone.

## Future work

Work not yet assigned to a phase document. Items move into a phase document when started, and are marked done here when completed.

- [x] **M3 — Tools:** moved to [05-m3-tools.md](05-m3-tools.md) (2026-10-16).
- [x] **M4 — Configuration:** moved to [06-m4-configuration.md](06-m4-configuration.md) (2026-10-18).
- [x] **M5 — Polish:** moved to [07-m5-polish.md](07-m5-polish.md) (2026-10-19).
- [ ] Fix the commit grouping on `feature/agent`: 7723847e deletes the M1 debug window files while AppController still references them until d6d22909, so 7723847e alone doesn't build. Needs a force-push; awaiting the user's decision.
- [ ] Optional clean-up: delete upstream's leftover branches on the fork (`10_7`, `gh-pages`, `no-copy-of-scopes`) and local `backup/pre-trailer-removal/*` branches and `refs/original`.
- [ ] **Agent panel UX pass** (in progress, see [08-ux-pass.md](08-ux-pass.md); asked for specifics 2026-10-20; the preview's scroll smoothness part is done, M5 step 7a) (user, 2026-10-15: "ux of the panel needs some work but we'll tackle that at the end"). Scheduled after the Markdown preview and M3–M4; collect specifics from the user then. Include the Markdown preview's scroll smoothness (user: "make a note to revisit this later after completion and when doing UX"); ideas in [04-markdown-preview.md](04-markdown-preview.md#future-work).
