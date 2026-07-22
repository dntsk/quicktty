# Handoff: восстановление после ошибки terminal surface

- **Дата:** 2026-07-22
- **Ветка:** `master`
- **Статус дерева:** есть незакоммиченные изменения

## Выполнено

- Создан новый checkout `/Users/silver/Projects/DNTSK/quicktty` из `dntsk/quicktty`; старые checkout/worktrees не удалялись.
- Утверждены design и implementation plan:
  - `docs/plans/2026-07-22-surface-failure-placeholder-design.md`;
  - `docs/plans/2026-07-22-surface-failure-placeholder.md`.
- Startup создаёт model identity до surface; surface creation failure не завершает приложение.
- Restore обрабатывает panes независимо и не закрывает успешные соседние surfaces.
- Missing surface отображается как palette-aware placeholder `Terminal unavailable` с `Retry` и `Close Pane`; tiny split использует clipped scroll viewport.
- Retry сохраняет `PaneID` и CWD, но всегда запускает fresh shell без persisted custom command.
- Close Pane выполняет model-only collapse без Ghostty close и replacement shell; generic missing surface также закрывается.
- Закрытие устойчиво к reentrant confirmation callbacks: после invalidation ownership повторно определяется по актуальному store до построения candidate.
- Inactive/background Retry и Close не переключают selection и не крадут focus.
- Broadcast затронутой tab сбрасывается независимо от её visibility.
- Pinned Ghostty API, revision и `Vendor/ghostty` не изменялись.

## Проверки

- Focused presentation tests — 10/10 PASS.
- Focused lifecycle tests — 65/65 PASS.
- `make format` — PASS.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check` — PASS: 473 tests, 26 suites.
- `git diff --check` — PASS перед обновлением memory.

## Незавершённое

- Изменения не закоммичены и не отправлены: пользователь не давал отдельной команды на commit/push.
- Ручной fault-injection smoke test в установленном приложении не выполнялся; приложение отдельно не запускалось.
- Отдельного upstream render-failure callback в pinned Ghostty API нет; текущая recovery-path покрывает создание/отсутствие surface.
- Keychain profile `quicktty-notary` по-прежнему не создавался.

## Следующий шаг

1. По явной команде пользователя просмотреть итоговый diff, создать commit и отправить `master`.
2. Затем выбрать следующую backlog-задачу: configurable shortcuts либо custom-command restore confirmation.

## Важный контекст

- Обычные New Tab/Split сохраняют прежний транзакционный rollback и не создают synthetic error panes.
- Ошибка surface не персистится; persisted descriptor остаётся источником identity, layout и CWD.
- `Retry` никогда не выполняет persisted custom startup command.
- `Close Pane` последней unavailable pane оставляет workspace пустым и окно открытым.
- Полный gate после production/test изменений зелёный; после него менялись только Markdown memory-файлы.
