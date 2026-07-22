# QuickTTY Rename Design

**Дата:** 2026-07-22  
**Статус:** утверждён

## Цель

Переименовать текущий продукт GhostTerm в QuickTTY до первой публикации нового GitHub-репозитория, не меняя terminal runtime, UI-поведение или архитектурные границы.

## Идентичность продукта

- Product, app, Xcode project/target/scheme и Swift module: `QuickTTY`.
- Test target/module: `QuickTTYTests`.
- Bundle identifier: `com.dntsk.QuickTTY`.
- Logger и pasteboard identifiers: `com.dntsk.QuickTTY.*`.
- GitHub repository: `git@github.com:dntsk/quicktty.git`.
- Product version: `0.1.0`, build `2`.
- Первый release label под новым именем: `0.1.0-alpha.2`.
- Release artifact: `QuickTTY-0.1.0-alpha.2-arm64.dmg`.
- Default notarization profile: `quicktty-notary`; профиль остаётся переопределяемым через environment.

## Чистый старт

QuickTTY не читает, не переносит и не удаляет пользовательские данные GhostTerm.

Новые пути:

- config: `~/.config/quicktty/config`;
- effective Ghostty config: `~/.config/quicktty/.ghostty-effective-config`;
- state: `~/Library/Application Support/QuickTTY/state.json`;
- собственные config keys: `quicktty-*`.

GhostTerm и QuickTTY могут существовать рядом как разные приложения с разными bundle IDs и каталогами данных. Старый config, state, app bundle и notarized DMG остаются нетронутыми.

## Граница с Ghostty

Переименование не затрагивает upstream engine и связанные имена:

- `GhosttyBridge` и все `Ghostty*` Swift-типы;
- `Vendor/ghostty` и закреплённую ревизию;
- `GhosttyKit.xcframework`;
- bundle resource directory `ghostty`;
- `.ghostty-effective-config`;
- Ghostty attribution и third-party notices.

`GhostTermConfig` и `GhostTermApplication` относятся к нашему продукту, поэтому становятся `QuickTTYConfig` и `QuickTTYApplication`.

## Файлы и история

Production/source directories становятся `QuickTTY/` и `QuickTTYTests/`. Xcode project продолжает генерироваться XcodeGen и становится `QuickTTY.xcodeproj`.

Актуальные документы — README, AGENTS, project rules, backlog, configuration reference, release scripts и living architecture memory — переходят на QuickTTY. Старые implementation plans, handoffs, completed-task entries и сведения о подписанной GhostTerm alpha сохраняют историческое имя и старые пути. Старый артефакт `.build/Release/GhostTerm-0.1.0-alpha.1-arm64.dmg` не переименовывается и не удаляется.

Локальная корневая папка текущего checkout может остаться `ghostterm`; свежий clone репозитория `dntsk/quicktty` естественно получит имя `quicktty`.

## Иконка

Новая иконка не является простой заменой букв в старой композиции. Направление:

- нативная macOS superellipse;
- сдержанный графитовый фон;
- крупная светлая `Q`;
- компактная надпись `TTY` холодного акцентного цвета;
- читаемость в Dock и в размере 16×16;
- воспроизводимая генерация first-party Swift-скриптом без новых зависимостей.

Сначала создаётся preview 1024×1024. Полный appiconset генерируется только после визуального подтверждения.

## Проверка результата

- XcodeGen создаёт только проект/scheme/targets QuickTTY.
- Debug build и все tests проходят под модулем QuickTTY.
- `make check` проходит полностью.
- Built app сообщает `QuickTTY`, `com.dntsk.QuickTTY`, version `0.1.0`, build `2`.
- Release contracts ожидают только QuickTTY alpha.2 paths и identifiers.
- Поиск старого имени в актуальном source/tooling пуст; старые совпадения остаются только в явно разрешённых исторических документах.
- Приложение не запускается, не устанавливается, не подписывается и не отправляется на notarization без отдельного разрешения пользователя.
