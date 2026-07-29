# Штатный поиск Ghostty

**Дата:** 2026-07-29  
**Статус:** утверждён

## Цель

Удалить кастомный AppKit `SearchOverlayView` и повторить штатный macOS search UX закреплённого Ghostty v1.3.1 (`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`) без подключения полного upstream Swift wrapper.

## Выбранный подход

Точечно адаптировать `SurfaceSearchOverlay`, `SearchState` и search lifecycle из:

- `Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift:193-205,400-600,1268-1279`;
- `Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:71-106,1571-1617`;
- `Vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift:2023-2119`.

Прямой импорт невозможен: upstream view зависит от полного `Ghostty.SurfaceView`, app delegate и Swift package macOS-приложения, тогда как QuickTTY использует собственный `GhosttyBridge`. Поэтому переносится только штатный SwiftUI overlay и его поведение; C handle остаётся private внутри `GhosttySurfaceView`, а SwiftUI view получает замыкания со стабильными Swift-значениями.

Полный upstream macOS wrapper не подключается: это нарушило бы текущую bridge-границу, продублировало lifecycle окна/surface и значительно расширило изменение. Сохранение кастомного `NSSearchField` отклонено по требованию заменить его поиском Ghostty.

## Поведение

- `Cmd+F` отправляет `start_search`; overlay создаётся по surface-targeted `GHOSTTY_ACTION_START_SEARCH` и повторный callback возвращает фокус в поле.
- Поле использует штатный Ghostty debounce: пустая строка и запросы длиной от трёх символов отправляются сразу, запросы длиной один-два символа — через 300 мс.
- Поиск отправляется как `search:<needle>`.
- Return отправляет `navigate_search:next`, Shift+Return — `navigate_search:previous`.
- Кнопки навигации, close, внешний вид, drag и привязка к ближайшему углу повторяют pinned `SurfaceSearchOverlay`.
- `Cmd+G` и `Cmd+Shift+G` используют `navigate_search:next` и `navigate_search:previous`; когда поле поиска действительно сфокусировано, события продолжают идти через настраиваемый shortcut route surface.
- Полноразмерный host принимает AppKit hit только внутри фактически измеренного frame панели; до measurement и вне панели событие получает terminal surface. Named local coordinates и явное преобразование flipped orientation сохраняют region при drag/snap/resize.
- Escape при пустом запросе закрывает поиск. При непустом запросе только возвращает фокус терминалу, сохраняя overlay и подсветку.
- Close сначала возвращает фокус терминалу, затем отправляет `end_search`.
- `SEARCH_SELECTED` трактуется как штатный нулевой индекс; UI показывает `selected + 1`. Отрицательные `SEARCH_SELECTED`/`SEARCH_TOTAL` становятся `nil`.
- Смена активной панели завершает поиск старой surface. Закрытие surface локально удаляет overlay и подписки до освобождения C handle.

## Архитектура

`GhosttyBridge` синхронно копирует optional needle `START_SEARCH` и scalar payloads остальных search callbacks до возврата из C callback. `SurfaceCallbackContext` ставит устойчивые события в существующую ordered FIFO и доставляет их на MainActor только живой surface.

`GhosttySurfaceView` владеет observable search state, Combine-подпиской needle и `NSHostingView` со SwiftUI overlay. SwiftUI-код не импортирует `GhosttyKit` и не вызывает C API. Все binding actions выполняются синхронно методом private bridge surface.

Opaque handles, callback payloads и upstream enums не выходят из `GhosttyBridge`. Ревизия Ghostty и зависимости не меняются.

## Проверка

Автотесты фиксируют:

- точные shortcut/action strings и default chords;
- `START_SEARCH`/`END_SEARCH` lifecycle, повторный focus/update needle и teardown;
- optional/нулевую индексацию total/selected;
- формат счётчика Ghostty;
- немедленную и отложенную доставку needle;
- точные navigation/close/focus callbacks overlay;
- pane-switch cleanup, отмену pending короткого needle после end/close и отсутствие записи `Cmd+F` в PTY;
- measured hit region и shortcut dispatch из фактически сфокусированного search field без зависимости от private SwiftUI hierarchy;
- pinned search ABI и callback-contract script.

После focused tests выполняются `make format`, `make lint`, `make build`, `make test` и `make check`. Коммиты и ручной запуск приложения не выполняются.
