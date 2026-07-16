# Handoff: сохранение высоты Quake

- **Дата:** 2026-07-16
- **Ветка:** agent/quake-tabs-polish
- **Статус дерева:** есть незакоммиченные изменения перед коммитом

## Выполнено

- Добавлены `ConfigDocument.formattedQuakeHeight(_:)`, `setQuakeHeight(_:)` и `ConfigController.updateQuakeHeight(_:)`.
- Последний `ghostterm-quake-height` обновляется с сохранением CRLF, комментария и остальных bytes.
- Update записывает source атомарно, затем транзакционно применяет документ; тест покрывает откат active/effective config при ошибке bridge.

## Проверки

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make format` — успешно.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint` — успешно.
- Focused `ConfigDocumentTests` и `ConfigControllerTests` — 15 тестов passed.

## Незавершённое

- Нет; требуется только проверить diff и создать разрешённый коммит `feat: persist resized Quake height`.

## Следующий шаг

1. Закоммитить проверенные изменения без push.

## Важный контекст

- Wiring из `AppDelegate` намеренно не менялся: это Task 2.
- `updateQuakeHeight` повторяет порядок `updatePresentationMode`: read → mutate → atomic source write → `apply`.
