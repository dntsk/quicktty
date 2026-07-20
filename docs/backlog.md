# GhostTerm Backlog

## Custom-command restore confirmation

**Status:** Deferred from MVP Task 13.

Current policy: every restored pane starts a fresh shell in its saved working directory. A saved custom startup command remains in the persisted pane descriptor but is never executed automatically.

Future behavior:

- collect saved custom commands into one restore confirmation;
- show workspace, tab, working directory, and command for each entry;
- allow all commands or replace all of them with shells;
- preserve pane IDs, split layout, active state, and persisted descriptors;
- never execute a saved command before explicit approval.

## Fully configurable keyboard shortcuts

**Status:** Backlog.

Every GhostTerm action must support a user-defined key chord instead of relying on hard-coded shortcuts. This includes tabs, workspaces, splits, pane navigation, broadcast, configuration, presentation mode, and the global Quake toggle.

Required behavior:

- assign any supported macOS key plus any combination of `cmd`, `opt`, `ctrl`, and `shift`;
- disable an action shortcut explicitly;
- apply shortcut changes through config hot reload without restarting surfaces or shells;
- update displayed `NSMenuItem` key equivalents immediately;
- detect duplicate GhostTerm assignments and report both conflicting actions;
- define deterministic precedence between GhostTerm-reserved shortcuts and Ghostty `keybind` entries;
- keep local application shortcuts and the global Quake shortcut as separate scopes;
- reject unsupported global shortcuts transactionally while preserving the last valid registration;
- provide stable action identifiers so future commands can be added without changing config syntax;
- add parser, conflict, menu synchronization, hot-reload, and global-registration rollback tests.
