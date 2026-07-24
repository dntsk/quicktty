# Handoff: terminal progress bridge

- **Дата:** 2026-07-24
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения Task 1 и два ранее созданных untracked plan-файла

## Выполнено

- Добавлены стабильные `GhosttyProgressReport`, `GhosttyCommandFinished` и `GhosttyActivityConfiguration`.
- Surface-targeted actions 56/58 синхронно копируются из C payload и доставляются через общий ordered FIFO `SurfaceCallbackContext` без coalescing.
- Teardown очищает очередь; старый callback context не доставляет события replacement surface с тем же `PaneID`.
- Finalized `progress-style` и `desktop-notifications` публикуются только при успешном reload.
- Callback contract и focused integration tests расширены по TDD.

## Проверки

- `make callback-contract` — PASS.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData test -only-testing:QuickTTYTests/GhosttySurfaceViewTests -only-testing:QuickTTYTests/GhosttyBridgeTests` — PASS, 119 тестов.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint` — PASS.
- `git diff --check` — PASS.

## Незавершённое

- Tasks 2+ из terminal progress implementation plan не начинались.
- Полный `make check` для одного Task 1 не запускался.

## Следующий шаг

1. Выполнить отдельный review Task 1 либо начать Task 2 с failing reducer tests.

## Важный контекст

- Системный `xcode-select` указывает на CommandLineTools; для Xcode-команд нужен локальный `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `Vendor/ghostty` и два `docs/plans/2026-07-24-terminal-progress-notifications*.md` не изменялись.
- Progress и command-finished намеренно не добавлены в `GhosttyRuntimeAction`.
