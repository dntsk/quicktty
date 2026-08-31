# Coding Agent Integrations

QuickTTY has two separate coding-agent features:

- standard terminal progress (OSC `9;4`) shown in tab and workspace chrome;
- optional restoration of a native agent session into the pane that originally registered it.

Session restoration relaunches an agent with its opaque native session ID. It is not a PTY, shell, process, scrollback, or memory checkpoint. Every non-agent pane starts a fresh shell after QuickTTY restarts.

## Restore policy

Restoration is attempted only when both settings are enabled:

```ini
quicktty-restore-workspaces = true
quicktty-restore-agent-sessions = true
```

Both default to `true`. Disabling agent restoration retains saved bindings but starts fresh shells. Disabling workspace restoration also prevents agent restoration.

QuickTTY persists only an allowlisted binding: adapter ID, opaque session ID, working directory, registration time, empty allowlisted launch metadata, and restore state. It does not persist arbitrary commands or environment variables and does not infer sessions from terminal output, titles, process trees, history, or agent data stores.

The `bindingDirectory` policy accepts any NFC-normalized canonical absolute path, including `/` and paths outside the user's home directory. Validation is lexical and does not require the directory to exist; a missing directory remains a valid binding and uses the home fallback only when planning the launch. Duplicate separators, `.` or `..` segments, trailing separators outside `/`, controls, and decomposed aliases are rejected.

A resumed launch uses the fixed bundled helper named `quicktty`. QuickTTY builds structured argv, encodes a bounded canonical payload, and the helper executes the resolved agent executable directly. Persisted state cannot select the helper, inject shell syntax, or supply a custom command. If the binding or compatibility policy cannot be verified, QuickTTY does not guess: it keeps the pane identity and opens a fresh shell or shows a pane-local failure with safe actions.

## Local lifecycle channel

Each pane receives exactly five app-owned variables:

- `QUICKTTY_PANE_ID` — persisted pane UUID;
- `QUICKTTY_AGENT_SOCKET` — app-owned local Unix socket;
- `QUICKTTY_INSTANCE_ID` — current QuickTTY process UUID;
- `QUICKTTY_PANE_TOKEN` — random per-pane credential;
- `QUICKTTY_AGENT_HELPER` — fixed bundled `quicktty` path.

Lifecycle messages are bounded and canonical, and must match the current instance, pane, and pane token. Retry rotates the token and attempt generation. During application termination QuickTTY freezes registration, clears pane credentials, rejects later lifecycle messages, flushes state, and then stops the socket and terminal surfaces. This preserves bindings across QuickTTY shutdown without accepting stale unregister events.

## Exact adapter registry

The registry contains these 20 IDs in this order. “Native” means a documented lifecycle integration shape; “wrapper” means process-lifetime tracking through an installed wrapper. It does **not** mean that auto-resume is currently verified.

| # | ID | Capability | Current version policy or blocked reason |
|---:|---|---|---|
| 1 | `claude` | native | Unverified; fresh shell |
| 2 | `codex` | native | Unverified; fresh shell |
| 3 | `grok` | blocked | Ambiguous official identity |
| 4 | `pi` | native | Any installed version reporting a valid semantic version and exposing the required public lifecycle extension API; locally and runtime verified on current Pi `0.84.4` |
| 5 | `omp` | native | Unverified; fresh shell |
| 6 | `campfire` | blocked | Not a sessionful agent |
| 7 | `amp` | wrapper | Unverified; fresh shell; wrapper required for lifecycle |
| 8 | `cursor` | native | Unverified; fresh shell |
| 9 | `gemini` | native | Unverified; fresh shell |
| 10 | `kiro` | blocked | Incompatible lifecycle generations |
| 11 | `antigravity` | wrapper | Unverified; fresh shell; wrapper required for lifecycle |
| 12 | `opencode` | wrapper | Unverified; fresh shell; selected sessions may remain unregistered |
| 13 | `rovo-dev` | blocked | Missing session identity |
| 14 | `hermes` | native | Unverified; fresh shell |
| 15 | `copilot` | native | Unverified; fresh shell |
| 16 | `codebuddy` | blocked | Beta lifecycle only |
| 17 | `droid` | native | Unverified; fresh shell |
| 18 | `qoder` | native | Unverified; fresh shell |
| 19 | `kimi` | native | Unverified; fresh shell |
| 20 | `ollama` | blocked | Missing persistent session API |

Totals are exactly 11 native, 3 wrapper, and 6 blocked. At present, only Pi has a locally and runtime-verified launch policy: installed Pi versions reporting a valid semantic version and exposing the required public lifecycle extension API are accepted, and the integration is locally verified on current Pi `0.84.4`. Every other launch-capable entry remains documented but version-unverified and therefore starts a fresh shell until a verified policy and tests are added. QuickTTY does not claim working auto-resume for those entries.

## Installer CLI

The bundled executable has this exact public grammar:

```text
quicktty integrations status [ids...]
quicktty integrations install [ids...] [--yes]
quicktty integrations uninstall [ids...] [--yes]
```

With no IDs, the command covers all 20 entries in registry order. IDs must be unique and known. `--yes` is accepted once, only as the final operand of `install` or `uninstall`; it is invalid for `status`. Without `--yes`, a TTY install or uninstall prints a preview and applies changes only after the user types the literal lowercase word `yes`. Non-interactive mutation requires `--yes`.

Status output reports the capability (`nativeLifecycle`, `wrapperLifecycle`, or `blocked`) and one bounded state: `available`, `installed`, `updateAvailable`, `noOp`, `missing`, `blocked`, `unverified`, `conflict`, `succeeded`, `failed`, or `skipped`. Exit status is `0` for a clean status/apply, `1` for conflicts or failures, and `2` for grammar or confirmation requirements.

The installer core:

- previews every owned-file, JSON-hook, marker-block, wrapper, plugin, and ownership-manifest mutation before applying it;
- creates a uniquely named `.quicktty-backup-…` copy before changing an existing file;
- uses compare-before-swap checks and refuses symlink/path, duplicate-key, ownership, marker, or changed-after-preview conflicts;
- records only QuickTTY-owned mutations in `~/Library/Application Support/QuickTTY/agent-integration-ownership.json`;
- uninstalls only content that still matches that ownership record and leaves unrelated user configuration intact;
- skips blocked or missing executables instead of writing their configuration.

There are no silent configuration writes. Installation and uninstallation always require an explicit preview/apply flow.

## Agent Integrations sheet

Open **QuickTTY → Agent Integrations…**. The sheet uses the same installer core, ordered registry, capabilities, statuses, previews, backups, ownership checks, and uninstall rules as the CLI; it does not spawn the CLI. Select Install or Uninstall, select eligible entries, review the paths and mutation kinds, and confirm before Apply. The sheet can also explicitly install or uninstall the launcher symlink `~/.local/bin/quicktty`; an unrelated file or symlink at that path is a conflict and is never overwritten.

The pane section shows only the known agent name and `Active`, `Restoring`, `Unverified`, or `Failed`. It never renders raw session IDs. **Retry** re-runs compatibility checks, rotates pane credentials, and attempts the saved binding again. **Forget** removes the binding and creates a fresh shell. Diagnostics are bounded and redacted; prompts, transcripts, commands, terminal text, environment values, and session IDs are not displayed.

## Restore fallback and duplicates

- A pane with no binding starts a fresh shell.
- Disabled restore policy starts a fresh shell and retains the binding.
- A failed or unverified binding starts a fresh shell until explicit Retry.
- Missing executable, unsupported or unverified version, invalid binding, unknown/blocked adapter, missing helper/controller, launch failure, timeout, or immediate exit fails closed. The pane keeps its identity and offers safe recovery; it never runs a persisted arbitrary command.
- A missing saved working directory falls back to the user's home directory.
- If multiple panes claim the same adapter/session pair, none wins. Each duplicate is marked failed; forget bindings until one claim remains, then Retry.
- A successful restoration must register the expected adapter/session back into the same pane. Stale socket messages, process callbacks, timers, and earlier Retry generations are ignored.

## OSC progress

OSC progress remains independent of session restoration. Any terminal program may emit OSC `9;4`; QuickTTY does not infer an agent identity from it.

### Pi

In Pi, open `/settings` and enable **Terminal progress** (`terminal.showTerminalProgress`). It is off by default. Pi emits working at `agent_start`, keepalive updates while running, and completed at `agent_end`; no progress helper, hook, or extension is required.

### Claude Code and Codex progress examples

The manual progress-only examples remain bundled at:

```text
/Applications/QuickTTY.app/Contents/Resources/AgentIntegrations/
```

Merge the appropriate example into existing settings; do not replace the full file. QuickTTY never silently installs these progress examples. `quicktty-progress` accepts only:

```text
quicktty-progress claude working|waiting|failed|completed
quicktty-progress codex working|waiting|failed|completed
```

States map to OSC `9;4` as `working` → `3`, `waiting` → `4`, `failed` → `2`, and `completed` → `0`. Claude mode prints one JSON object with `terminalSequence`; Codex mode writes OSC to `/dev/tty` and exactly `{}` to stdout. The helper reads no stdin, prompt, transcript, or environment secrets. Unknown modes, states, or extra arguments return nonzero.
