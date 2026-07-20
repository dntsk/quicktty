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
