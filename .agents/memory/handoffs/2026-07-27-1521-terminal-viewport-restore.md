# Handoff: сохранение terminal viewport при возврате вкладки

- **Дата:** 2026-07-27
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения; commit/push не выполнялись

## Выполнено

- Обработан pinned `GHOSTTY_ACTION_SCROLLBAR` в `GhosttyBridge` с coalesced callback delivery и sequence snapshots.
- `GhosttySurfaceView` сохраняет non-bottom scrollbar offset при detach/rehost и восстанавливает его через `scroll_to_row:<row>` после attach и актуальных resize/output callbacks.
- Bottom-following, ручная прокрутка, terminal scroll actions, paste и новый ввод имеют приоритет; stale callbacks очищаются при close и same-`PaneID` replacement.
- Добавлены integration regressions для coalescing, queued detach, clamp, bottom-following, manual actions, prompt actions, teardown и ABI target rejection.

## Проверки

- `make lint` — PASS.
- `make build` — PASS.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ... build-for-testing` — PASS.
- `git diff --check` — PASS.
- Runtime `xcodebuild test` не проходит в текущей headless-среде: Ghostty surface creation получает `embedded_window ... OutOfMemory` при отсутствии display; это затрагивает существующие integration tests тоже.
- Manual smoke не выполнялся.

## Незавершённое

- Не подтверждён visual/manual smoke на Debug-сборке с большой фоновой выдачей.
- Незакоммиченные изменения требуют обычного review пользователя; коммит не создавать самостоятельно.

## Следующий шаг

1. Запустить актуальную Debug-сборку в графической macOS-сессии.
2. В одной вкладке запустить большой поток вывода, перейти в другую вкладку, вернуться и проверить сохранение позиции без промотки.

## Важный контекст

- `Vendor/ghostty` и закреплённая ревизия не изменялись.
- Восстановление использует штатный Ghostty binding `scroll_to_row:<absolute row>`, а не выдуманный C API.
- Если viewport был внизу, QuickTTY не восстанавливает старый абсолютный offset и сохраняет bottom-following.
