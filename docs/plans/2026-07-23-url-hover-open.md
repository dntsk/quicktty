# URL Hover and Open Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Интегрировать Ghostty `Cmd+hover` cursor state и `Cmd+click` native URL opening без first-party URL hit testing или preview UI.

**Architecture:** Surface-targeted mouse-shape actions проходят через `SurfaceCallbackContext` к cursor rect конкретной `GhosttySurfaceView`. Open-URL payload копируется в stable typed runtime action и открывается injectable MainActor workspace client; Ghostty остаётся владельцем detection/highlight/click semantics.

**Tech Stack:** Swift 6, AppKit, NSWorkspace, embedded pinned libghostty, Swift Testing.

---

### Task 1: Stable URL action и native workspace client

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyRuntimeAction.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Create or modify: `QuickTTY/Integration/GhosttyBridge/GhosttyWorkspaceURLClient.swift`
- Modify: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`

**Steps:**

1. Добавить failing tests для strict callback payload copy, kinds, empty/invalid UTF-8, exact action tag и one-shot delivery.
2. Добавить Sendable `GhosttyOpenURL` и `.openURL` в `GhosttyRuntimeAction`; arbitrary C pointers не хранить.
3. Добавить injectable MainActor workspace client с upstream conversion policy для schemes, paths, `~`, text/html/unknown.
4. Скомпоновать internal open handler с существующим optional runtime action handler без изменения прочих action contracts.
5. Запустить focused `GhosttyBridgeTests`.

### Task 2: Surface mouse-shape callback и cursor rects

**Files:**
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift`
- Modify: `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`
- Modify: `QuickTTYTests/Integration/GhosttyMouseInputTests.swift`
- Modify: `QuickTTYTests/Integration/GhosttyBridgeTests.swift`
- Modify: `scripts/check-runtime-callbacks.sh` только если callback contract требует новый symbol

**Steps:**

1. Добавить failing tests для typed shape conversion, pointing hand, latest-value coalescing, inactive context и split-surface independence.
2. Специально обработать surface-targeted `GHOSTTY_ACTION_MOUSE_SHAPE` в free callback и немедленно скопировать enum.
3. Расширить `SurfaceCallbackContext` pending state; deliver на MainActor только active context и очистить при deactivate.
4. Добавить `GhosttySurfaceView.resetCursorRects()` и native cursor mapping без `push/pop/set`.
5. Явно не хранить `mouse_over_link` и не добавлять preview UI.
6. Запустить mouse/bridge focused tests и callback contract.

### Task 3: Regression, documentation и final gate

**Files:**
- Modify: `QuickTTY/Resources/configuration-reference.md` только если нужен note о non-shortcut link behavior
- Modify: `docs/backlog.md`
- Modify: `.agents/memory/integration-contracts.md`
- Modify: `.agents/memory/architecture-decisions.md`
- Modify: `.agents/memory/tasks-completed.md`
- Create: `.agents/memory/handoffs/YYYY-MM-DD-HHMM-url-hover-open.md`

**Steps:**

1. Проверить mouse reporting, selection, close-before-delivery, no PTY write и no `open-url` action regressions.
2. Отметить URL hover/open выполненным в backlog; Search остаётся следующей обязательной задачей.
3. Обновить integration contracts и handoff на русском языке.
4. Выполнить `make format`, `git diff --check`, production callback audit и pin audit.
5. Провести один integrated review всей feature; исправить только Critical/Important findings одним пакетом.
6. Выполнить `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make check` один раз после review fixes.
7. Не коммитить/push и не перезапускать приложение без отдельной команды пользователя.
