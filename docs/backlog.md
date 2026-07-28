# QuickTTY Backlog

## Custom-command restore confirmation

**Status:** Deferred from MVP Task 13.

Current policy: every restored pane starts a fresh shell in its saved working directory. A saved custom startup command remains in the persisted pane descriptor but is never executed automatically.

Future behavior:

- collect saved custom commands into one restore confirmation;
- show workspace, tab, working directory, and command for each entry;
- allow all commands or replace all of them with shells;
- preserve pane IDs, split layout, active state, and persisted descriptors;
- never execute a saved command before explicit approval.

## Interactive terminal search

**Status:** Завершено 2026-07-28.

QuickTTY показывает NSSearchField-оверлей поверх активного терминала с инкрементальным поиском через встроенный search thread Ghostty. Cmd+F открывает поиск, Cmd+G/Cmd+Shift+G или ↑↓ навигируют, Esc очищает подсветку, Enter закрывает с сохранением подсветки. Поиск привязан к одной активной панели и закрывается при смене панели. Debounce 200ms, счётчик совпадений. Контракт зафиксирован в `docs/plans/2026-07-27-interactive-terminal-search-design.md`.

## Terminal viewport preservation on tab restore

**Status:** Завершено 2026-07-27.

При rehost вкладки QuickTTY сохраняет последний scrollbar offset не внизу и восстанавливает его через штатный Ghostty `scroll_to_row:<row>` после актуального resize/output callback. Bottom-following и ручные scroll/input actions не перехватываются; callbacks очищаются при teardown и не переходят к replacement surface с тем же `PaneID`. Контракт закреплён integration regressions в `QuickTTYTests/Integration/GhosttySurfaceViewTests.swift`.

## URL hover and opening

**Status:** Завершено 2026-07-23.

Закреплённый Ghostty владеет detection/highlight и `Cmd+click`; QuickTTY принимает `open_url`, открывает schemes/file paths через `NSWorkspace` и применяет surface-local cursor shape через cursor rects. Preview UI и keyboard action `open-url` не добавлены. Контракт зафиксирован в `docs/plans/2026-07-23-url-hover-open-design.md`.

## Dynamic tab titles and rename

**Status:** Завершено 2026-07-23.

QuickTTY отображает opaque live title активной pane, поддерживает отдельный persisted manual override и inline rename через double-click или `Rename Tab…`. Automatic titles остаются ephemeral. Контракт зафиксирован в `docs/plans/2026-07-23-dynamic-tab-titles-design.md`.

## Terminal progress and agent integrations

**Status:** Завершено 2026-07-24.

QuickTTY принимает стандартный surface-scoped OSC 9;4 от любых terminal applications, показывает transient status в tab bar и Workspace selector и отправляет generic background notifications с exact pane navigation. Agent identity не определяется: Pi использует native Terminal progress, Claude Code и Codex — ручные lifecycle hook examples. Title и terminal output не анализируются, status не сохраняется. Контракт зафиксирован в `docs/plans/2026-07-24-terminal-progress-notifications-design.md`.
