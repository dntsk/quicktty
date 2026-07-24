# Handoff: terminal progress и background notifications

- **Дата:** 2026-07-24
- **Ветка:** `master`
- **Статус:** feature завершена; commit разрешён пользователем, push не разрешён

## Выполнено

- Добавлена surface-scoped обработка `GHOSTTY_ACTION_PROGRESS_REPORT` и `GHOSTTY_ACTION_COMMAND_FINISHED` с ordered delivery, C lifetime isolation и same-`PaneID` safety.
- Finalized `progress-style` и `desktop-notifications` обновляются транзакционно вместе с Ghostty config.
- Реализован transient reducer `working / waiting / failed / completed` с keepalive, 5-second notification threshold и 3-second visible acknowledgement.
- Tab bar показывает generic badge слева от title; Workspace selector/menu агрегирует статусы всех panes без structural reload.
- Добавлены lazy macOS notifications с privacy-safe generic content, bounded per-pane mapping и suppression для выбранной tab key window.
- Notification click показывает текущий Normal/Quake presentation и активирует exact workspace/tab/pane без surface/PTY restart.
- Bundled manual integrations:
  - Pi — native `/settings → Terminal progress`;
  - Claude Code — `terminalSequence` hooks;
  - Codex — lifecycle hooks через controlling TTY helper.
- Existing `~/.pi`, `~/.claude`, `~/.codex`, shell rc и `.env` автоматически не изменяются.
- Design: `docs/plans/2026-07-24-terminal-progress-notifications-design.md`.
- Implementation plan: `docs/plans/2026-07-24-terminal-progress-notifications.md`.
- User guide: `docs/agent-integrations.md`.

## Проверки

- `make callback-contract` — PASS.
- `make agent-integrations-contract` — PASS.
- Единый focused gate — 286 тестов в 5 suites, PASS.
- Integrated review нашёл четыре Important: failed command fallback, stale pending authorization, unbounded mapping и неполный Retry/collapse cleanup. Все исправлены и покрыты regressions; добавлен real PTY OSC 9;4 test.
- Первый `make check` после review выявил deinit crash: `removeSurface` создавал новый `[weak self]` handler во время teardown. Termination guard исправил regression; affected suites — 17 тестов, PASS.
- Финальный `make check` — 629 тестов в 29 suites, 0 failures.
- Последний XCResult перед commit: `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.24_17-02-18-+0300.xcresult`.
- Пользователь подтвердил basic manual smoke актуальной Debug-сборки: direct OSC 9;4, badge, background completion notification и Pi 0.82 с включённым `Terminal progress` работают.
- `git diff --check` — PASS.
- `Vendor/ghostty` и pin не менялись.

## Незавершённое

- Расширенный manual matrix для notification click между inactive workspace и hidden Quake не выполнялся.
- Push не выполнялся.
- Повторный automated reviewer после fixes не стартовал из-за сбоя subagent runner; исправления проверены focused и full gates.

## Следующий шаг

1. При необходимости проверить notification click между inactive workspace и Normal/hidden Quake.
2. Push выполнять только по отдельному явному запросу.

## Важный контекст

- Agent identity намеренно отсутствует; OSC 9;4 работает для всех CLI-задач.
- Status ephemeral и не входит в `state.json`.
- Notification content не содержит terminal title, cwd, command, prompt или output.
- `progress-style = false` очищает badges; `desktop-notifications = false` оставляет badges и запрещает system notifications.
- Не перезаписывать пользовательские agent configs; examples нужно merge вручную.
- Частичный handoff `2026-07-24-1417-terminal-progress-bridge.md` относится только к первому bridge-блоку; этот документ его заменяет как актуальный контекст.
