# Профиль проекта

## Проект

GhostTerm — нативный терминал для macOS. MVP включает tabs, binary splits, именованные workspaces, broadcast внутри текущего tab, Ghostty themes и переключение normal/Quake без потери запущенных shell-процессов.

## Команда

- Формат работы: solo development.
- Решения и изменения контрактов фиксируются в `.agents/memory/`.
- Git commits выполняются только человеком или по его явному запросу.

## Платформа и инструменты

- Язык: Swift.
- UI: AppKit.
- Минимальная ОС: macOS 15+.
- Архитектура: arm64 (Apple Silicon only).
- Проект: XcodeGen; Xcode-проект является генерируемым артефактом.
- Форматирование/линт: Apple `swift-format`.
- Concurrency: Swift strict concurrency.
- Терминальный движок: полная `libghostty`, закреплённая на конкретной ревизии.
- Zig: только build tool для `libghostty` под arm64.

## Внешняя интеграция

Ghostty предоставляет PTY/process lifecycle, VT/xterm emulation, terminal input, Metal rendering, scrollback, terminal configuration, fonts, palettes и themes. Нестабильный upstream C API изолирован в `GhosttyBridge`; подробный контракт — в `.agents/memory/integration-contracts.md`.

## Ограничения MVP

- Одно физическое окно; одновременно отображается один workspace.
- Режимы normal и Quake взаимоисключающие.
- Неактивные workspaces и их процессы продолжают работать до завершения приложения.
- Живые процессы не восстанавливаются после перезапуска.
- Настройка через текстовый config без отдельного Settings UI.
- Нет Intel, Universal Binary, нескольких обычных окон, sandbox и Mac App Store.
- Нет собственного VT parser, PTY layer, renderer или отдельного формата terminal themes.

## Сборка и проверки

- `make generate` — сгенерировать Xcode-проект через XcodeGen.
- `make format` — применить formatter.
- `make lint` — проверить стиль без изменений.
- `make build` — собрать проект.
- `make test` — запустить тесты.
- `make check` — выполнить полный локальный набор проверок.

## Поставка

- Основной артефакт: DMG для arm64.
- Release build должен быть подписан и notarized.
- `.agents/scripts/pre-deploy-check.sh` проверяет чистое дерево, соответствие upstream и запускает `make check`.
- Agent scripts не выполняют release, signing, notarization или публикацию.
- Sandbox/App Store не являются целью MVP.

## Источники истины

1. Продуктовый дизайн: `docs/plans/2026-07-14-ghostterm-design.md`.
2. Архитектурные решения: `.agents/memory/architecture-decisions.md`.
3. Интеграционные границы: `.agents/memory/integration-contracts.md`.
4. Правила реализации: `.agents/rules/architecture.md` и `.agents/rules/coding-style.md`.
