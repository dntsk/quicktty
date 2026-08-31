# QuickTTY Configuration Reference

The user configuration file is `~/.config/quicktty/config`. Lines without the `quicktty-` prefix are passed to Ghostty, except user `keybind` entries described below. Valid changes apply without restarting terminal surfaces or shell processes. If reload fails, the last valid configuration remains active.

## QuickTTY options

### `quicktty-presentation-mode`

Startup window mode: `normal` or `quake`. Default: `normal`.

### `quicktty-global-toggle`

Global shortcut that shows or hides the Quake window. It uses the shortcut grammar below but is registered separately through Carbon. Default: `f12`.

### `quicktty-shortcut`

Repeatable local shortcut assignment:

```ini
quicktty-shortcut = action-id=cmd+key
quicktty-shortcut = action-id=disabled
```

Use an `action-id` from the complete registry below. `disabled` explicitly removes an assignment.

### `quicktty-quake-height`

Share of the screen's available height. Accepts a fraction from `0` through `1` or a percentage from `1%` through `100%`. Default: `75%`.

### `quicktty-quake-animation-duration`

Nonnegative animation duration in seconds. Default: `0.18`.

### `quicktty-quake-padding`

Nonnegative Quake-window inset in points. Default: `0`.

### `quicktty-hide-on-focus-loss`

Whether the Quake window hides after losing focus: `true` or `false`. Default: `true`.

### `quicktty-quake-pin-to-screen`

Whether Quake remains on the display where it was first shown: `true` or `false`. Default: `false`. When false, it opens on the display containing the pointer.

### `quicktty-restore-workspaces`

Whether saved workspace descriptions are restored on the next launch: `true` or `false`. Default: `true`. When false, QuickTTY opens a new Default workspace while still restoring the normal window frame.

### `quicktty-restore-agent-sessions`

Whether eligible native coding-agent sessions are resumed when saved workspaces are restored: `true` or `false`. Default: `true`. The effective policy requires both this option and `quicktty-restore-workspaces` to be true.

Restoration relaunches an agent by its opaque native session ID into the original pane. It is not a PTY or process checkpoint. Disabling it starts fresh shells while retaining saved bindings. QuickTTY does not persist arbitrary commands or environment variables, and it does not infer sessions from output, titles, processes, history, or agent stores. An unverified or invalid binding fails closed to a fresh shell or a pane-local Retry/Forget state.

### `quicktty-config-editor`

Terminal editor command for the configuration, including arguments, for example `code --wait`. Default: `nano`. The `open-config` action opens it in a new terminal tab.

### `quicktty-update-channel`

Update channel: `stable` or `beta`. Default: `stable`. Stable reads the GitHub latest feed and excludes prereleases. Beta reads QuickTTY's versioned appcast, which is a superset of stable.

## Shortcut grammar

A shortcut contains optional modifiers and exactly one key separated by `+`. Modifier order is ignored while parsing; canonical order is `cmd+opt+ctrl+shift+key`. Duplicate modifiers, empty components, multiple keys, unknown tokens, and literal punctuation are invalid. A key without modifiers, such as `f12` or `space`, is valid.

Modifiers: `cmd`, `opt`, `ctrl`, `shift`.

Keys:

- letters `a`…`z` and digits `0`…`9`;
- function keys `f1`…`f20`;
- arrows `left`, `right`, `up`, `down`;
- navigation `home`, `end`, `page-up`, `page-down`;
- special keys `tab`, `enter`, `escape`, `space`, `delete`, `forward-delete`;
- punctuation names `grave`, `minus`, `equal`, `left-bracket`, `right-bracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash`.

## Action registry and defaults

The global Quake toggle is outside the local registry; its default is `quicktty-global-toggle = f12`.

### Application

| Action ID | Default |
|---|---|
| `quit` | `cmd+q` |
| `open-config` | `cmd+comma` |
| `toggle-presentation` | `cmd+opt+p` |

### Tabs and panes

| Action ID | Default |
|---|---|
| `new-tab` | `cmd+t` |
| `close-pane` | `cmd+w` |
| `close-tab` | `cmd+opt+w` |
| `split-right` | `cmd+d` |
| `split-down` | `cmd+shift+d` |
| `previous-pane` | `cmd+left-bracket` |
| `next-pane` | `cmd+right-bracket` |
| `focus-left` | `cmd+shift+left` |
| `focus-right` | `cmd+shift+right` |
| `focus-up` | `cmd+shift+up` |
| `focus-down` | `cmd+shift+down` |
| `select-tab-1` | `cmd+1` |
| `select-tab-2` | `cmd+2` |
| `select-tab-3` | `cmd+3` |
| `select-tab-4` | `cmd+4` |
| `select-tab-5` | `cmd+5` |
| `select-tab-6` | `cmd+6` |
| `select-tab-7` | `cmd+7` |
| `select-tab-8` | `cmd+8` |
| `select-tab-9` | `cmd+9` |
| `toggle-broadcast` | `cmd+b` |

### Workspaces

| Action ID | Default |
|---|---|
| `new-workspace` | `disabled` |
| `rename-workspace` | `disabled` |
| `delete-workspace` | `disabled` |
| `select-workspace-1` | `cmd+opt+1` |
| `select-workspace-2` | `cmd+opt+2` |
| `select-workspace-3` | `cmd+opt+3` |
| `select-workspace-4` | `cmd+opt+4` |
| `select-workspace-5` | `cmd+opt+5` |
| `select-workspace-6` | `cmd+opt+6` |
| `select-workspace-7` | `cmd+opt+7` |
| `select-workspace-8` | `cmd+opt+8` |
| `select-workspace-9` | `cmd+opt+9` |

### Terminal actions

| Action ID | Default | Fixed Ghostty core action |
|---|---|---|
| `copy` | `cmd+c` | `copy_to_clipboard` |
| `paste` | `cmd+v` | `paste_from_clipboard` |
| `paste-selection` | `cmd+shift+v` | `paste_from_selection` |
| `select-all` | `cmd+a` | `select_all` |
| `copy-url` | `disabled` | `copy_url_to_clipboard` |
| `clear-screen` | `cmd+k` | `clear_screen` |
| `reset-terminal` | `disabled` | `reset` |
| `font-increase` | `cmd+equal` | `increase_font_size:1` |
| `font-decrease` | `cmd+minus` | `decrease_font_size:1` |
| `font-reset` | `cmd+0` | `reset_font_size` |
| `scroll-top` | `cmd+home` | `scroll_to_top` |
| `scroll-bottom` | `cmd+end` | `scroll_to_bottom` |
| `scroll-page-up` | `cmd+page-up` | `scroll_page_up` |
| `scroll-page-down` | `cmd+page-down` | `scroll_page_down` |
| `scroll-to-selection` | `cmd+j` | `scroll_to_selection` |
| `previous-prompt` | `disabled` | `jump_to_prompt:-1` |
| `next-prompt` | `disabled` | `jump_to_prompt:1` |
| `find` | `cmd+f` | `start_search` |
| `find-next` | `cmd+g` | `navigate_search:next` |
| `find-previous` | `cmd+shift+g` | `navigate_search:previous` |
| `selection-left` | `shift+left` | `adjust_selection:left` |
| `selection-right` | `shift+right` | `adjust_selection:right` |
| `selection-up` | `shift+up` | `adjust_selection:up` |
| `selection-down` | `shift+down` | `adjust_selection:down` |
| `selection-page-up` | `shift+page-up` | `adjust_selection:page_up` |
| `selection-page-down` | `shift+page-down` | `adjust_selection:page_down` |
| `selection-home` | `shift+home` | `adjust_selection:home` |
| `selection-end` | `shift+end` | `adjust_selection:end` |

Prompt navigation remains typed and configurable but has no default chord because Command-Shift-arrow shortcuts are reserved for directional pane focus.

QuickTTY accepts only this typed allowlist, not arbitrary Ghostty action strings.

## Sequential application and conflicts

Each parse starts from built-in defaults and processes `quicktty-shortcut` entries from top to bottom.

- The last valid assignment for an action replaces its earlier value; `disabled` is valid.
- An unknown action, malformed assignment, or invalid chord reports a diagnostic without blocking other valid lines.
- During hot reload, an invalid line for a known action retains that action's last active value; on first launch it retains the default.
- Removing every assignment for an action restores its default.
- If two local actions claim one chord, the last valid owner receives it and the prior owner becomes disabled; the diagnostic names both actions.

The global shortcut has priority over local shortcuts. In Quake mode, Carbon registration replacement is transactional. If the new global chord cannot be registered, QuickTTY restores the last successful registration and continues applying other valid configuration changes.

## Ghostty keyboard boundary

Top-level user `keybind = ...` entries are silently excluded from the generated effective configuration. QuickTTY always appends:

```ini
keybind = clear
```

This clears built-in and included Ghostty bindings. Unassigned QuickTTY keyboard events, ordinary input, Control combinations, and IME continue through the normal terminal input path.

Terminal actions use only the fixed typed allowlist. Non-performable copy, copy URL, clear screen, scroll-to-selection, and selection actions do not consume the original event. Paste and paste-selection use broadcast only for panes in the active tab; all other terminal actions target the focused pane.

## Deferred terminal actions

Interactive Search uses Ghostty's native `start_search`, `end_search`, `search:<needle>`, `navigate_search:next`, and `navigate_search:previous` contract. Read-only, secure-input, and mouse-reporting stateful actions remain deferred until they have visible state, checked menu state, and lifecycle cleanup.

## Coding-agent integrations

QuickTTY displays OSC `9;4` progress and can optionally restore a version-verified native agent session. Session restoration requires the exact two-key policy above and never restores a PTY/process checkpoint or a persisted arbitrary command. The installer is explicit and never silently changes agent configuration. See `docs/agent-integrations.md` in the repository for the exact 20-entry registry, current Pi `0.83.0` verification boundary, CLI/UI workflow, fallback behavior, and progress setup.

## Ghostty options

### `progress-style`

Controls OSC `9;4` activity badges. Default: `true`. When false, QuickTTY clears current badges and ignores new progress events.

### `desktop-notifications`

Controls system notifications for terminal progress. Default: `true`. When false, badges still update but new notifications are not created.

Both options hot reload without restarting surfaces or shell processes. Only a fully valid Ghostty configuration becomes active.

### `copy-on-select`

QuickTTY defaults to `copy-on-select = clipboard`, which copies selections to the standard system clipboard. Set `copy-on-select = false` to disable it; any explicit user value is preserved.

## Example

```text
theme = catppuccin-mocha
font-size = 14

quicktty-presentation-mode = quake
quicktty-global-toggle = f12
quicktty-shortcut = new-tab=cmd+t
quicktty-shortcut = toggle-broadcast=disabled
quicktty-shortcut = clear-screen=ctrl+l
quicktty-quake-height = 75%
quicktty-quake-animation-duration = 0.18
quicktty-quake-padding = 0
quicktty-hide-on-focus-loss = true
quicktty-quake-pin-to-screen = false
quicktty-restore-workspaces = true
quicktty-restore-agent-sessions = true
quicktty-config-editor = nano

copy-on-select = clipboard
```

QuickTTY creates `.ghostty-effective-config` next to the user configuration. Do not edit it manually.
