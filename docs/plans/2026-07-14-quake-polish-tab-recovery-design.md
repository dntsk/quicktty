# Quake polish and tab recovery design

## Scope

Polish Quake presentation with a visible slide animation, mouse height resizing, and persistent height. Replace the single-surface presentation assumption with a runtime surface registry so users can create tabs and recover automatically after the final shell exits.

## Quake animation

The Quake panel remains a borderless `NSPanel`. Before showing, it is placed immediately above the selected screen, raised temporarily to `.popUpMenu`, ordered front, and animated on the next main run-loop turn. Deferring the frame animation prevents AppKit from coalescing the hidden and visible frames into a visual jump. Showing uses `easeOut`; hiding uses `easeIn`. After showing, the panel returns to `.floating` and receives keyboard focus. Cancellation and last-request-wins semantics remain unchanged.

## Mouse resize and persistence

The panel uses AppKit's native resizable window behavior. During live resize, its width and horizontal origin remain fixed to the selected screen, while the top edge stays anchored at `visibleFrame.maxY - padding`; only the bottom edge changes the height. A practical minimum height prevents collapsing the terminal chrome.

At the end of live resize, the controller converts the resulting height to a fraction of the selected screen's visible height and reports it to `AppDelegate`. `ConfigController` updates only `ghostterm-quake-height` through `ConfigDocument.setValue`, writes atomically, and applies the validated document. Existing comments, line endings, Ghostty options, and unrelated GhostTerm values are preserved. The current frame is not snapped by the resulting config callback; the persisted fraction is used on subsequent presentations and launches.

## Tabs and process exit

`WindowCoordinator` owns a `[PaneID: GhosttySurfaceView]` registry instead of one `defaultSurface`. A single `createShellTab()` path creates the Ghostty surface, descriptor, model tab, registry entry, presentation, and focus. It is used by startup, the tab-bar `+` button, and `Command+T`.

When a shell exits, its surface is explicitly removed from `GhosttyBridge`, the runtime registry, and `WorkspaceStore`. If no live tabs remain anywhere, GhostTerm immediately creates a replacement shell tab in the active workspace. If other tabs remain, normal active-tab correction is used. A creation failure leaves the application and empty workspace alive, reports the error, and keeps `+`/`Command+T` available.

## Testing

Pure tests cover resize geometry and height formatting. Config tests verify preserving and atomic update behavior. Presentation tests verify deferred animation ordering, levels, curves, cancellation, and top anchoring. Integration tests verify multiple surfaces, tab switching, explicit close, process exit cleanup, and final-tab replacement. UI tests verify `+` and `Command+T` route through the same action.
