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

## Stateful terminal modes

**Status:** Deferred until visible state is available.

Do not export shortcuts for read-only mode, secure input, or mouse-reporting mode until QuickTTY can present their live state and clean it up with the owning surface.

Required behavior:

- expose only typed actions backed by the pinned Ghostty API;
- show persistent visible state and synchronized checked menu state;
- scope state to the correct live surface and clear it on pane close, workspace change, and teardown;
- preserve normal terminal input and mouse behavior when a mode is inactive;
- add callback/state synchronization, hidden-pane, hot-reload shortcut, and lifecycle cleanup tests.

## Interactive terminal search

**Status:** Следующая обязательная интеграция.

Implement the search UI supported by pinned libghostty instead of exposing only headless search actions.

Required behavior:

- show a QuickTTY-owned search overlay inside the active terminal viewport;
- route start, search-selection, next, previous, and end actions to the active pane;
- consume search shortcuts without writing them into the PTY;
- preserve live surfaces, split layout, focus, and running processes while search opens or closes;
- synchronize query, selected match, and total match state through real embedded Ghostty callbacks;
- keep search state scoped to its pane and clear stale state when that pane closes;
- add callback lifetime, active/inactive pane, hot-reload shortcut, and no-PTY-write tests.

## URL hover and opening

**Status:** Завершено 2026-07-23.

Закреплённый Ghostty владеет detection/highlight и `Cmd+click`; QuickTTY принимает `open_url`, открывает schemes/file paths через `NSWorkspace` и применяет surface-local cursor shape через cursor rects. Preview UI и keyboard action `open-url` не добавлены. Контракт зафиксирован в `docs/plans/2026-07-23-url-hover-open-design.md`.
