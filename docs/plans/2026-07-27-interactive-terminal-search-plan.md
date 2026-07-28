# Interactive Terminal Search — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Добавить NSSearchField-оверлей поверх активного терминала с инкрементальным поиском через встроенный search thread Ghostty.

**Architecture:** SearchOverlayView добавляется как subview в GhosttySurfaceView. Bridge принимает search_total/search_selected callback'и и направляет их в surface. ShortcutAction получает find/findNext/findPrevious. Состояние привязано к одной активной панели.

**Tech Stack:** AppKit (NSSearchField, NSStackView), pinned Ghostty v1.3.1 binding actions, Swift concurrency (MainActor)

---

### Task 1: Добавить search actions в TerminalShortcutAction и ShortcutAction

**Files:**
- Modify: `QuickTTY/Input/ShortcutAction.swift`

**Step 1: Добавить search cases в TerminalShortcutAction**

В enum `TerminalShortcutAction` после `case nextPrompt` добавить:

```swift
case find = "find"
case findNext = "find-next"
case findPrevious = "find-previous"
```

**Step 2: Добавить обработку в coreAction**

В `var coreAction: String` добавить случаи для pure-terminal действий (findNext, findPrevious), а find оставить без coreAction:

```swift
case .findNext: "search:next"
case .findPrevious: "search:previous"
```

Для `.find` не добавлять case — он будет обработан отдельно как overlay action.

**Step 3: Добавить search actions в ShortcutAction**

В enum `ShortcutAction` добавить:

```swift
case find
case findNext = "find-next"
case findPrevious = "find-previous"
```

**Step 4: Добавить default chords**

В метод `defaultChord` добавить:

```swift
case .find: ShortcutChord(modifiers: .command, key: "f")
case .findNext: ShortcutChord(modifiers: .command, key: "g")
case .findPrevious: ShortcutChord(modifiers: [.command, .shift], key: "g")
```

**Step 5: Commit**

```bash
git add QuickTTY/Input/ShortcutAction.swift
git commit -m "feat: add find/findNext/findPrevious shortcut actions"
```

---

### Task 2: Добавить search callback события в GhosttyBridge и GhosttySurfaceView

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`

**Step 1: Добавить search события в GhosttySurfaceCallbackEvent**

В enum `GhosttySurfaceCallbackEvent` после `.scrollbarChanged` добавить:

```swift
case searchTotal(Int)
case searchSelected(Int?)
```

**Step 2: Добавить обработку search колбэков в GhosttyBridge**

В `ghosttyRuntimeActionCallback` добавить после scrollbar handler:

```swift
if action.tag == GHOSTTY_ACTION_SEARCH_TOTAL {
    // Copy payload then schedule via context
    ...
}
if action.tag == GHOSTTY_ACTION_SEARCH_SELECTED {
    // Copy payload then schedule via context
    ...
}
```

Добавить константы:

```swift
let GHOSTTY_ACTION_SEARCH_TOTAL = GhosttyActionTag(rawValue: 59)
let GHOSTTY_ACTION_SEARCH_SELECTED = GhosttyActionTag(rawValue: 60)
```

**Step 3: Добавить методы в SurfaceCallbackContext**

Добавить `scheduleSearchTotal(_ total: Int)` и `scheduleSearchSelected(_ selected: Int?)` — аналогично существующим `scheduleActivityEvent`.

**Step 4: Добавить обработку в processCallbackEvent GhosttySurfaceView**

В `processCallbackEvent` добавить:

```swift
case .searchTotal(let total):
    searchState?.total = UInt(max(0, total))
case .searchSelected(let selected):
    if let selected, selected > 0 {
        searchState?.selected = UInt(selected)
    } else {
        searchState?.selected = nil
    }
```

**Step 5: Commit**

```bash
git add QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift \
        QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift
git commit -m "feat: add search callback handling in bridge"
```

---

### Task 3: Создать SearchOverlayView

**Files:**
- Create: `QuickTTY/Presentation/Search/SearchOverlayView.swift`

**Step 1: Создать SearchOverlayView**

AppKit NSView с:
- `NSSearchField` как поле ввода
- Счётчик (NSTextField) "0/0" справа
- Debounce через DispatchWorkItem с 200ms задержкой
- Callback'и для needle change и навигации

```swift
final class SearchOverlayView: NSView {
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var debounceWork: DispatchWorkItem?

    var onNeedleChange: ((String) -> Void)?
    var onNavigate: ((SearchNavigation) -> Void)?
    var onClose: ((Bool) -> Void)? // true = clear search

    init() { ... }

    func updateCount(selected: UInt?, total: UInt?) { ... }
    func focus() { window?.makeFirstResponder(searchField) }
}
```

**Step 2: Настроить layout через Auto Layout**

Search field слева, count label справа, внутри горизонтального NSStackView. Общая ширина ~280pt, высота 28pt.

**Step 3: Добавить обработку клавиш**

Внутри `SearchOverlayView` добавить local key handler для:
- ↑ (previous match)
- ↓ (next match)
- Esc (close, clear search)
- Enter (close, keep search highlighted)

Использовать `NSSearchFieldDelegate` или `control(_:textView:doCommandBy:)`.

**Step 4: Commit**

```bash
git add QuickTTY/Presentation/Search/SearchOverlayView.swift
git commit -m "feat: add SearchOverlayView"
```

---

### Task 4: Добавить search состояние и методы в GhosttySurfaceView

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`

**Step 1: Добавить SearchState тип**

Внутри GhosttySurfaceView добавить:

```swift
final class SearchState {
    var needle = ""
    var total: UInt?
    var selected: UInt?
}
```

**Step 2: Добавить свойства**

```swift
private(set) var searchState: SearchState?
private var searchOverlayView: SearchOverlayView?
```

**Step 3: Добавить showSearchOverlay()**

```swift
func showSearchOverlay() {
    guard searchOverlayView == nil, let surface else { return }
    let overlay = SearchOverlayView()
    // configure callbacks
    overlay.onNeedleChange = { [weak self] needle in
        self?.performSearchBinding("search:\(needle)")
    }
    overlay.onNavigate = { [weak self] nav in
        switch nav {
        case .next: self?.performSearchBinding("search:next")
        case .previous: self?.performSearchBinding("search:previous")
        }
    }
    overlay.onClose = { [weak self] clear in
        self?.hideSearchOverlay(clearSearch: clear)
    }
    // add as subview, constrain to top of view
    addSubview(overlay)
    // ...
    searchState = SearchState()
    searchOverlayView = overlay
    performSearchBinding("start_search")
    overlay.focus()
}
```

**Step 4: Добавить hideSearchOverlay()**

```swift
func hideSearchOverlay(clearSearch: Bool = true) {
    if clearSearch { performSearchBinding("end_search") }
    searchOverlayView?.removeFromSuperview()
    searchOverlayView = nil
    searchState = nil
}
```

**Step 5: Добавить performSearchBinding()**

```swift
private func performSearchBinding(_ action: String) {
    guard let surface else { return }
    ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
}
```

**Step 6: Обработка в performTerminalShortcutAction**

Добавить в `performTerminalShortcutAction` обработку:

```swift
case .findNext: performSearchBinding("search:next")
case .findPrevious: performSearchBinding("search:previous")
```

**Step 7: Добавить find-first-responder в performKeyEquivalent**

В `performKeyEquivalent` добавить guard: если `searchOverlayView != nil` и
`searchField` — first responder, пропускать. Иначе стандартное поведение.

**Step 8: Commit**

```bash
git add QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift
git commit -m "feat: add search state and overlay methods to GhosttySurfaceView"
```

---

### Task 5: Замкнуть shortcut dispatch в WindowCoordinator

**Files:**
- Modify: `QuickTTY/WindowCoordinator.swift`

**Step 1: Добавить обработку find в dispatchShortcut**

В методе диспетчеризации shortcut добавить для `.find`:

```swift
case .find:
    activeSurface?.showSearchOverlay()
    return true
```

**Step 2: Добавить закрытие поиска при смене панели**

В методе переключения активной панели (activatePane или similar) добавить:

```swift
if let oldSurface = surface(for: oldPaneID) {
    oldSurface.hideSearchOverlay(clearSearch: true)
}
```

**Step 3: Commit**

```bash
git add QuickTTY/WindowCoordinator.swift
git commit -m "feat: wire search shortcut and pane-switch cleanup"
```

---

### Task 6: Тесты

**Files:**
- Create: `QuickTTYTests/Presentation/SearchOverlayViewTests.swift`
- Modify: `QuickTTYTests/Integration/GhosttySurfaceViewTests.swift`

**Step 1: Тест создания и lifecycle SearchOverlayView**

- overlay появляется
- debounce: 3 быстрых ввода → один search binding
- пустой needle → no binding
- ↑↓ стрелки → search:next/search:previous
- Esc → end_search
- Enter → закрыть без end_search

**Step 2: Тест search callback'ов через bridge**

- Приходит search_total → searchState.total обновляется
- Приходит search_selected → searchState.selected обновляется
- search_selected = 0 → selected = nil

**Step 3: Тест shortcuts**

- Cmd+F → showSearchOverlay вызывается
- Cmd+G → search:next binding
- Cmd+Shift+G → search:previous binding
- Краткий smoke Cmd+F does not write to PTY

**Step 4: Тест переключения панели**

- search открыт на панели A
- переключение на панель B
- панель A: search закрыт, end_search вызван

**Step 5: Commit**

```bash
git add QuickTTYTests/
git commit -m "test: add interactive search tests"
```

---

### Task 7: Документация и финализация

**Files:**
- Modify: `docs/backlog.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/tasks-completed.md`

**Step 1: Обновить backlog**

Пометить Interactive Terminal Search как завершённый.

**Step 2: Обновить integration contracts**

Добавить секцию search callback'ов и binding actions.

**Step 3: Обновить tasks-completed**

Добавить запись о завершении.

**Step 4: Commit**

```bash
git add docs/ .agents/memory/
git commit -m "docs: finalize interactive search in backlog and contracts"
```

---

### Итоговый список коммитов

1. `feat: add find/findNext/findPrevious shortcut actions`
2. `feat: add search callback handling in bridge`
3. `feat: add SearchOverlayView`
4. `feat: add search state and overlay methods to GhosttySurfaceView`
5. `feat: wire search shortcut and pane-switch cleanup`
6. `test: add interactive search tests`
7. `docs: finalize interactive search in backlog and contracts`
