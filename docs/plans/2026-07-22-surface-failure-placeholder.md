# Surface Failure Placeholder Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Сохранять pane identity и split layout при ошибке создания Ghostty surface во время startup/restore, показывая локальный placeholder с безопасными `Retry` и `Close Pane`.

**Architecture:** `WorkspaceStore` остаётся persisted source of truth, а `WindowCoordinator` хранит неперсистентный `[PaneID: SurfaceFailurePresentation]`. Split presentation получает surfaces и failures отдельно; отсутствующая surface рендерится как leaf-level SwiftUI placeholder. Retry создаёт fresh shell для существующего descriptor, Close Pane выполняет model-only `SplitCoordinator.closePane`.

**Tech Stack:** Swift 6, AppKit, SwiftUI host для upstream split tree, Swift Testing, embedded pinned libghostty, XcodeGen.

**Constraints:** Не менять pinned Ghostty API, публичный API приложения и транзакционную семантику обычного New Tab/Split. Не запускать приложение. Не коммитить без отдельного разрешения пользователя.

---

### Task 1: Failure presentation и split placeholder

**Files:**
- Create: `QuickTTY/Presentation/Errors/SurfaceFailurePresentation.swift`
- Create: `QuickTTY/Presentation/Errors/SurfaceErrorPlaceholder.swift`
- Modify: `QuickTTY/Presentation/Splits/GhosttySplitTreeView.swift`
- Modify: `QuickTTY/Presentation/WorkspaceViewController.swift`
- Test: `QuickTTYTests/Presentation/GhosttySplitTreeViewTests.swift`

**Step 1: Написать падающие presentation tests**

Добавить тесты, которые фиксируют:

- `SurfaceFailurePresentation` сохраняет только owned message;
- `GhosttySplitTreeCallbacks.retryUnavailablePane(_:)` и `closeUnavailablePane(_:)` маршрутизируют точный `PaneID`;
- `WorkspaceViewController.displayTerminal` принимает failure map независимо от surface registry;
- missing leaf не считается empty workspace и остаётся частью split host.

Пример callback contract:

```swift
var retriedPaneID: PaneID?
var closedPaneID: PaneID?
let callbacks = GhosttySplitTreeCallbacks(
    onResize: { _, _ in },
    onEqualize: { _ in },
    onRetryUnavailablePane: { retriedPaneID = $0 },
    onCloseUnavailablePane: { closedPaneID = $0 }
)
callbacks.retryUnavailablePane(paneID)
callbacks.closeUnavailablePane(paneID)
#expect(retriedPaneID == paneID)
#expect(closedPaneID == paneID)
```

**Step 2: Запустить focused test и подтвердить RED**

Run from repository root:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/GhosttySplitTreeViewTests
```

Expected: FAIL на отсутствующих failure types/callbacks/signature.

**Step 3: Добавить минимальные presentation types**

`SurfaceFailurePresentation` должен быть `Equatable` и `Sendable`, содержать только `message: String` и строиться из заранее owned строки. Не хранить `Error`, C handle, `NSView` или closure.

`SurfaceErrorPlaceholder` должен:

- показывать `Terminal unavailable`;
- показывать `presentation.message`;
- иметь кнопки `Retry` и `Close Pane`;
- использовать foreground/background текущего `GhosttyChromePalette`;
- назначить accessibility labels тем же действиям;
- вызывать только переданные main-actor closures.

**Step 4: Расширить split dataflow**

Передать через `WorkspaceViewController.displayTerminal` и `GhosttySplitTreeView`:

```swift
failures: [PaneID: SurfaceFailurePresentation]
onRetryUnavailablePane: (PaneID) -> Void
onCloseUnavailablePane: (PaneID) -> Void
```

Порядок leaf rendering:

1. surface существует → `GhosttySurfaceRepresentable`;
2. surface отсутствует → `SurfaceErrorPlaceholder` с failure message;
3. если failure map не содержит запись, использовать generic сообщение без создания persisted state.

Обновить все call sites `displayTerminal`, включая detach/teardown, пустыми failure map/callbacks там, где root равен `nil`.

**Step 5: Запустить focused presentation tests**

Expected: PASS.

---

### Task 2: Сброс broadcast для любой повреждённой tab

**Files:**
- Modify: `QuickTTY/Domain/WorkspaceStore.swift`
- Test: `QuickTTYTests/Domain/WorkspaceStoreTests.swift`

**Step 1: Написать падающий domain test**

Создать store минимум с двумя workspaces/tabs, включить broadcasting у tab, затем вызвать новый узкий mutation API для этой tab, пока она не является visible. Проверить:

- broadcast сброшен только у целевой tab;
- active workspace/tab не меняются;
- отсутствующие workspace/tab возвращают существующие `WorkspaceError` варианты;
- повторный reset идемпотентен.

**Step 2: Запустить focused test и подтвердить RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/WorkspaceStoreTests
```

**Step 3: Реализовать минимальный mutation**

Добавить internal метод:

```swift
mutating func resetBroadcasting(for tabID: TabID, in workspaceID: WorkspaceID) throws
```

Он должен валидировать ownership так же, как `setBroadcasting`, но не требовать active workspace/tab и не менять selection.

**Step 4: Запустить focused domain tests**

Expected: PASS.

---

### Task 3: Нефатальные startup и partial restore failures

**Files:**
- Modify: `QuickTTY/WindowCoordinator.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Заменить старый rollback expectation падающими recovery tests**

Добавить/изменить tests:

1. Empty-store startup + `bridge.failNextSurfaceCreationForTesting()`:
   - `start()` не пробрасывает `surfaceCreationFailed`;
   - store получает ровно одну Shell tab/pane;
   - pane identity сохраняется;
   - surface registries пусты;
   - failure state содержит эту pane;
   - workspace window/presentation остаются доступны.

2. Restore split из двух panes + `bridge.failSurfaceCreationForTesting(id:)` для одной:
   - успешная соседняя surface остаётся active в bridge/coordinator registry;
   - failed pane и исходный split root остаются в store;
   - failure state относится только к failed `PaneID`;
   - callback contexts не текут;
   - startup не откатывает успешную surface.

3. Persisted broadcasting у affected tab становится `false` и сохраняется одним committed snapshot.

**Step 2: Запустить lifecycle suite и подтвердить RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests
```

**Step 3: Добавить coordinator failure state**

В `WindowCoordinator` добавить:

```swift
private var surfaceFailures: [PaneID: SurfaceFailurePresentation] = [:]
```

И DEBUG read-only accessors для IDs/messages. При teardown очищать failure state после detach presentation.

**Step 4: Сделать empty-store startup model-first**

Для первого startup shell:

- создать `PaneID`, descriptor и `TerminalTab` в candidate store;
- закоммитить model identity;
- попытаться создать surface с текущей startup configuration/context `.window`;
- при успехе добавить surface registry;
- при ошибке записать owned localized description и не пробрасывать surface error.

Ошибки mutation/invariant по-прежнему могут быть `throw`; `start()` API не меняется.

**Step 5: Сделать restore независимым по pane**

`restoreWorkspaceSurfaces()` должен создавать каждую persisted pane отдельно с:

- saved absolute CWD;
- `command = nil`;
- `initialInput = nil`;
- `.newTab` для первого leaf, `.split` для остальных.

При ошибке:

- не закрывать успешные соседние surfaces;
- записать failure presentation;
- сбросить broadcasting affected tab через Task 2 API;
- продолжить restore.

После прохода атомарно назначить успешный registry и один раз закоммитить изменённый store, если broadcast действительно изменился.

**Step 6: Передать failure state в presentation**

`refreshWorkspacePresentation` фильтрует failures только для leaves активной tab и передаёт Retry/Close callbacks в `WorkspaceViewController`.

**Step 7: Запустить lifecycle и presentation suites**

Expected: PASS.

---

### Task 4: Retry existing pane безопасным fresh shell

**Files:**
- Modify: `QuickTTY/WindowCoordinator.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Написать падающие Retry tests**

Покрыть:

- повторная ошибка сохраняет тот же `PaneID`, store/root и соседние surfaces;
- message обновляется, failure остаётся;
- успешный Retry добавляет surface с тем же `PaneID`, удаляет failure и не меняет layout;
- CWD равен persisted descriptor CWD;
- `command == nil` и `initialInput == nil`, даже если persisted `startupCommand` custom;
- context `.newTab` для первого leaf и `.split` для последующих;
- активная восстановленная pane получает обычный presentation/focus path;
- Retry для уже живой либо удалённой pane является no-op.

Использовать существующие DEBUG surface configuration observations bridge; не добавлять fake C handles.

**Step 2: Запустить lifecycle suite и подтвердить RED**

Expected: FAIL на отсутствующем retry path.

**Step 3: Реализовать retry**

Добавить private main-actor `retryUnavailablePane(_:)`, который:

1. проверяет, что surface отсутствует;
2. находит workspace/tab/descriptor по `PaneID`;
3. вычисляет leaf context;
4. создаёт fresh-shell `GhosttySurfaceConfiguration`;
5. при успехе добавляет surface, очищает failure и refreshes presentation;
6. при ошибке заменяет owned message и refreshes только presentation;
7. не изменяет persisted descriptor и не вызывает global modal `onError`.

Close handler новой surface должен использовать существующий `surfaceDidRequestClose` route.

**Step 4: Запустить lifecycle suite**

Expected: PASS.

---

### Task 5: Model-only Close Pane

**Files:**
- Modify: `QuickTTY/WindowCoordinator.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`

**Step 1: Написать падающие close tests**

Покрыть:

- закрытие failed leaf в split вызывает `SplitCoordinator.closePane`, удаляет descriptor/failure и сохраняет соседнюю live surface;
- active pane корректируется существующей domain policy;
- закрытие последней failed pane удаляет tab и оставляет workspace пустым;
- replacement shell не создаётся;
- physical normal/Quake window не закрывается;
- GhosttyBridge close не вызывается для отсутствующей surface;
- unknown/live pane callback является no-op.

**Step 2: Запустить lifecycle suite и подтвердить RED**

Expected: FAIL на отсутствующем close-unavailable path.

**Step 3: Реализовать close**

Добавить private `closeUnavailablePane(_:)`:

- guard: surface отсутствует, pane присутствует в model;
- применить `.closePane` к candidate store;
- очистить failure и confirmation state для `PaneID`;
- commit/persist candidate;
- refresh presentation без replacement shell;
- не вызывать `removeSurface`, `ghosttyBridge.closeSurface` или generic `closeTab`, поскольку они требуют live surface и имеют replacement policy.

Защитить путь существующим `closingPaneIDs`, чтобы двойной click был идемпотентен.

**Step 4: Запустить lifecycle и split suites**

Expected: PASS.

---

### Task 6: Полная проверка и project memory

**Files:**
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/YYYY-MM-DD-HHMM-surface-failure-placeholder.md`
- Verify: all changed Swift files and tests

**Step 1: Форматирование**

```bash
make format
```

Просмотреть diff и убедиться, что formatter не затронул несвязанные файлы.

**Step 2: Focused regression tests**

Запустить:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test \
  -only-testing:QuickTTYTests/WorkspaceStoreTests \
  -only-testing:QuickTTYTests/GhosttySplitTreeViewTests \
  -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests
```

Expected: PASS.

**Step 3: Полный gate**

```bash
make check
```

Expected: lint/build/all tests PASS, Ghostty pin не изменён.

**Step 4: Audit**

Проверить:

- `git diff --check`;
- `git status --short`;
- нет изменений `Vendor/ghostty`;
- нет новых dependencies;
- обычные New Tab/Split failure rollback tests по-прежнему проходят;
- custom commands не запускаются на restore/Retry;
- AppKit/SwiftUI работают только на MainActor;
- opaque Ghostty handles не покидают bridge.

**Step 5: Обновить memory и handoff**

Записать на русском:

- принятый model-first startup/partial restore contract;
- Retry/Close semantics;
- отсутствие upstream render-failure callback;
- точные test results;
- известные ограничения.

Не выполнять commit/push без отдельного разрешения пользователя.
