---
title: Phase 0 — Repository Setup
status: complete
started: 2026-10-13
completed: 2026-10-13
tags: [textmate, implementation, git]
---

# Phase 0 — Repository Setup

**Status:** ✅ Complete (2026-10-13)
**Plan:** [textmate-ai-plan.md §4, §6 Parts A–C](../plans/textmate-ai-plan.md)

## Done

### GitHub
- Deleted the old `sombrerosquirrel/textmate` (a fork of tectiv3's fork).
- Re-forked directly from `textmate/textmate`, so the fork's parent is the original repo and PRs default to it.
- `main` set as the default branch on GitHub.
- Earlier local attempts (`textmate_aborted`, `textmate_aborted_2`, `textmate-just-copilot`) left untouched and ignored.

### Local clone
`/Volumes/Little/Projects/me/textmate`, submodules initialised (`git submodule update --init --recursive`).

| Remote | Repository |
|---|---|
| `origin` | `sombrerosquirrel/textmate` (our fork) |
| `upstream` | `textmate/textmate` (original) |
| `tectiv3` | `tectiv3/textmate` (PR #1467 source) |

### Branches

| Branch | Tracks / based on | Role |
|---|---|---|
| `master` | `upstream/master` | Mirror, never edited |
| `pr-1467` | `tectiv3/develop` | Mirror of PR #1467, never edited |
| `main` | `pr-1467` + `fix/*` | Default branch, daily use |
| `fix/*` | branched from `pr-1467` | One fix per branch, merged into `main` |
| `feature/agent` | branched from `main` | Agent harness; `main` merged in periodically |

### Conventions recorded
- `CLAUDE.md`: hard tabs at size 3 for our code (tectiv3's and vendor files keep their own style); no `Co-Authored-By` trailers in commits.
- Co-Authored-By trailers removed from earlier commits with `git filter-branch` (at the user's request). Backup refs kept locally.
- `.obsidian/` added to `.git/info/exclude`.
- Debug build is TextMate-dev (`com.macromates.TextMate-dev`). It shares `~/Library/Application Support/TextMate` with the release build (user's decision).

## Future work
- [ ] Delete upstream's leftover branches on the fork: `10_7`, `gh-pages`, `no-copy-of-scopes`.
- [ ] Delete local `backup/pre-trailer-removal/*` branches and `refs/original` from filter-branch.
