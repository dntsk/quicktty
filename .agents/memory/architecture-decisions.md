# Архитектурные решения

Формат ADR-lite. Источник начальных решений: `docs/plans/2026-07-14-ghostterm-design.md`.

## Swift и AppKit для нативного приложения

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Окно, responder chain, tabs, drag-and-drop, splits и Quake-анимация требуют нативной интеграции macOS.
- **Решение:** Основное приложение пишется на Swift и AppKit.
- **Отклонённые варианты:** В design doc альтернативный основной UI-слой не зафиксирован.
- **Последствия:** AppKit и `NSView` работают только на main thread; проект соблюдает Swift strict concurrency.

## Полная закреплённая `libghostty`

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Нужны PTY, VT/xterm-эмуляция, input, Metal renderer, scrollback, fonts, config и themes.
- **Решение:** Встраивать полную `libghostty` на конкретной ревизии; Zig использовать только как build tool.
- **Отклонено:** `libghostty-vt`; собственные VT parser, PTY layer, renderer или font pipeline; плавающая upstream-ревизия.
- **Последствия:** Бинарная интеграция сложнее, но терминальный стек не дублируется; обновления upstream выполняются контролируемо.

## Изоляция C API в `GhosttyBridge`

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Upstream C API нестабилен и не должен распространяться по Swift-коду.
- **Решение:** Все C-вызовы, opaque handles, lifecycle и callbacks изолируются в `GhosttyBridge`.
- **Отклонено:** Прямые вызовы C API из controllers/views; дополнительный protocol, полностью дублирующий bridge.
- **Последствия:** Изменения upstream локализованы; чистая модель оперирует `paneID` и командами.

## Целевая платформа и поставка

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** MVP оптимизируется для современного Apple Silicon Mac и прямой поставки.
- **Решение:** macOS 15+, arm64, генерация проекта через XcodeGen, подписанный и notarized DMG.
- **Отклонено:** Intel, Universal Binary, Mac App Store, sandbox-first сборка.
- **Последствия:** MVP не использует sandbox/App Store; signing и notarization обязательны для релиза DMG.

## Одно окно и взаимоисключающие presentation modes

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Normal и Quake должны показывать те же запущенные sessions без потери процессов.
- **Решение:** Приложение имеет одно физическое окно; `normal` и `quake` взаимоисключающие. Существующий `WorkspaceViewController` переносится между контейнерами, normal frame сохраняется.
- **Отклонено:** Несколько обычных окон; одновременные normal и Quake окна; пересоздание panes/processes при переключении.
- **Последствия:** `PresentationController` обязан выполнять транзакционный переход и возвращаться в normal при ошибке.

## Runtime-модель workspaces

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Пользователь может иметь несколько workspaces, но окно показывает один.
- **Решение:** Неактивные workspaces остаются запущенными; tab принадлежит ровно одному workspace; identity — UUID, имя обязательно и уникально без учёта регистра.
- **Отклонено:** Имя как identity; остановка процессов при переключении workspace; одновременное отображение нескольких workspaces.
- **Последствия:** Перемещение tabs не перезапускает panes и процессы.

## Split-tree принадлежит приложению

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Splits должны участвовать в модели, навигации и восстановлении состояния.
- **Решение:** Каждый tab хранит бинарный `SplitNode`; UI splits управляется QuickTTY, а команды Ghostty маршрутизируются в модель.
- **Отклонено:** Делегирование split UI внутреннему UI Ghostty; плоский список panes.
- **Последствия:** Collapse, proportions, focus navigation и equalize тестируются как чистая модель.

## Broadcast только в текущем tab

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Panes могут использовать разные terminal keyboard modes.
- **Решение:** Каждая pane получает исходное logical keyboard/paste event; broadcast ограничен текущим tab и автоматически отключается при смене tab/workspace, restore или ошибке surface.
- **Отклонено:** Рассылка уже закодированных байтов; broadcast между tabs/workspaces; broadcast mouse, scroll, resize и UI-команд.
- **Последствия:** UI постоянно показывает состояние broadcast и отдельный focus indicator.

## Текстовый config поверх формата Ghostty

- **Дата:** 2026-07-14
- **Статус:** заменено ADR «Идентичность QuickTTY и чистый старт» от 2026-07-22; последующие пункты сохраняются только как историческая запись.
- **Контекст:** Нужны terminal-настройки Ghostty и небольшое пространство параметров GhostTerm.
- **Решение:** Читать `~/.config/ghostterm/config`; параметры `ghostterm-` обрабатывает `ConfigController`, остальные передаются в `libghostty`. Точечное изменение сохраняет комментарии и остальные строки.
- **Отклонено:** Settings UI в MVP; отдельный формат terminal themes; полная перегенерация config.
- **Последствия:** Ошибочный reload сохраняет последнюю валидную конфигурацию и показывает diagnostic banner.

## Сохранение описания состояния, но не живых процессов

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Layout должен восстанавливаться после запуска, но сохранение живых shell-сессий значительно усложняет MVP.
- **Решение:** Хранить versioned state в Application Support: workspaces, tabs, split-tree, cwd, startup commands, focus и normal frame; при запуске создавать новые процессы.
- **Отклонено:** Daemon/tmux для восстановления живых процессов; молчаливый повтор пользовательских команд.
- **Последствия:** Пользовательские команды требуют одного агрегированного подтверждения; migrations явные, запись atomic с debounce.

## Ghostty themes определяют terminal и chrome

- **Дата:** 2026-07-14
- **Статус:** принято
- **Контекст:** Терминал и chrome должны выглядеть согласованно без второго формата тем.
- **Решение:** Terminal palette и параметры берутся из Ghostty config; chrome использует фон активной темы и системные semantic colors.
- **Отклонено:** Собственный формат themes; жёстко заданная light/dark схема.
- **Последствия:** Appearance вычисляется по яркости фона; при разных split backgrounds используется верхняя pane у tab bar.

## Ошибка surface сохраняет pane и split layout

- **Дата:** 2026-07-22
- **Статус:** принято
- **Контекст:** Ошибка создания одной Ghostty surface при startup или restore не должна завершать приложение, уничтожать соседние sessions либо оставлять прозрачную пустую pane.
- **Решение:** `WorkspaceStore` остаётся источником identity/layout, а `WindowCoordinator` хранит неперсистентное failure-state по `PaneID`. Startup создаёт model-first tab, restore обрабатывает panes независимо. Retry создаёт fresh shell с тем же `PaneID` и saved CWD; Close Pane изменяет только модель и не создаёт replacement shell.
- **Отклонено:** Полный rollback restore; fatal startup alert для surface creation; synthetic error-tab после неудачного New Tab/Split; собственный render-failure callback без поддержки pinned Ghostty API.
- **Последствия:** Обычные New Tab/Split остаются транзакционными; persisted custom commands не запускаются при Retry; broadcast повреждённой tab сбрасывается; runtime render failures можно подключить позже только через реальный upstream signal.

## Идентичность QuickTTY и чистый старт

- **Дата:** 2026-07-22
- **Статус:** принято
- **Контекст:** Имя GhostTerm нельзя использовать: существуют точные терминальные продукты, включая пересечение на macOS и записи в npm/GitHub. GhostTTY также нельзя использовать: существует SSH honeypot с точным именем, а название легко спутать с Ghostty.
- **Решение:** Выбрать QuickTTY. Канонический config — `~/.config/quicktty/config`; только параметры с собственным префиксом `quicktty-` обрабатывает `ConfigController`, остальные передаются в `libghostty`. Чистый старт выбран намеренно: bundle `QuickTTY.app` с identity `com.dntsk.QuickTTY`, state `~/Library/Application Support/QuickTTY/state.json` и release identity `0.1.0-alpha.2` не читают, не переносят и не удаляют данные GhostTerm.
- **Отклонено:** GhostTerm и GhostTTY; миграция либо очистка существующих данных GhostTerm.
- **Последствия:** Исторические документы и артефакты GhostTerm неизменяемы, включая подписанный alpha.1; новые документы и будущие поставки используют QuickTTY.

## QuickTTY владеет всеми управляющими сочетаниями

- **Дата:** 2026-07-23
- **Статус:** принято
- **Контекст:** Жёстко заданные AppKit shortcuts и отдельная таблица Ghostty bindings создавали нескольких владельцев одного keyboard event, не позволяли безопасно применять изменения через hot reload и усложняли performable fallback.
- **Решение:** Локальные действия задаются стабильным typed registry `ShortcutAction` и конфигурируются повторяемой строкой `quicktty-shortcut`; global Quake toggle остаётся отдельным Carbon scope с той же grammar. Ghostty `keybind` не участвует в dispatch: top-level assignments молча фильтруются, а effective config завершается `keybind = clear`.
- **Отклонено:** Произвольные Ghostty action strings в пользовательском shortcut config; одновременное владение сочетаниями AppKit и Ghostty; пересоздание terminal surfaces при reload.
- **Последствия:** Last-valid и last-owner-wins semantics детерминированы, global chord имеет приоритет над local scope, Carbon replacement откатывается к последней успешной registration, а неназначенные события сохраняют normal terminal/IME path. Stateful terminal modes отложены до видимого состояния; Search остаётся следующей обязательной интеграцией.

## Ghostty владеет URL detection, highlight и click semantics

- **Дата:** 2026-07-23
- **Статус:** принято
- **Контекст:** URL regex, OSC 8 metadata, modifier gating, terminal-relative path resolution и решение о поглощении click уже реализованы в закреплённом Ghostty. Дублирование hit testing в QuickTTY нарушило бы terminal selection и TUI mouse reporting.
- **Решение:** QuickTTY обрабатывает только surface-targeted `mouse_shape` и app-lifetime `open_url`. Cursor хранится локально в `GhosttySurfaceView` и применяется через cursor rects; stable URL payload открывается узким injectable MainActor client по upstream macOS policy. `mouse_over_link`, preview UI и keyboard action `open-url` не добавляются; существующий `copy-url` не меняется.
- **Отклонено:** First-party URL parser/hit testing; preview popup/state; `NSCursor.push/pop/set`; allowlist URL schemes; новый shortcut для открытия ссылки.
- **Последствия:** `Cmd+hover`/`Cmd+click` полностью следуют detection Ghostty, custom schemes разрешены, accepted action не запускает Ghostty fallback второй раз, а cursor state и teardown изолированы по surface.
