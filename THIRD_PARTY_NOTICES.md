# Уведомления о сторонних компонентах

## Ghostty

GhostTerm использует Ghostty v1.3.1, закреплённый на commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

Статическая embedding-библиотека Ghostty включается в приложение, но каталог `Vendor/ghostty` не поставляется в DMG. Кроме того, GhostTerm адаптирует узкие части AppKit keyboard/IME и mouse/scroll-поведения из следующих файлов той же закреплённой ревизии:

- `include/ghostty.h:43-57,59-98,972-1000,1100-1127` — clipboard и mouse/scroll ABI;
- `macos/Sources/Ghostty/NSEvent+Extension.swift:3-76`;
- `macos/Sources/Ghostty/Ghostty.Input.swift` — modifier mapping, scoped key-event wrappers и mouse/scroll value mapping около строк 253-535;
- `macos/Sources/Ghostty/Ghostty.App.swift:326-425` — clipboard read/confirm/write mapping;
- `macos/Sources/Ghostty/GhosttyPackage.swift:248-309` — owned clipboard request/content types;
- `macos/Sources/Ghostty/Ghostty.Shell.swift:3-17` — shell escaping;
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:376-390,641-701,820-1426,1485-1569,1808-2037`;
- `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift`;
- `macos/Sources/Helpers/KeyboardLayout.swift`;
- `macos/Sources/Features/ClipboardConfirmation/ClipboardConfirmationController.swift`;
- `macos/Sources/Features/ClipboardConfirmation/ClipboardConfirmationView.swift`;
- `macos/Sources/Features/Terminal/BaseTerminalController.swift:1076-1136`;
- `src/apprt/embedded.zig` — clipboard request/two-call completion около строк 53-76, 660-755 и 1985-1999, mouse button/position/scroll wrappers около строк 820-897 и 1817-1868;
- `src/Surface.zig` — paste/copy/OSC52 safety и mouse button, position, scroll callbacks.

Адаптированный код находится только в first-party bridge/presentation-файлах и не импортирует полный upstream macOS Swift wrapper. При обновлении Ghostty эти участки переносятся вручную после сравнения upstream diff и прогона integration tests.

### MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Это уведомление описывает лицензию стороннего компонента и не определяет лицензию самого GhostTerm.
