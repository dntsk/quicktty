# URL Hover and Open Design

**Дата:** 2026-07-23
**Статус:** утверждён

## Цель

QuickTTY должен полноценно интегрировать URL detection закреплённого Ghostty:

- `Cmd+hover` подсвечивает regex URL или OSC 8 hyperlink и показывает pointing-hand cursor;
- `Cmd+click` открывает ссылку через native macOS workspace;
- terminal selection, TUI mouse reporting и обычные mouse events сохраняются;
- URL preview и keyboard action `open-url` не добавляются.

## Владение поведением

Ghostty остаётся единственным владельцем:

- link regex и OSC 8 metadata;
- проверки modifier;
- renderer highlight;
- определения ссылки под текущей mouse position;
- решения, поглощать ли click;
- разрешения terminal-relative file paths перед `open_url` action.

QuickTTY не анализирует terminal text и не выполняет собственный hit testing.

## Hover и cursor

`GHOSTTY_ACTION_MOUSE_SHAPE` с surface target преобразуется в typed Swift value внутри free C callback. `SurfaceCallbackContext` coalesce-ит обновления и доставляет только последнее active surface state на `MainActor`.

`GhosttySurfaceView` хранит текущую typed mouse shape и реализует её через `resetCursorRects()`. Для link pointer используется `NSCursor.pointingHand`. Для остальных закреплённых Ghostty shapes используется ближайший native `NSCursor`; неподдержанное значение безопасно оставляет предыдущую shape.

`NSCursor.push/pop` и глобальный `set()` не используются: cursor rects корректно ограничивают состояние конкретной pane при splits, workspace switch, remount и close.

`GHOSTTY_ACTION_MOUSE_OVER_LINK` намеренно не сохраняется: URL preview отклонён, а открытие выполняется по отдельному `open_url` action.

## Открытие URL

`GHOSTTY_ACTION_OPEN_URL` преобразуется в stable `GhosttyOpenURL` до возврата из callback:

- callback-scoped bytes копируются;
- UTF-8 валидируется строго;
- сохраняется kind `unknown`, `text` или `html`;
- пустое/невалидное значение не принимается.

Принятый action доставляется на `MainActor` через runtime callback context и возвращает `true` Ghostty, поэтому internal fallback не открывает URL второй раз.

Injectable `GhosttyWorkspaceURLClient` повторяет upstream macOS policy:

- значение с URL scheme передаётся `NSWorkspace` без allowlist;
- значение без scheme становится стандартизированным file URL с expansion `~`;
- `text` использует default editor, если он доступен;
- `html` и `unknown` используют default workspace application.

Поддерживаются `http`, `https`, `mailto`, custom schemes и file paths. Дополнительный confirmation не показывается, потому что действие требует явный `Cmd+click`.

## Lifecycle и concurrency

- C pointers и C enums не покидают `GhosttyBridge`.
- Payload URL копируется синхронно в callback.
- AppKit и `NSWorkspace` вызываются только на `MainActor`.
- Pending mouse shape очищается при `SurfaceCallbackContext.deactivateAndDrain()`.
- Cursor state принадлежит surface view и не сохраняется в model/state.
- Уже принятый explicit open относится к application lifecycle и не зависит от последующего закрытия pane.
- URL не попадает в PTY, diagnostics, workspace state или shell history.

## Ошибки

Empty или invalid UTF-8 action возвращает `false`, позволяя Ghostty применить собственную fallback policy. После принятия action ошибка `NSWorkspace` только логируется; повторное открытие не запускается, чтобы исключить duplicate side effect.

## Тестирование

Проверить:

- pinned action tags и typed conversion;
- копирование callback-scoped URL buffer;
- strict UTF-8/empty rejection;
- URL scheme, custom scheme, relative/absolute path и `~` conversion;
- ровно один вызов injected workspace client;
- отсутствие duplicate fallback для accepted action;
- mapping pinned mouse shapes и pointing hand;
- coalescing и close-before-delivery;
- независимое cursor state split panes;
- mouse movement/reporting/selection regressions;
- отсутствие preview UI, PTY writes и new shortcut action;
- callback/MainActor/teardown contracts.

После focused tests выполняются один integrated review и один `make check`, затем ручной smoke test regex URL и OSC 8 hyperlink после отдельного разрешения на запуск актуальной Debug-сборки.
