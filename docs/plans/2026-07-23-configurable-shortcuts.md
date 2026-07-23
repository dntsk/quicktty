# Configurable Shortcuts Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Сделать QuickTTY единственным владельцем configurable keyboard shortcuts, отключить Ghostty keybind table и сохранить обычный terminal input, IME и performable pass-through.

**Architecture:** Typed `ShortcutAction`/`ShortcutChord`/`ShortcutConfiguration` задают стабильный registry и defaults. `ConfigController` применяет shortcut-инструкции построчно с fallback к последнему active state, `ShortcutController` синхронизирует AppKit menus, а `GhosttyBridge` выполняет только typed terminal allowlist на текущей focused surface. Effective Ghostty config молча удаляет пользовательские `keybind` и завершается `keybind = clear`.

**Tech Stack:** Swift 6, AppKit, Carbon global hotkeys, embedded pinned libghostty, Swift Testing, XcodeGen.

**Constraints:** Не менять `Vendor/ghostty` и pinned revision. Не добавлять dependencies или Settings UI. Не запускать приложение. Не коммитить/push без отдельной команды пользователя. Focused tests по этапам, один `make check` и один финальный review.

---

### Task 1: Typed shortcut domain и полный registry

**Files:**
- Create: `QuickTTY/Input/ShortcutChord.swift`
- Create: `QuickTTY/Input/ShortcutAction.swift`
- Create: `QuickTTY/Input/ShortcutConfiguration.swift`
- Create: `QuickTTYTests/Input/ShortcutConfigurationTests.swift`
- Modify: `QuickTTY/Input/HotKeyDescriptor.swift` только если нужен временный compatibility adapter

**Step 1: Написать RED tests для key grammar**

Покрыть:

- весь утверждённый key token set;
- modifiers в любом порядке;
- canonical serialization `cmd+opt+ctrl+shift+key`;
- modifierless chord;
- duplicate modifier, empty component, missing/multiple/unsupported key;
- literal punctuation и aliases отклоняются;
- `disabled` парсится только на уровне assignment, не как key.

**Step 2: Написать RED tests registry/defaults**

Проверить точный набор stable action IDs и defaults из design doc:

- application;
- tabs/panes;
- indexed tab/workspace selection;
- workspace management;
- terminal allowlist.

Тест должен падать при duplicate action ID или duplicate default chord. Исключение — global Quake находится вне local defaults.

**Step 3: Реализовать минимальные value types**

Ожидаемые границы:

```swift
struct ShortcutChord: Codable, Equatable, Hashable, Sendable {
    let key: ShortcutKey
    let modifiers: Set<ShortcutModifier>
}

enum ShortcutAction: String, CaseIterable, Codable, Sendable { ... }

struct ShortcutConfiguration: Equatable, Sendable {
    private(set) var chords: [ShortcutAction: ShortcutChord]
}
```

`ShortcutAction` предоставляет typed metadata через computed/static registry, а не хранит closures внутри Sendable value.

**Step 4: Реализовать last-owner-wins mutation**

API должен атомарно:

- заменить chord action;
- освободить его старый chord;
- при конфликте отключить предыдущего владельца;
- вернуть typed conflict с chord, previous action и winning action;
- поддержать explicit disabled.

**Step 5: Запустить focused tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-domain \
  test -only-testing:QuickTTYTests/ShortcutConfigurationTests
```

Expected: PASS.

---

### Task 2: Postрочный config parsing и last-valid hot reload

**Files:**
- Modify: `QuickTTY/Config/QuickTTYConfig.swift`
- Modify: `QuickTTY/Config/ConfigDocument.swift`
- Modify: `QuickTTY/Config/ConfigController.swift`
- Modify: `QuickTTYTests/Config/ConfigDocumentTests.swift`
- Modify: `QuickTTYTests/Config/ConfigControllerTests.swift`

**Step 1: Написать RED parser tests**

Покрыть grammar:

```ini
quicktty-shortcut = action-id=chord
quicktty-shortcut = action-id=disabled
```

И semantics:

- valid lines применяются независимо;
- unknown action/malformed chord игнорируется с diagnostic;
- invalid known action сохраняет previous active chord;
- на первом startup invalid known action сохраняет default;
- удалённая строка возвращает default;
- repeated action: последняя valid instruction побеждает;
- chord conflict: последний action получает chord, previous становится disabled, diagnostic называет обоих;
- global chord отключает конфликтующий local action с diagnostic;
- unrelated QuickTTY options сохраняют partial-application behavior.

Добавить `ConfigDiagnostic.Reason` только для shortcut parse/conflict/global conflict; silent Ghostty keybind не является diagnostic.

**Step 2: Ввести parse context**

`ConfigDocument.parse` должен принимать optional previous active shortcut/global state либо typed context. Parsing всегда начинает с defaults; previous state используется только для invalid known instructions.

Не передавать mutable controller или UI в parser.

**Step 3: Расширить QuickTTYConfig**

Добавить full resolved local `ShortcutConfiguration` и shared `ShortcutChord` для global toggle. Сохранить `Equatable`/`Sendable`.

Мигрировать текущий `HotKeyDescriptor` без параллельной второй grammar. Compatibility adapter допустим только временно и должен быть удалён до завершения.

**Step 4: Изменить ConfigController.apply**

Parsing получает `activeConfig` как previous context. Existing Ghostty effective-file transaction и rollback не ослабляются.

`activeConfig` обновляется только после успешных write + Ghostty reload. `onUpdate` и diagnostics сохраняют current reentrant-document guard.

**Step 5: Запустить config suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-config \
  test \
  -only-testing:QuickTTYTests/ConfigDocumentTests \
  -only-testing:QuickTTYTests/ConfigControllerTests
```

Expected: PASS.

---

### Task 3: Удаление Ghostty keybinds из effective config

**Files:**
- Modify: `QuickTTY/Config/ConfigDocument.swift`
- Modify: `QuickTTYTests/Config/ConfigDocumentTests.swift`
- Modify: `QuickTTYTests/Config/ConfigControllerTests.swift`
- Modify: `QuickTTY/Resources/default-config`

**Step 1: Написать RED filtering tests**

Проверить:

- top-level `keybind = ...` полностью отсутствует в effective data;
- comments и похожие keys не удаляются;
- diagnostics для Ghostty keybind не создаются;
- QuickTTY shortcut lines по-прежнему удаляются;
- BOM/CRLF/no-final-newline сохраняются настолько, насколько это возможно без нарушения финальной directive;
- effective data всегда завершается отдельной строкой `keybind = clear`;
- final clear расположен после `include`, user Ghostty options и injected `copy-on-select`;
- повторный load детерминирован и не накапливает clear lines.

**Step 2: Реализовать exact Ghostty assignment detection**

Не использовать substring replacement. Определять assignment с учётом whitespace/comment так же, как существующий parser, но только exact key `keybind`.

**Step 3: Добавить final clear**

Сформировать effective data транзакционно. `keybind = clear` должен оставаться последней assignment даже при отсутствии newline в source.

**Step 4: Обновить starter config**

Добавить документированный `quicktty-shortcut` пример, но не дублировать весь registry в starter file.

**Step 5: Запустить config suites**

Использовать command Task 2. Expected: PASS.

---

### Task 4: Transactional global Carbon shortcut

**Files:**
- Modify: `QuickTTY/Input/GlobalHotKeyController.swift`
- Modify: `QuickTTYTests/Input/HotKeyDescriptorCarbonTests.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorConfigurationTests.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`

**Step 1: Написать RED conversion tests**

Проверить Carbon keyCode/modifiers для representative keys всех групп:

- letters/digits;
- punctuation;
- arrows/navigation;
- function keys;
- modifierless chord.

Mapping должен быть exhaustive и не зависеть от force-cast Unicode.

**Step 2: Написать RED rollback tests**

Через injected Carbon client/fake проверить:

- same chord no-op;
- new registration success;
- new registration failure восстанавливает previous chord;
- unregister failure не теряет tracked previous state;
- rollback failure выдаёт explicit error и не утверждает ложную registration;
- unsupported/system-rejected global chord не меняет local shortcuts.

**Step 3: Реализовать transactional replace**

Не оставлять текущий путь `unregister old → fail new → empty`. Controller должен либо сохранить старую registration, либо восстановить её прежде чем вернуть ошибку.

Protocol `HotKeyControlling` остаётся MainActor. Production Carbon functions инжектируются через узкий client без раскрытия refs вне controller.

**Step 4: Применить global-over-local policy**

Resolved local configuration уже должна отключить local owner global chord до menu/responder publication.

**Step 5: Запустить focused tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-global \
  test \
  -only-testing:QuickTTYTests/HotKeyDescriptorCarbonTests \
  -only-testing:QuickTTYTests/WindowCoordinatorConfigurationTests
```

Expected: PASS.

---

### Task 5: ShortcutController и native menu synchronization

**Files:**
- Create: `QuickTTY/Input/ShortcutController.swift`
- Modify: `QuickTTY/AppDelegate.swift`
- Modify: `QuickTTYTests/AppDelegateLifecycleTests.swift`
- Modify: `QuickTTYTests/Presentation/WorkspacePresentationTests.swift` только при изменении menu validation contracts

**Step 1: Написать RED menu tests**

Проверить stable identity и exact menu placement для:

- Quit/Open Config/Toggle Presentation;
- New/Close Tab и Close Pane;
- splits/navigation/tab selection;
- workspace management/selection;
- broadcast;
- Edit/terminal actions, которым допустим consuming menu equivalent.

Hot reload tests:

- меняет keyEquivalent/modifiers существующего item, не создавая duplicate;
- `disabled` очищает shortcut;
- conflict-disabled previous owner очищается;
- indexed actions обновляются независимо;
- exact action/representedObject/target не теряются;
- device-dependent flags не сохраняются.

**Step 2: Создать MainActor ShortcutController**

Controller владеет:

- active local configuration;
- stable mapping action → menu item;
- action metadata → selector/representedObject;
- responder-only map для conditional terminal actions.

Он не владеет `GhosttySurfaceView` и не хранит C handles.

**Step 3: Упростить AppDelegate installers**

Удалить hard-coded chord detection/canonicalization, завязанную на старые defaults. Menu identity определяется title/action/stable identifier, а shortcut приходит из controller.

Добавить недостающие first-party actions: quit, close active pane/tab и workspace management shortcuts. Existing validation/confirmation paths должны переиспользоваться.

**Step 4: Подключить config onUpdate**

Каждый active config update синхронно обновляет WindowCoordinator и ShortcutController на MainActor. Startup menu installation использует уже parsed active config, без промежуточного hard-coded состояния.

**Step 5: Запустить AppDelegate tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-menu \
  test -only-testing:QuickTTYTests/AppDelegateLifecycleTests
```

Expected: PASS.

---

### Task 6: Typed terminal action dispatch и performable fallback

**Files:**
- Create: `QuickTTY/Input/TerminalShortcutAction.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `QuickTTY/Input/TerminalInputRouter.swift` только если typed dispatch принадлежит существующему router
- Modify: `QuickTTYTests/Integration/GhosttyKeyboardInputTests.swift`
- Modify: `QuickTTYTests/Integration/GhosttyClipboardTests.swift`
- Modify: `QuickTTYTests/Input/TerminalInputRouterTests.swift`
- Modify: `scripts/check-runtime-callbacks.sh` только если contract audit требует новый allowed symbol

**Step 1: Написать RED typed allowlist tests**

Проверить exact mapping action ID → fixed Ghostty action string. Запретить arbitrary strings и исключённые actions (`text`, `csi`, files, crash, app/window/tab/split).

**Step 2: Добавить typed surface execution**

`GhosttySurfaceView` выполняет allowlisted action через private C handle на MainActor и возвращает core `Bool`. После close — no-op/false. DEBUG observations хранят только typed action/result, не handle.

**Step 3: Добавить dynamic responder matching**

Заменить hard-coded `isPlainCommandT`, split/navigation/digit checks на active ShortcutConfiguration.

Порядок focused keyDown:

1. local structural/menu shortcut резервируется для AppKit;
2. responder-only terminal action выполняется на source pane;
3. success → consume;
4. performable false → вернуть false и позволить normal keyDown/PTy path;
5. unmatched → existing Ctrl/IME/redispatch behavior.

Удалить production вызов `ghostty_surface_key_is_binding`. Не удалять сам C import/API, если он нужен тестам или upstream adaptation, но production keyboard path не должен его вызывать.

**Step 4: Сохранить target/broadcast policy**

- paste/paste-selection используют существующий current-tab broadcast route;
- остальные terminal actions — только source/focused pane;
- inactive/hidden/closed pane — no-op;
- structural actions никогда не broadcast.

**Step 5: Проверить performable menu interaction**

Conditional responder actions не должны иметь competing consuming menu equivalent. Copy menu validation может использовать `ghostty_surface_has_selection`, но не выполнять side effect во время validation.

**Step 6: Запустить keyboard/clipboard/input tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-input \
  test \
  -only-testing:QuickTTYTests/GhosttyKeyboardInputTests \
  -only-testing:QuickTTYTests/GhosttyClipboardTests \
  -only-testing:QuickTTYTests/TerminalInputRouterTests
```

Expected: PASS.

---

### Task 7: Structural action integration и hot-reload lifecycle

**Files:**
- Modify: `QuickTTY/AppDelegate.swift`
- Modify: `QuickTTY/WindowCoordinator.swift`
- Modify: `QuickTTYTests/AppDelegateLifecycleTests.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`
- Modify: `QuickTTYTests/Presentation/WindowCoordinatorConfigurationTests.swift`
- Modify: `QuickTTYTests/Presentation/BroadcastInputTests.swift`

**Step 1: Написать RED end-to-end action tests**

Проверить configurable routes для:

- new/close tab and pane with live-process confirmation;
- split and pane navigation;
- indexed tab/workspace activation;
- workspace create/rename/delete;
- broadcast toggle;
- presentation/config/quit.

No-op validation должна совпадать с current menu/domain availability.

**Step 2: Подключить active configuration ко всем routes**

Hard-coded shortcuts больше не должны оставаться в production AppDelegate/SurfaceView. Action IDs являются единственным источником chord ownership.

**Step 3: Проверить hot reload без recreation**

Создать live surfaces, применить новый config и проверить:

- ObjectIdentifier surfaces не меняется;
- process/callback contexts сохраняются;
- old chords больше не dispatch;
- new chords dispatch один раз;
- disabled chords проходят в PTY/normal AppKit path;
- menu и responder map опубликованы согласованно.

**Step 4: Проверить global/local conflict**

Global chord вызывает только Quake action; local owner disabled и не dispatch при активном приложении.

**Step 5: Запустить lifecycle suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-shortcuts-lifecycle \
  test \
  -only-testing:QuickTTYTests/AppDelegateLifecycleTests \
  -only-testing:QuickTTYTests/WindowCoordinatorTabLifecycleTests \
  -only-testing:QuickTTYTests/WindowCoordinatorConfigurationTests \
  -only-testing:QuickTTYTests/BroadcastInputTests
```

Expected: PASS.

---

### Task 8: Configuration reference, contracts и final gate

**Files:**
- Modify: `QuickTTY/Resources/configuration-reference.md`
- Modify: `QuickTTY/Resources/default-config`
- Modify: `README.md`
- Modify: `docs/backlog.md` only if implementation clarifies Search/OpenURL prerequisites
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/YYYY-MM-DD-HHMM-configurable-shortcuts.md`

**Step 1: Обновить documentation**

Зафиксировать:

- grammar и полный action registry/defaults;
- `disabled`, sequential override и last-owner-wins;
- invalid-line/removed-line semantics;
- global precedence/rollback;
- silent Ghostty keybind removal;
- terminal performable fallback;
- Search и URL hover/open как обязательные следующие задачи.

**Step 2: Выполнить format**

```bash
make format
```

**Step 3: Запустить один combined focused regression**

Запустить suites Tasks 1–7 одной командой или минимальным числом `xcodebuild`, не повторяя отдельные reviews.

**Step 4: Полный gate**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check
```

Expected: lint/build/all tests PASS; Ghostty pin unchanged.

**Step 5: Audit**

Проверить один раз:

- `git diff --check`;
- `git status --short`;
- `git submodule status`;
- no production `ghostty_surface_key_is_binding` call;
- final effective config ends with one `keybind = clear`;
- no arbitrary binding action string API;
- no new dependency/public C handle;
- no app launch/signing/release.

**Step 6: Один final review**

Провести один integrated review всей feature против design/plan. Исправлять только Critical/Important defects; Minor записывать без циклических review, если они не влияют на correctness.

**Step 7: Memory/handoff**

Записать точные test counts, action boundary, config semantics и отложенные Search/OpenURL задачи. Commit/push выполнять только по отдельной команде пользователя.
