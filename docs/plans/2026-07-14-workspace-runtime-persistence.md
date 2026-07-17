# Workspace Runtime Persistence and Tab Reordering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** GhostTerm автоматически восстанавливает workspaces, tabs, splits и CWD после перезапуска, позволяет создавать, переименовывать и удалять workspaces, а tabs можно вручную сортировать перетаскиванием.

**Architecture:** `WorkspaceStore` остаётся единственным источником истины. `WindowCoordinator` транзакционно создаёт новые Ghostty surfaces для сохранённых pane descriptors, сообщает о каждом завершённом изменении модели в `AppDelegate`, а существующий `StateStore` сохраняет snapshots с debounce и atomic replace. Workspace management остаётся AppKit UI поверх domain operations; drag-and-drop использует локальный `NSCollectionView` move и сохраняет новый порядок через ту же mutation pipeline.

**Tech Stack:** Swift 6, AppKit, SwiftUI split adapter, libghostty, Swift Testing, XcodeGen.

---

## User-visible behavior

- После перезапуска сохраняются workspace names, tab order, split tree, divider ratios, active workspace/tab/pane и CWD каждой pane.
- Старые процессы не продолжаются: для каждой сохранённой pane создаётся новый shell в сохранённой папке.
- Сохранённый custom startup command не запускается автоматически; descriptor сохраняется для отдельного confirmation milestone.
- Новый workspace сразу становится активным и получает одну shell tab.
- Пустой workspace удаляется сразу. Непустой удаляется после одного destructive alert, закрывающего все его terminal processes. Последний workspace удалить нельзя.
- Tab можно перетащить мышью на новую позицию внутри текущего workspace; порядок сохраняется после restart.
- Broadcast runtime state не сохраняется.

### Task 1: Domain operations for durable workspace mutations

**Files:**
- Modify: `GhostTerm/Domain/WorkspaceError.swift`
- Modify: `GhostTerm/Domain/WorkspaceStore.swift`
- Modify: `GhostTerm/Domain/TerminalTab.swift`
- Test: `GhostTermTests/Domain/WorkspaceStoreTests.swift`

**Step 1: Write failing tests**

Проверить:

- удаление empty/non-empty workspace возвращает удалённый snapshot;
- active workspace после удаления переключается на ближайший оставшийся элемент;
- background deletion не меняет active workspace;
- последний workspace удалить нельзя;
- tab reorder принимает только точную permutation текущего workspace и сохраняет active tab;
- update pane CWD меняет только нужный descriptor;
- неизвестные workspace/tab/pane IDs дают typed errors и не мутируют store.

**Step 2: Run domain tests and verify failure**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project GhostTerm.xcodeproj -scheme GhostTerm \
  -only-testing:GhostTermTests/WorkspaceStoreTests
```

Expected: новые tests FAIL до реализации.

**Step 3: Implement minimal domain API**

Добавить операции:

```swift
mutating func deleteWorkspace(_ workspaceID: WorkspaceID) throws -> Workspace
mutating func reorderTabs(_ orderedTabIDs: [TabID], in workspaceID: WorkspaceID) throws
mutating func updateWorkingDirectory(_ cwd: String, for paneID: PaneID) throws
```

`deleteWorkspace` запрещает удаление последнего workspace. `reorderTabs` требует exact permutation и не переносит tabs между workspaces. CWD принимает только непустой absolute path, уже нормализованный runtime callback.

**Step 4: Run tests**

Expected: domain suite PASS.

**Step 5: Commit**

```bash
git commit -m "feat: add durable workspace mutations"
```

### Task 2: Restore saved surfaces transactionally at startup

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Test: `GhostTermTests/Presentation/SplitPresentationTests.swift`

**Step 1: Write failing restore tests**

Build a saved store containing:

- two workspaces;
- several tabs;
- nested horizontal/vertical splits;
- distinct CWD values;
- active workspace/tab/pane IDs;
- a `.custom` startup descriptor.

Проверить после `start()`:

- surface IDs exactly match all saved pane IDs;
- surface count equals saved leaf count;
- active split tree and surface views render without replacing IDs;
- every surface receives its descriptor CWD;
- every restored pane starts a shell, including descriptors containing custom commands;
- only saved active pane receives focus;
- no tabs are added when valid saved tabs exist;
- an entirely empty default state creates one shell tab;
- failure while restoring any surface closes all surfaces created by that restore and leaves model unchanged.

**Step 2: Run focused lifecycle tests and verify failure**

Expected: current `start()` creates an extra tab and does not restore descriptors.

**Step 3: Implement transactional restore**

`WindowCoordinator.start()` must:

1. snapshot `workspaceStore`;
2. iterate workspaces/tabs and `root.leaves` order;
3. create each surface with its preserved `PaneID` and descriptor CWD;
4. clear `command` and `initialInput` for restored descriptors;
5. assign `.newTab` context to the first leaf and `.split` to later leaves;
6. publish the surface registry only after all creations succeed;
7. close all temporary surfaces on failure;
8. create one normal shell only when every workspace is empty;
9. render/focus the saved active pane.

Do not serialize or restore C handles/processes.

**Step 4: Run focused tests and build**

Expected: restore tests and `make build` PASS.

**Step 5: Commit**

```bash
git commit -m "feat: restore workspace surfaces at startup"
```

### Task 2A: Config-controlled restore, config editor shortcut and copy-on-select

**Files:**
- Modify: `GhostTerm/Config/GhostTermConfig.swift`
- Modify: `GhostTerm/Config/ConfigDocument.swift`
- Modify: `GhostTerm/Config/ConfigController.swift`
- Modify: `GhostTerm/Resources/default-config`
- Modify: `GhostTerm/Resources/configuration-reference.md`
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Test: `GhostTermTests/Config/ConfigDocumentTests.swift`
- Test: `GhostTermTests/Config/ConfigControllerTests.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Test: `GhostTermTests/Integration/GhosttyKeyboardInputTests.swift`

**Step 1: Add and parse two GhostTerm options**

```text
ghostterm-restore-workspaces = true
ghostterm-config-editor = nano
```

`restore-workspaces` accepts only `true`/`false`, defaults to `true` and affects only the next launch. `config-editor` must be a non-empty command, defaults to `nano`, and may contain normal command arguments.

**Step 2: Gate startup restore**

Before constructing `WindowCoordinator`, `AppDelegate` chooses the loaded `applicationState.workspaceStore` when `restoreWorkspaces == true`; otherwise it passes a fresh `WorkspaceStore()`. Normal window frame restoration remains independent and always uses saved state.

**Step 3: Add Cmd-comma config tab**

Install an idempotent `Open Configuration…` application-menu item with exact `Cmd+,`. Reserve exact `Cmd+,` before Ghostty binding lookup. The action creates a new tab in the active workspace using the configured terminal editor and shell-escaped `~/.config/ghostterm/config` path. The tab is created transactionally, titled `Config`, and its custom command is not auto-replayed by Task 2 restore.

**Step 4: Make selection update the standard clipboard**

Ghostty's `copy-on-select = true` prefers its separate selection pasteboard on macOS. GhostTerm's effective terminal default must therefore be:

```text
copy-on-select = clipboard
```

Inject this line into generated `.ghostty-effective-config` only when the user has no explicit `copy-on-select` assignment. Add it to the starter config. An explicit user value such as `false` remains authoritative.

**Step 5: Test and commit**

Test parser defaults/validation/last-value behavior, startup gating without changing frame restore, exact shortcut bypass/idempotence, transactional editor-tab creation/quoting, and effective-config default/override behavior.

```bash
git commit -m "feat: configure workspace restore and config editing"
```

### Task 3: Persist every completed runtime mutation and live CWD

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Test: `GhostTermTests/AppDelegateLifecycleTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Test: `GhostTermTests/Persistence/StateStoreTests.swift`

**Step 1: Write failing notification tests**

Inject a workspace snapshot callback into `WindowCoordinator` and verify exactly one final snapshot after:

- create/close/activate/reorder tab;
- split/close pane;
- focus pane;
- resize/equalize split;
- create/rename/delete/activate workspace;
- move tabs between workspaces;
- accepted `GHOSTTY_ACTION_PWD` change.

Failed transactional operations must not emit a snapshot. Broadcast may emit, but its runtime flag must remain excluded from encoded JSON.

**Step 2: Add narrow persistence callback**

Add to `WindowCoordinator`:

```swift
typealias WorkspacePersistence = @MainActor (WorkspaceStore) -> Void
```

All successful model assignments go through one helper that commits the candidate store, updates UI when requested, then emits the immutable snapshot. Avoid emitting partially mutated state.

**Step 3: Route live CWD changes**

After `GhosttySurfaceView` handles `.pwdChanged`, `GhosttyBridge` reports `(PaneID, String)` to `WindowCoordinator`. The coordinator updates only the matching pane descriptor and emits a debounced snapshot. Ignore empty/non-absolute/stale pane updates.

**Step 4: Wire AppDelegate lifecycle**

- Pass `applicationState.workspaceStore` as `initialWorkspaceStore`.
- Pass a callback to `workspaceStoreDidChange`.
- At termination, read one final persistence snapshot from `WindowCoordinator` before `flushPendingSave()` so the latest CWD is not lost.
- Preserve existing normal-window-frame merge behavior.

**Step 5: Run tests**

Expected: AppDelegate lifecycle, focused coordinator tests and StateStore tests PASS.

**Step 6: Commit**

```bash
git commit -m "feat: persist runtime workspace changes"
```

### Task 4: Workspace create, rename and delete UI

**Files:**
- Modify: `GhostTerm/Presentation/Workspace/WorkspaceSelector.swift`
- Refactor: `GhostTerm/Presentation/Workspace/CreateWorkspaceController.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Test: `GhostTermTests/Presentation/WorkspacePresentationTests.swift`
- Test: `GhostTermTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Write failing selector and flow tests**

Проверить:

- selector lists workspaces followed by `New Workspace…`, `Rename Workspace…`, `Delete Workspace…`;
- action rows never become selected workspace values;
- rename sheet starts with current name and excludes it from duplicate checking;
- create trims/validates name, creates one shell tab and activates workspace transactionally;
- rename updates selector immediately;
- delete action is disabled for the last workspace;
- empty workspace deletion is immediate;
- non-empty workspace presents exactly one destructive alert with tab/pane counts;
- cancellation preserves model/surfaces;
- confirmation closes all workspace surfaces once, invalidates confirmations, removes workspace and activates its nearest neighbor.

**Step 2: Generalize name sheet minimally**

Reuse one controller for create and rename by injecting title, initial value, submit button title and error wording. Do not create a second validation implementation.

**Step 3: Add selector management actions**

Append separator and management rows to the `NSPopUpButton`. Re-select the active workspace immediately when an action row is invoked so the selector title never remains an action label.

**Step 4: Implement coordinator flows**

- New: create candidate workspace, create one surface/tab, activate and commit only after all steps succeed.
- Rename: mutate candidate and commit.
- Delete: empty immediately; non-empty through one dedicated destructive `NSAlert`; kill surfaces only after confirmation.

**Step 5: Run presentation/lifecycle tests**

Expected: new tests PASS and existing move-to-workspace flow remains unchanged.

**Step 6: Commit**

```bash
git commit -m "feat: manage workspaces from selector"
```

### Task 5: Make tab drag reordering work and persist it

**Files:**
- Modify: `GhostTerm/Presentation/TabBar/TabItemView.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Test: `GhostTermTests/Presentation/WorkspacePresentationTests.swift`
- Test: `GhostTermTests/Presentation/TabSelectionModelTests.swift`

**Step 1: Write failing interaction tests**

Проверить:

- `TabItemBackgroundView.mouseDown` performs current click/multi-selection logic and forwards the event to the responder chain so `NSCollectionView` can start a drag;
- local drag validates only `.ghostTermTab` from the same collection view;
- single tab moves before the indicated destination;
- selected tabs move as one ordered block;
- dropping onto the same effective position is a no-op and emits no persistence snapshot;
- active tab remains active;
- accepted reorder immediately updates displayed order and emits the persisted store order.

**Step 2: Fix event forwarding**

The current background view consumes `mouseDown`, preventing collection-view drag tracking. Preserve custom selection, then forward to `super.mouseDown(with:)` (or an equally narrow tested responder-chain solution). Do not add a custom drag framework.

**Step 3: Use domain reorder operation**

Replace ad-hoc `WorkspaceStore` reconstruction in `WindowCoordinator.reorderTabs` with Task 1’s validated operation. Commit only when order actually changes.

**Step 4: Run tests and manual interaction build**

Expected: drag tests PASS; tab order changes visually without recreating any surface.

**Step 5: Commit**

```bash
git commit -m "fix: enable persistent tab drag reordering"
```

### Task 6: Final durability and regression validation

**Files:**
- Modify only files required by review findings.
- Add: `.agents/memory/handoffs/<timestamp>-workspace-persistence.md`

**Step 1: Spec review**

Verify every user-visible behavior in this plan, especially:

- no custom command auto-execution;
- no surface restart during workspace/tab switching or drag reorder;
- no save after failed mutation;
- one warning for non-empty workspace deletion;
- saved tab order and CWD survive restart;
- broadcast is off after restore.

**Step 2: Code-quality review**

Audit MainActor isolation, callback ownership, restore rollback, close reentrancy, test lifecycle ordering and state snapshot consistency.

**Step 3: Run checks**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make format
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint
./scripts/check-runtime-callbacks.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
git diff --check
```

Run focused suites for domain, persistence, workspace presentation, tab lifecycle, split presentation and AppDelegate lifecycle. Attempt full `make check`; report known real-surface host crashes separately from new failures.

**Step 4: Manual restart test**

1. Create two workspaces.
2. Add/reorder tabs.
3. Create nested splits and `cd` to distinct directories.
4. Quit normally and relaunch.
5. Verify names/order/layout/ratios/CWD/focus.
6. Verify all panes contain fresh shells and broadcast is off.
7. Delete a non-empty workspace, confirm once, quit/relaunch and verify it stays deleted.

**Step 5: Final commit if review required fixes**

```bash
git commit -m "fix: harden workspace state restoration"
```

Do not push.