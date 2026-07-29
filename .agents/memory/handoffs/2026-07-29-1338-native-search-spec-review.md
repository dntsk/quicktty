# Handoff: завершение spec-review штатного поиска Ghostty

- **Дата:** 2026-07-29
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения

## Выполнено

- Исправлен hit-testing полноразмерного SwiftUI host: overlay публикует измеренный frame панели через named coordinate space, host принимает hit только внутри region с учётом flipped AppKit coordinates.
- `FocusState` поля поиска связан с surface-local focus flag; configurable shortcut route разрешён для terminal first responder или реально сфокусированного search field и закрыт для постороннего responder.
- End/close сбрасывают focus и отменяют pending 300 ms needle delivery; повторный START сохраняет штатный refocus.
- Добавлены регрессии для Cmd+F/G/Shift+G без terminal input, pane switch `end_search`, delayed needle teardown и same-pane replacement.
- Обновлены design и integration contract. Vendor, pin и зависимости не изменялись; приложение вручную не запускалось.

## Проверки

- Focused xcodebuild до production edits — ожидаемый compile FAIL на отсутствующих interaction region/state/host API.
- `make format` — PASS.
- Focused suites `GhosttySurfaceSearchOverlayTests`, `GhosttyKeyboardInputTests`, `GhosttyBridgeTests`, `WindowCoordinatorTabLifecycleTests` — PASS.
- `make callback-contract` — PASS.
- `make lint` — PASS.
- `make build` — PASS.
- `make test` — PASS, 659 тестов в 30 suites.
- `make check` — PASS, 659 тестов в 30 suites.
- `git diff --check` — PASS.
- `git diff --name-only -- Vendor` и `git diff -- Vendor` — пусто.

## Незавершённое

- Открытых findings по указанному spec-review не осталось.
- Изменения не закоммичены по требованию пользователя.

## Следующий шаг

1. Просмотреть итоговый незакоммиченный diff и при необходимости закоммитить вручную.

## Важный контекст

- До первого geometry measurement host безопасно пропускает все hits к terminal surface.
- Search shortcuts не захардкожены в SwiftUI и продолжают использовать `ShortcutConfiguration`/`GhosttyBridge` route.
- Единственные контролируемые ожидания по 350 ms находятся в регрессиях pinned debounce 300 ms.
