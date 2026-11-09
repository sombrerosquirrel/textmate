# CLAUDE.md - TextMate Development Guide

### Workflow
- **Ignore this** always activate serena project first (with full cwd path)
- always list serena memories and always read task completion guideline


## Project Overview

TextMate is a macOS-native text editor written in **Objective-C++**. Low-level data structures and algorithms are C++20; GUI code uses Objective-C++ with AppKit/Cocoa. Licensed under GPL v3. Minimum deployment target: macOS 14.0.

## Repository Structure

```
Applications/   - 9 apps (TextMate, mate, commit, gtm, indent, etc.)
Frameworks/     - 42 self-contained frameworks (core logic + GUI)
PlugIns/        - Plugin system (dialog, dialog-1.x) — incorporated into repo
Shared/         - Shared PCH headers, oak utility includes
vendor/         - External deps (Onigmo, kvdb)
bin/            - Build tools (gen_test, CxxTest) and release scripts
cmake/          - CMake helper functions (TextMateHelpers.cmake)
```

## Build System

- **Build tool:** CMake + Ninja
- **Bundle ID:** `com.macromates.TextMate-dev` (coexists with production TextMate)

### Key Build Commands

```bash
make                 # Incremental debug build (ASan enabled)
make release         # Incremental release build (LTO, no ASan)
make run             # Build debug and launch
make clean           # Remove all build dirs
```

### Dependencies

ninja, cmake, swift (optional, for OakSwiftUI framework)

### Build Quirks

- `-ObjC` linker flag required to load ObjC categories from static libraries
- OakDebug linked unconditionally (symbols used in all build configs)
- Plugin `.tmplugin` bundles need ad-hoc codesigning before embedding in app
- gen_test runner inlines test source bodies — don't compile test files separately
- Framework resources (icons, images, plists) must be added to TextMate app CMakeLists since static libs can't carry resources

## Architecture

### Core Data Structures (Frameworks/)

- **buffer/** - Text buffer: `ng::buffer_t` built on `ng::detail::storage_t` (chunked text via `oak::basic_tree_t`)
- **editor/** - Editing operations, clipboard, snippets, 40+ editor actions
- **layout/** - Text layout/rendering: `ng::layout_t` wraps buffer + viewport
- **parse/** - Grammar/syntax parsing engine
- **scope/** - Scope management for syntax highlighting
- **text/** - String/text utilities

### GUI Frameworks

- **OakTextView** - Main text editor view + GutterView + OTVStatusBar
- **OakAppKit** - macOS AppKit utilities/extensions
- **DocumentWindow** - Document/session management
- **Preferences** - Settings UI
- **BundleEditor** / **BundlesManager** - Bundle editing and management

### Support Frameworks

- **command/** - Command execution
- **plist/** - Property list I/O
- **regexp/** - Regex (Onigmo-based)
- **scm/** - Source control (git, svn, hg)
- **theme/** - Theme loading
- **file/** - File I/O
- **io/** - I/O abstractions
- **undo/** - Undo/redo stack

### Entry Point

`Applications/TextMate/src/main.mm` - Sets app support dir via `oak::application_t::set_support()`, registers signal handlers, calls `NSApplicationMain()`.

### App Support Path

Use `oak::application_t::support("relative/path")` (from `<OakSystem/application.h>`) instead of hardcoding `~/Library/Application Support/TextMate/`. Set once in `main.mm`.

## Code Conventions

- **Tab size:** tabSize=3, softTabs=false
- **Namespaces:** `oak::` (utilities), `ng::` (text/buffer engine)
- **Type suffix:** `_t` for type definitions, `_ptr` for smart pointers
- **Pointer style:** `type* var`
- **Visibility:** hidden by default (`-fvisibility=hidden`)
- **Memory:** std::shared_ptr, ARC for Objective-C
- **Header guards:** `#ifndef SOMETHING_H_RANDOMHASH`
- **Commit messages:** Summary < 70 chars, blank line, then reasoning
- **No `@available` checks** for APIs available since macOS 14 (our minimum target)

## Testing

- **Framework:** CxxTest (at `bin/CxxTest`)
- **Test files:** `Frameworks/<name>/tests/t_*.cc` or `t_*.mm`
- **Run tests:** `cd build-debug && ctest --output-on-failure`

## Git
- **Convention:** Don't add  Co-Authored-By: "Claude Opus 5.5 <noreply@anthropic.com>"

## Docs
- **Purpose:** Provide details of planning, implementation and future work for developing AI agents, harness and supporting features.
- **Plans:** exist in /docs/ai/plans/
- **Implementation:** /docs/ai/implementation. Files will be created as phases of work is started, updated, completed and future work will be added at the bottom and updated when completed.

## Upstream Status

This fork (`tectiv3/textmate`) is based on `textmate/textmate` at the latest upstream commit. Upstream is unmaintained. Active community fork: `tagliala/textmate`.

## Behavioral guidelines
### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```
Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.
