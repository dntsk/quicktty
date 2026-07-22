# Surface Failure Placeholder Design

**Дата:** 2026-07-22  
**Статус:** утверждён

## Цель

Ошибка создания terminal surface при startup или workspace restore не должна завершать QuickTTY, разрушать сохранённый split layout либо оставлять прозрачную пустую pane. Неисправная pane показывает локальный placeholder с безопасным восстановлением.

## Состояние

`WorkspaceStore`, стабильные `PaneID` и split layout остаются источником истины. `WindowCoordinator` хранит только неперсистентное presentation-состояние ошибок surface по `PaneID`: короткое локализованное сообщение без C handles.

Отсутствующая surface для существующей pane считается недоступной pane. Ошибка не записывается в `state.json`: persisted descriptor уже содержит всё необходимое для безопасного повторного запуска shell.

## Startup и restore

Surfaces существующего store создаются независимо. Успешные surfaces добавляются в registry; ошибка одной surface не откатывает остальные и не завершает приложение. Pane, tab, workspace и split layout сохраняются, а для неудачной pane регистрируется error presentation.

Если исходный workspace пуст, coordinator сначала создаёт shell descriptor и tab identity, затем пытается создать surface. Неудача оставляет доступный error placeholder вместо fatal startup alert.

Broadcast для tab с недоступной pane выключается. Сохранённый custom startup command никогда не выполняется при restore или Retry.

## Presentation

`GhosttySplitTreeView` показывает вместо отсутствующей surface локальный placeholder:

- заголовок `Terminal unavailable`;
- краткую причину ошибки;
- кнопку `Retry`;
- кнопку `Close Pane`.

Placeholder занимает только соответствующий leaf, использует текущую terminal palette и предоставляет accessibility labels. Остальные panes и разделители продолжают работать.

## Retry

`Retry` повторно создаёт surface с тем же `PaneID`, сохранённым CWD и fresh shell. Контекст выбирается как `.newTab` для первого leaf tab и `.split` для остальных.

При успехе surface атомарно добавляется в bridge/coordinator registry, error state удаляется, presentation обновляется и активная pane получает focus. При повторной ошибке layout и identity не меняются; обновляется только локальное сообщение.

## Close Pane

`Close Pane` выполняет model-only закрытие через `SplitCoordinator`: отсутствующая surface не требуется и GhosttyBridge не вызывается. Split сворачивается по обычным правилам.

Если закрывается последняя pane tab, tab удаляется. Workspace может остаться пустым; автоматический replacement shell не создаётся, чтобы не повторять заведомо неуспешное создание.

## Границы

Обычное создание новых tabs и splits остаётся транзакционным: неудачная пользовательская команда не создаёт новый error-tab. Публичный API и pinned Ghostty C API не меняются.

Закреплённый Ghostty API не предоставляет отдельный render-failure callback. Такой callback не выдумывается; новый coordinator state позволит подключить реальный upstream signal позже.

## Проверка

Тесты должны подтвердить:

- partial restore сохраняет model/layout и успешные соседние surfaces;
- startup creation failure оставляет error pane и не становится fatal;
- Retry failure сохраняет identity и обновляет сообщение;
- Retry success сохраняет `PaneID`, CWD и layout;
- Retry не запускает persisted custom command;
- Close Pane сворачивает split без bridge surface;
- закрытие последней недоступной pane оставляет пустой workspace;
- broadcast затронутого tab выключается;
- placeholder показывает обе кнопки и маршрутизирует точный `PaneID`;
- существующие tab/split/process lifecycle contracts продолжают проходить.
