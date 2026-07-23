# Handoff: dynamic tab titles и manual rename

- **Дата:** 2026-07-23
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения; feature и project docs не закоммичены

## Выполнено

- Реализован дизайн `docs/plans/2026-07-23-dynamic-tab-titles-design.md` по плану `docs/plans/2026-07-23-dynamic-tab-titles.md`.
- Добавлены surface-targeted `GHOSTTY_ACTION_SET_TITLE`, `GHOSTTY_ACTION_SET_TAB_TITLE` и `GHOSTTY_ACTION_PROMPT_TITLE_TAB` со strict synchronous UTF-8 copy, coalescing и безопасным teardown.
- Effective title использует persisted exact manual override, затем live title активной pane, затем `Shell`/`Config` fallback; automatic titles не сохраняются. Splits и inactive workspaces учитываются.
- Добавлены plain double-click и `Rename Tab…`, single-line inline editor, Enter/blur commit, Escape cancel, exact-empty reset, сохранение whitespace/Unicode/emoji, terminal focus restoration и Quake transient interaction.
- Pinned Ghostty не изменён: v1.3.1, `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. Новых shortcut, AI protocol/parsing, icon registry, badges и terminal writes нет.

## Проверки

- Focused combined — 271 тест в 6 suites, PASS за 13.516s; `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.23_16-47-27-+0300.xcresult`.
- `make format` — PASS.
- `make callback-contract` — PASS.
- `git diff --check` — PASS.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check` — 562 теста, 27 suites, 0 failures за 16.487s; `.build/DerivedData/Logs/Test/Test-QuickTTY-2026.07.23_16-48-37-+0300.xcresult`.
- Integrated review: исправлен Important guard для rename selected, но inactive tab; для same-`PaneID` replacement добавлен regression test, подтвердивший достаточность существующего deactivate lifecycle. Открытых Critical/Important нет.

## Незавершённое

- Пользователь подтвердил manual smoke актуальной Debug-сборки: dynamic titles и manual rename работают.
- Commit и push не выполнялись.

## Следующий шаг

1. Commit и push выполнять только по отдельной прямой команде пользователя.

## Важный контекст

- Automatic title остаётся ephemeral opaque Unicode строкой; manual override сохраняется отдельно и имеет высший приоритет.
- Raw Unicode/emoji OSC title уже совместим с будущим текстом статуса AI-агента. Structured agent-aware protocol, parsing, icons и badges намеренно отложены, протокол не выбран.
- Не менять pin или `Vendor/ghostty` при продолжении этой задачи.
