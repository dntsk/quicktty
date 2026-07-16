# Ghostty-Inspired Tabs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restyle GhostTerm tabs to match the supplied Ghostty visual references without copying Ghostty code, and add Command+1…9 tab switching.

**Architecture:** Keep the existing first-party AppKit collection view and selection model. Replace title-sized scrolling cells with a non-scrolling equal-width layout, implement first-party drawing/hover states, and route reserved Command-number shortcuts through AppKit menu actions to `WindowCoordinator`. Chrome colors are extracted from the finalized public Ghostty configuration and applied only to the workspace subtree, so tabs match the terminal theme without a global appearance override.

**Tech Stack:** Swift 6, AppKit, Swift Testing, XcodeGen, apple/swift-format.

---

### Task 1: Equal-width Ghostty-inspired tab visuals

**Files:**
- Modify: `GhostTerm/Presentation/TabBar/TabItemView.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift` only if chrome material/separator needs adjustment
- Test: `GhostTermTests/Presentation/WorkspacePresentationTests.swift`

**Steps:**
1. Add failing tests for equal-width calculation: all tabs divide available width, additional tabs shrink existing cells, and no minimum width introduces overflow.
2. Remove the horizontal scroll container and constrain the collection view directly beside the fixed new-tab button.
3. Draw inactive tabs transparent and active tabs as a neutral gray capsule with subtle border; add inactive hover fill and multi-selection outline.
4. Center the title, keep a trailing shortcut label, and show close on the left only while hovering. Keep broadcast as a small conditional orange indicator without permanent leading space.
5. Replace the textured `+` with a fixed circular outline/hover button.
6. Run focused presentation tests, format, lint, and build.

### Task 2: Command-number switching

**Files:**
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Integration/GhosttyKeyboardInputTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Steps:**
1. Add failing tests for canonical Command+1…9 menu items and direct tab-index activation.
2. Add `WindowCoordinator.activateTab(at:)`, bounded to the current workspace.
3. Install idempotent AppKit menu shortcuts for Command+1…9 and route them to the coordinator.
4. Reserve exact Command-number events before Ghostty binding lookup; tolerate Caps Lock while rejecting Shift/Option/Control.
5. Show `⌘1…⌘9` in corresponding cells; tabs after nine have no shortcut label.
6. Run focused menu/input/lifecycle tests, format, lint, build, and launch the visual milestone.
