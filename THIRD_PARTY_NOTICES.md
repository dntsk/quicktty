# Third-Party Notices

## Ghostty

QuickTTY uses Ghostty v1.3.1, pinned to commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

The static Ghostty embedding library is included in the application, but the `Vendor/ghostty` directory is not distributed in the DMG. QuickTTY also directly compiles the following pinned MIT-licensed sources without modification for split layout, divider, and pointer behavior:

- `macos/Sources/Features/Splits/SplitView.swift`;
- `macos/Sources/Features/Splits/SplitView.Divider.swift`;
- `macos/Sources/Helpers/Backport.swift`.

QuickTTY also adapts narrow portions of AppKit keyboard/IME and mouse/scroll behavior from the following files in the same pinned revision:

- `include/ghostty.h:43-57,59-98,835-847,918-963,972-1000,1100-1127` — clipboard, search, and mouse/scroll ABI;
- `macos/Sources/Ghostty/NSEvent+Extension.swift:3-76`;
- `macos/Sources/Ghostty/Ghostty.Input.swift` — modifier mapping, scoped key-event wrappers, and mouse/scroll value mapping around lines 253-535;
- `macos/Sources/Ghostty/Ghostty.App.swift:326-425,2023-2119` — clipboard read/confirm/write mapping and search callback lifecycle;
- `macos/Sources/Ghostty/GhosttyPackage.swift:248-309` — owned clipboard request/content types;
- `macos/Sources/Ghostty/Ghostty.Shell.swift:3-17` — shell escaping;
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift:193-205,400-600,1268-1279` — search state, SwiftUI overlay, and debounce;
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:71-106,376-390,641-701,820-1426,1485-1569,1571-1617,1808-2037` — search actions and keyboard/IME/mouse behavior;
- `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift`;
- `macos/Sources/Helpers/KeyboardLayout.swift`;
- `macos/Sources/Features/ClipboardConfirmation/ClipboardConfirmationController.swift`;
- `macos/Sources/Features/ClipboardConfirmation/ClipboardConfirmationView.swift`;
- `macos/Sources/Features/Terminal/BaseTerminalController.swift:1076-1136`;
- `src/apprt/embedded.zig` — clipboard request/two-call completion around lines 53-76, 660-755, and 1985-1999, plus mouse button/position/scroll wrappers around lines 820-897 and 1817-1868;
- `src/Surface.zig` — paste/copy/OSC52 safety and mouse button, position, and scroll callbacks.

The adapted code exists only in first-party bridge and presentation files and does not import the complete upstream macOS Swift wrapper. When updating Ghostty, these portions are ported manually after reviewing the upstream diff and running integration tests.

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

This notice describes the license terms for a third-party component. QuickTTY's first-party code is licensed separately under the repository's [MIT License](LICENSE).
