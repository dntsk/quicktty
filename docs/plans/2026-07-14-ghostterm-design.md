# GhostTerm — дизайн MVP

Дата: 2026-07-14

## Цель

Создать нативный терминал для macOS с двумя взаимоисключающими режимами отображения, tabs, splits, workspaces, broadcast-вводом и поддержкой тем Ghostty.

## Ограничения MVP

- Только macOS 15+.
- Только Apple Silicon.
- Основная поставка — подписанный и notarized DMG.
- Одно физическое окно приложения.
- Несколько открытых workspaces, но одновременно отображается один.
- Режимы normal и Quake взаимоисключающие.
- Никакого сохранения живых процессов после перезапуска приложения.
- Текстовый конфиг без отдельного Settings UI.
- Терминальный движок — полная embedding-библиотека `libghostty`, зафиксированная на конкретной ревизии.

## Не входит в MVP

- Intel и Universal Binary.
- Mac App Store и sandbox-first сборка.
- Несколько обычных окон.
- Собственный VT parser, PTY layer или renderer.
- Broadcast между всеми tabs или workspaces.
- Восстановление живых shell-сессий через daemon или tmux.

## Технологический подход

Основное приложение пишется на Swift и AppKit. AppKit управляет окном, responder chain, tabs, drag-and-drop, splits и Quake-анимацией.

`libghostty` отвечает за:

- PTY и дочерние процессы;
- VT/xterm-эмуляцию;
- terminal input;
- Metal-рендеринг;
- scrollback;
- terminal configuration;
- цветовые палитры и темы.

Полная библиотека используется вместо отдельного `libghostty-vt`, чтобы не реализовывать собственные PTY, renderer и font pipeline. Ревизия Ghostty фиксируется. Его нестабильный C API изолируется внутри `GhosttyBridge`.

Zig используется только как build tool для сборки библиотеки под arm64.

## Основные компоненты

### `GhosttyBridge`

Единственная точка взаимодействия Swift-кода с C API Ghostty:

- lifecycle engine и config;
- создание и уничтожение terminal surfaces;
- keyboard, mouse и paste events;
- resize;
- config reload;
- runtime callbacks;
- завершение дочернего процесса;
- получение cwd и terminal metadata.

Opaque C handles не выходят за пределы bridge. AppKit и `NSView` используются только на main thread.

### `WorkspaceStore`

Хранит список workspaces, активный workspace и управляет сохранением состояния.

### `WorkspaceSession`

Runtime-состояние workspace. Неактивные workspaces остаются запущенными до завершения приложения.

### `TerminalTab`

Содержит корневой `SplitNode`, заголовок, порядок и состояние broadcast.

### `SplitNode`

Бинарное дерево:

- leaf — terminal pane;
- branch — horizontal или vertical split с пропорцией.

Закрытие leaf сворачивает освободившуюся ветку. Изменение размера обновляет пропорцию.

### `TerminalPane`

Связывает pane identity, session descriptor и surface из `GhosttyBridge`.

### `WindowCoordinator`

Управляет единственным окном, tab bar, workspace selector и текущим `WorkspaceViewController`.

### `PresentationController`

Управляет взаимоисключающими режимами `normal` и `quake`, переносит существующий `WorkspaceViewController` между оконными контейнерами и сохраняет normal window frame.

### `ConfigController`

Читает пользовательский config, выделяет параметры GhostTerm, передаёт terminal-настройки в `libghostty`, следит за изменениями файла и сохраняет presentation mode.

## Модель окна и workspaces

В приложении существует одно физическое окно. Оно отображает один активный workspace.

Workspaces может быть несколько. Каждый содержит собственные tabs, panes и процессы. При переключении workspace предыдущий скрывается, но его процессы продолжают работать.

При первом запуске создаётся workspace `Default`.

Имена workspaces:

- обязательны;
- уникальны без учёта регистра;
- могут быть переименованы;
- не являются identity — внутренние связи используют UUID.

Workspace selector расположен слева от строки tabs.

## Tabs и создание workspaces

Строка tabs поддерживает:

- обычный выбор активного tab;
- `Command+Click` для множественного выбора;
- `Shift+Click` для выбора диапазона;
- drag-and-drop для изменения порядка;
- контекстное меню для перемещения.

Команда `Move to New Workspace…`:

1. Получает выбранные tabs.
2. Показывает диалог с обязательным именем.
3. Проверяет уникальность без учёта регистра.
4. Создаёт workspace.
5. Перемещает tabs без перезапуска panes и процессов.
6. Делает новый workspace активным.

Tab принадлежит ровно одному workspace.

## Splits

Каждый tab содержит собственное split-tree. Поддерживаются:

- horizontal split;
- vertical split;
- изменение пропорций мышью;
- переключение фокуса по направлениям;
- переход к следующей и предыдущей pane;
- equalize splits;
- закрытие pane.

Команды split, пришедшие из `libghostty`, маршрутизируются в модель приложения. UI splits не делегируется внутреннему UI Ghostty.

## Broadcast

Broadcast действует только внутри текущего tab.

При включении:

- tab bar показывает постоянный индикатор;
- область tab получает заметную рамку;
- исходные keyboard events отправляются каждой pane;
- paste подтверждается один раз и передаётся каждой pane;
- активная pane продолжает иметь отдельный focus indicator.

Каждая surface получает исходное logical input event, а не байты, закодированные для активной pane. Это необходимо, потому что panes могут использовать разные terminal keyboard modes.

Не транслируются:

- mouse events;
- scroll;
- resize;
- команды интерфейса;
- создание и закрытие splits.

Broadcast автоматически отключается при:

- переходе на другой tab;
- переключении workspace;
- восстановлении приложения;
- ошибке одной из surfaces.

## Presentation modes

### Normal

Стандартное macOS-окно с title bar, resize, minimize и сохранением последней геометрии.

### Quake

Окно:

- появляется на дисплее под курсором;
- занимает всю ширину `visibleFrame`;
- имеет высоту 75% по умолчанию;
- располагается под menu bar;
- находится выше обычных окон;
- доступно на текущем Space;
- получает keyboard focus после появления;
- выдвигается сверху;
- возвращает focus предыдущему приложению после скрытия.

Окно скрывается:

- повторным глобальным hotkey;
- при потере focus.

Автоскрытие выполняется с короткой задержкой и отменяется, если открыт menu, sheet или системный диалог.

Высота, animation duration, отступы и hide-on-focus-loss задаются в конфиге.

### Переключение режима

Команда `toggle_presentation_mode` переключает `normal ↔ quake` без перезапуска shell-процессов.

При переходе в Quake сохраняется normal window frame. `WorkspaceViewController` переносится в Quake window container. При возврате normal frame восстанавливается.

Новый режим сразу записывается в config и используется при следующем запуске.

Глобальный hotkey показа и скрытия регистрируется только в Quake-режиме. Конфликт hotkey показывает ошибку, но не завершает приложение.

Если переход в Quake не удался, приложение возвращается в normal и не сохраняет ошибочный режим.

## Конфигурация

Пользовательский файл:

`~/.config/ghostterm/config`

Формат основан на Ghostty. Параметры с префиксом `ghostterm-` обрабатывает `ConfigController`; остальные terminal-параметры передаются в `libghostty`.

При первом запуске создаётся короткий starter config, содержащий:

- основные terminal-настройки;
- все параметры GhostTerm;
- фактические значения по умолчанию;
- краткие комментарии;
- указание на встроенный справочник.

Полный список параметров Ghostty автоматически не генерируется.

Команды меню:

- `GhostTerm → Open Config`;
- `Help → Configuration Reference`;
- `Help → Reveal Example Config`.

Полный справочник GhostTerm поставляется внутри `.app` и доступен без интернета.

Переключение presentation mode изменяет только параметр `ghostterm-presentation-mode`, не удаляя комментарии и не переформатируя остальные строки.

Config reload применяется ко всем существующим surfaces без перезапуска shell.

При ошибке reload продолжает действовать последняя валидная версия. Над tab bar показывается diagnostic banner с файлом и строкой ошибки.

## Сохранение состояния

Автоматическое состояние хранится отдельно от пользовательского config:

`~/Library/Application Support/GhostTerm/state.json`

Сохраняются:

- версия формата;
- UUID и имя workspace;
- порядок tabs;
- split-tree и пропорции;
- cwd каждой pane;
- описание стартовой команды;
- активные workspace, tab и pane;
- normal window frame.

Состояние записывается с debounce и atomic replace.

Если сохранённый cwd отсутствует, shell без предупреждения запускается в домашнем каталоге.

Обычные shell восстанавливаются автоматически. Перед восстановлением пользовательских команд показывается одно подтверждение со списком команд. Отклонённые команды заменяются обычным shell в соответствующем cwd.

Повреждённый state-файл переименовывается в backup, после чего создаётся workspace `Default`. Неизвестные поля игнорируются; версии формата мигрируются явно.

## Завершение процессов

После завершения shell pane сразу закрывается.

- Последняя pane закрывает tab.
- Последний tab active workspace закрывает normal-окно.
- В Quake-режиме последний tab скрывает окно.
- Следующий вызов пустого Quake-окна создаёт новый shell.

Закрытие pane с активным foreground process требует подтверждения. Массовое закрытие tab или workspace использует одно агрегированное подтверждение.

## Темы и UI chrome

Terminal palette, font, cursor, background opacity и ANSI colors берутся из Ghostty config. Отдельный формат terminal themes не вводится.

UI использует гибридный подход, аналогичный Ghostty:

- фон tab bar и workspace selector берётся из фона активной terminal theme;
- light/dark AppKit appearance определяется по яркости фона;
- текст и icons используют системные semantic colors;
- broadcast indicator использует отдельный контрастный accent.

При split с разными backgrounds фон chrome выбирается по верхней pane, граничащей с tab bar.

## Обработка ошибок

- Ошибка config reload сохраняет последнюю валидную конфигурацию.
- Ошибка одной surface показывает placeholder с `Retry` и `Close Pane`.
- Ошибка инициализации `libghostty` показывает отдельное error window и путь к логам.
- Конфликт global hotkey не завершает приложение.
- Ошибка Quake transition возвращает приложение в normal mode.
- Broadcast всегда выключается при ошибке одной из целевых surfaces.

## Поток команд

1. AppKit получает user event.
2. `WindowCoordinator` определяет, является ли event командой интерфейса.
3. UI-команда изменяет workspace/tab/split model.
4. Terminal input получает список целевых `paneID`.
5. Production coordinator находит surfaces и напрямую вызывает `GhosttyBridge`.
6. Runtime callbacks Ghostty преобразуются обратно в model commands.
7. Изменение модели обновляет UI и планирует сохранение state.

Дополнительный protocol, дублирующий `GhosttyBridge`, не вводится. Чистая модель не зависит от renderer и возвращает команды с `paneID`.

## Тестирование

### Unit tests

- split-tree: split, close, resize и collapse;
- перемещение выбранных tabs;
- уникальность workspace names;
- порядок tabs и восстановление focus;
- broadcast target selection и auto-disable;
- presentation state transitions;
- config parsing и точечное обновление строки;
- сохранение комментариев config;
- state serialization и migrations.

### Integration tests

Используется настоящий `GhosttyBridge`:

- engine и surface lifecycle;
- запуск короткой shell-команды;
- получение вывода;
- resize;
- process exit и автоматическое закрытие pane;
- config hot reload;
- theme update без перезапуска process.

### UI tests

- создание именованного workspace;
- проверка case-insensitive uniqueness;
- множественный выбор tabs;
- horizontal и vertical splits;
- переключение workspace;
- broadcast indicator;
- normal/Quake mode command.

### Ручные smoke tests

- global hotkey;
- hide on focus loss;
- Quake animation;
- выбор дисплея под курсором;
- подключение и отключение монитора;
- несколько одновременно выводящих panes;
- длительный scrollback;
- Unicode, emoji и IME;
- copy/paste и URLs;
- `ssh`, `tmux` и полноэкранные TUI;
- переход normal/Quake без потери процессов;
- подписанная и notarized сборка на чистом Mac.

## Критерий готовности MVP

MVP готов, когда Quake mode, normal mode, splits, broadcast текущего tab, tabs, именованные workspaces и Ghostty themes работают без потери shell-процессов при навигации и переключении presentation mode.
