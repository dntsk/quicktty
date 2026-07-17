# Справочник конфигурации GhostTerm

Пользовательский файл находится по адресу `~/.config/ghostterm/config`. Строки без префикса `ghostterm-` передаются Ghostty. Изменения применяются без перезапуска shell-процессов; при ошибке продолжает действовать последняя валидная конфигурация.

## Параметры GhostTerm

### `ghostterm-presentation-mode`

Режим окна при запуске: `normal` или `quake`. Значение по умолчанию — `normal`.

### `ghostterm-global-toggle`

Глобальная комбинация показа и скрытия Quake-окна. Формат: функциональная клавиша `f1`…`f20` с необязательными модификаторами `cmd`, `opt`, `ctrl`, `shift` через `+`. Значение по умолчанию — `f12`.

### `ghostterm-quake-height`

Доля высоты доступной области экрана. Допустимы доля `0...1` или проценты `1%...100%`. Значение по умолчанию — `75%`.

### `ghostterm-quake-animation-duration`

Длительность анимации в секундах, неотрицательное число. Значение по умолчанию — `0.18`.

### `ghostterm-quake-padding`

Внутренний отступ Quake-окна в points, неотрицательное число. Значение по умолчанию — `0`.

### `ghostterm-hide-on-focus-loss`

Скрывать Quake-окно после потери фокуса: `true` или `false`. Значение по умолчанию — `true`.

### `ghostterm-restore-workspaces`

Восстанавливать сохранённые рабочие пространства при следующем запуске: `true` или `false`. Значение по умолчанию — `true`. При `false` GhostTerm открывает новое рабочее пространство Default; восстановление рамки окна при этом сохраняется.

### `ghostterm-config-editor`

Команда терминального редактора для конфигурации, включая аргументы, например `code --wait`. Значение по умолчанию — `nano`. Сочетание `Cmd+,` открывает файл в новой вкладке терминала.

## Параметры Ghostty

### `copy-on-select`

GhostTerm по умолчанию использует `copy-on-select = clipboard`, чтобы копирование по выделению помещало текст в обычный системный буфер обмена. Укажите `copy-on-select = false`, чтобы отключить это поведение; любое явное значение пользователя, включая `true` и `clipboard`, сохраняется без изменений.

## Сочетания клавиш

- `Cmd+,` — открыть конфигурацию в новой вкладке терминала.
- `Cmd+B` — включить или выключить broadcast-ввод для текущей вкладки.

## Пример

```text
theme = catppuccin-mocha
font-size = 14

ghostterm-presentation-mode = quake
ghostterm-global-toggle = f12
ghostterm-quake-height = 75%
ghostterm-quake-animation-duration = 0.18
ghostterm-quake-padding = 0
ghostterm-hide-on-focus-loss = true
ghostterm-restore-workspaces = true
ghostterm-config-editor = nano

copy-on-select = clipboard
```

Файл `.ghostty-effective-config` создаётся GhostTerm рядом с пользовательским config. Его не следует редактировать вручную.
