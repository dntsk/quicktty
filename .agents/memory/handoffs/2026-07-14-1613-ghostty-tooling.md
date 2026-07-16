# Handoff: Ghostty dependency/tooling

- **Дата:** 2026-07-14
- **Ветка:** main
- **Статус дерева:** есть незакоммиченные изменения; `.gitmodules` и gitlink `Vendor/ghostty` staged, остальные файлы нового репозитория untracked

## Выполнено

- Ghostty v1.3.1 добавлен submodule и закреплён на `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.
- Добавлены проверки инструментов и воспроизводимая сборка `GhosttyKit.xcframework` через Zig 0.15.2.
- Static XCFramework добавлен в XcodeGen link phase без embed.
- Обновлены Makefile, README, third-party notices и project memory.
- `GhosttyBridge` и Swift/C interop намеренно не добавлялись.

## Проверки

- `./scripts/check-tools.sh` — успешно.
- `git -C Vendor/ghostty rev-parse HEAD` — точный закреплённый commit.
- `./scripts/build-ghostty.sh` — успешно, создан `Vendor/ghostty/macos/GhosttyKit.xcframework`.
- `xcodegen generate --spec project.yml` — успешно.
- `make lint` — успешно.
- `make build` — успешно; XCFramework обработан и `libghostty-fat.a` залинкован.
- `make test` — успешно, 2 Swift Testing tests.
- `make check` — успешно.

## Незавершённое

- Swift `GhosttyBridge` отсутствует согласно границе Task 1.

## Следующий шаг

1. Начинать Swift/C bridge только в отдельной задаче после изучения headers и lifecycle закреплённой ревизии.

## Важный контекст

- Первая Ghostty-сборка остановилась на отсутствии Metal Toolchain; установлен рекомендованной Xcode командой `xcodebuild -downloadComponent MetalToolchain`, без `sudo` и без смены `xcode-select`.
- Upstream `libtool` при первой полной сборке вывел предупреждения о 8-byte alignment некоторых Mach-O members, но артефакт и итоговая Xcode-сборка успешны.
- Xcode tests выводят системные предупреждения AppIntents/linkd и одно предупреждение чтения XCTest binary, но завершаются успешно.
