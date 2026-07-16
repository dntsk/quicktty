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

## Сочетания клавиш

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
```

Файл `.ghostty-effective-config` создаётся GhostTerm рядом с пользовательским config. Его не следует редактировать вручную.
