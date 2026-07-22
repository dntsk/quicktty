# Handoff: изоляция теста persistence CWD

- **Дата:** 2026-07-22
- **Ветка:** `rename/quicktty`
- **Статус дерева:** подготовлены тестовая правка и этот handoff к коммиту.

## Выполнено

- `QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift`: тест persistence CWD захватывает coordinator handler, отключает bridge handler до delivery runtime-событий и вызывает захваченный handler синхронно.
- Assertions проверяют raw committed `workspaceStoreForTesting`; stale callback вызывается после очистки surface map.

## Проверки

- `swift format format --in-place QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift` — успешно.
- `swift format lint QuickTTYTests/Presentation/WindowCoordinatorTabLifecycleTests.swift` — успешно.
- Точный тест — 30/30 успешных запусков, в каждом выбран 1 тест.
- `WindowCoordinatorTabLifecycleTests` — 3/3 успешных запуска, по 52 теста.
- `make test` — 2/2 успешно, 452 теста.
- `make check` — успешно, 452 теста.
- `git diff --check` — успешно.

## Незавершённое

- Нет.

## Следующий шаг

1. Изменение готово к использованию после коммита.

## Важный контекст

- Нестабильность вызывала асинхронная OSC7 PWD от реальных PTY после восстановления nonexistent CWD; production-обработка latest event не менялась.
