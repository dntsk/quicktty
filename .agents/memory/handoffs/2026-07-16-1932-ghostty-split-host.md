# Handoff: Ghostty SplitView host

- **Дата:** 2026-07-16
- **Ветка:** `main`
- **Статус дерева:** Task 1 готова к коммиту

## Выполнено

- В target `GhostTerm` напрямую добавлены закреплённые `SplitView.swift`, `SplitView.Divider.swift` и `Backport.swift` из `Vendor/ghostty`.
- Добавлен рекурсивный first-party `GhosttySplitTreeView`: существующие `GhosttySurfaceView` возвращаются через `NSViewRepresentable`, отсутствующие поверхности отображаются пустым diagnostic placeholder.
- `WorkspaceViewController` удерживает один `NSHostingController` и обновляет его `rootView`; пустое workspace удаляет host и показывает существующую метку.
- `WindowCoordinator` передаёт корень активной вкладки и реестр поверхностей. Обработчики resize/equalize пока намеренно no-op до Task 2.
- Добавлены тесты descriptor/callback/identity host и обновлён presentation test.

## Проверки

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make format` — пройдено.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint` — пройдено.
- Focused `GhosttySplitTreeViewTests` и `WorkspacePresentationTests` — 14 тестов пройдены.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build` — пройдено.
- `git -C Vendor/ghostty status --porcelain=v1` — пустой вывод.

## Незавершённое

- Task 2 должна подключить callbacks resize/equalize к `SplitCoordinator` и lifecycle нескольких surface.
- Runtime-команды и shortcut остаются задачей 3.

## Следующий шаг

1. Реализовать Task 2 из `docs/plans/2026-07-14-upstream-ghostty-splits.md`.
