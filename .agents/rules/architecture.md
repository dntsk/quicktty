# Архитектура

## Общая схема

GhostTerm разделяет чистую runtime-модель, AppKit presentation, persistence/config и интеграцию с терминальным движком. Главный принцип зависимости: нестабильный C API Ghostty заканчивается внутри `GhosttyBridge`; модель оперирует Swift-типами и `paneID`.

Поток команды:

1. AppKit получает событие пользователя.
2. `WindowCoordinator` отделяет UI-команду от terminal input.
3. UI-команда изменяет workspace/tab/split model.
4. Для terminal input определяется список целевых `paneID`.
5. Production coordinator находит surfaces и вызывает `GhosttyBridge`.
6. Runtime callbacks преобразуются bridge в команды модели.
7. Изменение модели обновляет UI и планирует сохранение state.

## Компоненты и ответственность

- `GhosttyBridge` — lifecycle engine/config/surfaces, input, resize, reload, callbacks, process exit, cwd и metadata.
- `WorkspaceStore` — список workspaces, active workspace и координация сохранения.
- `WorkspaceSession` — runtime-состояние workspace; скрытые sessions остаются запущенными.
- `TerminalTab` — root `SplitNode`, title, order и broadcast state.
- `SplitNode` — бинарное дерево leaf/branch с orientation и proportion.
- `TerminalPane` — связь identity, session descriptor и surface bridge.
- `WindowCoordinator` — единственное окно, tab bar, workspace selector и текущий workspace controller.
- `PresentationController` — взаимоисключающие normal/Quake transitions без пересоздания процессов.
- `ConfigController` — parsing GhostTerm-параметров, передача terminal config, reload и сохранение presentation mode.

## Направление зависимостей

- AppKit presentation зависит от модели и coordinators.
- Чистая модель не зависит от AppKit, Metal, Ghostty renderer или C API.
- Production coordinator связывает model identities с bridge surfaces.
- `GhosttyBridge` — единственный слой, зависящий от upstream C API.
- Persistence сериализует descriptors и layout, но не C handles и не живые процессы.
- Дополнительный protocol, дублирующий весь `GhosttyBridge`, не вводится.

## Инварианты MVP

- Одно физическое окно и один отображаемый workspace.
- Normal и Quake взаимоисключающие; переход сохраняет surfaces и shell-процессы.
- Workspaces могут быть скрыты, но продолжают работать до завершения приложения.
- Tab принадлежит ровно одному workspace; workspace identity основана на UUID, имя уникально без учёта регистра.
- Каждый tab имеет собственное split-tree; закрытие leaf сворачивает освободившуюся branch.
- Broadcast ограничен текущим tab и отключается при смене tab/workspace, restore и ошибке surface.
- Последняя pane закрывает tab; поведение последнего tab зависит от presentation mode.
- Живые процессы не переживают перезапуск приложения.

## Concurrency и UI

- AppKit, `NSView`, window/view-controller transitions и UI state выполняются на main thread.
- Runtime callbacks Ghostty не обращаются к UI до явного перехода в main-actor context.
- Teardown surface и обработка запоздалых callbacks должны соблюдать единый lifecycle-инвариант.
- Swift strict concurrency является обязательным ограничением, а не режимом best effort.

## Конфигурация и state

- Пользовательский config: `~/.config/ghostterm/config`.
- `ghostterm-` параметры принадлежат `ConfigController`; остальные terminal parameters передаются `libghostty`.
- Изменение presentation mode точечно меняет одну строку и сохраняет комментарии.
- Автоматический state: `~/Library/Application Support/GhostTerm/state.json`.
- State versioned, записывается через debounce и atomic replace; migrations явные, неизвестные поля игнорируются.
- В state сохраняются descriptors/layout/focus/frame, но не runtime handles.

## Границы MVP

Не добавлять без нового архитектурного решения:

- Intel/Universal Binary;
- sandbox или Mac App Store distribution;
- несколько обычных окон;
- собственный VT/PTY/renderer/font pipeline;
- broadcast между tabs/workspaces;
- daemon/tmux для сохранения живых sessions;
- Settings UI или отдельный формат themes.
