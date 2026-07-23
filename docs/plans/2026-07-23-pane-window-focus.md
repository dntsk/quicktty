# Pane and Window Focus Presentation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Добавить Ghostty-style dimming неактивных panes и отдельное визуальное состояние non-key окна, сохранив terminal cursor полностью под управлением pinned Ghostty и не добавляя pane border.

**Architecture:** Finalized Ghostty config преобразуется в immutable `GhosttySplitAppearance` внутри bridge. `WorkspaceViewController` владеет observable presentation state для window key state, palette и split appearance; `GhosttySplitTreeView` затемняет leaves вне `activePaneID`, не владея surfaces и не меняя layout. Существующий `GhosttySurfaceView` продолжает единолично передавать фактический first-responder focus в `libghostty`, поэтому hollow cursor не дублируется.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Testing, embedded Ghostty C API, XcodeGen, strict concurrency.

**Commit policy:** Не выполнять commit/push без отдельной команды пользователя.

**Visual outcome:** После первого manual smoke пользователь полностью отклонил accent/neutral frame. Финальная реализация оставляет только dimming; window activation показывают custom chrome и Ghostty cursor.

---

### Task 1: Finalized Ghostty split appearance

**Files:**
- Create: `QuickTTY/Integration/GhosttyBridge/GhosttySplitAppearance.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyConfiguration.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Test: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`

**Steps:**

1. Добавить failing tests, которые загружают finalized config с `background`, `unfocused-split-opacity` и `unfocused-split-fill` и проверяют immutable `GhosttySplitAppearance`.
2. Добавить test отсутствующего `unfocused-split-fill`: fill должен совпадать с finalized background; default opacity `0.7` должен стать overlay alpha `0.3` с разумной floating-point tolerance.
3. Расширить transactional reload test: valid reload одновременно заменяет chrome palette и split appearance; invalid reload сохраняет оба прежних значения.
4. Запустить `GhosttyBridgeTests` и подтвердить RED.
5. Добавить `GhosttySplitAppearance: Equatable, Sendable` с `unfocusedFill: GhosttyRGB` и `unfocusedOverlayOpacity: Double`, а также fallback, совпадающий с upstream defaults.
6. В `GhosttyConfiguration` читать finalized values только через `ghostty_config_get`. Optional fill при `false` заменять уже извлечённым background. Не распространять C types за пределы bridge.
7. В `GhosttyBridge` установить appearance при init и заменять его только после успешного reload рядом с `chromePalette`.
8. Повторить focused test.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:QuickTTYTests/GhosttyBridgeTests test
```

Expected: PASS.

### Task 2: Testable pane decoration and surface-safe rendering

**Files:**
- Modify: `QuickTTY/Presentation/Splits/GhosttySplitTreeView.swift`
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Test: `QuickTTYTests/Presentation/GhosttySplitTreeViewTests.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift` only where existing focus switching needs coverage

**Steps:**

1. Добавить pure testable mapping: active pane → no dim; inactive pane → configured dim. Key/non-key window не должен менять pane decoration.
2. Добавить integration test двух mounted surfaces: смена `activePaneID` меняет presentation, но сохраняет те же `ObjectIdentifier` surfaces и не создаёт transient tiny PTY size.
3. Добавить hit-testing assertion: dim overlay не перехватывает mouse events у live surface и placeholder actions.
4. Запустить `GhosttySplitTreeViewTests` и подтвердить RED.
5. Передать optional `activePaneID` из `WindowCoordinator.refreshWorkspacePresentation` через `WorkspaceViewController.displayTerminal` в split tree. Nil не должен выделять произвольную pane.
6. Обернуть и live surface, и unavailable placeholder в общий leaf decoration. Overlay fill строить из `GhosttySplitAppearance`; использовать `.allowsHitTesting(false)`.
7. Не добавлять pane border/frame: пробная frame удалена после visual smoke без изменения dimming/model/bridge.
8. Не менять `GhosttySurfaceView.setSurfaceFocused`, `ghostty_surface_set_focus`, renderer cursor logic или surface ownership.
9. Повторить focused tests.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:QuickTTYTests/GhosttySplitTreeViewTests \
  -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests test
```

Expected: PASS; existing surface identities and process state remain unchanged.

### Task 3: Window key state and inactive chrome

**Files:**
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Test: `QuickTTYTests/Presentation/WorkspacePresentationTests.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorConfigurationTests.swift`
- Test: relevant Normal/Quake lifecycle suite if transfer behavior is covered there

**Steps:**

1. Добавить failing deterministic AppKit tests с controllable `NSWindow.isKeyWindow` и explicit `didBecomeKey`/`didResignKey` notifications.
2. Проверить: become-key даёт full chrome alpha; resign-key даёт muted chrome; pane decoration от key state не зависит и `activePaneID` не меняется.
3. Добавить transfer test: после перемещения root view из одного test window в другое уведомления старого окна игнорируются, нового — применяются; hosted surfaces сохраняют identity.
4. Добавить config reload presentation test: новый split appearance применяется без surface recreation и invalid reload не меняет текущий appearance.
5. Реализовать main-actor observable window/split presentation state. Root `NSView` сообщает `viewDidMoveToWindow`; observer подписывается только на текущее окно и снимает старые subscriptions.
6. При key-state change обновлять published state split tree и `chromeView.alphaValue`. Использовать фиксированное умеренное inactive alpha только для custom chrome; не менять Metal surface/layer opacity.
7. `WindowCoordinator.applyConfiguration` синхронизирует и `chromePalette`, и `GhosttySplitAppearance` после успешного reload.
8. Повторить focused tests и проверить strict concurrency warnings.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:QuickTTYTests/WorkspacePresentationTests \
  -only-testing:QuickTTYTests/WindowCoordinatorConfigurationTests \
  -only-testing:QuickTTYTests/PresentationControllerLifecycleTests test
```

Expected: PASS; Normal/Quake transfer не создаёт новые surfaces и stale window notifications не меняют UI.

### Task 4: Integrated verification and memory

**Files:**
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/2026-07-23-pane-window-focus.md`

**Steps:**

1. Запустить все focused suites из Tasks 1–3.
2. Запустить `make format`, затем `git diff --check` и `make lint`.
3. Провести один integrated review относительно `docs/plans/2026-07-23-pane-window-focus-design.md`; исправить все Critical/Important findings одним пакетом и повторить focused suites.
4. Один раз запустить final gate:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check
```

5. Обновить project memory точным test evidence и зафиксировать, что frame отклонена после visual smoke, а cursor остаётся Ghostty-owned.
6. Запускать QuickTTY только после отдельного разрешения пользователя; проверить Normal/Quake, single pane, nested splits, rename editor focus и app switching. Первый разрешённый smoke привёл к полному удалению frame; обновлённая сборка требует повторного smoke.
7. Commit/push не выполнять без отдельной команды пользователя.
