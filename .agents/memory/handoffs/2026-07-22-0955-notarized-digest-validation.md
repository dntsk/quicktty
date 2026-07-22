# Handoff: контракт валидации notarized digest

- **Дата:** 2026-07-22
- **Ветка:** main
- **Статус дерева:** ожидается чистое после коммита `test: bind notarized digest validation`

## Выполнено

- В контрактном тесте закреплён порядок: финальный SHA-256 извлекается, валидируется `notarize_is_valid_sha256 "$dmg_hash"`, затем выводится.
- Production-скрипт `scripts/notarize-dmg.sh` не изменялся.

## Проверки

- `/bin/sh -n scripts/notarize-dmg.sh scripts/tests/notarize-dmg-test.sh` — успешно.
- `make notarize-contract` — успешно.
- `make lint` — успешно.
- `git diff --check` — успешно.

## Незавершённое

- Нет.

## Следующий шаг

1. При наличии настроенного remote отправить commit в upstream.

## Важный контекст

- В репозитории на момент передачи не настроен Git remote, поэтому автоматическая отправка невозможна.
