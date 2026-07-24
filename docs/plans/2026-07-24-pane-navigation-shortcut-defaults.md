# Pane Navigation Shortcut Defaults Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make `Cmd+Shift+Left/Right/Up/Down` the built-in directional pane-focus shortcuts and remove built-in shortcuts from shell prompt navigation.

**Architecture:** Keep the existing typed `ShortcutAction` registry, conflict resolution, dispatch routes, and user override grammar unchanged. Change only built-in defaults and the canonical fallback menu metadata, then update exact contract tests and bundled documentation.

**Tech Stack:** Swift 6, AppKit, Swift Testing, XcodeGen.

---

### Task 1: Pin the new default map with failing tests

**Files:**
- Modify: `QuickTTYTests/Input/ShortcutConfigurationTests.swift:95-175`
- Modify: `QuickTTYTests/AppDelegateLifecycleTests.swift:785-892`

**Step 1: Update registry expectations**

Expect these exact defaults:

```swift
"focus-left": "cmd+shift+left"
"focus-right": "cmd+shift+right"
"focus-up": "cmd+shift+up"
"focus-down": "cmd+shift+down"
"previous-prompt": nil
"next-prompt": nil
```

Keep both prompt actions in the typed terminal allowlist with their existing Ghostty core actions so users can assign custom chords.

**Step 2: Update menu expectations**

Expect all four canonical directional menu items to use `[.command, .shift]`. In the duplicate-normalization test, make the reusable left-arrow item use Command+Shift and preserve foreign Command+Option and Command+Shift+Control variants.

**Step 3: Run focused tests and verify failure**

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project QuickTTY.xcodeproj \
  -scheme QuickTTY \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:QuickTTYTests/ShortcutConfigurationTests \
  -only-testing:QuickTTYTests/AppDelegateLifecycleTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: failures show the production defaults and canonical menu metadata still use Command+Option arrows and prompt navigation still owns Command+Shift Up/Down.

### Task 2: Apply the minimal production change

**Files:**
- Modify: `QuickTTY/Input/ShortcutAction.swift:154-196`
- Modify: `QuickTTY/AppDelegate.swift:633-663`

**Step 1: Change pane focus defaults**

Use `.command, .shift` for `.focusLeft`, `.focusRight`, `.focusUp`, and `.focusDown`.

**Step 2: Remove prompt defaults**

Return `nil` for `.previousPrompt` and `.nextPrompt` in `defaultChord`. Do not remove the action IDs, terminal routes, core actions, or custom assignment support.

**Step 3: Change canonical fallback menu metadata**

Use `[.command, .shift]` for all four directional pane items. Do not change selectors, titles, target routing, or previous/next pane shortcuts.

**Step 4: Run focused tests**

Run the Task 1 command. Expected: PASS.

### Task 3: Update user-facing contracts

**Files:**
- Modify: `QuickTTY/Resources/configuration-reference.md:83-154`
- Modify: `docs/plans/2026-07-23-configurable-shortcuts-design.md:80-140`
- Modify: `.agents/memory/tasks-completed.md`

**Step 1: Update default tables**

Document `cmd+shift+left/right/up/down` for directional pane focus and `disabled` for `previous-prompt`/`next-prompt`. Keep the fixed Ghostty core action names visible.

**Step 2: Record rationale**

State that prompt navigation remains configurable but has no built-in chord because Command+Shift arrows are reserved for directional pane focus.

**Step 3: Record completion**

Add a concise Russian entry to project memory after all checks pass.

### Task 4: Verify the complete change

**Step 1: Format and lint**

```sh
make format
make lint
```

Expected: PASS.

**Step 2: Run the full gate**

```sh
make check
```

Expected: all contracts, build, and tests PASS.

**Step 3: Inspect the final tree**

```sh
git diff --check
git status --short --branch
git diff --stat
git status --short -- Vendor/ghostty
```

Expected: no whitespace errors, no `Vendor/ghostty` changes, and only shortcut-default implementation/tests/docs/memory plus this plan are modified. Do not commit or push without a new explicit user request.
