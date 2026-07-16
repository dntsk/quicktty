# GhostTerm

GhostTerm — нативный терминал для macOS с tabs, splits, workspaces, broadcast-вводом и взаимоисключающими режимами normal/Quake. Источник продуктовых решений: `docs/plans/2026-07-14-ghostterm-design.md`.

## Стек

- Swift и AppKit, macOS 15+, только arm64.
- Полная embedding-библиотека `libghostty`, закреплённая на конкретной ревизии; Zig используется только для её сборки.
- XcodeGen для генерации Xcode-проекта.
- Apple `swift-format` и Swift strict concurrency.
- Поставка: подписанный и notarized DMG.

## Быстрые команды

- Генерация проекта: `make generate`
- Форматирование: `make format`
- Линт: `make lint`
- Сборка: `make build`
- Тесты: `make test`
- Полная проверка: `make check`

## Критические правила

1. Следовать утверждённому design doc; не расширять MVP без отдельного решения.
2. В приложении одно физическое окно; режимы normal и Quake взаимоисключающие и не перезапускают shell-процессы.
3. Весь нестабильный C API Ghostty изолировать в `GhosttyBridge`; opaque C handles не должны покидать bridge.
4. AppKit и `NSView` использовать только на main thread; соблюдать Swift strict concurrency.
5. Не менять закреплённую ревизию полной `libghostty` без явной задачи и полного набора integration tests.
6. MVP не использует sandbox и не предназначен для Mac App Store; релиз — подписанный и notarized DMG для arm64.
7. Не читать секреты и `.env`; не коммитить и не выполнять release/signing без явного запроса.
8. После значимых изменений обновлять соответствующую project memory; при завершении сессии оставлять handoff.

## Навигация

- `.agents/rules/project-profile.md` — профиль проекта, ограничения MVP и процесс поставки.
- `.agents/rules/architecture.md` — границы компонентов, зависимости и архитектурные инварианты.
- `.agents/rules/coding-style.md` — правила Swift/AppKit, форматирования и concurrency.
- `.agents/memory/integration-contracts.md` — контракт `GhosttyBridge` и интеграция с Ghostty.
- `.agents/memory/architecture-decisions.md` — принятые решения и отклонённые альтернативы.
- `.agents/memory/tasks-completed.md` — журнал завершённых задач.
- `.agents/memory/handoffs/README.md` — формат передачи контекста между сессиями.
- `.agents/scripts/style-audit.sh` — read-only проверка стиля Swift.
- `.agents/scripts/pre-deploy-check.sh` — проверка дерева, upstream и `make check` перед выпуском.
- `.agents/scripts/post-commit-reminder.sh` — напоминание об обновлении project memory.
