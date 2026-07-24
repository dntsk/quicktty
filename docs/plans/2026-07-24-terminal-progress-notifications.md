# Terminal Progress and Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add generic OSC 9;4 progress badges and background completion/attention notifications with exact pane navigation, plus documented Pi, Claude Code, and Codex integrations.

**Architecture:** Pinned Ghostty converts OSC 9;4 and OSC 133 into surface-targeted C actions. `GhosttyBridge` copies them into stable Swift values and routes ordered events to a transient MainActor activity controller keyed by `PaneID`; AppKit chrome derives tab/workspace aggregates without touching persisted domain state or terminal content. A separately injectable notification controller owns authorization and click routing.

**Tech Stack:** Swift 6, AppKit, UserNotifications, pinned `libghostty`, Swift Testing, shell contract tests, XcodeGen.

**Constraint:** Do not modify `Vendor/ghostty`, the pin, persisted state schema, terminal titles, pane decoration, or user agent configs. Do not commit or push without explicit user permission.

---

### Task 1: Bridge progress and command-finished actions

**Files:**
- Create: `QuickTTY/Integration/GhosttyBridge/GhosttyProgressReport.swift`
- Create: `QuickTTY/Integration/GhosttyBridge/GhosttyActivityConfiguration.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift:45-130,315-405,578-593,734-815`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift:278-336,1733-1763,1890-1935,2080-2305`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyConfiguration.swift`
- Modify: `scripts/check-runtime-callbacks.sh`
- Test: `QuickTTYTests/Integration/GhosttySurfaceViewTests.swift`
- Test: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`

**Step 1: Write failing bridge conversion tests**

Cover exact C-union conversion for all five progress states, `-1` versus `0...100`, command exit `-1` versus `0...255`, duration, invalid target/state, and exact pinned tags `56`/`58`.

**Step 2: Write failing delivery/lifecycle tests**

Verify:

- two surfaces route to their own `PaneID`;
- `working → remove` is delivered in order even before MainActor drains;
- repeated progress events preserve order;
- command-finished edge events are not coalesced;
- deactivated/closed context drops queued events;
- old events do not reach a replacement surface with the same `PaneID`.

**Step 3: Run focused tests and confirm failure**

```bash
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/GhosttySurfaceViewTests \
  -only-testing:QuickTTYTests/GhosttyBridgeTests
```

Expected: FAIL because stable progress types/handlers do not exist.

**Step 4: Implement stable types and ordered callback route**

Add C-independent values:

```swift
struct GhosttyProgressReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case remove
        case set
        case error
        case indeterminate
        case pause
    }

    let state: State
    let progress: UInt8?
}

struct GhosttyCommandFinished: Equatable, Sendable {
    let exitCode: UInt8?
    let durationNanoseconds: UInt64
}
```

Add surface handlers `(PaneID, value) -> Void`. In the top-level callback, validate surface target, recover callback userdata, copy scalar values synchronously, and enqueue stable events before the app-level action path. Use ordered pending arrays for both action kinds; do not use latest-only coalescing.

**Step 5: Read finalized activity config transactionally**

Add `GhosttyActivityConfiguration(progressStyleEnabled:desktopNotificationsEnabled:)`, populated from finalized `progress-style` and `desktop-notifications`. Replace it only with a valid bridge reload, alongside palette/split appearance; invalid reload preserves the old value.

**Step 6: Extend callback contract and run tests**

```bash
make callback-contract
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/GhosttySurfaceViewTests \
  -only-testing:QuickTTYTests/GhosttyBridgeTests
```

Expected: PASS.

### Task 2: Build the transient activity reducer

**Files:**
- Create: `QuickTTY/Presentation/TerminalActivity/TerminalActivityState.swift`
- Create: `QuickTTY/Presentation/TerminalActivity/TerminalActivityController.swift`
- Test: `QuickTTYTests/Presentation/TerminalActivityControllerTests.swift`

**Step 1: Write failing pure state tests**

Use an injectable monotonic `now` closure and deterministic cleanup scheduler. Cover:

- first working starts activity;
- Pi keepalive preserves original start instant;
- determinate progress updates visible percentage;
- pause and error create one-shot attention transitions;
- repeated same state does not duplicate effects;
- remove after working/waiting produces completed;
- remove after error clears without producing success;
- remove without active state is a no-op;
- command-finished only affects an existing active record;
- non-zero command exit produces failed;
- `4.999s` completion is not notification-eligible, exact `5s` is eligible;
- selected visible completed/failed cleanup after three seconds;
- inactive completed/failed persists until acknowledgement;
- pane removal cancels cleanup and emits no notification.

**Step 2: Run and confirm failure**

```bash
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/TerminalActivityControllerTests
```

**Step 3: Implement the minimal reducer/controller**

Keep state keyed by `PaneID`, expose immutable live status map, and return typed effects (`waiting`, `failed`, `completed(duration:)`, `cleared`) to the owner. Do not import AppKit, UserNotifications, GhosttyKit, or persistence types. Preserve start time across working/pause transitions. Scheduling must be replaceable in tests and canceled per pane.

**Step 4: Run focused tests**

Expected: PASS without sleeps.

### Task 3: Render tab and workspace status without structural reload

**Files:**
- Create: `QuickTTY/Presentation/TerminalActivity/TerminalStatusPresentation.swift`
- Create: `QuickTTY/Presentation/TerminalActivity/TerminalStatusBadgeView.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabItemView.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabBarViewController.swift`
- Modify: `QuickTTY/Presentation/Workspace/WorkspaceSelector.swift`
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Test: `QuickTTYTests/Presentation/WorkspacePresentationTests.swift`

**Step 1: Write failing aggregation tests**

Verify no status for an empty input and precedence `failed > waiting > working > completed`, independent of pane order. A determinate aggregate exists only when all winning contributors have percentages; use their integer average.

**Step 2: Write failing AppKit presentation tests**

Verify:

- badge is left of tab title;
- spinner/percentage/pause/error/check representations and accessibility labels;
- status-only refresh keeps the same `TabItemView`, reload generation, title, selection, first responder and rename editor;
- clearing hides badge and restores title layout;
- workspace button and inactive workspace `NSMenuItem.badge` update in place;
- open menu tracking and item target/action/checkmark survive refresh;
- existing 28 pt tab and 22 pt selector geometry stays unchanged.

**Step 3: Implement pure aggregate presentation**

Derive tab status from all `tab.root.leaves`. Derive workspace status from all original pane statuses, not averages of averages.

**Step 4: Implement status-only AppKit updates**

Add status caches and `refreshStatuses` APIs following the existing live-title update path. Do not call `reloadData`, `workspaceMenu.removeAllItems`, full `apply`, or update the SwiftUI split host for a status-only change.

**Step 5: Run focused presentation tests**

```bash
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/WorkspacePresentationTests
```

Expected: PASS.

### Task 4: Wire live activity into `WindowCoordinator`

**Files:**
- Modify: `QuickTTY/WindowCoordinator.swift:203-272,1120-1190,1662-1914`
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Write failing coordinator lifecycle tests**

Cover active pane, inactive split, inactive tab and inactive workspace. Assert status updates:

- do not mutate `WorkspaceStore` or persistence snapshots;
- do not recreate surfaces/split host;
- do not change first responder;
- immediately update tab/workspace aggregate;
- ignore stale callback from closed or replaced surface;
- clear when `progress-style` becomes false;
- keep badges but produce no notification effect when only `desktop-notifications` becomes false.

**Step 2: Connect typed bridge handlers**

Own one activity controller in `WindowCoordinator`, validate that each `PaneID` still maps to a live owning tab, apply progress/command events, and invoke only `workspaceViewController.refreshStatuses`. Full presentation apply receives current status map for structural changes.

**Step 3: Add cleanup and acknowledgement hooks**

Clear activity in the common surface removal path. When a destination tab becomes selected in a key window, acknowledge completed/failed records and retain live waiting/working records.

**Step 4: Run focused coordinator tests**

```bash
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests
```

Expected: PASS.

### Task 5: Add lazy macOS notifications and exact destination activation

**Files:**
- Create: `QuickTTY/Notifications/TerminalDestination.swift`
- Create: `QuickTTY/Notifications/TerminalNotificationClient.swift`
- Create: `QuickTTY/Notifications/TerminalNotificationController.swift`
- Modify: `QuickTTY/AppDelegate.swift`
- Modify: `QuickTTY/Presentation/PresentationController.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Test: `QuickTTYTests/Notifications/TerminalNotificationControllerTests.swift`
- Test: `QuickTTYTests/Presentation/PresentationStateMachineTests.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Write failing notification policy tests**

With a fake center/client, cover:

- waiting/failed immediately eligible;
- completed only after five seconds;
- no request for short, duplicate, suppressed, disabled or stale activity;
- suppression exactly when mode-aware active window is key and exact source tab selected; active pane does not matter;
- authorization requested lazily once and concurrent events queue behind it;
- denied authorization is remembered;
- notification content is generic and userInfo contains only versioned marker plus UUIDs;
- no terminal title/cwd/command/prompt appears in logs or requests;
- foreground delivery rechecks suppression.

**Step 2: Implement injectable notification controller**

Keep `UNUserNotificationCenter` behind a narrow MainActor client. Production delegate callbacks hop safely to MainActor and ignore responses after shutdown. Do not request permission during app startup.

**Step 3: Write failing click-navigation tests**

Cover Normal, visible Quake and hidden Quake. Click must activate exact workspace/tab/pane, show the current presentation, and preserve every existing surface object/ID. Closed pane and stale destination are no-ops.

**Step 4: Add mode-preserving presentation API**

Add `showCurrentPresentation()`:

- Normal calls existing normal show path;
- Quake requests `.shown` through existing visibility state machine.

Do not call mode transition or surface creation.

**Step 5: Implement transactional destination activation**

Resolve exact UUID triple, mutate a candidate store with existing workspace/tab/pane primitives, show current presentation, commit once, then refresh with terminal focus.

**Step 6: Run focused notification/navigation tests**

```bash
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/TerminalNotificationControllerTests \
  -only-testing:QuickTTYTests/PresentationStateMachineTests \
  -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests
```

Expected: PASS and no real notification prompt.

### Task 6: Ship Pi, Claude Code, and Codex integration guidance

**Files:**
- Create: `QuickTTY/Resources/AgentIntegrations/quicktty-progress`
- Create: `QuickTTY/Resources/AgentIntegrations/claude-settings.example.json`
- Create: `QuickTTY/Resources/AgentIntegrations/codex-hooks.example.json`
- Create: `docs/agent-integrations.md`
- Create: `scripts/tests/agent-integrations-test.sh`
- Modify: `project.yml`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `QuickTTY/Resources/configuration-reference.md`

**Step 1: Add failing shell contract**

Test shell syntax, exact OSC bytes for working/waiting/error/remove, valid Claude JSON `terminalSequence`, valid Codex empty JSON output, no stdin/prompt reads, graceful missing controlling TTY, valid example JSON, and expected bundle resource paths.

**Step 2: Implement dependency-free helper**

Support explicit modes:

```text
quicktty-progress claude working|waiting|failed|completed
quicktty-progress codex  working|waiting|failed|completed
```

Claude mode prints only valid JSON with `terminalSequence`. Codex mode writes OSC to `/dev/tty` when available, never blocks/fails the agent when unavailable, and prints `{}` where hook stdout requires JSON. Do not inspect hook stdin or environment payload.

**Step 3: Add manually merged examples**

Claude Code 2.1.141+ mappings:

- `UserPromptSubmit` → working;
- needs-input/permission `Notification` → waiting;
- `PostToolUse` → working;
- `Stop` → completed/remove;
- `StopFailure` → failed.

Codex mappings:

- `UserPromptSubmit` → working;
- `PermissionRequest` → waiting;
- `PostToolUse` → working;
- `Stop`/`SessionEnd` → completed/remove.

Pi documentation instructs enabling **Terminal progress** through `/settings`; no Pi extension or title parsing.

**Step 4: Add docs and bundle resources**

State explicitly that QuickTTY never modifies `~/.pi`, `~/.claude`, `~/.codex`, `.env` or shell rc automatically. Explain app-path adjustment when QuickTTY is installed outside `/Applications`.

**Step 5: Run contracts and build resource check**

```bash
make agent-integrations-contract
make build
find .build/DerivedData/Build/Products/Debug/QuickTTY.app/Contents/Resources \
  -path '*AgentIntegrations*' -type f -print
```

Expected: helper and both examples bundled, arm64 app build PASS.

### Task 7: Integrated verification and project memory

**Files:**
- Modify: `docs/backlog.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/tasks-completed.md` only after all gates pass
- Create: `.agents/memory/handoffs/YYYY-MM-DD-HHMM-terminal-progress.md`

**Step 1: Run formatting and focused aggregate gate**

```bash
make format
make lint
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test \
  -only-testing:QuickTTYTests/GhosttySurfaceViewTests \
  -only-testing:QuickTTYTests/GhosttyBridgeTests \
  -only-testing:QuickTTYTests/TerminalActivityControllerTests \
  -only-testing:QuickTTYTests/WorkspacePresentationTests \
  -only-testing:QuickTTYTests/TerminalNotificationControllerTests \
  -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests
```

**Step 2: Request one integrated spec/code-quality review**

Review the complete diff against `docs/plans/2026-07-24-terminal-progress-notifications-design.md`. Fix every Critical/Important finding and rerun affected focused tests.

**Step 3: Run final gate once**

```bash
make check
git diff --check
git status --short
```

Expected: all contracts/build/tests PASS, no Vendor/ghostty changes, no secret/user-config files.

**Step 4: Manual smoke with permission**

Do not install, launch or close QuickTTY without explicit permission. When permitted, verify Pi Terminal progress, inactive tab/workspace badges, five-second notification threshold, suppression in active selected tab, notification click routing, Normal/Quake transfer and no PTY resize/restart.

**Step 5: Record verified results**

Update backlog/contracts/ADR/tasks-completed and create a Russian handoff with exact tests and remaining manual checks. Do not commit or push until explicitly requested.
