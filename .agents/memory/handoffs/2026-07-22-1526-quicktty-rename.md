# Handoff: финальный аудит переименования QuickTTY

- **Дата:** 2026-07-22
- **Ветка:** `rename/quicktty`
- **Статус дерева:** чистое после `chore: complete QuickTTY rename`.

## Выполнено

- Дизайн: `c0fc61a` (`docs: plan QuickTTY product rename`) и `a27f8a3` (`design: add QuickTTY application icon`).
- Реализация: `92dd499`, `9353fbe`, `c282d6d`, `b43ce1b`, `7c5ef80`, `8d7b4a1`; модули, bundle/config/state identity, release tooling, документация и icon переведены на QuickTTY.
- Final audit подтвердил clean start: QuickTTY не читает, не переносит и не удаляет данные GhostTerm. Исторический GhostTerm alpha.1 сохранён как неприкосновенный артефакт и не изменялся; в этом fresh worktree его ignored DMG локально не материализован.
- Актуальная identity: `QuickTTY`, `com.dntsk.QuickTTY`, version `0.1.0`, build `2`; Debug и unsigned Release bundles содержат `ghostty` и `ThirdPartyNotices.txt`, executable — arm64 Mach-O.
- Единственное formatter-изменение — перенос цепочки вызовов в `QuickTTY/Config/ConfigController.swift`.

## Проверки

- `make format` — выполнен; только ожидаемый перенос строк formatter.
- `make check` — успешно: contracts, Debug build и `Test run with 452 tests in 26 suites passed`; `** TEST SUCCEEDED **`. AppKit runner code 6 отсутствует в полном журнале.
- Debug `Info.plist` — `QuickTTY`, `com.dntsk.QuickTTY`, `0.1.0`, `2`, executable `QuickTTY`; resources и arm64 Mach-O проверены без запуска bundle.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-QuickTTYRelease CODE_SIGNING_ALLOWED=NO build` — `** BUILD SUCCEEDED **`; Release metadata, resources и arm64 Mach-O проверены. Первый запуск этой команды без project `DEVELOPER_DIR` завершился до сборки из-за активных Command Line Tools.
- `git diff --check` — успешно.

## Незавершённое

- Кодовая работа завершена; нужен только review пользователя.

## Следующий шаг

1. Пользователю проверить итоговый commit, затем самостоятельно merge и push при необходимости.

## Важный контекст

- `origin`: `git@github.com:dntsk/quicktty.git`.
- Не выполнялись push, merge, `build-release.sh`, release, signing, notarization, DMG, Keychain/secrets, install, `open` или kill. Bundle вручную не запускался; `make check` запускал только обязательные XCTest.
- Не заявлять о существовании подписанной QuickTTY alpha: такой артефакт этой задачей не создавался.
- Исторические GhostTerm references остаются только в разрешённых historical plans/handoffs/completed rows, naming ADR и integration changelog, а также в tests, защищающих старый alpha.1 artifact и явный legacy profile override. Имена Ghostty, `Vendor/ghostty` и `.ghostty-effective-config` не менялись.
