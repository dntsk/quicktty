# Ghostty Native Search Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Удалить кастомный AppKit search overlay и адаптировать штатные UI, lifecycle и action semantics закреплённого Ghostty.

**Architecture:** `GhosttyBridge` принимает штатные surface callbacks `START_SEARCH`, `END_SEARCH`, `SEARCH_TOTAL` и `SEARCH_SELECTED`. `GhosttySurfaceView` хранит observable state и хостит узко адаптированный upstream SwiftUI `SurfaceSearchOverlay`; SwiftUI не видит C API. Полный upstream macOS wrapper и новые зависимости не подключаются.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Combine, pinned libghostty v1.3.1, Swift Testing.

**Constraint:** Не менять Ghostty pin, не запускать приложение вручную, не выполнять git commit.

---

### Task 1: Зафиксировать штатные shortcut и callback semantics тестами

**Files:**
- Modify: `QuickTTYTests/Input/ShortcutConfigurationTests.swift`
- Modify: `QuickTTYTests/Integration/GhosttySurfaceViewTests.swift`
- Modify: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`
- Delete: `QuickTTYTests/Presentation/SearchOverlayViewTests.swift`
- Create: `QuickTTYTests/Presentation/GhosttySurfaceSearchOverlayTests.swift`

**Step 1: Написать failing shortcut tests**

Проверить:

- `find` → `start_search`, default `Cmd+F`;
- `find-next` → `navigate_search:next`, default `Cmd+G`;
- `find-previous` → `navigate_search:previous`, default `Cmd+Shift+G`.

**Step 2: Написать failing surface lifecycle tests**

Через stable `GhosttySurfaceCallbackEvent` проверить:

- `searchStarted(nil)` создаёт state и hosting overlay;
- `searchStarted("needle")` устанавливает needle;
- повторный start сохраняет identity state, обновляет непустой needle и запрашивает focus;
- `searchEnded` удаляет state/overlay без повторного небезопасного C доступа;
- `searchTotal(nil)` и `searchSelected(nil)` очищают значения;
- `searchSelected(0)` сохраняет нулевой индекс;
- close во время поиска очищает state и pending delivery.

**Step 3: Написать failing overlay behavior tests**

Тестировать доступные pure/internal seams, а не SwiftUI hierarchy:

- count: selected `3`, total `17` → `4/17`; selected nil, total `5` → `-/5`; оба nil → пустая строка;
- Return → `.next`, Shift+Return → `.previous`;
- Escape с пустым needle → close, с непустым → focus terminal;
- navigation strings точны: `navigate_search:next`/`previous`.

**Step 4: Дополнить pinned ABI test**

Проверить raw tags `START_SEARCH = 59`, `END_SEARCH = 60`, `SEARCH_TOTAL = 61`, `SEARCH_SELECTED = 62` по фактическому C enum закреплённого header, а также layout соответствующих payload structs. Значения не задавать по памяти — использовать импортированные C constants и подтвердить ожидаемую последовательность из header.

**Step 5: Запустить тесты и подтвердить FAIL**

Run:

```bash
make generate
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test \
  -only-testing:QuickTTYTests/ShortcutConfigurationTests \
  -only-testing:QuickTTYTests/GhosttySurfaceViewTests \
  -only-testing:QuickTTYTests/GhosttyBridgeTests \
  -only-testing:QuickTTYTests/GhosttySurfaceSearchOverlayTests
```

Expected: FAIL из-за отсутствующих native search events/view/actions.

---

### Task 2: Перенести штатный search callback lifecycle в GhosttyBridge

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift:45-76`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift:355-373,2500-2580`
- Modify: `scripts/check-runtime-callbacks.sh`

**Step 1: Расширить stable callback events**

Добавить ordered события:

```swift
case searchStarted(String?)
case searchEnded
case searchTotal(Int?)
case searchSelected(Int?)
```

`total`/`selected < 0` преобразовывать в `nil`; `0` является валидным selected index.

**Step 2: Скопировать START_SEARCH payload до возврата callback**

Для `GHOSTTY_ACTION_START_SEARCH` требовать surface target и active surface userdata. `needle == nil` копировать как `nil`; непустой/пустой C string копировать через strict `String(validatingCString:)`. Невалидный payload отклонять (`false`).

**Step 3: Обработать END_SEARCH/TOTAL/SELECTED**

Все четыре search event направить через `SurfaceCallbackContext` ordered FIFO. Opaque surface и C payload не захватывать в MainActor Task.

**Step 4: Зафиксировать callback contract script**

Добавить read-only проверки всех четырёх tags, target/userdata lookup, synchronous needle copy и методов schedule.

**Step 5: Запустить callback и bridge tests**

Run:

```bash
make callback-contract
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test -only-testing:QuickTTYTests/GhosttyBridgeTests
```

Expected: PASS.

---

### Task 3: Заменить SearchOverlayView штатным SurfaceSearchOverlay Ghostty

**Files:**
- Delete: `QuickTTY/Presentation/Search/SearchOverlayView.swift`
- Create: `QuickTTY/Presentation/Search/GhosttySurfaceSearchOverlay.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift:1-6,417-424,551-562,1399-1405,1884-2010`
- Modify: `QuickTTY/Input/ShortcutAction.swift:39-97,99-223`
- Modify: `QuickTTY/WindowCoordinator.swift:1356-1359,1488-1491`

**Step 1: Адаптировать upstream SwiftUI overlay**

Перенести из pinned `SurfaceView.swift:400-600` без дизайнерских изменений:

- HStack spacing/padding/background/shadow;
- plain TextField шириной 180 и встроенный счётчик;
- navigation и close buttons с `SearchButtonStyle`;
- Return/Shift+Return;
- Escape semantics;
- drag и snap к ближайшему углу;
- top-right initial corner и 8 pt outer padding;
- macOS 26 `ConcentricRectangle` fallback на `RoundedRectangle`.

Добавить English provenance comment с точным upstream path и commit. View принимает stable callbacks и не импортирует `GhosttyKit`.

**Step 2: Перенести upstream SearchState/debounce**

`SearchState` сделать `ObservableObject` с `@Published needle/selected/total`. В `GhosttySurfaceView` использовать Combine pipeline upstream:

- `removeDuplicates()`;
- empty или длина `>= 3` — immediate;
- длина `1...2` — delay 300 ms;
- `switchToLatest()`;
- action `search:<needle>` только для текущего live state.

**Step 3: Хостить overlay поверх surface**

Создать `NSHostingView<GhosttySurfaceSearchOverlay>`, растянуть по bounds surface, не менять Metal surface/layout/PTY size. Прозрачная область не должна блокировать terminal input; добавить узкий pass-through hosting behavior только если это требуется AppKit hit testing.

**Step 4: Повторить lifecycle Ghostty.App**

- `.find` отправляет `start_search`, а не создаёт UI заранее;
- callback start создаёт/обновляет state и фокусирует TextField;
- UI close возвращает first responder surface и отправляет `end_search`;
- callback end локально удаляет overlay/subscription;
- repeated start фокусирует существующий field;
- Escape с non-empty needle возвращает first responder surface без закрытия;
- pane switch отправляет `end_search` старой surface;
- close очищает local state без ожидания callback.

**Step 5: Добавить native navigation shortcuts**

Добавить `findNext`/`findPrevious` и точные core actions `navigate_search:next`/`navigate_search:previous`. Удалить special-case пустой coreAction для `.find`; его coreAction — `start_search`.

**Step 6: Запустить focused tests**

Run:

```bash
make generate
xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  test \
  -only-testing:QuickTTYTests/ShortcutConfigurationTests \
  -only-testing:QuickTTYTests/GhosttySurfaceViewTests \
  -only-testing:QuickTTYTests/GhosttySurfaceSearchOverlayTests
```

Expected: PASS.

---

### Task 4: Обновить integration contract и завершить проверку

**Files:**
- Modify: `THIRD_PARTY_NOTICES.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/tasks-completed.md`
- Modify: `docs/plans/2026-07-27-interactive-terminal-search-design.md`
- Modify: `docs/plans/2026-07-27-interactive-terminal-search-plan.md`

**Step 1: Обновить provenance**

Добавить адаптированные upstream search ranges в `THIRD_PARTY_NOTICES.md`. В старых search design/plan явно отметить, что кастомный overlay superseded новым утверждённым дизайном, не переписывая исторический документ.

**Step 2: Обновить project memory**

Зафиксировать native action names, callback lifecycle, zero-based selected index, SwiftUI overlay и teardown/focus semantics. Не заявлять manual smoke, если он не выполнялся.

**Step 3: Форматирование и read-only gates**

Перед `make format` проверить diff. Затем:

```bash
make format
make lint
make build
make test
make check
git diff --check
git status --short
```

Expected: все проверки PASS; в diff отсутствуют изменения `Vendor/ghostty`, pin и generated/release artifacts.

**Step 4: Self-review**

Сравнить итоговый view построчно с pinned `SurfaceSearchOverlay`, проверить отсутствие C API в presentation-файле, отсутствие кастомного `NSSearchField` и отсутствие `search:next`/`search:previous` в first-party коде.

Коммит не выполнять.
