# Handoff: config diagnostics overlay

- **Дата:** 2026-07-20
- **Ветка:** main
- **Статус дерева:** чистое

## Выполнено

- Доведён dirty bounded/accessibility overlay для inline config diagnostics.
- `ConfigDiagnosticView` ограничивает overlay десятью визуальными строками и высотой 160pt, объявляет accessibility notification только для нового/изменённого непустого presentation.
- `normalizedLine` теперь схлопывает любой непрерывный whitespace-run в один ASCII space и обрезает пробелы по краям, не меняя явный `joined(separator: "\n")` между строками.
- В `WorkspacePresentationTests` зафиксированы regression-проверки на multiline/CRLF нормализацию, ограничение высоты и accessibility announcement/value.

## Проверки

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make format` — прошло
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make lint` — прошло
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project GhostTerm.xcodeproj -scheme GhostTerm -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -only-testing:GhostTermTests/WorkspacePresentationTests test` — прошло дважды
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build` — прошло
- `git diff --check` — прошло

## Незавершённое

- Ничего по этой задаче.

## Следующий шаг

1. Если продолжать работу над diagnostics overlay, запускать уже полный `make check` только при новой задаче.

## Важный контекст

- Исправлялась только реальная регрессия: double-space при `\n` + `\r\n` в `normalizedLine`.
- Accessibility announcement остаётся константой `Configuration diagnostics available`; текст diagnostics доступен через `accessibilityValue()`.
