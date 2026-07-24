# Интеграции с агентами

QuickTTY показывает состояние агента по стандартным terminal progress sequences OSC `9;4`. Настройка выполняется вручную: приложение не устанавливает hooks, не изменяет конфигурацию агента и не запускает команды интеграции автоматически.

Bundled-файлы находятся в установленном приложении:

```text
/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/
```

Если QuickTTY установлен не в `/Applications`, замените этот префикс во всех командах. Пути в JSON-примерах намеренно заключены в кавычки. Существующую конфигурацию нужно **объединить** с примером вручную; не заменяйте файл целиком.

## Pi 0.82

Pi поддерживает progress sequences без hooks и helper-скрипта. Откройте `/settings`, найдите **Terminal progress** и включите параметр `terminal.showTerminalProgress` (по умолчанию он выключен).

При включённом параметре Pi отправляет OSC `9;4;3` при `agent_start`, продолжает keepalive во время работы и отправляет OSC `9;4;0` при `agent_end`. Расширение Pi, разбор заголовка терминала или дополнительные hooks не нужны.

## Claude Code 2.1.141+

Claude Code запускает command hooks без controlling TTY. Поэтому helper в режиме `claude` не пишет в `/dev/tty`, а печатает в stdout единственный валидный JSON-объект с allowlisted universal field `terminalSequence`. JSON декодируется в точную OSC-последовательность; другого stdout нет.

Вручную объедините содержимое bundled-файла `claude-settings.example.json` с top-level объектом `hooks` в существующих settings Claude Code. Пример использует:

- `UserPromptSubmit` → `working`;
- `PermissionRequest` → `waiting`;
- `Notification` с matcher `permission_prompt|idle_prompt|agent_needs_input` → `waiting`;
- `PostToolUse` и `PostToolUseFailure` → `working`;
- `Stop` и `SessionEnd` → `completed` (удалить progress indication);
- `StopFailure` → `failed`.

Каждая команда вызывает quoted helper, например:

```text
"/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/quicktty-progress" claude waiting
```

Hook не читает stdin, prompt, transcript или environment secrets.

## Codex

Вручную объедините содержимое bundled-файла `codex-hooks.example.json` с top-level объектом `hooks` существующего `hooks.json`. Соответствия в примере:

- `UserPromptSubmit` → `working`;
- `PermissionRequest` → `waiting`;
- `PostToolUse` → `working`;
- `Stop` и `SessionEnd` → `completed` (удалить progress indication).

Codex сохраняет controlling terminal для hook subprocess. Поэтому режим `codex` пишет OSC непосредственно в `/dev/tty`, а в stdout печатает ровно `{}` — в частности, `Stop` всегда получает валидный JSON. Если `/dev/tty` недоступен, helper не блокирует агента: он всё равно печатает `{}` и завершается успешно.

Пример команды:

```text
"/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/quicktty-progress" codex working
```

Hook не читает stdin, prompt, transcript или environment secrets.

## Контракт helper

Поддерживаются только вызовы:

```text
quicktty-progress claude working|waiting|failed|completed
quicktty-progress codex working|waiting|failed|completed
```

Состояния соответствуют OSC `9;4`: `working` → `3`, `waiting` → `4`, `failed` → `2`, `completed` → `0`. Неизвестный режим, состояние или лишний аргумент дают ненулевой exit status. Скрипт не получает содержимое диалога и не требует новых зависимостей.
