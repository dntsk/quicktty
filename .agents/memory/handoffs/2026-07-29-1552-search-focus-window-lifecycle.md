# Handoff: lifecycle окна в regression test поиска

- **Дата:** 2026-07-29
- **Ветка:** master
- **Статус дерева:** есть большой незакоммиченный native-search diff

## Выполнено

- Найдена production-причина: первоначальный `requestFocus()` публиковал notification до монтирования SwiftUI-подписки, поэтому первое поле поиска могло остаться без фокуса.
- В overlay возвращён штатный Ghostty `.onAppear`, который устанавливает `FocusState` при первом показе.
- Удалён гоняющийся initial async notification; notification сохранён только для повторного `START_SEARCH`.
- До измерения frame панели полноразмерный hosting view теперь пропускает hit в terminal surface.
- Экспериментальные activation/CoreGraphics-костыли из regression test полностью удалены; исходный test setup сохранён.

## Проверки

- `make build` — PASS.
- Focused search tests — PASS: 8 тестов в 2 suites, включая initial/end lifecycle, repeated START и overlay hit-testing.
- Targeted `swift format lint` — PASS.
- `git diff --check` — PASS.
- Spec review и code-quality review — APPROVED без findings.

## Незавершённое

- Полный `make test` после финального минимального патча не запускался.
- GUI-dependent production-focus regression не включался в финальный короткий прогон: unit-test host на macOS 26 нельзя надёжно сделать frontmost поверх другого приложения без внешнего UI automation.

## Следующий шаг

1. Проверить `Cmd+F` вручную в собранном приложении: поле должно сразу принимать ввод.
2. Перед ручным коммитом запустить `make check` в подходящей GUI-сессии.

## Важный контекст

- Production fix минимален и совпадает с pinned upstream lifecycle.
- Vendor, Ghostty pin, зависимости и публичный API не менялись.
