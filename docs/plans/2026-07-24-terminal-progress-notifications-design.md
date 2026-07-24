# Terminal Progress and Notifications Design

**Дата:** 2026-07-24
**Статус:** утверждён пользователем

## Цель

Показывать transient progress любого terminal task в tab bar и Workspace selector, а для длительных фоновых задач отправлять macOS notification с переходом к исходной pane. Pi, Claude Code и Codex используют тот же стандартный terminal protocol; QuickTTY не определяет тип агента и не анализирует terminal output или title.

## Решения пользователя

- Основной transport — стандартный ConEmu OSC 9;4 через pinned Ghostty.
- Progress работает для всех terminal applications, не только для AI-агентов.
- Badge показывается в tab bar и агрегируется в Workspace selector/menu.
- Agent identity в UI отсутствует.
- Notification подавляется, только когда source tab выбрана и её окно является key window.
- Completion notification разрешена после пяти секунд activity; pause/error уведомляются сразу.
- Click по notification показывает текущий Normal/Quake presentation, переключает exact workspace/tab и фокусирует source pane.
- Completed/failed badge в невыбранной tab хранится до просмотра; в уже видимой tab показывается кратко.

## Transport и границы

QuickTTY принимает `GHOSTTY_ACTION_PROGRESS_REPORT` только с `GHOSTTY_TARGET_SURFACE`. Callback синхронно копирует scalar payload в стабильный Swift value до actor hop. Opaque C handles, target и callback-scoped values не покидают `GhosttyBridge`.

Wire mapping:

- `GHOSTTY_PROGRESS_STATE_SET` → working с optional `0...100`;
- `GHOSTTY_PROGRESS_STATE_INDETERMINATE` → working без процента;
- `GHOSTTY_PROGRESS_STATE_PAUSE` → waiting;
- `GHOSTTY_PROGRESS_STATE_ERROR` → failed;
- `GHOSTTY_PROGRESS_STATE_REMOVE` → завершение или очистка текущего progress.

Progress events доставляются упорядоченно. Их нельзя coalesce-ить до MainActor: последовательность `working → remove` может полностью прийти до первого actor hop. Повторные одинаковые Pi keepalive обрабатываются reducer-ом как no-op и не сбрасывают время начала.

`GHOSTTY_ACTION_COMMAND_FINISHED` также копируется как surface event, но используется только как fallback для активного progress, который приложение не сняло. Он не начинает activity и не создаёт notifications для обычных shell-команд без OSC 9;4.

Pinned Ghostty option `progress-style = false` отключает badges и очищает live progress. `desktop-notifications = false` сохраняет badges, но запрещает QuickTTY-generated system notifications. Обе finalized настройки обновляются транзакционно при valid hot reload; invalid reload сохраняет последние valid значения.

## Transient state

Domain persistence не меняется. Новый MainActor-owned activity controller хранит записи по `PaneID`:

```text
idle
working(progress?, startedAt)
waiting(progress?, startedAt)
failed(progress?, startedAt, acknowledged)
completed(startedAt, acknowledged)
```

Правила переходов:

1. Первый `set`/`indeterminate` начинает activity и фиксирует monotonic instant.
2. Следующие working keepalive меняют только visible progress; `startedAt` сохраняется.
3. `pause` сохраняет исходный `startedAt` и создаёт one-shot attention transition.
4. `error` сохраняет исходный `startedAt` и создаёт one-shot failure transition.
5. `remove` после working/waiting создаёт completed; после failed или без active state очищает запись.
6. `COMMAND_FINISHED` завершает только существующий active progress; non-zero exit code даёт failed.
7. Новый working снимает прежний completed/failed acknowledgement.
8. Surface close, Retry replacement, model-only pane collapse и bridge shutdown очищают status/timers без notification.

Clock и delayed completion cleanup инъецируются для тестов; production использует monotonic clock. В key window выбранной tab completed/failed badge живёт три секунды. В background/inactive tab он сохраняется, пока tab не станет выбранной в key window. Waiting не acknowledgе-ится открытием tab: это live protocol state.

## Presentation

Status остаётся AppKit chrome state и не добавляется в `WorkspacePresentationState`, SwiftUI split tree, `TerminalTab`, `Workspace` или `WorkspaceStore`.

Tab badge расположен слева от title и не меняет live/manual title. Compact representation:

- indeterminate working — spinner;
- determinate working — percentage;
- waiting — pause/attention symbol;
- failed — error symbol;
- completed — checkmark.

Badge имеет tooltip и accessibility label. Terminal viewport, pane dimming, cursor и borders не меняются.

Tab status агрегирует все leaves, а не только active pane. Workspace status агрегирует все panes всех tabs. Приоритет:

```text
failed > waiting > working > completed
```

Для determinate aggregate процент показывается, только если все contributors победившей фазы determinate; используется среднее значение. Status-only refresh обновляет существующие visible tab items и existing `NSMenuItem` badges без `reloadData`, отмены inline rename, rebuild split host или сброса открытого workspace menu.

## Notifications

Небольшой `TerminalNotificationController` изолирует `UNUserNotificationCenter` за injectable client. Реальный center не используется в unit tests.

Eligibility:

- waiting/failed transition — сразу;
- completed — только если activity длилась не меньше пяти секунд;
- repeated keepalive и repeated same-state events — без новых requests;
- source destination должна всё ещё разрешаться в live workspace/tab/pane;
- notification запрещена при `activeWindow.isKeyWindow && source tab selected`;
- `desktop-notifications = false` запрещает request до проверки authorization.

Authorization запрашивается лениво при первом eligible event. Параллельные запросы coalesce-ятся; denied не вызывает повторных prompts. Перед foreground presentation suppression проверяется повторно.

Notification не содержит terminal title, command, cwd, prompt или agent text. Используются generic тексты QuickTTY: task waiting, failed или completed. В `userInfo` находятся только UUID destination и versioned internal marker.

Default click:

1. Проверяет exact workspace/tab/pane и live surface.
2. На candidate store активирует workspace, tab и pane транзакционно.
3. Показывает текущий Normal или Quake presentation без mode transition.
4. Commit-ит store один раз и обновляет presentation с terminal focus.
5. Не создаёт surface, shell или PTY и не меняет startup command.

Stale/closed destination становится no-op. Поздний response после shutdown игнорируется.

## CLI integrations

QuickTTY не изменяет `~/.pi`, `~/.claude`, `~/.codex`, shell rc или `.env` автоматически.

### Pi

Pi 0.82 уже отправляет `OSC 9;4;3` на `agent_start`, keepalive во время работы и `OSC 9;4;0` на `agent_end`, когда включена настройка **Terminal progress** (`terminal.showTerminalProgress`). Пользователь включает её через `/settings`; отдельный QuickTTY extension для basic working/completed не нужен.

### Claude Code

Claude Code 2.1.141+ hooks поддерживают JSON field `terminalSequence` и allowlist OSC 9;4. Примеры hooks переводят `UserPromptSubmit` в working, permission/needs-input notification в pause, `Stop` в remove и `StopFailure` в error. Hook stdout остаётся valid JSON и не попадает в prompt как случайный текст.

### Codex

Современный Codex lifecycle hooks дают `UserPromptSubmit`, `PermissionRequest`, `Stop` и `SessionEnd`. Hook process сохраняет controlling terminal, хотя stdout/stderr captured; bundled helper пишет OSC непосредственно в `/dev/tty` и возвращает допустимый пустой JSON там, где он требуется. Если controlling TTY недоступен, helper завершается успешно без изменения agent behavior.

Versioned, manually merged examples поставляются с приложением и документируются отдельно. Existing agent hook configs не перезаписываются.

## Ошибки и privacy

- Invalid action target/state/progress игнорируется и возвращает `false`.
- Notification errors логируются только как domain/code, без title, cwd, command и body.
- Отказ notification permission не влияет на badge.
- Отсутствие `/dev/tty` в Codex hook не блокирует Codex.
- Hook helpers не читают stdin payload, transcript, prompts или environment secrets.
- Vendor/ghostty и pin не меняются.

## Проверки

- Direct C-union mapping, invalid target/state, ordered delivery, teardown и same-`PaneID` replacement.
- Real OSC 9;4 PTY path.
- Reducer transitions, keepalive, exact 5-second threshold и `COMMAND_FINISHED` fallback с injectable clock.
- Config hot reload для `progress-style`/`desktop-notifications` и rollback invalid config.
- Aggregate priority/percentage across split panes, tabs и workspaces.
- Status-only refresh не закрывает rename, не rebuild-ит menu/split и не меняет first responder.
- Notification suppression matrix, lazy authorization, duplicate prevention и privacy.
- Click routing в Normal и hidden Quake без recreation surfaces.
- Shell contract tests для Pi instructions и Claude/Codex hook examples.
- Один integrated review и финальный `make check`.

## Вне scope

- Определение или показ agent identity.
- Parsing `π - project`, Claude/Codex titles или terminal text.
- Собственный OSC protocol, Unix socket или process-tree polling.
- История задач, persisted progress и notification content из terminal output.
- Pane overlay/frame и изменение terminal cursor.
- Автоматическая модификация сторонних конфигов.
