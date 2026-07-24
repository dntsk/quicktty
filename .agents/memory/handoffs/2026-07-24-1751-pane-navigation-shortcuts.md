# Handoff: defaults directional pane navigation

- **Дата:** 2026-07-24
- **Ветка:** `master`
- **HEAD:** `9222ade feat: add terminal progress notifications`
- **Статус:** shortcut-изменения завершены и не закоммичены; ветка опережает `origin/master` на предыдущий commit

## Выполнено

- Built-in directional pane focus изменён:
  - `focus-left` → `cmd+shift+left`;
  - `focus-right` → `cmd+shift+right`;
  - `focus-up` → `cmd+shift+up`;
  - `focus-down` → `cmd+shift+down`.
- `previous-prompt` и `next-prompt` больше не имеют built-in chord.
- Prompt action IDs, typed terminal allowlist, Ghostty routes `jump_to_prompt:-1/1` и custom `quicktty-shortcut` assignments сохранены.
- Canonical AppKit View-menu metadata использует Command+Shift arrows; duplicate normalization переиспользует canonical item и сохраняет foreign Command+Option/Control variants.
- Bundled configuration reference и configurable-shortcuts design синхронизированы.
- План: `docs/plans/2026-07-24-pane-navigation-shortcut-defaults.md`.

## Проверки

- TDD RED: 52 теста, ровно 3 ожидаемых failing tests на старых production defaults.
- Focused после реализации: 52 теста в 2 suites, PASS.
- Отдельные spec reviews: tests PASS, production PASS, docs PASS.
- Отдельные quality reviews: tests APPROVED, production APPROVED, docs APPROVED.
- `make format` — PASS.
- `make lint` — PASS.
- `make check` — 629 тестов в 29 suites, 0 failures.
- XCResult: `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.24_17-48-54-+0300.xcresult`.
- Финальный integrated review — APPROVED.
- `git diff --check` — PASS до записи project memory/handoff.
- `Vendor/ghostty` не менялся.

## Незавершённое

- Manual smoke нового chord не выполнялся. Уже запущенный экземпляр QuickTTY может использовать предыдущий binary; нужен разрешённый пользователем relaunch актуальной Debug-сборки.
- Shortcut diff, plan и memory не закоммичены и не отправлены.
- Предыдущий terminal-progress commit `9222ade` всё ещё не pushed.

## Следующий шаг

1. С явного разрешения пользователя закрыть уже запущенный QuickTTY и открыть актуальную Debug-сборку.
2. Проверить `Cmd+Shift+стрелки` в split layout и отсутствие prompt jump.
3. Commit/push выполнять только по отдельному явному запросу.
