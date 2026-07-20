# Inline Config Diagnostics Design

## Goal

GhostTerm продолжает запускать shell и применять валидные настройки, когда отдельные `ghostterm-*` строки содержат ошибки. Ошибки показываются как read-only monospace block внутри terminal viewport без записи в PTY, изменения shell command или загрязнения history.

## Configuration semantics

`ConfigDocument` уже разбирает GhostTerm assignments построчно и возвращает одновременно `GhostTermConfig` и `[ConfigDiagnostic]`. `ConfigController` перестаёт считать эти diagnostics fatal: валидные assignments применяются, ошибочные assignments игнорируются, а отсутствующее валидное значение остаётся default либо более ранним валидным assignment того же документа.

Все `ghostterm-*` строки, включая ошибочные, исключаются из generated Ghostty config. Поэтому неизвестная или malformed GhostTerm-строка не попадает в `libghostty`.

Ошибки Ghostty options остаются transactional. Если `libghostty` отклоняет effective config, GhostTerm сохраняет последнюю валидную runtime configuration и показывает текст ошибки. Автоматически удалять произвольные Ghostty-строки нельзя: pinned C API возвращает только diagnostic message, а не структурированный source range.

## Presentation

`WorkspaceViewController` владеет компактным diagnostic overlay над terminal content. Он использует monospaced system font, контрастный полупрозрачный фон и не принимает mouse events. Split tree и surfaces не пересоздаются и не меняют layout.

Overlay показывает config path и список сообщений. Чтобы не закрывать terminal полностью, отображаются первые восемь diagnostics и строка с количеством остальных. Пустой список скрывает overlay.

## Data flow

`ConfigController` получает отдельный `onDiagnostics([ConfigDiagnostic])` callback и вызывает его после успешного применения Ghostty configuration. Пустой список означает, что предыдущий warning можно убрать.

Fatal read/write/watcher/Ghostty reload errors продолжают приходить через `onError`. `AppDelegate` преобразует оба callback в presentation model с config path. Если `WindowCoordinator` ещё не создан, model хранится как pending и применяется после startup. `WindowCoordinator` только передаёт immutable presentation в `WorkspaceViewController`; terminal runtime state не меняется.

## Testing

- invalid GhostTerm lines больше не отклоняют reload;
- valid values из того же документа применяются;
- invalid GhostTerm lines отсутствуют в effective Ghostty config;
- следующий valid reload очищает diagnostics;
- Ghostty reload failure сохраняет предыдущую configuration;
- overlay показывает path/messages, ограничивает длинный список и пропускает hit-testing;
- обновление/очистка overlay не пересоздаёт surfaces;
- startup pending diagnostic появляется после создания coordinator.
