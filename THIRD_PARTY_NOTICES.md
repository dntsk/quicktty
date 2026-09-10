# Third-Party Notices

## Ghostty

QuickTTY uses Ghostty v1.3.1, pinned to commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

The native library build applies four MIT-licensed patches, in order, from `scripts/patches/ghostty` to an isolated snapshot, without modifying the pinned upstream sources:

- `0001-free-text-abi.patch` is the exact one-line backport of upstream commit `4803d58bb4ea8d2a71ebc1e5239f09a060e9e7c3`, matching the existing two-argument C declaration of `ghostty_surface_free_text`.
- `0002-screen-point-bounds.patch` is a QuickTTY-local fix for exact SCREEN/HISTORY y-coordinate bounds. It is not an upstream fix; active/viewport bounds, corner behavior, and public headers remain unchanged.
- `0003-darwin-process-exit-status.patch` is a QuickTTY-local change limited to `src/termio/Exec.zig` on Darwin's static kqueue backend. Its low-level process registration mirrors the pinned MIT-licensed libxev `ProcessKqueue.wait`, but performs the single reap in Ghostty to retain the raw status: normal `EXITSTATUS`, conventional `128 + TERMSIG`, or `UInt32.max` for unavailable/unrepresentable terminal status or ECHILD. A watcher error alone never reports exit or discards a collected raw status. If a single nonblocking wait probe cannot confirm exit, the existing termios timer continues observation (250 ms between fallback ticks, including while unfocused) without re-registering the failed watcher. Cancellation and teardown disable observation without reaping or notifying from callbacks; cleanup ownership is retained until a terminal status is reaped or ECHILD confirms the child is no longer ours. Other platforms retain the existing watcher and timer behavior. No launch mode, C ABI, dependency, or pinned revision changes are made, and libxev itself is not modified. This is not a general upstream fix: the revised timer fallback has not been compiled or runtime-tested; normal nonzero status propagation through `login` and cancellation/fault timing remain unverified. Final-tail PTY EOF ordering is addressed separately by `0004` below and remains runtime-unverified.
- `0004-managed-terminal-control.patch` is a QuickTTY-local change limited to `include/ghostty.h`, `src/apprt/embedded.zig`, `src/Surface.zig`, `src/termio/Exec.zig`, and `src/termio/Termio.zig`. Its explicit managed-only factory launches the helper directly as the root child, avoiding the `login` intermediary that can obscure the managed command's exit status; normal and restored login launches remain unchanged. The private, prefixed C API consists of `quicktty_surface_new_managed`, `quicktty_surface_output_state`, and `quicktty_surface_read_tail`; both the C header declarations and compiled functions are included in the generated native package. The output-state helper reads actual atomic native reader state: completion requires PTY EOF after parsing, independently of root process exit; failure and cancellation do not manufacture completion. Managed surfaces omit Ghostty's synthetic exit notice because the host supplies the exit badge. The tail helper reads the current bounded terminal suffix under the renderer lock without allocating the whole history; final capture must first check reader completion. The existing `Text`/`ghostty_text_s` layout and two-argument `ghostty_surface_free_text` ABI are preserved. This patch does not change dependencies or the pinned revision. The runtime fix is not yet verified: fresh native compilation, packaged header/export integration, managed exit/EOF/final-tail behavior, and normal/restore regression checks remain outstanding.

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
