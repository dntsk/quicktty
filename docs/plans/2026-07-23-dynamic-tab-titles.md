# Dynamic Tab Titles and Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task.

**Goal:** Повторить Ghostty dynamic tab title и manual rename semantics без persistence transient titles и без изменения terminal processes.

**Architecture:** Surface-targeted Ghostty callbacks копируются и coalesce-ятся внутри `GhosttyBridge`; каждая live surface хранит последний automatic title. Presentation выбирает title активной pane, а persisted optional override в `TerminalTab` имеет высший приоритет. Собственный AppKit tab bar выполняет inline rename и возвращает focus terminal surface.

**Tech Stack:** Swift 6, AppKit, Swift Testing, embedded Ghostty C API, XcodeGen, strict concurrency.

**Commit policy:** Не выполнять commit/push без отдельной команды пользователя.

---

### Task 1: Persisted tab-title override

**Files:**
- Modify: `QuickTTY/Domain/TerminalTab.swift`
- Modify: `QuickTTY/Domain/WorkspaceStore.swift`
- Test: `QuickTTYTests/Domain/TerminalTabTests.swift`
- Test: `QuickTTYTests/Domain/WorkspaceStoreTests.swift`
- Test: `QuickTTYTests/Persistence/StateStoreTests.swift`

**Steps:**

1. Добавить failing tests: старый JSON без override декодируется как `nil`; Unicode/emoji override round-trips; exact empty снимает override; whitespace сохраняется; неизвестный `TabID` даёт существующий typed error.
2. Запустить focused domain/persistence tests и подтвердить RED.
3. Добавить `private(set) var titleOverride: String?`, backward-compatible `decodeIfPresent`, encoding optional field и сохранение override во всех reconstructing paths `TerminalTab`.
4. Добавить `TerminalTab.setTitleOverride(_:)` с exact-empty → `nil` и `WorkspaceStore.setTitleOverride(_:for:)` как атомарную mutation.
5. Повторить focused tests; убедиться, что state version не меняется и старые fixtures проходят.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:QuickTTYTests/TerminalTabTests \
  -only-testing:QuickTTYTests/WorkspaceStoreTests \
  -only-testing:QuickTTYTests/StateStoreTests test
```

Expected: PASS.

### Task 2: Ghostty title callback boundary

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyRuntimeAction.swift` only if a stable typed prompt value is needed
- Modify: `scripts/check-runtime-callbacks.sh`
- Test: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`
- Test: `QuickTTYTests/Integration/GhosttySurfaceViewTests.swift`

**Steps:**

1. Добавить failing callback tests для `SET_TITLE`, `SET_TAB_TITLE`, `PROMPT_TITLE_TAB`, invalid/null UTF-8, synchronous payload copy, latest-value coalescing, inactive context и teardown drain.
2. Запустить focused integration tests и подтвердить RED.
3. В top-level callback принимать только surface target, synchronously copy strict UTF-8 C string и schedule stable events через `SurfaceCallbackContext`.
4. Добавить separate events/handlers для automatic surface title, tab override request и tab prompt. `PROMPT_TITLE_SURFACE` вернуть `false`.
5. Хранить `currentTitle` в `GhosttySurfaceView`; очищать pending callback state при teardown; не логировать title content.
6. Расширить callback contract script точными tags/surface-target/coalescing assertions без ослабления существующих safety checks.
7. Повторить focused tests и `make callback-contract`.

Expected: все callbacks one-shot/coalesced, stale delivery отсутствует, pointers не покидают bridge.

### Task 3: Active-pane title routing and precedence

**Files:**
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabBarViewController.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabItemView.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Test: `QuickTTYTests/Presentation/WorkspacePresentationTests.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Steps:**

1. Добавить failing tests для precedence `override ?? active-pane automatic ?? fallback`, raw emoji preservation, inactive split update, pane focus switch, inactive workspace, closed/stale pane и no surface recreation.
2. Запустить focused presentation/lifecycle tests и подтвердить RED.
3. Передавать live `[PaneID: String]` из coordinator/presentation без записи automatic title в `WorkspaceStore`.
4. Выбирать automatic title только по `TerminalTab.activePaneID`; обновлять tab chrome при title callback без terminal host rebuild и без focus change.
5. Подключить bridge handlers в init/deinit; `SET_TAB_TITLE` мутирует owning tab override через `commitWorkspaceStore`; prompt принимается только для current live tab.
6. При split focus/workspace switch использовать уже сохранённый `GhosttySurfaceView.currentTitle`; после close исключать удалённую surface.
7. Повторить focused tests.

Expected: live title следует active pane, override остаётся видимым при дальнейших callbacks, clearing показывает последний live title.

### Task 4: Inline tab rename UI

**Files:**
- Modify: `QuickTTY/Presentation/TabBar/TabItemView.swift`
- Modify: `QuickTTY/Presentation/TabBar/TabBarViewController.swift`
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Test: `QuickTTYTests/Presentation/WorkspacePresentationTests.swift`
- Test: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Test: relevant Quake lifecycle tests in `QuickTTYTests/Presentation/`

**Steps:**

1. Добавить failing tests: double-click begins rename; context menu has `Rename Tab…`; seed is effective title; Enter/blur commit; Escape cancel; empty reset; dynamic update during edit does not overwrite field; finish restores active surface focus.
2. Добавить lifecycle tests: closing/reloading edited tab cancels safely; Quake rename begins/ends transient interaction exactly once; rename input does not reach Ghostty/PTTY.
3. Реализовать single-line borderless inline `NSTextField` внутри custom tab item. Не копировать private native tab hierarchy из Ghostty.
4. Подключить plain double-click и represented `TabID` context-menu action. Multi-selection/reorder semantics не менять.
5. На commit выполнить coordinator store mutation/persistence; на cancel не менять store; после finish восстановить focus. Empty string снимает override, whitespace сохраняется.
6. Защитить active editor от automatic-title refresh; после finish показать latest resolved title.
7. Повторить focused UI/lifecycle tests.

Expected: UI соответствует Ghostty semantics, обычный click/drag/close/broadcast не регрессируют.

### Task 5: Integration evidence and project memory

**Files:**
- Modify: `docs/backlog.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/2026-07-23-dynamic-tab-titles.md`

**Steps:**

1. Запустить focused suites для bridge, domain, persistence, workspace presentation, tab lifecycle и Quake lifecycle.
2. Запустить `make format` и `git diff --check`.
3. Провести один integrated review по design doc; исправить все Critical/Important findings одним пакетом и повторить focused tests.
4. Один раз запустить final gate:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check
```

5. Обновить backlog/memory точным test evidence. Зафиксировать, что AI-specific protocol/icons/status parsing остаются отдельной будущей задачей, а raw Unicode/emoji OSC titles уже поддерживаются.
6. По отдельному разрешению запустить Debug QuickTTY и вручную проверить:
   - prompt path;
   - preexec command title;
   - OSC title с emoji;
   - split focus title switch;
   - rename/clear через double-click и context menu.
7. Commit/push не выполнять без отдельной команды пользователя.
