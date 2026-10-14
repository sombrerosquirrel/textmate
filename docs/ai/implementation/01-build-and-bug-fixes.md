---
title: Phase 1 — Build and Bug Fixes
status: complete
started: 2026-10-13
completed: 2026-10-13
tags: [textmate, implementation, build, fixes]
---

# Phase 1 — Build and Bug Fixes

**Status:** ✅ Complete (2026-10-13). User checkpoint passed before feature work started. UI fixes found while testing M2 were added afterwards; they're listed below.
**Plan:** [textmate-ai-plan.md §6 Part D](../plans/textmate-ai-plan.md)

Each fix is a separate `fix/*` branch from `pr-1467`, merged into `main`, so each can be offered to tectiv3 or upstream on its own.

## Build and test fixes

| Branch | Commits | What and why |
|---|---|---|
| `fix/swift-build-paths` | d3ff4fac | Swift 6.4 (Xcode 27) writes `OakSwiftUI-Swift.h` under `.build/out/…`. `build.sh` copies it to `build-*/swift-include`; CMake uses `OakSwiftUI_INCLUDE_DIR`. |
| `fix/tests` | faf1d627, 802d34c8, 9a8e24e0, 0ed35f77 | `runner.mm` falls back to the process name when the bundle ID is nil. ASan fixes in `t_rect`, `t_match`, `t_basic_tree_delta`, `t_basic_tree_numeric` (`basic_tree_t` uses a stashing iterator, so `std::reverse_iterator` is unsafe). Environment updates: io ignores `com.apple.*` xattrs; theme expectation #171717; git test uses `init -b master`; hg/svn tests skip when missing; spelling test calls `recheck_spelling`; `t_save` checks ASCII output (macOS 27 iconv bug). |
| `fix/onigmo-setup` | 4f454917 | **App bug:** `vendor/Onigmo/src/setup.c` was never linked from the static library, so `\w` matched ASCII only. Now an OBJECT library linked via `$<TARGET_OBJECTS>`. Vendor sources unmodified. |
| `fix/build-warnings` | 5f46f2cc | `text/types.h`: `range_t(0)` → `range_t(pos_t())` (it constructed a `std::string` from a null pointer). CMake policy `CMP0156` NEW removes duplicate-library linker warnings. |
| `fix/command-wait-race` | 83791e63 | Lost wake-up in `command::runner_t::wait_for_command` (also in upstream) made command tests hang intermittently. Now an atomic flag plus `CFRunLoopRunInMode` in 0.1 s slices (`usleep` when the run loop has no sources). Passed 30 repeats. |

Result: `make debug` builds, `ctest` 23/23 on `main`, stable across repeated runs. Vendor code verified unmodified: submodules at upstream commits, xdiff matches git v2.54.0, nlohmann/json matches v3.11.3.

## UI fixes (added 2026-10-13, found while testing M2)

| Branch | Commits | What and why |
|---|---|---|
| `fix/window-follows-theme` | dcdc79bd | The window (file browser, tabs, title bar, status bar) followed the macOS appearance, so a light theme in dark mode gave a dark frame around a light editor. `DocumentWindowController` now observes `textView.themeUUID` and sets `window.appearance` from `theme->is_dark()`. `OakTextView` picks the "auto" theme from `NSApp.effectiveAppearance` (not its own, which now comes from the window) and observes it via KVO. |
| `fix/tab-bar-height` | b005661b, bc642126 | Tabs were 22pt. System window tabs (e.g. TextEdit) are 28pt. Tab bar is now 29pt (28pt tabs + 1pt top border); title and close button centred vertically. Tabs fill the bar's full height, removing a 1pt white line where the title bar showed through above the editor. |
| `fix/file-browser-background` | 0b68f0fa | tectiv3's commit 7b0723f6 set the file browser to `controlBackgroundColor`, which is white in light mode. Light themes now get #ECECEC (the grey of the release build, measured from a screenshot); dark themes use `windowBackgroundColor`. |

Findings:
- The release TextMate 2.0.23 is built against the macOS 11 SDK, so macOS 27 draws it in the older style (centred title, grey sidebar). Builds using the macOS 27 SDK get the new design.
- `UIDesignRequiresCompatibility` in Info.plist doesn't restore the old style on macOS 27 (tested). The title stays left-aligned (accepted by the user).

## Future work
- [ ] Optional: clean up remaining warnings: about 37 Onigmo old-style C declarations (vendor), about 23 Ruby frozen-string-literal notices from `bin/gen_test`, about 40 macOS deprecations (`commitEditing`, `WebUndefined`, …).
- [ ] Check whether the file browser's header and footer strips (`NSVisualEffectMaterialTitlebar`) match the new #ECECEC background.
- [ ] Offer the `fix/*` branches to tectiv3 or upstream if wanted (not required).
