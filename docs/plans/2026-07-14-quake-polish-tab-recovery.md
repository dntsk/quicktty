# Quake Polish and Tab Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add smooth Quake presentation, mouse-resizable persistent height, real tab creation, and automatic shell recovery after the final process exits.

**Architecture:** Keep Quake behavior inside `QuakeWindowController`, with AppKit-specific window animation and resize events behind testable protocols/helpers. Extend the preserving config pipeline for height writeback. Replace `WindowCoordinator`'s single surface reference with a PaneID-keyed registry and one transactional tab creation path used by startup, UI actions, and final-tab recovery.

**Tech Stack:** Swift 6, AppKit, Swift Testing, Ghostty C API through `GhosttyBridge`, XcodeGen, apple/swift-format.

---

### Task 1: Preserve and persist a resized Quake height

**Files:**
- Modify: `GhostTerm/Config/ConfigDocument.swift`
- Modify: `GhostTerm/Config/ConfigController.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Test: `GhostTermTests/Config/ConfigDocumentTests.swift`
- Test: `GhostTermTests/Config/ConfigControllerTests.swift`

**Step 1: Write failing tests**

Add tests that set Quake height to a fraction, assert a stable locale-independent percentage string, preserve inline comments/CRLF/unrelated options, atomically write the source config, and publish the updated effective config once.

**Step 2: Run tests to verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project GhostTerm.xcodeproj -scheme GhostTerm -destination 'platform=macOS,arch=arm64' -only-testing:GhostTermTests/ConfigDocumentTests -only-testing:GhostTermTests/ConfigControllerTests test
```

Expected: FAIL because height formatting and `updateQuakeHeight` do not exist.

**Step 3: Implement minimal preserving writeback**

Add a formatter that clamps only valid `0 < fraction <= 1` input and writes a trimmed percent with enough precision for pixel-stable restoration. Add `ConfigController.updateQuakeHeight(_:)` using the same read → mutate → atomic write → transactional apply pattern as presentation mode. Avoid a new dependency and avoid rewriting the whole document.

**Step 4: Run focused tests and formatting**

Run the two suites above, `make format`, and `make lint`. Expected: PASS.

**Step 5: Commit**

```bash
git add GhostTerm/Config GhostTerm/AppDelegate.swift GhostTermTests/Config
git commit -m "feat: persist resized Quake height"
```

### Task 2: Animate and resize the Quake panel

**Files:**
- Modify: `GhostTerm/Presentation/QuakeWindow.swift`
- Modify: `GhostTerm/Presentation/QuakeWindowController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Test: `GhostTermTests/Presentation/PresentationStateMachineTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorConfigurationTests.swift`

**Step 1: Write failing animation and resize tests**

Test that show starts offscreen at the animation level, defers movement until a scheduled main-loop action, uses an opening ease-out curve, restores floating level before focus, and keeps last-request-wins cancellation. Test live-resize normalization: screen width stays fixed, top remains anchored, height is clamped to a practical minimum/available maximum, and persistence fires only at the end of user live resize.

**Step 2: Run focused tests to verify failure**

Run the two presentation suites. Expected: FAIL on missing animation lifecycle and resize callbacks.

**Step 3: Implement AppKit behavior**

Add `.resizable` to the borderless panel. Add narrow protocol methods for animation level and resize state rather than leaking concrete `NSPanel` behavior into pure tests. Defer only the start of AppKit frame animation by one main-loop turn; cancellation must cancel a deferred request too. In `NSWindowDelegate` resize hooks, constrain manual width/origin/top while permitting height changes. Report the final fraction through `WindowCoordinator` to the config persistence closure.

**Step 4: Run focused tests, format, lint, and build**

Expected: all focused tests and build pass.

**Step 5: Commit**

```bash
git add GhostTerm/Presentation GhostTerm/WindowCoordinator.swift GhostTerm/AppDelegate.swift GhostTermTests/Presentation
git commit -m "feat: animate and resize Quake window"
```

### Task 3: Introduce real multi-surface tab runtime

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift` only if a narrow lookup/test hook is required
- Test: create `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Update: tests using `defaultSurfaceForTesting`

**Step 1: Write failing lifecycle tests**

Cover creation of two shell tabs with distinct PaneIDs/surfaces, switching the active tab's displayed surface, closing one without affecting the other, process-exit cleanup from both registries, and automatic creation of exactly one replacement when the final live tab exits. Verify a failed replacement leaves the window alive and reports the error.

**Step 2: Run the new suite to verify failure**

Expected: FAIL because only `defaultSurface` exists and exited surfaces are not closed in the bridge.

**Step 3: Implement transactional tab creation and cleanup**

Replace `defaultSurface` with `[PaneID: GhosttySurfaceView]`. Extract `createShellTab(in:)` so a failed model insertion closes the just-created surface and does not mutate the registry. Make refresh resolve any active pane through the registry. On process exit, close the bridge surface before removing the pane/tab model; if no tabs remain globally, create one replacement in the active workspace. Never close the normal window solely because the last shell exited.

**Step 4: Run lifecycle and existing integration tests**

Run the new suite plus clipboard, renderer lifecycle, and workspace presentation suites. Expected: PASS.

**Step 5: Commit**

```bash
git add GhostTerm/WindowCoordinator.swift GhostTerm/Integration/GhosttyBridge GhostTermTests
git commit -m "feat: manage terminal surfaces per tab"
```

### Task 4: Add New Tab keyboard and menu actions

**Files:**
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Test: `GhostTermTests/Presentation/WorkspacePresentationTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Write failing routing tests**

Test that File contains New Tab with `Command+T` routed to the coordinator method. New Tab is available only through the File menu and `Command+T`; the tab bar has no `+` control. Test creation in the active workspace and focus of the new surface.

**Step 2: Run focused tests to verify failure**

Expected: FAIL because no New Tab UI action exists.

**Step 3: Implement minimal UI**

Keep the tab bar free of a New Tab control. Install a File → New Tab item with `Command+T` in `AppDelegate` and route it to `WindowCoordinator.createNewTab()`. Keep the action available for empty workspaces and both presentation modes.

**Step 4: Run focused tests, format, lint, and build**

Expected: PASS.

**Step 5: Commit**

```bash
git add GhostTerm/Presentation GhostTerm/WindowCoordinator.swift GhostTerm/AppDelegate.swift GhostTermTests/Presentation
git commit -m "feat: add New Tab actions"
```

### Task 5: Milestone validation

**Files:**
- Update docs only if implementation details changed.

**Step 1: Run full checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check
```

Expected: formatting, lint, runtime callback guard, build, and all tests pass.

**Step 2: Focused review**

Review cancellation races, focus-loss during animation, config watcher re-entry, double close callbacks, replacement-shell recursion, and surface ownership leaks. Fix only Critical/Important findings and rerun affected tests.

**Step 3: Manual milestone**

Build and launch exact Debug app. Verify normal → Quake, repeated F12 during animation, bottom-edge resize, config writeback, relaunch height restore, `Command+T`, `+`, tab switching, and `exit` automatic replacement.
