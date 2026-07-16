# GhostTerm MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: use `subagent-driven-development` to execute this plan task-by-task with a fresh implementer, spec review, and code-quality review for every task. Implementation agents must not commit automatically.

**Goal:** Собрать нативный arm64-терминал для macOS 15+ с normal/Quake presentation modes, tabs, binary splits, именованными workspaces, broadcast текущего tab и темами Ghostty.

**Architecture:** Чистая Swift-модель хранит workspaces, tabs, panes и split-tree. AppKit отвечает за единственное окно и presentation. Полная pinned `libghostty` отвечает за PTY, VT, renderer и terminal config; её нестабильный C API изолирован внутри `GhosttyBridge`, а C handles не покидают bridge.

**Tech Stack:** Swift 6, AppKit, Swift Testing, XcodeGen 2.45.4, Apple `swift-format`, Zig 0.15.2+, Ghostty v1.3.1 (`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`), Carbon Hot Key API, signed/notarized DMG.

---

## Условия выполнения

- Полный Xcode сейчас не установлен. До Task 1 нужно установить Xcode и выбрать его Developer Directory.
- Zig сейчас не установлен. Ghostty v1.3.1 требует Zig не ниже 0.15.2.
- `libghostty` embedding API нестабилен. Обновление commit выполняется только отдельной задачей.
- Каждый production change начинается с падающего теста, если слой допускает автоматизацию.
- После каждого task: `make lint`, релевантные tests, spec review, затем code-quality review.
- Не создавать дополнительный `TerminalSurface` protocol поверх `GhosttyBridge`.
- Не добавлять зависимости без отдельного объяснения.
- Не выполнять Git commit автоматически. В конце task только показать `git diff` и предложить checkpoint человеку.

## Milestone 1: рабочая terminal surface

### Task 1: Проверка toolchain и pin Ghostty

**Files:**
- Create: `scripts/check-tools.sh`
- Create: `scripts/build-ghostty.sh`
- Create: `.gitmodules`
- Create: `Vendor/ghostty/` как Git submodule
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `Makefile`
- Modify: `project.yml`
- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `.agents/memory/integration-contracts.md`

**Step 1: Установить системные prerequisites**

Пользователь устанавливает полный Xcode. Затем проверить:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Установить Zig и проверить:

```bash
brew install zig
zig version
```

Expected: Xcode отвечает версией, Zig имеет версию `0.15.2` или новее.

**Step 2: Написать failing tool check**

Создать `scripts/check-tools.sh`, который с `set -eu` проверяет `xcodebuild`, `xcodegen`, `swift format`, `zig`, а также что `xcode-select -p` не указывает только на `/Library/Developer/CommandLineTools`.

Run:

```bash
scripts/check-tools.sh
```

Expected сейчас: FAIL на полном Xcode или Zig.

**Step 3: Добавить pinned submodule**

```bash
git submodule add https://github.com/ghostty-org/ghostty.git Vendor/ghostty
git -C Vendor/ghostty checkout 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
git submodule status
```

Expected: submodule указывает на commit Ghostty v1.3.1.

**Step 4: Создать воспроизводимый build script**

`scripts/build-ghostty.sh` должен:

1. Проверить точный commit submodule.
2. Проверить `zig`.
3. Выполнить из `Vendor/ghostty`:

```bash
zig build \
  -Dapp-runtime=none \
  -Dxcframework-target=native \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast
```

4. Проверить наличие `Vendor/ghostty/macos/GhosttyKit.xcframework`.

**Step 5: Подключить XCFramework**

В `project.yml` добавить к target `GhostTerm`:

```yaml
dependencies:
  - framework: Vendor/ghostty/macos/GhosttyKit.xcframework
```

XCFramework статический: не включать `embed: true`.

В `Makefile` добавить:

```makefile
.PHONY: doctor ghostty

doctor:
	./scripts/check-tools.sh

ghostty:
	./scripts/build-ghostty.sh

generate: ghostty
	xcodegen generate --spec project.yml
```

**Step 6: Зафиксировать лицензию**

`THIRD_PARTY_NOTICES.md` должен указать Ghostty v1.3.1, commit, MIT license и путь `Vendor/ghostty/LICENSE`. Не менять лицензию самого GhostTerm, пока пользователь её не выбрал.

**Step 7: Проверить build dependency**

```bash
make doctor
make ghostty
make generate
make build
```

Expected: `GhosttyKit.xcframework` собран; приложение линкуется с `GhosttyKit`.

**Step 8: Review checkpoint**

```bash
git status --short
git diff -- . ':!Vendor/ghostty'
git submodule status
```

Не коммитить автоматически.

### Task 2: Bootstrap `GhosttyBridge`

**Files:**
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttyBridgeError.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttyConfiguration.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttyRuntimeAction.swift`
- Create: `GhostTermTests/Integration/GhosttyBridgeTests.swift`
- Modify: `GhostTerm/GhostTermApplication.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `.agents/memory/integration-contracts.md`

**Step 1: Написать failing initialization test**

```swift
import Foundation
import Testing
@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct GhosttyBridgeTests {
    @Test
    func initializesWithEmptyConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appending(path: "config")
        try Data().write(to: configURL)

        let bridge = try GhosttyBridge(configURL: configURL)

        #expect(bridge.isReady)
    }
}
```

Run: `make test`

Expected: FAIL — `GhosttyBridge` не существует.

**Step 2: Инициализировать global Ghostty runtime**

В `GhostTermApplication.main()` вызвать до создания bridge:

```swift
guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    fatalError("ghostty_init failed")
}
```

Не вызывать `ghostty_cli_try_action()` в GUI MVP: CLI actions не входят в scope.

**Step 3: Реализовать config ownership**

`GhosttyConfiguration` владеет `ghostty_config_t`, загружает только переданный файл:

```swift
ghostty_config_load_file(config, configURL.path)
ghostty_config_load_recursive_files(config)
ghostty_config_finalize(config)
```

Она извлекает diagnostics через `ghostty_config_diagnostics_count/get_diagnostic`, освобождает config через `ghostty_config_free` и не раскрывает handle наружу bridge package scope.

**Step 4: Реализовать app ownership**

`@MainActor final class GhosttyBridge`:

- хранит `GhosttyConfiguration`;
- создаёт `ghostty_runtime_config_s`;
- передаёт `Unmanaged.passUnretained(self).toOpaque()` как app userdata;
- создаёт один `ghostty_app_t`;
- освобождает app до config;
- предоставляет `isReady`, `reloadConfig(at:)`, `setApplicationFocused(_:)`;
- не возвращает C handles.

На первом этапе clipboard callbacks возвращают `false`/ничего, action callback преобразует только action tag в `GhosttyRuntimeAction`, wakeup callback делает `DispatchQueue.main.async { bridge.tick() }`.

**Step 5: Зафиксировать callback contract**

До implementation callback handlers прочитать pinned:

- `Vendor/ghostty/include/ghostty.h`;
- `Vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift`;
- Zig implementations callback-ов.

В `.agents/memory/integration-contracts.md` добавить фактические threading и userdata guarantees. Не угадывать их.

**Step 6: Подключить bridge к app lifecycle**

`AppDelegate` создаёт bridge до `WindowCoordinator`, сообщает `NSApplication.didBecomeActive/didResignActive` и показывает отдельный `NSAlert`, если initialization failed.

**Step 7: Проверить**

```bash
make lint
make test
```

Expected: bridge initialization test PASS; приложение запускается без surface.

### Task 3: Первая AppKit terminal surface

**Files:**
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceConfiguration.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/GhosttyInput.swift`
- Create: `GhostTerm/Integration/GhosttyBridge/NSEvent+Ghostty.swift`
- Create: `GhostTermTests/Integration/GhosttySurfaceViewTests.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `GhostTerm/WindowController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `THIRD_PARTY_NOTICES.md`

**Step 1: Написать failing surface lifecycle test**

Тест создаёт hidden `NSWindow`, surface с командой:

```text
/bin/sh -lc 'printf ghostterm-ready'
```

и ожидает callback завершения процесса, после чего проверяет, что повторный `close()` безопасен.

Run: `make test`

Expected: FAIL — API surface отсутствует.

**Step 2: Реализовать `GhosttySurfaceConfiguration`**

Swift value type содержит `workingDirectory`, `command`, `initialInput`, `waitAfterCommand`, `context`. Метод `withCValue(view:_:)`:

- начинает с `ghostty_surface_config_new()`;
- ставит `GHOSTTY_PLATFORM_MACOS`;
- передаёт opaque pointer на `GhosttySurfaceView` в `userdata` и `nsview`;
- удерживает C strings только внутри closure;
- не сохраняет pointers.

**Step 3: Реализовать surface ownership**

`@MainActor final class GhosttySurfaceView: NSView, NSTextInputClient`:

- приватно владеет `ghostty_surface_t`;
- имеет stable `PaneID`;
- создаётся только через `GhosttyBridge.makeSurface(id:configuration:)`;
- реализует idempotent `close()` через `ghostty_surface_free`;
- не освобождает surface вне main actor;
- сообщает bridge о close/process-exit callbacks.

**Step 4: Адаптировать renderer sizing**

Из pinned upstream адаптировать только нужную логику `SurfaceView_AppKit.swift`:

- `acceptsFirstResponder`;
- `viewDidChangeBackingProperties`;
- framebuffer size через `convertToBacking`;
- `ghostty_surface_set_content_scale`;
- `ghostty_surface_set_size`;
- `ghostty_surface_set_display_id`.

Скопированный/адаптированный MIT-код отметить в `THIRD_PARTY_NOTICES.md`.

**Step 5: Реализовать keyboard и IME**

Адаптировать `NSEvent+Extension.swift` и минимальную часть upstream `SurfaceView_AppKit.swift`:

- keyDown/keyUp/flagsChanged;
- modifier conversion;
- `interpretKeyEvents`;
- `setMarkedText`, `unmarkText`, `insertText`;
- `ghostty_surface_preedit`;
- `ghostty_surface_ime_point`.

Исходный logical `NSEvent` должен оставаться доступен bridge для будущего broadcast; нельзя переиспользовать encoded bytes другой pane.

**Step 6: Реализовать mouse и clipboard minimum**

Поддержать mouse button, move, drag, scroll, copy, paste и selection. Clipboard callbacks bridge работают через `NSPasteboard`; OSC 52 read/write подтверждаются до выполнения.

**Step 7: Показать первый shell**

`WindowCoordinator` создаёт один `PaneID`, surface и вставляет её view в content controller. При запуске должен появиться интерактивный login shell.

**Step 8: Проверить vertical slice**

```bash
make lint
make test
make build
open .build/DerivedData/Build/Products/Debug/GhostTerm.app
```

Manual expected: ввод, Unicode, resize, copy/paste и завершение shell работают; после `exit` surface закрывается.

## Milestone 2: чистая модель

### Task 4: Identity types и binary split-tree

**Files:**
- Create: `GhostTerm/Domain/Identity.swift`
- Create: `GhostTerm/Domain/SplitAxis.swift`
- Create: `GhostTerm/Domain/SplitNode.swift`
- Create: `GhostTermTests/Domain/SplitNodeTests.swift`
- Move: `GhostTerm/PresentationMode.swift` → `GhostTerm/Domain/PresentationMode.swift`

**Step 1: Написать failing split tests**

Покрыть:

- split leaf горизонтально и вертикально;
- отказ при неизвестном `PaneID`;
- clamp ratio в `0.1...0.9`;
- remove leaf и collapse parent;
- remove последней leaf возвращает `nil`;
- сохранение порядка leaves;
- Codable round trip.

Пример:

```swift
@Test
func removingLeafCollapsesItsParent() throws {
    let left = PaneID()
    let right = PaneID()
    var root = SplitNode.pane(left)
    #expect(root.split(left, axis: .horizontal, newPane: right, ratio: 0.5))

    root = root.removing(right)

    #expect(root == .pane(left))
}
```

**Step 2: Проверить FAIL**

Run: `make test`

Expected: FAIL — types отсутствуют.

**Step 3: Реализовать minimum model**

Создать `PaneID`, `TabID`, `WorkspaceID` как `RawRepresentable`, `Codable`, `Hashable`, `Sendable` wrappers над UUID.

`indirect enum SplitNode` содержит:

```swift
case pane(PaneID)
case split(id: UUID, axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
```

Реализовать только операции из tests: `leaves`, `contains`, `split`, `removing`, `updatingRatio`.

**Step 4: Проверить PASS**

```bash
make format
make test
```

### Task 5: Tabs, workspaces и store operations

**Files:**
- Create: `GhostTerm/Domain/StartupCommand.swift`
- Create: `GhostTerm/Domain/TerminalPaneDescriptor.swift`
- Create: `GhostTerm/Domain/TerminalTab.swift`
- Create: `GhostTerm/Domain/Workspace.swift`
- Create: `GhostTerm/Domain/WorkspaceStore.swift`
- Create: `GhostTerm/Domain/WorkspaceError.swift`
- Create: `GhostTermTests/Domain/WorkspaceStoreTests.swift`

**Step 1: Написать failing workspace tests**

Проверить:

- при пустом store создаётся `Default`;
- имя обязательно после trim;
- `Backend` и `backend` конфликтуют;
- новый workspace получает UUID;
- выбранные tabs перемещаются без изменения IDs/panes;
- tab имеет одного владельца;
- active tab корректируется после move/close;
- inactive workspaces остаются в store;
- broadcast выключается при смене tab/workspace;
- broadcast не восстанавливается как active после decode.

**Step 2: Реализовать minimum data model**

`TerminalPaneDescriptor`: id, cwd, startup command.

`TerminalTab`: id, title, root split node, active pane, runtime-only `isBroadcasting`.

`Workspace`: id, name, ordered tabs, active tab.

`WorkspaceStore`: ordered workspaces, active workspace, pure synchronous operations. Он не импортирует AppKit и GhosttyKit.

Имена сравнивать после trim и locale-stable case folding. Не использовать имя как identity.

**Step 3: Проверить**

```bash
make lint
make test
```

Expected: все domain tests PASS.

### Task 6: Versioned state persistence

**Files:**
- Create: `GhostTerm/Persistence/ApplicationState.swift`
- Create: `GhostTerm/Persistence/StateStore.swift`
- Create: `GhostTerm/Persistence/StateMigration.swift`
- Create: `GhostTermTests/Persistence/StateStoreTests.swift`
- Modify: `GhostTerm/AppDelegate.swift`

**Step 1: Написать failing persistence tests**

Проверить:

- round trip workspaces/tabs/splits/cwd/focus/frame;
- state version присутствует;
- unknown JSON fields игнорируются;
- write использует atomic replacement;
- corrupted file перемещается в `.backup-<timestamp>`;
- missing cwd при restore заменяется home без warning;
- runtime broadcast сбрасывается;
- save debounce coalesces несколько изменений детерминированным test clock, без `sleep`.

**Step 2: Реализовать state DTO**

Не кодировать live objects и C handles. `ApplicationState` содержит только descriptors, active IDs и `NormalWindowFrame` из Double values.

**Step 3: Реализовать `StateStore`**

Production URL:

```text
~/Library/Application Support/GhostTerm/state.json
```

Использовать `FileManager.url(for:in:appropriateFor:create:)`, temporary sibling file и atomic replace. Clock/scheduler внедрять узко только для debounce test, не вводить renderer protocol.

**Step 4: Подключить lifecycle**

Загрузить state перед созданием surfaces. Сохранять после model changes и при termination. Пользовательские startup commands пока декодировать как pending; confirmation реализуется в Task 13.

**Step 5: Проверить**

```bash
make lint
make test
```

## Milestone 3: config и AppKit UI

### Task 7: GhostTerm config поверх Ghostty format

**Files:**
- Create: `GhostTerm/Config/GhostTermConfig.swift`
- Create: `GhostTerm/Config/ConfigDocument.swift`
- Create: `GhostTerm/Config/ConfigController.swift`
- Create: `GhostTerm/Config/ConfigFileWatcher.swift`
- Create: `GhostTerm/Resources/default-config`
- Create: `GhostTerm/Resources/configuration-reference.md`
- Create: `GhostTermTests/Config/ConfigDocumentTests.swift`
- Create: `GhostTermTests/Config/ConfigControllerTests.swift`
- Modify: `project.yml`
- Modify: `GhostTerm/AppDelegate.swift`

**Step 1: Написать failing parser tests**

Проверить:

- `ghostterm-presentation-mode = normal`;
- default mode `normal`;
- default hotkey `cmd+f12`;
- default Quake height `75%`;
- hide-on-focus-loss default `true`;
- animation duration и padding;
- comments/blank/unknown lines сохраняются byte-for-byte;
- изменение presentation mode меняет только effective line;
- duplicate key: последнее значение effective;
- malformed GhostTerm value даёт line diagnostic;
- terminal lines выводятся в filtered file без `ghostterm-` keys.

**Step 2: Реализовать config values**

```swift
struct GhostTermConfig: Equatable, Sendable {
    var presentationMode: PresentationMode = .normal
    var globalToggle = HotKeyDescriptor(command: true, key: .f12)
    var quakeHeight: Double = 0.75
    var quakeAnimationDuration: TimeInterval = 0.18
    var quakePadding: CGFloat = 0
    var hideOnFocusLoss = true
}
```

**Step 3: Реализовать preserving document parser**

`ConfigDocument` хранит исходные строки с terminators. Он распознаёт только `ghostterm-` namespace; прочие строки не интерпретирует. Update заменяет value нужной строки или добавляет строку в конец.

**Step 4: Создать starter config и reference**

User config:

```text
~/.config/ghostterm/config
```

Filtered terminal config писать атомарно рядом:

```text
~/.config/ghostterm/.ghostty-effective-config
```

Так относительные include paths сохраняют базовую директорию. Generated файл не редактируется пользователем.

Starter config содержит все GhostTerm options и короткий terminal example. Комментарии внутри config — на английском; справочник проекта — на русском.

**Step 5: Реализовать reload**

File watcher coalesces filesystem events, перечитывает config, и только при полном успехе:

1. заменяет active `GhostTermConfig`;
2. записывает filtered Ghostty config;
3. вызывает `GhosttyBridge.reloadConfig`;
4. уведомляет UI.

При ошибке действует последняя валидная версия.

**Step 6: Проверить**

```bash
make lint
make test
```

Manual: изменить theme/font и убедиться, что shell не перезапущен.

### Task 8: Tab bar и workspace selector

**Files:**
- Create: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Create: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Create: `GhostTerm/Presentation/TabBar/TabItemView.swift`
- Create: `GhostTerm/Presentation/Workspace/WorkspaceSelector.swift`
- Create: `GhostTerm/Presentation/Workspace/CreateWorkspaceController.swift`
- Create: `GhostTermTests/Presentation/TabSelectionModelTests.swift`
- Modify: `GhostTerm/WindowController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`

**Step 1: Написать failing selection tests**

Отдельная value-модель selection проверяет click, Command-click, Shift-range, active tab и очистку selection после move.

**Step 2: Реализовать custom AppKit tab bar**

Использовать `NSCollectionView`, а не native window tabs: нужен multi-select. Tab bar показывает active state, close button, title, broadcast indicator и поддерживает reorder.

**Step 3: Реализовать workspace selector**

`NSPopUpButton` показывает уникальные workspace names. Выбор вызывает store operation, отключает broadcast прежнего tab и меняет отображаемый workspace без уничтожения surfaces.

**Step 4: Реализовать create/move flow**

Контекстные команды:

- `Move to New Workspace…`;
- `Move to Workspace`;
- `Duplicate into Workspace` оставить disabled/deferred, пока явно не реализован процесс clone.

Диалог требует имя, показывает inline duplicate/empty error, затем перемещает tabs и активирует workspace.

**Step 5: Проверить**

```bash
make lint
make test
```

Manual: создать `Backend`, проверить отказ для `backend`, переместить несколько tabs без restart процессов.

### Task 9: Recursive split presentation

**Files:**
- Create: `GhostTerm/Presentation/Splits/SplitNodeViewController.swift`
- Create: `GhostTerm/Presentation/Splits/PaneViewController.swift`
- Create: `GhostTerm/Presentation/Splits/SplitCoordinator.swift`
- Create: `GhostTermTests/Presentation/SplitCoordinatorTests.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`

**Step 1: Написать failing coordinator tests**

Проверить model commands для split horizontal/vertical, focus next/directions, resize ratio, equalize и close/collapse. Tests работают с IDs, не с renderer mock.

**Step 2: Реализовать recursive controllers**

Branch использует `NSSplitViewController`, leaf — `PaneViewController` с view из `GhosttyBridge`. UI строится из `SplitNode`; model остаётся source of truth.

**Step 3: Lifecycle hidden surfaces**

При скрытии tab/workspace bridge вызывает internal `ghostty_surface_set_occlusion(surface, true)`. Процесс продолжает работать. При показе: false + refresh/redraw.

**Step 4: Подключить Ghostty actions**

`GHOSTTY_ACTION_NEW_SPLIT`, goto, resize, equalize и close преобразуются в model commands с target `PaneID`. Не делегировать split UI upstream Ghostty app.

**Step 5: Проверить**

```bash
make lint
make test
```

Manual: nested splits обоих направлений, resize, focus, close/collapse, TUI resize.

### Task 10: Broadcast текущего tab

**Files:**
- Create: `GhostTerm/Input/TerminalInputRouter.swift`
- Create: `GhostTerm/Input/BroadcastController.swift`
- Create: `GhostTermTests/Input/TerminalInputRouterTests.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabItemView.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`

**Step 1: Написать failing routing tests**

Чистый router получает store snapshot, source pane и logical event и возвращает ordered target `PaneID`:

- broadcast off → source only;
- on → все leaves текущего tab;
- не включает panes другого tab/workspace;
- tab/workspace switch сбрасывает mode;
- surface error сбрасывает mode;
- mouse/scroll/UI command никогда не broadcast.

**Step 2: Реализовать logical event routing**

Keyboard event передаётся каждой target surface отдельно через bridge, чтобы каждая surface применила собственный translation/keyboard mode.

**Step 3: Реализовать broadcast paste**

Один раз получить pasteboard content и выполнить собственное safety confirmation. После подтверждения bridge завершает paste для каждой surface через её собственный Ghostty paste path; не отправлять encoded bytes active pane.

**Step 4: Добавить persistent indicator**

Tab item показывает badge, workspace content — контрастную рамку. Focused pane остаётся отдельно выделенной.

**Step 5: Проверить**

```bash
make lint
make test
```

Manual: две panes с разными shells/TUI получают keys, `Ctrl+C` и paste; mouse действует только на target.

## Milestone 4: process lifecycle и presentation modes

### Task 11: Process exit, close confirmation и surface errors

**Files:**
- Create: `GhostTerm/Presentation/Errors/SurfaceErrorViewController.swift`
- Create: `GhostTerm/Presentation/Errors/DiagnosticBannerView.swift`
- Create: `GhostTermTests/Domain/PaneLifecycleTests.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `GhostTerm/Domain/WorkspaceStore.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`

**Step 1: Написать failing lifecycle tests**

Проверить:

- process exit закрывает pane сразу;
- last pane закрывает tab;
- last tab normal закрывает window;
- last tab Quake скрывает window;
- следующий Quake toggle создаёт новый shell;
- close active foreground process требует одного confirmation;
- multi-close агрегирует confirmation;
- surface failure отключает broadcast и сохраняет остальные panes.

**Step 2: Реализовать callbacks**

Close/process-exit callback bridge преобразуется в `PaneID` command. Не оставлять exit placeholder.

**Step 3: Реализовать errors**

Surface init/render error показывает placeholder `Retry`/`Close Pane`. Config diagnostics показывает banner с path/line и `Open Config`.

**Step 4: Проверить**

```bash
make lint
make test
```

Manual: `exit`, failing command, close running `ssh`, renderer retry.

### Task 12: Normal/Quake mode и global hotkey

**Files:**
- Create: `GhostTerm/Presentation/NormalWindowController.swift`
- Create: `GhostTerm/Presentation/QuakeWindow.swift`
- Create: `GhostTerm/Presentation/QuakeWindowController.swift`
- Create: `GhostTerm/Presentation/PresentationController.swift`
- Create: `GhostTerm/Input/GlobalHotKeyController.swift`
- Create: `GhostTerm/Input/HotKeyDescriptor.swift`
- Create: `GhostTermTests/Presentation/PresentationStateMachineTests.swift`
- Create: `GhostTermTests/Input/HotKeyDescriptorTests.swift`
- Modify: `project.yml`
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/AppDelegate.swift`

**Step 1: Написать failing state-machine tests**

Проверить transitions normal→quake→normal, сохранение normal frame, idempotent visibility requests, rollback при failure и сохранение mode только после successful transition.

**Step 2: Написать hotkey parser tests**

Проверить `cmd+f12`, invalid combinations и round trip config. Default — `cmd+f12`.

**Step 3: Подключить Carbon**

В `project.yml` добавить `Carbon.framework`. `GlobalHotKeyController` использует `RegisterEventHotKey`/`UnregisterEventHotKey` для одного toggle hotkey без CGEventTap. Регистрация активна только в Quake mode. Conflict возвращает typed error и показывает diagnostic.

**Step 4: Реализовать два window containers**

- `NormalWindowController`: standard titled/resizable window.
- `QuakeWindow`: borderless `NSPanel`, `canBecomeKey/Main = true`, floating accessibility subrole.
- `PresentationController`: владеет одним `WorkspaceViewController` и переносит его view между контейнерами; одновременно visible только один container.

**Step 5: Реализовать Quake geometry**

Экран определяется по `NSEvent.mouseLocation`. Target frame использует `screen.visibleFrame`, полную ширину и `75%` высоты. Hidden frame находится над `visibleFrame.maxY`. Padding и duration берутся из config.

**Step 6: Реализовать show/hide**

- повтор hotkey скрывает;
- потеря key status скрывает после короткой cancellable delay;
- attached sheet/menu/system dialog отменяет auto-hide;
- предыдущий `NSRunningApplication` активируется после hide;
- повторные команды во время animation приводят к последнему requested state.

**Step 7: Реализовать mode command**

Menu command `Toggle Presentation Mode` переключает mode, сохраняет config строку после успеха и не перезапускает surfaces/processes.

**Step 8: Проверить**

```bash
make lint
make test
```

Manual: `Command+F12`, display under cursor, focus loss, rapid toggle, normal↔Quake, внешний монитор.

### Task 13: Startup command confirmation и restore

**Files:**
- Create: `GhostTerm/Presentation/Restore/StartupCommandConfirmationController.swift`
- Create: `GhostTerm/Runtime/WorkspaceRuntimeController.swift`
- Create: `GhostTermTests/Runtime/WorkspaceRuntimeControllerTests.swift`
- Modify: `GhostTerm/Persistence/StateStore.swift`
- Modify: `GhostTerm/WindowCoordinator.swift`

**Step 1: Написать failing restore tests**

Проверить:

- обычный shell запускается автоматически;
- missing cwd silently заменяется home;
- custom commands собираются в одно confirmation request;
- approved commands запускаются;
- rejected commands заменяются обычным shell в cwd;
- IDs/layout сохраняются;
- live process handles не сериализуются.

**Step 2: Реализовать restore plan**

`WorkspaceRuntimeController` сначала строит pure `RestorePlan`, затем UI один раз подтверждает список custom commands, после чего bridge создаёт surfaces.

**Step 3: Проверить**

```bash
make lint
make test
```

Manual: сохранить несколько workspaces, перезапустить app, подтвердить/отклонить commands.

## Milestone 5: themes, polish и release

### Task 14: Theme-synced chrome и help commands

**Files:**
- Create: `GhostTerm/Presentation/Theme/ChromeTheme.swift`
- Create: `GhostTerm/Presentation/Theme/ChromeThemeController.swift`
- Create: `GhostTermTests/Presentation/ChromeThemeTests.swift`
- Create: `GhostTerm/Menu/MainMenuController.swift`
- Modify: `GhostTerm/Integration/GhosttyBridge/GhosttyConfiguration.swift`
- Modify: `GhostTerm/Presentation/TabBar/TabBarViewController.swift`
- Modify: `GhostTerm/Presentation/Workspace/WorkspaceSelector.swift`
- Modify: `GhostTerm/AppDelegate.swift`

**Step 1: Написать failing theme tests**

Проверить luminance→light/dark appearance, active top pane background selection и контраст broadcast accent.

**Step 2: Получать effective background**

Bridge читает `background`, `background-opacity` и `window-theme` через `ghostty_config_get`, преобразует в собственный Swift `ChromeThemeSnapshot` и не возвращает C types.

**Step 3: Применять hybrid chrome**

Tab bar/workspace selector используют background active top pane. Text/icons используют `labelColor`, `secondaryLabelColor`, `controlAccentColor`; appearance выбирается по luminance или explicit window-theme.

**Step 4: Добавить menu commands**

- New Tab;
- Split Horizontal/Vertical;
- Toggle Broadcast;
- Toggle Presentation Mode;
- Open Config;
- Configuration Reference;
- Reveal Example Config.

Reference открывается из app bundle, config создаётся при отсутствии.

**Step 5: Проверить**

```bash
make lint
make test
```

Manual: light/dark/custom Ghostty themes, hot reload, splits с разными backgrounds.

### Task 15: UI tests, release archive, DMG и notarization

**Files:**
- Create: `GhostTermUITests/WorkspaceFlowUITests.swift`
- Create: `GhostTermUITests/SplitAndBroadcastUITests.swift`
- Create: `scripts/build-release.sh`
- Create: `scripts/notarize-dmg.sh`
- Create: `GhostTerm/GhostTerm.entitlements`
- Modify: `project.yml`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `.agents/scripts/pre-deploy-check.sh`
- Modify: `.agents/memory/tasks-completed.md`

**Step 1: Добавить UI test target**

XcodeGen target `GhostTermUITests` зависит от `GhostTerm` и входит в scheme test action. Tests покрывают создание именованного workspace, duplicate name error, tab move, splits и visible broadcast indicator.

Global hotkey и multi-display не автоматизировать — оставить manual smoke tests.

**Step 2: Написать release script**

`scripts/build-release.sh` требует непустые:

```text
DEVELOPMENT_TEAM
CODE_SIGN_IDENTITY
```

и выполняет `xcodebuild archive` для arm64 Release с hardened runtime в `.build/Release/GhostTerm.xcarchive`, затем создаёт `.build/Release/GhostTerm.dmg` через `hdiutil`. Скрипт не читает `.env` и Keychain secrets.

**Step 3: Написать notarization script**

`scripts/notarize-dmg.sh` принимает путь DMG и имя заранее созданного Keychain profile аргументами:

```bash
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --verbose "$DMG"
```

Никаких credentials в repo.

**Step 4: Полная автоматическая проверка**

```bash
make check
```

Expected: format lint, unit/integration/UI tests и Debug build PASS.

**Step 5: Manual smoke matrix**

Проверить на чистом Apple Silicon Mac с macOS 15+:

- normal и Quake;
- `Command+F12`;
- focus-loss hide;
- экран под курсором и отключение монитора;
- tabs/workspaces/multi-select;
- nested splits и resize;
- broadcast keys/paste/`Ctrl+C`;
- Unicode, emoji, IME;
- copy/paste, OSC 52, URLs;
- `ssh`, `tmux`, `vim`, `less`, полноэкранные TUI;
- theme hot reload;
- process exit и close confirmations;
- state restore и custom-command confirmation;
- signed/notarized DMG install и Gatekeeper assessment.

**Step 6: Финальный review**

Запустить отдельного reviewer по design doc и integration contracts. Все Critical/Important findings исправить и повторно проверить. Обновить `.agents/memory/tasks-completed.md` и написать handoff.

Не коммитить или публиковать автоматически.

## Definition of Done

- Все исходные функции design doc работают.
- Navigation и normal↔Quake не перезапускают shell.
- Inactive workspaces продолжают процессы.
- Process exit сразу закрывает pane.
- Broadcast ограничен текущим tab и всегда визуально заметен.
- Config reload не уничтожает последнюю валидную конфигурацию.
- C handles и upstream C types не выходят из `GhosttyBridge`.
- `make check` проходит с полным Xcode.
- DMG подписан, notarized и проходит Gatekeeper на чистом Mac.
