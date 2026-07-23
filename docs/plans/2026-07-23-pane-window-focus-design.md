# Pane and Window Focus Presentation Design

**Дата:** 2026-07-23
**Статус:** утверждено пользователем после visual smoke; pane frame полностью удалена как визуально раздражающая

## Цель

QuickTTY визуально различает выбранную pane, фактический terminal input focus и активность окна. Split presentation повторяет удачное поведение pinned Ghostty: неактивные panes затемняются через `unfocused-split-opacity`/`unfocused-split-fill`, а terminal text cursor остаётся полностью под управлением renderer Ghostty.

## Состояния и источники истины

Три состояния намеренно не объединяются:

- `TerminalTab.activePaneID` определяет последнюю выбранную pane текущего tab;
- `NSWindow.isKeyWindow` определяет активность окна;
- `window.firstResponder === GhosttySurfaceView` определяет, принимает ли terminal keyboard input.

`activePaneID` не очищается при потере window focus или временном переходе focus в rename/editor. Это сохраняет понятную последнюю выбранную pane и существующую persistence-семантику.

## Матрица presentation

- Active pane в любом состоянии окна: полная яркость, без border/frame.
- Остальные panes: overlay цвета `unfocused-split-fill` с alpha `1 - unfocused-split-opacity`.
- Custom tab/workspace chrome в non-key window приглушается, но terminal content дополнительно целиком не затемняется.
- Если focus временно находится в rename/editor или другом приложении, active pane остаётся выбранной; точное отсутствие terminal input focus показывает hollow cursor Ghostty.

Первая пробная реализация использовала accent/neutral frame. Пользователь отклонил её после visual smoke: синяя 2px рамка оказалась слишком резкой, а сама border — визуально раздражающей независимо от толщины и цвета. Финальный presentation различает panes только Ghostty-style dimming, а активность окна — chrome и terminal cursor.

## Terminal cursor contract

QuickTTY не рисует и не конфигурирует отдельный terminal cursor. Существующий `GhosttySurfaceView` передаёт в `ghostty_surface_set_focus` условие `window.isKeyWindow && window.firstResponder === surface`.

Pinned Ghostty при `focus=false`:

- показывает hollow block независимо от обычной формы cursor;
- останавливает blink и оставляет hollow cursor видимым;
- при возврате focus восстанавливает terminal-requested block/bar/underline и blink.

Исключения Ghostty сохраняются: скрытый terminal cursor остаётся скрытым, IME preedit и password-input следуют upstream priority rules. QuickTTY не дублирует эту логику.

## Ghostty split configuration

Добавляется immutable Swift value `GhosttySplitAppearance`:

- `unfocusedFill: GhosttyRGB`;
- `unfocusedOverlayOpacity: Double`.

`GhosttyConfiguration` извлекает finalized `unfocused-split-opacity` и optional `unfocused-split-fill` через существующий `ghostty_config_get`. Если fill не задан, используется finalized terminal background, как в upstream macOS frontend. Config opacity преобразуется в overlay alpha через `1 - value`.

`GhosttyBridge` публикует appearance рядом с `chromePalette` и заменяет их вместе только после успешного transactional reload. Новые QuickTTY config keys и persistence fields не добавляются.

## Presentation architecture

`WindowCoordinator` передаёт `activePaneID` и `GhosttySplitAppearance` в существующий `WorkspaceViewController.displayTerminal`. `GhosttySplitTreeView` применяет leaf-local decoration и не владеет surfaces.

`WorkspaceViewController` наблюдает key state именно того `NSWindow`, в который в данный момент установлен его root view. Это важно для взаимоисключающих Normal/Quake presentation: один и тот же controller/surfaces перемещаются между окнами без recreation процессов. При переносе observer перепривязывается, stale notifications старого окна игнорируются.

Window key transition обновляет только presentation и chrome. Surface identity, split layout, active pane, PTY и persisted state не меняются.

## Ограничения

Не входят:

- pane border/frame и config keys для неё;
- изменение pinned Ghostty или его cursor renderer;
- отдельные badges/status labels;
- изменение terminal background opacity или Metal layer opacity;
- анимация dimming;
- изменение active pane при window resign-key.

## Тестирование

- finalized extraction custom/default fill и opacity;
- transactional config reload обновляет split appearance, invalid reload сохраняет старое;
- deterministic mapping active/inactive pane в dimming state; key/non-key window не меняет pane decoration;
- overlay не принимает hit testing и не заменяет hosted `GhosttySurfaceView`;
- active-pane switch обновляет decoration без surface recreation;
- key/resign и перенос Normal/Quake перепривязывают window observation;
- chrome dimming восстанавливается при become-key;
- существующие focus tests подтверждают передачу focus в Ghostty и не меняются;
- focused suites, один integrated review и один final `make check`.
