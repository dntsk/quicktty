# Dynamic Tab Titles and Rename Design

**Дата:** 2026-07-23
**Статус:** утверждено пользователем — повторить поведение pinned Ghostty; AI-specific semantics отложены

## Цель

QuickTTY показывает live title активной pane каждого tab так же, как Ghostty: terminal/PWD/shell integration формируют `GHOSTTY_ACTION_SET_TITLE`, а host отображает полученную строку без собственного разбора. Пользователь может задать sticky имя tab; пустое имя снимает override и немедленно возвращает последний live title.

## Scope

Входит:

- surface-targeted `GHOSTTY_ACTION_SET_TITLE`;
- title активной pane как automatic title tab;
- persisted manual override с precedence над automatic title;
- `GHOSTTY_ACTION_SET_TAB_TITLE` и tab-вариант `GHOSTTY_ACTION_PROMPT_TITLE`;
- double-click inline rename и `Rename Tab…` в context menu;
- Enter/blur commit, Escape cancel, пустая строка снимает override;
- lifecycle для splits, inactive workspaces, pane/tab close, restore и Quake transient interaction;
- сохранение Unicode/emoji без host-side интерпретации.

Не входит:

- отдельный shortcut/action ID QuickTTY;
- surface-title editor;
- AI-agent protocol, icon registry, badges, progress parsing или notifications;
- изменение Ghostty shell integration или pinned revision;
- сохранение transient automatic title в workspace state.

## Upstream contract

Pinned Ghostty `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` формирует `SET_TITLE` из OSC 0/2. Если explicit terminal title отсутствует, core использует PWD; bundled shell integration обычно показывает форматированный путь в prompt и исполняемую команду во время preexec. macOS frontend слушает title focused surface, хранит `titleOverride` на уровне tab/controller и продолжает обновлять automatic title под override.

QuickTTY повторяет эту precedence:

1. `manualTitleOverride`, если задан;
2. последний live `SET_TITLE` активной pane;
3. существующий model fallback (`Shell`/`Config`).

Пустой manual title означает `nil`, а не пустой override. Whitespace и Unicode не нормализуются: Ghostty сохраняет введённую строку буквально и очищает override только для exact empty string.

## Model и persistence

`TerminalTab.title` остаётся backward-compatible fallback. Добавляется optional `titleOverride`, декодируемый через `decodeIfPresent`; существующий state v1 продолжает загружаться без миграции и не превращает старые `Shell`/`Config` в sticky override.

`WorkspaceStore` получает атомарную mutation по `TabID`. Override входит в обычный `ApplicationState`/`StateStore` snapshot. Automatic titles не входят в Codable model и не переживают restart: restored fresh shells снова публикуют актуальные titles.

Такое разделение заранее совместимо с агентскими AI: агент может отправлять обычный OSC title с текстом или emoji, и QuickTTY покажет его как opaque Unicode string. Позднее badges/status model можно добавить отдельно, не меняя persistence ручного имени и не разбирая уже сохранённые titles.

## Callback и concurrency

`ghosttyRuntimeActionCallback` синхронно:

- принимает только surface target с live `ghostty_surface_userdata`;
- проверяет non-null C string и strict UTF-8;
- копирует payload до возврата из C callback;
- передаёт stable Swift `String` в `SurfaceCallbackContext`.

`SurfaceCallbackContext` coalesce-ит consecutive automatic titles до latest value и доставляет их на `MainActor`. Teardown очищает pending title и не доставляет stale event. `SET_TAB_TITLE` использует тот же lifetime-safe surface context, но доставляется как отдельный request: пустая строка снимает override у содержащего tab. Tab prompt принимается только для surface-targeted `GHOSTTY_PROMPT_TITLE_TAB`; surface prompt остаётся unsupported, потому что текущий scope — rename tab.

`GhosttySurfaceView` хранит только последний automatic title своей surface. `GhosttyBridge` публикует typed handlers; C handles и pointers не покидают bridge.

## Presentation и split semantics

`WindowCoordinator` не копирует automatic title в `WorkspaceStore`. Он строит live map `PaneID → String` из существующих surfaces и передаёт её в `WorkspaceViewController`. Для каждого `TerminalTab` tab bar выбирает title его `activePaneID`. При смене focused split presentation сразу переключается на уже известный title новой active pane.

Title callback inactive pane обновляет её surface state, но не меняет видимый title tab, пока pane не станет active. Title callback inactive workspace сохраняется только в live surface и появляется при переключении workspace. После закрытия pane/tab surface удаляется, поэтому stale title исчезает без отдельной persisted cleanup.

Title update не пересоздаёт terminal surfaces, не меняет split layout/focus и не пишет в PTY. Частые статусы, включая будущие agent titles, обновляют только tab chrome.

## Rename UI

QuickTTY использует собственный tab bar, поэтому не копирует private native `NSTabBar` traversal Ghostty. Семантика остаётся той же:

- plain double-click по tab начинает inline edit;
- context menu содержит `Rename Tab…`;
- editor seeded текущим effective title (`override ?? automatic ?? fallback`);
- Enter и blur коммитят;
- Escape отменяет;
- пустой commit очищает override;
- после завершения focus возвращается active terminal surface.

Во время inline edit live automatic title продолжает обновляться в фоне, но не перезаписывает текст field. После cancel показывается последний live title; после non-empty commit — override. В Quake edit удерживает transient interaction, чтобы focus loss не скрыл окно.

## Ошибки и ограничения

Malformed/null/non-UTF-8 title callback возвращает `false` и ничего не меняет. Callback закрытой surface отбрасывается. Rename неизвестного/закрытого tab не меняет store. Не добавляется logging title content, чтобы command lines, paths, tokens и agent text не попадали в public logs.

## Тестирование

- Codable backward compatibility и persisted override;
- exact-empty reset, whitespace/Unicode/emoji preservation;
- strict callback copy, invalid UTF-8, coalescing и teardown;
- active/inactive split и workspace title routing;
- manual override precedence при последующих automatic updates;
- `SET_TAB_TITLE`/tab prompt routing и stale surface rejection;
- double-click/context menu, Enter/blur/Escape и focus restoration;
- title updates не пересоздают surfaces и не пишут в PTY;
- Quake transient interaction cleanup;
- callback contract audit и unchanged Ghostty pin.
