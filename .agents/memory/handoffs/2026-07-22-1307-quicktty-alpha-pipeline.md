# Handoff: QuickTTY alpha.2 release pipeline

- **Дата:** 2026-07-22
- **Ветка:** rename/quicktty
- **Статус дерева:** чистое после коммита `build: rename alpha pipeline to QuickTTY`

## Выполнено

- Release и notarization pipeline переименованы в QuickTTY alpha.2: archive, DMG, stage, build number, bundle/project/scheme и default notary profile.
- Контракты сначала изменены и подтверждённо падали на старых `BUILD_NUMBER=1` и `.GhostTerm-notary-result` до production-изменений.
- Cleanup-контракт проверяет сохранность исторических GhostTerm alpha.1 archive/DMG/evidence/stage.

## Проверки

- `sh -n scripts/*.sh scripts/tests/*.sh` — успешно.
- `make release-contract` — успешно.
- `make notarize-contract` — успешно.
- `make lint` — успешно; есть существующее предупреждение swift-format `QuickTTY/Config/ConfigController.swift:119:24` (`AddLines`).

## Незавершённое

- Нет.

## Следующий шаг

1. Не запускать release/notarize без отдельного запроса и credentials.

## Важный контекст

- `QUICKTTY_FORCE_GHOSTTY_REBUILD` заменяет app-owned `GHOSTTERM_*`; все Ghostty upstream имена, pin и файл `scripts/build-ghostty.sh` сохранены.
- Production scripts и Makefile не содержат `GhostTerm`, `ghostterm` или `GHOSTTERM_`; тесты намеренно содержат исторические alpha.1 имена и явный override `ghostterm-notary`.
