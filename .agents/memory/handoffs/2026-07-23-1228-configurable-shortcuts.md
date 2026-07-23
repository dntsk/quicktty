# Handoff: configurable shortcuts integrated review

- **Дата:** 2026-07-23
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения всей feature configurable shortcuts

## Выполнено

- Исправлены четыре Important findings integrated review без расширения feature:
  - malformed `quicktty-shortcut = <known-action>` теперь остаётся diagnostic, но участвует в previous-active/default fallback; unknown/malformed остальные случаи не изменены;
  - local matcher сначала использует logical unmodified output `characters(byApplyingModifiers: [])`, US shifted-symbol table оставлен fallback для synthetic input без пригодного unmodified output; hardware key-code mapping не добавлялся, non-Latin без canonical token остаётся unmatched;
  - popup `WorkspaceSelector` больше не владеет `Cmd+Opt+1…9`: у всех реальных popup items пустые `keyEquivalent` и modifier mask, click/tracking routes сохранены;
  - desired global chord отделён от optional actual Carbon registration. `HotKeyControlling.registeredChord` отражает только фактическое состояние, coordinator не делает ложный retry после transactional failure, а общий runtime resolver дополнительно отключает owner actual chord и публикует один результат в menus и bridge.
- ConfigController не зависит от Carbon; configured candidate продолжает резервироваться config policy, actual divergence применяется runtime resolver на reload. Автоматическое восстановление local owner до следующего reload не добавлялось.
- Public documentation не менялась в integrated review: утверждённая семантика сохраняется.

## Проверки

- Focused config: `ConfigDocumentTests + ConfigControllerTests` — PASS, 45 тестов в 2 suites.
- Focused Carbon/runtime: `HotKeyDescriptorCarbonTests + WindowCoordinatorConfigurationTests` — PASS, 20 тестов в 2 suites.
- `AppDelegateLifecycleTests` — PASS, 41 тест в 1 suite.
- `WorkspacePresentationTests` — PASS, 38 тестов в 1 suite.
- Aggregated `GhosttyBridgeTests` — PASS, 94 теста в 1 suite; в этот запуск также прошёл `positionsUseTopLeftLogicalPointsAndEveryDragUsesPositionPath`.
- `make format` — PASS.
- `git diff --check` — PASS после format и после полного gate.
- Первый post-review `make check` прошёл contracts, lint и Debug build, но existing mouse-drag test флакнул после 524 из 525 тестов; тот же тест до этого прошёл в focused suite.
- Повторный `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check` — PASS: 525 тестов в 27 suites, 0 failures, 13.693 s. XCResult: `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.23_12-57-01-+0300.xcresult`.
- Production grep `ghostty_surface_key_is_binding` по `QuickTTY/**/*.swift` — совпадений нет.
- Local matcher production grep по `keyCode`/`kVK_ANSI` — совпадений нет.
- `git submodule status` — `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28 Vendor/ghostty (v1.3.1)`; pin unchanged.
- Приложение отдельно не запускалось; signing, release, notarization, commit и push не выполнялись.

## Незавершённое

- Ручной runtime smoke test shortcuts не выполнялся: приложение отдельно не запускалось по safety contract.
- Commit и push требуют отдельной команды пользователя.

## Следующий шаг

1. По явной команде пользователя выполнить commit/push либо сначала провести ручной runtime smoke test.

## Важный контекст

- При unregister failure actual old Carbon chord остаётся зарезервирован runtime вместе с configured candidate; rollback success публикует actual old; replacement+rollback failure публикует `nil`, coordinator не выдумывает old registration.
- Menu controller и Ghostty bridge всегда получают один и тот же resolved `ShortcutConfiguration`.
- Logical matcher не обещает physical-layout invariance и намеренно не использует hardware key codes.
- Interactive Search, URL hover/open и stateful read-only/secure-input/mouse-reporting остаются вне этой feature.
