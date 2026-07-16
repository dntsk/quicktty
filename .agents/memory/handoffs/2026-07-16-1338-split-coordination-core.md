# Handoff: pure split coordination core

- **Дата:** 2026-07-16
- **Ветка:** `agent/split-core`
- **Статус дерева:** изменения подготовлены к коммиту

## Выполнено

- Добавлены pure `SplitCommand`, `SplitFocusDirection`, `SplitDelta`, typed `SplitCoordinatorError`.
- `SplitCoordinator` транзакционно изменяет `WorkspaceStore` через существующие atomic API `TerminalTab`.
- Реализованы split, close/collapse с закрытием tab для последней pane, ratio clamp, recursive equalize, последовательный и геометрический directional focus.
- Добавлены точные тесты nested layout, focus, ratio, equalize, close-last и atomic errors.

## Проверки

- Временный SwiftPM harness: `xcrun swift test --filter SplitCoordinatorTests` — 8 тестов PASS.
- `swift format lint` для трёх новых Swift-файлов — PASS.
- `git diff --check` — PASS.

## Незавершённое

- AppKit controllers и интеграция с `WorkspaceViewController`/`WindowCoordinator` не выполнялись по границам lane.
- Полный project test не запускался: submodule `Vendor/ghostty` в worktree не инициализирован.

## Следующий шаг

1. UI lane строит recursive presenter по `SplitDelta.root` и создаёт/закрывает surfaces по `newPane.id`/`paneID`.

## Важный контекст

- `.horizontal` моделируется по оси X (left/right), `.vertical` — по оси Y (top/down).
- Deltas содержат только Swift IDs/descriptors/tree, без AppKit и C handles.
