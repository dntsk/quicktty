# Handoff: workspace persistence и drag tabs

## Статус

Milestone реализован в `main`, push не выполнялся. Рабочее дерево перед handoff было чистым.

## Реализовано

- Runtime restore всех сохранённых workspaces, tabs, split trees, ratios, active IDs и CWD с новыми shell-процессами.
- Сохранённые custom commands не запускаются автоматически при restore.
- `ghostterm-restore-workspaces = true|false`, default `true`; `false` начинает новый `Default`, normal frame восстанавливается независимо.
- `ghostterm-config-editor = nano`; `Cmd+,` открывает `~/.config/ghostterm/config` в новом tab через настроенный terminal editor.
- Effective Ghostty default `copy-on-select = clipboard`; явная пользовательская настройка имеет приоритет; UTF-8 BOM сохраняется и корректно парсится.
- Все успешные изменения WorkspaceStore и live CWD сохраняются через существующий debounced atomic StateStore.
- Pending CWD синхронно попадает в final state при немедленном quit.
- Последняя завершившаяся pane заменяется shell атомарно, без промежуточного пустого snapshot.
- Workspace selector: New, Rename, Delete; новый workspace получает shell; последний удалить нельзя; непустой удаляется после одного предупреждения.
- Native drag tabs внутри workspace, включая multi-selection, no-op/rejection и persistence порядка.
- Production shutdown сначала сохраняет pending CWD, затем отсоединяет terminal views и surfaces, затем выключает GhosttyBridge.

## Ключевые commits

- `8f2f393` / `012e11b` — domain workspace mutations и coverage.
- `22b2300` / `7322c25` / `0d1c72e` — surface restore и безопасные lifecycle tests.
- `a2146a8` / `49fd7d2` / `d955512` — config options, copy-on-select и BOM.
- `d56d336` / `3a39b07` — Cmd-comma config editor.
- `2eca2d5` / `6c63544` / `6e489db` — runtime persistence, callback coverage, pending CWD и atomic replacement.
- `dc2ac53` / `6d7b93f` / `47bc78b` — workspace management UI и tests.
- `5bf65d6` / `08405a1` / `81f3937` — persistent tab drag и acceptance semantics.
- `a4e04a7` — production renderer teardown order.

## Проверки

- Final build: успешно.
- `make check`: 409 tests; 408 прошли.
- Единственное падение: существующий flaky `GhosttyBridgeTests.keyEquivalentRedispatchesMatchingTimestampWithoutStealingOtherShortcuts()` (`GhosttyKeyboardInputTests.swift:750-751`).
- В этом полном прогоне ранее нестабильный `windowPerformClosePreemptsClipboardAndConfirmsRealActiveSurface()` прошёл.
- Final code review после teardown: APPROVED.

## Запущенное приложение

- Debug app: `.build/DerivedData/Build/Products/Debug/GhostTerm.app`
- PID после запуска: `96833`.

## Ручная проверка пользователем

1. Создать/переименовать workspace, создать несколько tabs и nested splits.
2. Перетащить одну tab и multi-selected tabs, проверить обычный click без drag.
3. Выполнить разные `cd`, изменить ratios, quit/relaunch и проверить restore.
4. Проверить `ghostterm-restore-workspaces = false`, затем `true`.
5. Нажать `Cmd+,`, проверить terminal editor.
6. Выделить текст мышью и вставить через обычный `Cmd+V`.
7. Удалить непустой workspace: cancel и allow; проверить одно предупреждение.

## Следующее

- Исправить flaky key-equivalent test/production redispatch race и добиться полностью зелёного `make check`.
- После ручного подтверждения перейти к dynamic tab titles, custom-command restore confirmation, diagnostics/terminfo/release packaging.
