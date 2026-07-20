# Handoff: hardening копирования Ghostty runtime resources

- **Дата:** 2026-07-20
- **Ветка:** main
- **Статус дерева:** чистое после commit `fix: harden Ghostty resource copy`

## Выполнено

- `copy-ghostty-resources.sh` принимает destination только с tail `GhostTerm.app/Contents/Resources` и сверяет его с canonical ожидаемым Xcode path, переданным build phase.
- После `cd -P` скрипт меняет staging, backups и targets только относительными именами текущего pinned `Resources` directory.
- EXIT cleanup отделён от HUP/INT/TERM handler; test-only TERM failpoint после backup восстанавливает прежний `terminfo` и очищает staging.
- POSIX fixture покрывает неверные app/path, несовпадающий Xcode path, Resources symlink, target symlinks, допустимые `.build`/DerivedData/archive paths и signal rollback.

## Проверки

- `sh -n scripts/copy-ghostty-resources.sh` — успешно.
- `sh -n scripts/tests/copy-ghostty-resources-test.sh` — успешно.
- `sh scripts/tests/copy-ghostty-resources-test.sh` три раза — успешно.
- `make generate` — успешно.
- unsigned Debug и Release `xcodebuild` с `CODE_SIGNING_ALLOWED=NO` — успешно.
- Проверка Debug/Release bundles — runtime resources присутствуют; у Release нет `Contents/_CodeSignature`.
- `make lint` и `git diff --check` — успешно.

## Незавершённое

- Нет.

## Следующий шаг

1. При изменении Xcode build phase сохранять передачу expected resource path вторым аргументом скрипта.

## Важный контекст

- Проверки пути предназначены для предотвращения локальных ошибочных вызовов, а не являются privilege boundary.
- `GHOSTTERM_TEST_SEND_TERM_AFTER_TERMINFO_BACKUP=1` предназначена только для deterministic POSIX fixture.
