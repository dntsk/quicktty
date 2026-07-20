# Inline Config Diagnostics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Apply valid GhostTerm config lines while showing ignored line errors as a non-interactive diagnostic block inside the terminal viewport.

**Architecture:** `ConfigController` separates non-fatal parsed diagnostics from fatal I/O/Ghostty reload errors. `AppDelegate` converts both into an immutable presentation and preserves startup diagnostics until `WindowCoordinator` exists. `WorkspaceViewController` renders the presentation without touching PTY state or recreating surfaces.

**Tech Stack:** Swift 6, AppKit, libghostty, Swift Testing, XcodeGen.

---

### Task 1: Make GhostTerm line diagnostics non-fatal

**Files:**
- Modify: `GhostTerm/Config/ConfigController.swift`
- Test: `GhostTermTests/Config/ConfigControllerTests.swift`

**Step 1: Write failing tests**

Add tests proving that a document containing one valid and one invalid `ghostterm-*` assignment:

- calls Ghostty reload once;
- applies the valid value;
- excludes both GhostTerm lines from effective config;
- reports the invalid line through a diagnostics callback;
- becomes the active document so an unchanged watcher event is a no-op.

Add a second reload with valid content and assert that the callback receives an empty diagnostics list.

**Step 2: Run focused tests and verify failure**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GhostTerm.xcodeproj -scheme GhostTerm \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:GhostTermTests/ConfigControllerTests test
```

Expected: tests fail because `ConfigController.apply` throws `.invalidConfig`.

**Step 3: Add the callback and change apply semantics**

Add:

```swift
typealias DiagnosticsHandler = @MainActor ([ConfigDiagnostic]) -> Void
```

Inject `onDiagnostics`, defaulting to `{ _ in }`. Remove the fatal guard for parsed GhostTerm diagnostics. Keep all existing effective-file and Ghostty reload rollback logic. After successful reload and `onUpdate`, call `onDiagnostics(result.diagnostics)`; an empty list clears previous warnings.

Do not call `onDiagnostics` when Ghostty reload fails.

**Step 4: Run focused tests**

Expected: `ConfigControllerTests` pass.

**Step 5: Commit**

```bash
git commit -m "feat: ignore invalid GhostTerm config lines"
```

### Task 2: Add a non-interactive terminal diagnostic overlay

**Files:**
- Create: `GhostTerm/Presentation/Diagnostics/ConfigDiagnosticPresentation.swift`
- Create: `GhostTerm/Presentation/Diagnostics/ConfigDiagnosticView.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Test: `GhostTermTests/Presentation/WorkspacePresentationTests.swift`

**Step 1: Write failing presentation tests**

Mount `WorkspaceViewController` in a real `NSWindow` and verify:

- empty diagnostics keep the view hidden;
- path and first eight messages are visible;
- more than eight messages adds a remaining-count line;
- applying an empty presentation hides it;
- hit-testing through the overlay resolves the underlying terminal host, not the diagnostic view;
- terminal/split hosting controller identity is unchanged while showing and clearing diagnostics.

**Step 2: Implement the presentation model**

Use an immutable Sendable model:

```swift
struct ConfigDiagnosticPresentation: Equatable, Sendable {
    let path: String
    let messages: [String]
}
```

**Step 3: Implement the view**

Create an AppKit view with a monospaced wrapping label and translucent high-contrast background. Override hit testing to always return `nil`. Limit rendered messages to eight and append `… and N more`.

Add the view above `terminalContentView` without changing terminal constraints. Expose:

```swift
func applyConfigurationDiagnostics(_ presentation: ConfigDiagnosticPresentation?)
```

**Step 4: Run presentation tests**

Expected: `WorkspacePresentationTests` pass.

**Step 5: Commit**

```bash
git commit -m "feat: show config errors inside terminal viewport"
```

### Task 3: Wire runtime and startup diagnostics

**Files:**
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Config/ConfigController.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorConfigurationTests.swift`

**Step 1: Write failing wiring tests**

Verify:

- parsed diagnostics include config path and line-aware localized messages;
- an empty successful callback clears the presentation;
- fatal ConfigController errors produce a path plus readable message;
- diagnostics received before coordinator creation remain pending;
- applying/clearing diagnostics through coordinator preserves every surface identity and focus.

**Step 2: Add readable error conversion**

Make `ConfigControllerError` conform to `LocalizedError`. Preserve all detailed `ConfigDiagnostic.localizedDescription` values for `.invalidConfig` compatibility, even though parsed line diagnostics now use `onDiagnostics`.

**Step 3: Wire AppDelegate**

Add pending diagnostic state. The ConfigController diagnostics callback maps each diagnostic to `localizedDescription`. ConfigController errors map to one readable message. After `WindowCoordinator.start()`, apply pending diagnostics. Successful valid reload passes `nil` and clears the overlay.

Keep generic WindowCoordinator errors log-only; only ConfigController callbacks drive this overlay.

**Step 4: Wire WindowCoordinator**

Add a narrow method that forwards the immutable presentation to `WorkspaceViewController`. Do not commit workspace state, persist snapshots, change focus, or recreate surfaces.

**Step 5: Run focused and regression checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make format
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GhostTerm.xcodeproj -scheme GhostTerm \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:GhostTermTests/ConfigControllerTests \
  -only-testing:GhostTermTests/WorkspacePresentationTests \
  -only-testing:GhostTermTests/WindowCoordinatorConfigurationTests \
  -only-testing:GhostTermTests/AppDelegateLifecycleTests test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
git diff --check
```

Expected: all focused suites, lint, callback contract and build pass.

**Step 6: Manual verification**

Add malformed `ghostterm-quake-height`, reload, and verify shell remains usable while the terminal overlay lists the exact line. Fix the line and verify the overlay disappears without restarting surfaces.

**Step 7: Commit**

```bash
git commit -m "feat: route config diagnostics to terminal overlay"
```
