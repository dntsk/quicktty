# Справочник конфигурации QuickTTY

Пользовательский файл находится по адресу `~/.config/quicktty/config`. Строки без префикса `quicktty-` передаются Ghostty, кроме пользовательских `keybind`, описанных ниже. Изменения применяются без перезапуска terminal surfaces и shell-процессов; при ошибке продолжает действовать последняя валидная конфигурация.

## Параметры QuickTTY

### `quicktty-presentation-mode`

Режим окна при запуске: `normal` или `quake`. Значение по умолчанию — `normal`.

### `quicktty-global-toggle`

Глобальная комбинация показа и скрытия Quake-окна. Использует полную грамматику сочетаний из раздела ниже, но регистрируется отдельно от локальных действий через Carbon. Значение по умолчанию — `f12`.

### `quicktty-shortcut`

Повторяемая инструкция для локальных сочетаний:

```ini
quicktty-shortcut = action-id=cmd+key
quicktty-shortcut = action-id=disabled
```

`action-id` берётся из полного registry ниже. `disabled` явно снимает сочетание с действия.

### `quicktty-quake-height`

Доля высоты доступной области экрана. Допустимы доля `0...1` или проценты `1%...100%`. Значение по умолчанию — `75%`.

### `quicktty-quake-animation-duration`

Длительность анимации в секундах, неотрицательное число. Значение по умолчанию — `0.18`.

### `quicktty-quake-padding`

Внутренний отступ Quake-окна в points, неотрицательное число. Значение по умолчанию — `0`.

### `quicktty-hide-on-focus-loss`

Скрывать Quake-окно после потери фокуса: `true` или `false`. Значение по умолчанию — `true`.

### `quicktty-restore-workspaces`

Восстанавливать сохранённые рабочие пространства при следующем запуске: `true` или `false`. Значение по умолчанию — `true`. При `false` QuickTTY открывает новое рабочее пространство Default; восстановление рамки окна при этом сохраняется.

### `quicktty-config-editor`

Команда терминального редактора для конфигурации, включая аргументы, например `code --wait`. Значение по умолчанию — `nano`. Действие `open-config` открывает файл в новой вкладке терминала.

## Грамматика сочетаний

Сочетание состоит из необязательных модификаторов и ровно одной клавиши через `+`. Порядок модификаторов при чтении не важен; канонический порядок — `cmd+opt+ctrl+shift+key`. Повтор модификатора, пустой компонент, несколько клавиш, неизвестный token и буквальный знак пунктуации не допускаются. Сочетание без модификаторов допустимо, например `f12` или `space`.

Модификаторы:

- `cmd`;
- `opt`;
- `ctrl`;
- `shift`.

Клавиши:

- буквы `a`…`z`;
- цифры `0`…`9`;
- функциональные клавиши `f1`…`f20`;
- стрелки `left`, `right`, `up`, `down`;
- навигация `home`, `end`, `page-up`, `page-down`;
- специальные клавиши `tab`, `enter`, `escape`, `space`, `delete`, `forward-delete`;
- пунктуация `grave`, `minus`, `equal`, `left-bracket`, `right-bracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash`.

## Registry действий и значения по умолчанию

Global Quake toggle не входит в локальный registry; его default — `quicktty-global-toggle = f12`.

### Приложение

| Action ID | Default |
|---|---|
| `quit` | `cmd+q` |
| `open-config` | `cmd+comma` |
| `toggle-presentation` | `cmd+opt+p` |

### Вкладки и panes

| Action ID | Default |
|---|---|
| `new-tab` | `cmd+t` |
| `close-pane` | `cmd+w` |
| `close-tab` | `cmd+opt+w` |
| `split-right` | `cmd+d` |
| `split-down` | `cmd+shift+d` |
| `previous-pane` | `cmd+left-bracket` |
| `next-pane` | `cmd+right-bracket` |
| `focus-left` | `cmd+opt+left` |
| `focus-right` | `cmd+opt+right` |
| `focus-up` | `cmd+opt+up` |
| `focus-down` | `cmd+opt+down` |
| `select-tab-1` | `cmd+1` |
| `select-tab-2` | `cmd+2` |
| `select-tab-3` | `cmd+3` |
| `select-tab-4` | `cmd+4` |
| `select-tab-5` | `cmd+5` |
| `select-tab-6` | `cmd+6` |
| `select-tab-7` | `cmd+7` |
| `select-tab-8` | `cmd+8` |
| `select-tab-9` | `cmd+9` |
| `toggle-broadcast` | `cmd+b` |

### Workspaces

| Action ID | Default |
|---|---|
| `new-workspace` | `disabled` |
| `rename-workspace` | `disabled` |
| `delete-workspace` | `disabled` |
| `select-workspace-1` | `cmd+opt+1` |
| `select-workspace-2` | `cmd+opt+2` |
| `select-workspace-3` | `cmd+opt+3` |
| `select-workspace-4` | `cmd+opt+4` |
| `select-workspace-5` | `cmd+opt+5` |
| `select-workspace-6` | `cmd+opt+6` |
| `select-workspace-7` | `cmd+opt+7` |
| `select-workspace-8` | `cmd+opt+8` |
| `select-workspace-9` | `cmd+opt+9` |

### Terminal actions

| Action ID | Default | Fixed Ghostty core action |
|---|---|---|
| `copy` | `cmd+c` | `copy_to_clipboard` |
| `paste` | `cmd+v` | `paste_from_clipboard` |
| `paste-selection` | `cmd+shift+v` | `paste_from_selection` |
| `select-all` | `cmd+a` | `select_all` |
| `copy-url` | `disabled` | `copy_url_to_clipboard` |
| `clear-screen` | `cmd+k` | `clear_screen` |
| `reset-terminal` | `disabled` | `reset` |
| `font-increase` | `cmd+equal` | `increase_font_size:1` |
| `font-decrease` | `cmd+minus` | `decrease_font_size:1` |
| `font-reset` | `cmd+0` | `reset_font_size` |
| `scroll-top` | `cmd+home` | `scroll_to_top` |
| `scroll-bottom` | `cmd+end` | `scroll_to_bottom` |
| `scroll-page-up` | `cmd+page-up` | `scroll_page_up` |
| `scroll-page-down` | `cmd+page-down` | `scroll_page_down` |
| `scroll-to-selection` | `cmd+j` | `scroll_to_selection` |
| `previous-prompt` | `cmd+shift+up` | `jump_to_prompt:-1` |
| `next-prompt` | `cmd+shift+down` | `jump_to_prompt:1` |
| `selection-left` | `shift+left` | `adjust_selection:left` |
| `selection-right` | `shift+right` | `adjust_selection:right` |
| `selection-up` | `shift+up` | `adjust_selection:up` |
| `selection-down` | `shift+down` | `adjust_selection:down` |
| `selection-page-up` | `shift+page-up` | `adjust_selection:page_up` |
| `selection-page-down` | `shift+page-down` | `adjust_selection:page_down` |
| `selection-home` | `shift+home` | `adjust_selection:home` |
| `selection-end` | `shift+end` | `adjust_selection:end` |

QuickTTY принимает только этот typed allowlist и не принимает произвольные строки Ghostty actions.

## Последовательное применение и конфликты

Parsing каждого config начинается со встроенных defaults и обрабатывает `quicktty-shortcut` сверху вниз.

- Последняя валидная инструкция для action заменяет его предыдущее значение; `disabled` является валидным значением.
- Unknown action, malformed instruction и invalid chord дают diagnostic, но не блокируют остальные валидные строки.
- При hot reload невалидная строка известного action сохраняет последнее активное значение этого action; при первом запуске сохраняется default.
- Если все строки action удалены из config, action возвращается к default.
- Если chord уже принадлежит другому локальному action, последний валидный владелец получает chord, предыдущий становится `disabled`; diagnostic называет chord и оба action ID.

Глобальное сочетание имеет приоритет над локальным: конфликтующий local action становится `disabled`. В Quake-режиме замена Carbon registration транзакционна. Если новое глобальное сочетание не регистрируется, QuickTTY восстанавливает последнюю успешную registration, продолжает применять остальные config-изменения и резервирует восстановленное глобальное сочетание перед публикацией локальной карты. Конфликтующее с новым настроенным global сочетанием local action остаётся отключённым до следующего reload.

## Keyboard boundary Ghostty

Пользовательские top-level `keybind = ...` молча исключаются из generated effective config и не создают diagnostics. В конце effective config после остальных параметров и `include` QuickTTY всегда записывает:

```ini
keybind = clear
```

Эта финальная строка очищает встроенные Ghostty bindings и bindings из include-файлов. Неназначенное QuickTTY keyboard event, включая обычный ввод, Ctrl-комбинации и IME, проходит в terminal input.

Terminal actions вызываются только через фиксированный typed allowlist. Если `copy`, `copy-url`, `clear-screen`, `scroll-to-selection` или одно из действий `selection-*` не может быть выполнено и Ghostty возвращает `false`, исходное событие не поглощается и продолжает normal terminal input path. `paste` и `paste-selection` используют broadcast только для panes активной вкладки; все остальные terminal actions выполняются только на focused pane. Hidden, inactive и закрытая surface не является shortcut target.

## Отложенные terminal actions

Stateful actions read-only, secure input и mouse reporting не экспортируются до появления видимого состояния, checked menu state и корректного lifecycle cleanup. Interactive Search и URL hover/open остаются обязательными следующими интеграциями; их требования зафиксированы в `docs/backlog.md` исходного проекта.

## Параметры Ghostty

### `copy-on-select`

QuickTTY по умолчанию использует `copy-on-select = clipboard`, чтобы копирование по выделению помещало текст в обычный системный буфер обмена. Укажите `copy-on-select = false`, чтобы отключить это поведение; любое явное значение пользователя, включая `true` и `clipboard`, сохраняется без изменений.

## Пример

```text
theme = catppuccin-mocha
font-size = 14

quicktty-presentation-mode = quake
quicktty-global-toggle = f12
quicktty-shortcut = new-tab=cmd+t
quicktty-shortcut = toggle-broadcast=disabled
quicktty-shortcut = clear-screen=ctrl+l
quicktty-quake-height = 75%
quicktty-quake-animation-duration = 0.18
quicktty-quake-padding = 0
quicktty-hide-on-focus-loss = true
quicktty-restore-workspaces = true
quicktty-config-editor = nano

copy-on-select = clipboard
```

Файл `.ghostty-effective-config` создаётся QuickTTY рядом с пользовательским config. Его не следует редактировать вручную.
