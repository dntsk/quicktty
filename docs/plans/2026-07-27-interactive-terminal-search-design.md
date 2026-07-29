# Interactive Terminal Search

**Дата:** 2026-07-27
**Статус:** superseded документом `docs/plans/2026-07-29-ghostty-native-search-design.md`; историческое содержание сохранено.

## Сводка

Добавить полоску поиска поверх активного terminal viewport с инкрементальным поиском
и навигацией, используя встроенный search thread Ghostty v1.3.1. Поиск привязан к
одной активной панели, закрывается при смене панели.

## UX

- `Cmd+F` открывает NSSearchField в верхней части активного viewport.
- Инкрементальный поиск с debounce ~200ms: `search:<needle>` уходит при каждом
  изменении текста.
- Счётчик совпадений (3/17) в правой части поля.
- Навигация: `Cmd+G` / `Cmd+Shift+G` или ↑↓ в поле поиска.
- `Esc` — закрыть поиск и очистить подсветку.
- `Enter` — закрыть поиск, но сохранить подсветку и навигацию (поиск остаётся
  активным).
- Клик по терминалу вне поля — закрыть поиск.
- Поиск только в активной панели; при переключении панели поиск закрывается.

## Ghostty API (pinned v1.3.1)

### Binding actions (app → Ghostty)

Все через `ghostty_surface_binding_action(surface, action, len)`:

| String | Действие |
|---|---|
| `start_search` | Открыть поиск (UI + search thread) |
| `search:<needle>` | Искать строку; пустой needle = отмена |
| `search:next` | Следующее совпадение |
| `search:previous` | Предыдущее совпадение |
| `search_selection` | Искать выделенный текст |
| `end_search` | Закрыть поиск, очистить подсветку |

### Callback actions (Ghostty → app)

Приходят как `ghostty_action_s` с `GHOSTTY_TARGET_SURFACE`:

| Tag | Payload | Значение |
|---|---|---|
| `GHOSTTY_ACTION_START_SEARCH` | `{:needle}` | Ghostty хочет открыть поиск (например, из kitty-протокола) |
| `GHOSTTY_ACTION_SEARCH_TOTAL` | `{total}` | Общее число совпадений |
| `GHOSTTY_ACTION_SEARCH_SELECTED` | `{selected}` | Текущий selected match (1-based, nil если 0) |

## Архитектура

### Состояние

```swift
// Inside GhosttySurfaceView
struct SearchState {
    var needle: String                  // текущий текст поиска
    var total: UInt?                    // общее число совпадений (nil пока неизвестно)
    var selected: UInt?                 // текущий выбранный match
    var isActive: Bool { needle.isEmpty == false || showingOverlay }
}
```

Состояние хранится в `GhosttySurfaceView`, не в `GhosttyBridge`. Причина: search
state привязан к life surface и не нужен модели/координатору.

### Компоненты

1. **GhosttyBridge** — добавляет обработку `GHOSTTY_ACTION_SEARCH_TOTAL` (tag 59) и
   `GHOSTTY_ACTION_SEARCH_SELECTED` (tag 60) в `ghosttyRuntimeActionCallback`.
   Пропускает `start_search` callback для kitty-совместимости (пока не
   реализован — deferred).

2. **SearchOverlayView** — новый AppKit `NSView`, содержащий:
   - `NSSearchField` с placeholder "Search"
   - Debounce-логика через `DispatchWorkItem` с отменой
   - Кнопка счётчика справа или встроенный текст в search field

3. **GhosttySurfaceView** — добавляет:
   - `searchState: SearchState?` (nil когда поиск неактивен)
   - `searchOverlayView: SearchOverlayView?`
   - `showSearchOverlay()` — создаёт и добавляет overlay в view hierarchy,
     отправляет `start_search` binding
   - `hideSearchOverlay(clearSearch: Bool)` — убирает overlay, отправляет
     `end_search` при `clearSearch`
   - Обработку combined search callbacks от bridge

4. **WindowCoordinator** — добавляет:
   - Переключение панели → закрыть поиск в старой панели
   - Перенаправление Cmd+G/Cmd+Shift+G на поиск активной панели

5. **ShortcutAction** — добавляет:
   - `find` — Cmd+F, открывает search overlay
   - `findNext` — Cmd+G (terminal action)
   - `findPrevious` — Cmd+Shift+G (terminal action)

### Dataflow

```
Пользователь жмёт Cmd+F
→ Shortcut dispatch → GhosttySurfaceView.showSearchOverlay()
→ ghostty_surface_binding_action(surface, "start_search", ...)
→ Search overlay появляется

Пользователь вводит текст
→ debounce 200ms
→ ghostty_surface_binding_action(surface, "search:needle", ...)
→ Ghostty начинает поиск
→ Callback: GHOSTTY_ACTION_SEARCH_TOTAL → searchState.total = 3
→ Callback: GHOSTTY_ACTION_SEARCH_SELECTED → searchState.selected = 1
→ Счётчик обновляется: "1/3"

Cmd+G
→ ghostty_surface_binding_action(surface, "search:next", ...)
→ Callback: GHOSTTY_ACTION_SEARCH_SELECTED → searchState.selected = 2

Esc
→ ghostty_surface_binding_action(surface, "end_search", ...)
→ overlay удаляется, searchState = nil
```

### Жизненный цикл

- `close()` / `deinit` — удалить overlay, searchState = nil, binding сбрасывать
  не нужно (surface уже закрыт)
- Переключение панели — hideSearchOverlay(clearSearch: true) на старой
- Отключение surface от окна (detach) — скрыть overlay, не очищая состояние
- Возврат surface в окно (attach) — если searchState.isActive, показать overlay

## Тесты

- Search state lifecycle: show → needle change → total callback → selected callback → hide
- Debounce: rapid input = один binding с последним needle
- Empty needle = no binding call
- Pane switch = search cleared
- Teardown safety: close surface while search active
- Cmd+F shortcut: consumed, not written to PTY
- Cmd+G/Cmd+Shift+G: consumed as search navigation

## Не входит в объём

- Regex toggle
- Case-sensitive toggle
- Multi-pane search
- Kitty-протокол `start_search` callback (deferred)
- Подсветка всех совпадений в скроллбаре (deferred)
- История поисковых запросов
