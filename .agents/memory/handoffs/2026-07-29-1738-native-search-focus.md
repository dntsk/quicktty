# Handoff: повторный фокус native search

- **Дата:** 2026-07-29
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения

## Выполнено

- В `QuickTTY/Presentation/Search/GhosttySurfaceSearchOverlay.swift` добавлен маленький helper для нового transition фокуса: сначала сброс `isSearchFieldFocused = false`, затем `DispatchQueue.main.async { true }`.
- Этот helper используется и на `.onAppear`, и при matching notification `QuickTTY.GhosttySearchFocus`.
- В `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift` убран `hostingView.window?.makeFirstResponder(hostingView)` из deferred scheduling initial focus.

## Проверки

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -destination 'platform=macOS' build` — успешно.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -destination 'platform=macOS' test -only-testing:QuickTTYTests/GhosttySurfaceSearchOverlayTests -only-testing:QuickTTYTests/GhosttyBridgeTests` — невалидный селектор, тесты не запустились как intended.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuickTTY.xcodeproj -scheme QuickTTY -destination 'platform=macOS' test -only-testing:QuickTTYTests/GhosttyKeyboardInputTests/hostedSearchFocusCallbackAndConfiguredFindRoutingUseProductionPaths` — succeeded, но фильтр в итоге не выполнил tests.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift-format lint ...` — остались warnings в `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift`.
- `git diff --check` — clean.

## Незавершённое

- Нет добавленного regression-теста именно на повторный focus transition: стабильного production seam без искусственного API не нашёл.
- `swift-format lint` ещё ругается на форматирование в `GhosttySurfaceView.swift`.

## Следующий шаг

1. Если нужно добить качество, отформатировать `QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift` под `swift-format`.
2. При необходимости добавить тест только если появится стабильный seam для наблюдения transition фокуса.

## Важный контекст

- Не трогать `Vendor/pin/dependencies/API`, hit-testing и Escape behavior.
- `Escape`-закрытие и Y hit-test fixes сохранены.
- Локальная причина бага исправлена через forced refocus transition, а не через `makeFirstResponder(hostingView)`.
