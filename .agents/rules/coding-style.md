# Стиль кода

## Форматирование и линт

- Использовать Apple `swift-format` как единственный автоматический formatter/linter Swift.
- `make format` может изменять Swift-файлы; перед запуском проверять diff.
- `make lint` и `.agents/scripts/style-audit.sh` должны быть read-only.
- Перед завершением задачи запускать минимально релевантные тесты; перед выпуском — `make check`.

## Swift

- Соблюдать Swift strict concurrency без отключения диагностик на уровне target.
- UI-состояние, AppKit и `NSView` изолировать main actor/main thread.
- Значения, пересекающие actor/task boundary, должны иметь корректную `Sendable`-семантику.
- Не использовать `@unchecked Sendable`, `nonisolated(unsafe)` или подавление concurrency warnings без документированного инварианта и необходимости.
- Типы и protocols именовать `UpperCamelCase`; функции, свойства и локальные значения — `lowerCamelCase`.
- Предпочитать value types для чистой модели и явные UUID-based identity для workspace/tab/pane.
- Не добавлять абстракции, wrappers и protocols без реальной границы или тестовой потребности.
- Не менять публичный API без необходимости задачи.

## AppKit и модель

- Views/controllers не должны напрямую вызывать C API Ghostty.
- UI-команды сначала изменяют модель; terminal input маршрутизируется по `paneID` через production coordinator в `GhosttyBridge`.
- Чистая модель не импортирует AppKit, renderer или upstream C headers.
- События broadcast передавать как logical input events, а не как байты активной pane.

## C interop

- Любые C handles, pointers, callbacks и преобразования upstream типов держать внутри `GhosttyBridge`.
- Явно соблюдать ownership и teardown закреплённой ревизии `libghostty`.
- Не предполагать стабильность upstream C API и не распространять его типы по приложению.

## Комментарии и документация

- Комментарии в коде писать только на английском.
- Комментировать причину или неочевидный инвариант, а не пересказывать код.
- Project documentation и project memory писать на русском.
- Не оставлять закомментированный код, временные debug prints и маркеры без связанной задачи.

## Тесты

- Чистую модель покрывать unit tests без renderer и процессов.
- Контракт `GhosttyBridge` проверять integration tests с настоящей библиотекой.
- Concurrency-sensitive поведение тестировать детерминированно; не заменять синхронизацию произвольными задержками.
- При исправлении дефекта сначала добавлять воспроизводящий тест, если слой допускает автоматизацию.
