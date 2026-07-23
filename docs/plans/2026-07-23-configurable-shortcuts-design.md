# Configurable Shortcuts Design

**Дата:** 2026-07-23
**Статус:** утверждён

## Цель

Все управляющие сочетания QuickTTY настраиваются через текстовый config и принадлежат QuickTTY. Ghostty не владеет keyboard bindings: неназначенные QuickTTY события передаются в `libghostty` только как terminal input.

Изменение shortcuts применяется через hot reload без пересоздания terminal surfaces или shell-процессов.

## Config syntax

Локальные shortcuts задаются повторяемой инструкцией:

```ini
quicktty-shortcut = new-tab=cmd+t
quicktty-shortcut = copy=cmd+c
quicktty-shortcut = toggle-broadcast=disabled
```

Левая часть value — стабильный action ID. Правая часть — canonical chord либо `disabled`.

Global Quake shortcut остаётся отдельным параметром и отдельным scope:

```ini
quicktty-global-toggle = f12
```

Он использует ту же грамматику key/modifier, но регистрируется через Carbon и работает вне приложения.

## Key grammar

Modifier tokens:

- `cmd`;
- `opt`;
- `ctrl`;
- `shift`.

Порядок modifiers при parsing не важен; canonical serialization использует порядок выше. Duplicate modifiers не допускаются.

Key tokens:

- `a`…`z`, `0`…`9`;
- `f1`…`f20`;
- `left`, `right`, `up`, `down`;
- `home`, `end`, `page-up`, `page-down`;
- `tab`, `enter`, `escape`, `space`, `delete`, `forward-delete`;
- `grave`, `minus`, `equal`, `left-bracket`, `right-bracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash`.

Допускается любая комбинация modifiers, включая отсутствие modifiers. Literal punctuation в chord не используется: canonical names исключают неоднозначности с `+`, whitespace и раскладками.

## Shortcut model

`ShortcutAction` — стабильный typed identifier. Он задаёт:

- строковый config ID;
- scope и target policy;
- default chord;
- menu metadata, если действие показывается в menu;
- typed execution route;
- performable/pass-through policy.

`ShortcutChord` содержит canonical key и modifiers. `ShortcutConfiguration` хранит максимум один chord на action и максимум одного владельца на chord. `nil` означает `disabled`.

Config не принимает произвольные Ghostty action strings. Terminal action string генерируется только из first-party typed allowlist.

## Application actions и defaults

| Action ID | Default |
|---|---|
| `quit` | `cmd+q` |
| `open-config` | `cmd+comma` |
| `toggle-presentation` | `cmd+opt+p` |

Global Quake toggle не входит в local registry; default `quicktty-global-toggle` — `f12`.

## Tab и pane actions

| Action ID | Default |
|---|---|
| `new-tab` | `cmd+t` |
| `close-pane` | `cmd+w` |
| `close-tab` | `cmd+opt+w` |
| `split-right` | `cmd+d` |
| `split-down` | `cmd+shift+d` |
| `previous-pane` | `cmd+left-bracket` |
| `next-pane` | `cmd+right-bracket` |
| `focus-left` | `cmd+opt+left` |
| `focus-right` | `cmd+opt+right` |
| `focus-up` | `cmd+opt+up` |
| `focus-down` | `cmd+opt+down` |
| `select-tab-1`…`select-tab-9` | `cmd+1`…`cmd+9` |
| `toggle-broadcast` | `cmd+b` |

`close-pane` повторяет текущую surface-close policy: live process требует confirmation. `close-tab` использует first-party tab close и проверяет все panes. Structural actions никогда не broadcast.

## Workspace actions

| Action ID | Default |
|---|---|
| `new-workspace` | `disabled` |
| `rename-workspace` | `disabled` |
| `delete-workspace` | `disabled` |
| `select-workspace-1`…`select-workspace-9` | `cmd+opt+1`…`cmd+opt+9` |

## Terminal actions

| Action ID | Default | Core action |
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
| `previous-prompt` | `cmd+shift+up` | `jump_to_prompt:-1` |
| `next-prompt` | `cmd+shift+down` | `jump_to_prompt:1` |
| `selection-left` | `shift+left` | `adjust_selection:left` |
| `selection-right` | `shift+right` | `adjust_selection:right` |
| `selection-up` | `shift+up` | `adjust_selection:up` |
| `selection-down` | `shift+down` | `adjust_selection:down` |
| `selection-page-up` | `shift+page-up` | `adjust_selection:page_up` |
| `selection-page-down` | `shift+page-down` | `adjust_selection:page_down` |
| `selection-home` | `shift+home` | `adjust_selection:home` |
| `selection-end` | `shift+end` | `adjust_selection:end` |

`copy`, `copy-url`, `clear-screen`, `scroll-to-selection` и keyboard selection adjustment сохраняют performable semantics: если core action возвращает `false`, исходное key event продолжает normal terminal input path.

Paste и paste-selection используют существующую broadcast policy активной tab. Copy, selection, scroll, prompt, font и reset выполняются только на focused pane.

## Не включённые Ghostty actions

Не экспортируются в shortcut config:

- Ghostty-owned tabs, windows, splits, command palette и inspector;
- key tables;
- произвольные `text:`, `csi:` и `esc:` actions;
- временные screen/scrollback/selection files;
- `crash:*`;
- upstream undo/redo window lifecycle.

`toggle_readonly`, `toggle_secure_input` и `toggle_mouse_reporting` откладываются до появления видимого состояния, checked menu state и корректного lifecycle cleanup.

Interactive search и URL hover/open являются обязательными следующими интеграциями и отдельно зафиксированы в `docs/backlog.md`.

## Sequential merge и diagnostics

Parsing начинается с built-in defaults и обрабатывает инструкции сверху вниз.

- Валидная инструкция изменяет только указанный action.
- `disabled` является валидным явным значением.
- Повтор action заменяет предыдущее значение; последняя валидная инструкция побеждает.
- Если новый chord принадлежит другому local action, последний action получает chord, прежний владелец становится `disabled`.
- Conflict diagnostic сообщает chord и оба action ID, но candidate применяется.
- Unknown action, invalid chord или malformed shortcut instruction игнорируется отдельно; остальные инструкции применяются.
- При hot reload невалидная инструкция известного action сохраняет последнее активное значение этого action.
- При первом startup невалидная инструкция известного action сохраняет default.
- Если строка action удалена из config, action возвращается к default.

Для поддержки различия между отсутствующей и невалидной строкой parser публикует typed instruction results, а `ConfigController` строит candidate с доступом к последней активной configuration.

## Global и local conflicts

Global Quake shortcut имеет приоритет над local scope. Если global chord совпадает с local action:

- global registration сохраняется;
- local action становится `disabled`;
- diagnostic сообщает оба action ID;
- local action не восстанавливается автоматически до следующего config reload.

Замена global registration транзакционна. Если Carbon не принимает новый chord, восстанавливается предыдущая успешная registration; остальные config и local shortcut изменения продолжают применяться.

## Ghostty keybind boundary

Top-level Ghostty `keybind` assignments молча удаляются из effective config. Diagnostics для них не показываются.

После всех остальных Ghostty assignments в effective config всегда добавляется:

```ini
keybind = clear
```

Финальный clear удаляет Ghostty defaults и bindings из processed `include` files. QuickTTY-owned `quicktty-*` строки, как и прежде, не передаются Ghostty.

`ghostty_surface_key_is_binding` больше не участвует в keyboard dispatch. Неназначенное QuickTTY event передаётся в `ghostty_surface_key` как terminal input; Ctrl+C, Ctrl+Z, IME и обычный ввод сохраняются.

## Dispatch architecture

MainActor `ShortcutController` владеет active `ShortcutConfiguration`, action registry и menu synchronization. Config hot reload заменяет local responder map целиком и обновляет существующие menu items без пересоздания surfaces.

Application/structural actions маршрутизируются в typed методы `AppDelegate` и `WindowCoordinator`. Terminal actions выполняются на текущей focused surface через typed `GhosttyBridge` allowlist. Opaque C handle остаётся private в `GhosttySurfaceView`.

Conditional terminal actions обрабатываются в responder path до normal terminal encoding. `Bool` результата core action определяет consume/pass-through. Menu validation не должна повторно поглощать event, для которого performable action вернул `false`.

Hidden/inactive surface не является shortcut target. Shortcut routing не хранит stale `GhosttySurfaceView` reference и каждый раз разрешает active `PaneID` через coordinator/bridge registry.

## Menu synchronization

Каждый пользовательский menu command имеет стабильный menu item identity. Hot reload обновляет его `keyEquivalent` и exact device-independent modifier mask. `disabled` очищает оба значения.

Responder-only conditional actions, которым требуется pass-through, не получают конкурирующий consuming menu equivalent. Их текущая конфигурация остаётся видна в Configuration Reference; menu presentation добавляется только если можно сохранить performable fallback.

Menu action validation и checked state продолжают использовать текущую domain/runtime availability.

## Проверка

Тесты должны покрыть:

- полный key parser, aliases rejection и canonical serialization;
- defaults и stable action IDs;
- sequential overrides, `disabled`, removed-line reset и invalid-line preservation;
- last-owner-wins, automatic disable и conflict diagnostics;
- global-over-local conflict и Carbon rollback;
- menu synchronization при hot reload;
- responder performable fallback без PTY loss;
- focused target и broadcast policies;
- typed terminal allowlist и post-close no-op;
- silent removal top-level Ghostty `keybind`;
- final `keybind = clear` после includes/остального config;
- отсутствие `ghostty_surface_key_is_binding` в production path;
- IME, Ctrl-key и ordinary terminal input regressions;
- отсутствие surface/shell recreation на hot reload;
- MainActor, callback lifetime и no opaque-handle escape.
