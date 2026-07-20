# Handoff: нотарификация signed alpha DMG

- **Дата:** 2026-07-20
- **Ветка:** main
- **Статус дерева:** чистое после коммита `f0c2117`.

## Выполнено

- Добавлен POSIX-скрипт `scripts/notarize-dmg.sh` с проверками exact DMG, подписи, JSON-ответа, stapler и Gatekeeper.
- Добавлены чистые helper-функции и offline contract `scripts/tests/notarize-dmg-test.sh`.
- Добавлены Make targets `notarize`, `notarize-contract`, `signed-alpha` и документация выпуска.

## Проверки

- `make notarize-contract` — прошёл.
- `make lint` — прошёл.
- `make callback-contract` — прошёл.
- `git diff --check` — прошёл.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun notarytool history --keychain-profile ghostterm-notary` — прошёл, истории отправок нет.

## Незавершённое

- Реальная отправка DMG, stapling и Gatekeeper-проверка конкретного артефакта намеренно не выполнялись.

## Следующий шаг

1. После явного разрешения при чистом дереве запустить `make notarize` для exact DMG.

## Важный контекст

- Скрипт не читает и не принимает credentials; он использует только имя заранее сохранённого Keychain profile.
- При неуспешном статусе Apple JSON сохраняется, а скрипт печатает команду для просмотра log.
