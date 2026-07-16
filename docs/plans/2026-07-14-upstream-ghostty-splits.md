# Upstream Ghostty Splits Integration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add recursive terminal panes using Ghostty's pinned generic `SplitView` implementation directly from the submodule, with Command+D/Command+Shift+D creation and mouse resizing.

**Architecture:** Compile Ghostty's generic SwiftUI `SplitView`, divider, and pointer backport sources directly into the GhostTerm target without copying or editing them. A thin first-party SwiftUI adapter maps GhostTerm's persistent `SplitNode` and existing AppKit `GhosttySurfaceView` instances into the upstream view. WindowCoordinator remains responsible for pane surface ownership and model transactions.

**Tech Stack:** Swift 6, AppKit, SwiftUI hosting, pinned Ghostty source, libghostty C API, Swift Testing, XcodeGen.

---

### Task 1: Compile and host upstream SplitView

**Files:**
- Modify: `project.yml`
- Use directly: `Vendor/ghostty/macos/Sources/Features/Splits/SplitView.swift`
- Use directly: `Vendor/ghostty/macos/Sources/Features/Splits/SplitView.Divider.swift`
- Use directly: `Vendor/ghostty/macos/Sources/Helpers/Backport.swift`
- Create: `GhostTerm/Presentation/Splits/GhosttySplitTreeView.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Modify: `THIRD_PARTY_NOTICES.md`
- Test: create `GhostTermTests/Presentation/GhosttySplitTreeViewTests.swift`

**Steps:**
1. Add the three pinned vendor files as source entries in XcodeGen without copying or modifying them.
2. Add an `NSViewRepresentable` that returns an existing `GhosttySurfaceView` without owning or closing it.
3. Recursively map `.pane` to the representable and `.split` to upstream `SplitView`, preserving axis and ratio.
4. Route upstream resize binding and equalize callbacks by split UUID.
5. Replace WorkspaceViewController's single-view host with an `NSHostingController` for active tab layouts; empty workspace remains AppKit-native.
6. Verify direct vendor source compilation, tree mapping, surface identity, divider direction, and callback IDs.
7. Run focused tests, format, lint, and build; commit.

### Task 2: Integrate pane surface lifecycle

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Test: extend `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Steps:**
1. Add a MainActor surface-focus callback so clicking/focusing a pane updates `TerminalTab.activePaneID` without intercepting terminal mouse events.
2. Add transactional `splitActivePane(axis:)`: create a new `.split` surface, apply `SplitCoordinator.split`, commit registry/store, render, and focus the new pane; rollback the surface on model failure.
3. Render the active tab root with all matching surfaces rather than one active surface.
4. Apply divider resize through `SplitCoordinator.updateRatio`; update the hosted root continuously. Double-click uses `equalize`.
5. On process exit, apply `closePane`: collapse only that branch; close the tab only when its final pane exits; preserve final-tab replacement behavior.
6. Verify nested splits, mouse ratios, focus, pane exit collapse, registry counts, and rollback.
7. Run focused tests and build; commit.

### Task 3: Add split commands

**Files:**
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Integration/GhosttyKeyboardInputTests.swift`

**Steps:**
1. Install idempotent menu actions: Command+D creates a right-hand pane (`SplitAxis.horizontal`), Command+Shift+D creates a lower pane (`SplitAxis.vertical`).
2. Reserve only those exact semantic shortcuts before Ghostty binding lookup so AppKit routes them; tolerate Caps Lock and reject extra Option/Control.
3. Keep the new pane active and focused in Normal and Quake modes.
4. Verify command modifiers, menu dispatch, nested split creation, and surface focus.
5. Run focused checks, build, and launch the visual milestone.

### Task 4: Milestone validation

1. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check`; separate known real-surface test-host instability from new failures.
2. Review direct vendor source update risk, SwiftUI/AppKit ownership, callback reentrancy, and surface leaks.
3. Launch from main and manually verify Command+D, Command+Shift+D, nested splits, drag resizing, equalize, focus, exit collapse, Normal, and Quake.
