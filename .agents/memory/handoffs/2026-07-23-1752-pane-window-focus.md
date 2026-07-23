# Handoff: active pane и window focus presentation

- **Дата:** 2026-07-23
- **Ветка:** master, HEAD `b7f8b89`
- **Статус дерева:** есть незакоммиченные feature, tests, plans и project memory; commit/push не выполнялись

## Выполнено

- Реализован дизайн `docs/plans/2026-07-23-pane-window-focus-design.md` по плану `docs/plans/2026-07-23-pane-window-focus.md`.
- Добавлен `GhosttySplitAppearance`: finalized `unfocused-split-opacity` преобразуется в overlay alpha, optional `unfocused-split-fill` использует terminal background как fallback; reload остаётся транзакционным.
- Active pane остаётся без overlay; остальные panes, включая failure placeholder, используют Ghostty-style dimming. Overlay не перехватывает input и не меняет layout. Pane border/frame полностью отсутствует.
- Custom tab/workspace chrome приглушается только в non-key window. Observable state безопасно перепривязывает window notifications при переносе одного `WorkspaceViewController` между Normal/Quake.
- Terminal text cursor не дублируется: существующий `ghostty_surface_set_focus` оставлен без изменений, pinned Ghostty сам показывает hollow non-blinking cursor при unfocused surface.
- Integrated review исправил единственный Important: palette initial frame/divider/failure placeholder обновляется при hot reload без replacement hosting controller или surfaces. Re-review — APPROVED, открытых Critical/Important нет.
- Первый разрешённый visual smoke отклонил 2px accent frame как слишком резкую, затем 1px gray frame как всё ещё раздражающую. Весь frame branch и split dependency от key state удалены; остаются только dimming, chrome и Ghostty cursor.

## Проверки

- Focused suites `GhosttyBridgeTests`, `GhosttySplitTreeViewTests`, `WorkspacePresentationTests`, `WindowCoordinatorConfigurationTests` — 182 теста, 0 failures.
- `make format` — PASS.
- `make lint` — PASS.
- `git diff --check` — PASS.
- Первый полный gate до visual adjustment — 569 тестов, 27 suites, 0 failures.
- Frameless focused suites — 70 тестов, 0 failures.
- Финальный `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check` после удаления frame — 569 тестов, 27 suites, 0 failures; `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.23_18-02-20-+0300.xcresult`.
- Pinned Ghostty и `GhosttySurfaceView` не изменены.

## Незавершённое

- Первый manual smoke выполнен на версии с frame; пользователь потребовал полностью убрать border.
- Пользователь подтвердил повторный visual smoke frameless Debug-сборки: итоговый dimming/chrome/cursor presentation одобрен.
- Commit и push не выполнялись.

## Следующий шаг

1. Commit и push выполнять только по отдельной прямой команде пользователя.

## Важный контекст

- `activePaneID`, `NSWindow.isKeyWindow` и terminal first responder намеренно независимы.
- Theme hot reload обязан обновлять split appearance/palette без пересоздания surfaces и transient PTY resize.
- Не менять pinned Ghostty или рисовать собственный terminal cursor.
