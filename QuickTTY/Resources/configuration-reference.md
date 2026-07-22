# Справочник конфигурации QuickTTY

Пользовательский файл находится по адресу `~/.config/quicktty/config`. Строки без префикса `quicktty-` передаются Ghostty. Изменения применяются без перезапуска shell-процессов; при ошибке продолжает действовать последняя валидная конфигурация.

## Параметры QuickTTY

### `quicktty-presentation-mode`

Режим окна при запуске: `normal` или `quake`. Значение по умолчанию — `normal`.

### `quicktty-global-toggle`

Глобальная комбинация показа и скрытия Quake-окна. Формат: функциональная клавиша `f1`…`f20` с необязательными модификаторами `cmd`, `opt`, `ctrl`, `shift` через `+`. Значение по умолчанию — `f12`.

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

Команда терминального редактора для конфигурации, включая аргументы, например `code --wait`. Значение по умолчанию — `nano`. Сочетание `Cmd+,` открывает файл в новой вкладке терминала.

## Параметры Ghostty

### `copy-on-select`

QuickTTY по умолчанию использует `copy-on-select = clipboard`, чтобы копирование по выделению помещало текст в обычный системный буфер обмена. Укажите `copy-on-select = false`, чтобы отключить это поведение; любое явное значение пользователя, включая `true` и `clipboard`, сохраняется без изменений.

## Сочетания клавиш

- `Cmd+,` — открыть конфигурацию в новой вкладке терминала.
- `Cmd+B` — включить или выключить broadcast-ввод для текущей вкладки.
- `Cmd+Option+1`…`9` — переключиться на рабочее пространство с номером 1…9.

## Пример

```text
theme = catppuccin-mocha
font-size = 14

quicktty-presentation-mode = quake
quicktty-global-toggle = f12
quicktty-quake-height = 75%
quicktty-quake-animation-duration = 0.18
quicktty-quake-padding = 0
quicktty-hide-on-focus-loss = true
quicktty-restore-workspaces = true
quicktty-config-editor = nano

copy-on-select = clipboard
```

Файл `.ghostty-effective-config` создаётся QuickTTY рядом с пользовательским config. Его не следует редактировать вручную.
