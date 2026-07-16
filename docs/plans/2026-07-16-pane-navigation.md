# Pane Navigation Shortcuts Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Navigate the active tab's existing split panes with the pinned Ghostty macOS shortcuts.

**Architecture:** `AppDelegate` owns idempotent View-menu entries, `GhosttySurfaceView` returns their exact semantic events to AppKit before binding lookup, and `WindowCoordinator` applies existing transactional `SplitCoordinator` focus commands. The coordinator commits only a changed live destination, rehosts the existing root, and focuses that surface.

**Tech Stack:** Swift 6, AppKit, Swift Testing, Ghostty bridge.

---

### Task 1: Cover menu and event ownership

**Files:**
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Integration/GhosttyKeyboardInputTests.swift`

1. Write tests for six idempotent View-menu entries, target/action normalization, exact key equivalents and modifier masks, deduplication, and foreign modified shortcuts.
2. Write keyboard tests for Command+brackets and Command+Option+arrows, including Caps Lock and rejected Shift/Control variants.
3. Install the items after existing View actions and reserve only those semantic events before Ghostty binding lookup.

### Task 2: Focus live panes transactionally

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

1. Write lifecycle tests for nested sequential wrapping and all directional moves, verifying model focus, AppKit first responder, and unchanged surface identities/count.
2. Write a single-pane no-op test.
3. Apply `SplitCoordinator.focusPrevious`, `.focusNext`, or `.focus` to a candidate store; commit only a changed destination that has a live surface, then rehost and focus it.

### Task 3: Verify and document defaults

The built-in, non-configurable pane shortcuts are: Command+[ (previous), Command+] (next), and Command+Option+Left/Right/Up/Down (directional focus). They introduce no configuration keys.

Run formatting, linting, focused AppDelegate/keyboard/split/lifecycle tests, build, and inspect the final diff.
