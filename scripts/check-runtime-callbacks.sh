#!/bin/sh
set -eu

bridge='QuickTTY/Integration/GhosttyBridge/GhosttyBridge.swift'
surface='QuickTTY/Integration/GhosttyBridge/GhosttySurfaceView.swift'

for binding in \
    'wakeup_cb: ghosttyRuntimeWakeupCallback' \
    'action_cb: ghosttyRuntimeActionCallback' \
    'read_clipboard_cb: ghosttyRuntimeReadClipboardCallback' \
    'confirm_read_clipboard_cb: ghosttyRuntimeConfirmReadClipboardCallback' \
    'write_clipboard_cb: ghosttyRuntimeWriteClipboardCallback' \
    'close_surface_cb: ghosttyRuntimeCloseSurfaceCallback'
do
    if ! grep -Fq "$binding" "$bridge"; then
        printf 'runtime callback must use a free function: %s\n' "$binding" >&2
        exit 1
    fi
done

for function in \
    ghosttyRuntimeWakeupCallback \
    ghosttyRuntimeActionCallback \
    ghosttyRuntimeReadClipboardCallback \
    ghosttyRuntimeConfirmReadClipboardCallback \
    ghosttyRuntimeWriteClipboardCallback
do
    if ! grep -Eq "^private func ${function}\\(" "$bridge"; then
        printf 'runtime callback entry must remain a top-level free function: %s\n' "$function" >&2
        exit 1
    fi
done

if ! grep -Eq '^func ghosttyRuntimeCloseSurfaceCallback\(' "$surface"; then
    printf 'surface close callback entry must remain a top-level free function\n' >&2
    exit 1
fi

for mouse_contract in \
    'action.tag == GHOSTTY_ACTION_MOUSE_SHAPE' \
    'target.tag == GHOSTTY_TARGET_SURFACE' \
    'context.scheduleMouseShape' \
    'override func resetCursorRects()' \
    'invalidateCursorRects(for: self)'
do
    if ! grep -Fq "$mouse_contract" "$bridge" "$surface"; then
        printf 'surface mouse-shape callback contract is missing: %s\n' "$mouse_contract" >&2
        exit 1
    fi
done

for title_contract in \
    'action.tag == GHOSTTY_ACTION_SET_TITLE' \
    'action.tag == GHOSTTY_ACTION_SET_TAB_TITLE' \
    'action.tag == GHOSTTY_ACTION_PROMPT_TITLE' \
    'action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB' \
    'target.tag == GHOSTTY_TARGET_SURFACE' \
    'String(validatingCString: titlePointer)' \
    'context.scheduleTitleChange' \
    'context.scheduleTabTitleChange' \
    'context.scheduleTabTitlePrompt' \
    'surfaceTitleHandler?(paneID, title)' \
    'surfaceTabTitleHandler?(paneID, title)' \
    'surfaceTabTitlePromptHandler?(paneID)' \
    'var pendingTitle: String?' \
    'let shouldSchedule = state.pendingTitle == nil' \
    'state.pendingTitle = title' \
    'state.pendingTitle = nil' \
    'deliverTitleChangeIfActive'
do
    if ! grep -Fq "$title_contract" "$bridge" "$surface"; then
        printf 'surface title callback contract is missing: %s\n' "$title_contract" >&2
        exit 1
    fi
done

title_route='case .titleChanged(let title):
            surface.processCallbackEvent(
                event,
                confirmationHandler: clipboardConfirmationHandler
            )
            surfaceTitleHandler?(paneID, title)'
if ! grep -Fq "$title_route" "$bridge"; then
    printf 'automatic title must update its live surface before external routing\n' >&2
    exit 1
fi

if ! grep -Fq 'guard let surface = surfaces[paneID] else { return }' "$bridge"; then
    printf 'surface title callbacks must reject stale surface identities\n' >&2
    exit 1
fi

if grep -Fq 'GHOSTTY_ACTION_MOUSE_OVER_LINK' "$bridge" "$surface"; then
    printf 'mouse-over-link state must not enter the bridge without preview UI\n' >&2
    exit 1
fi

if grep -Eq '\.(push|set)\(\)|NSCursor\.pop\(\)' "$surface"; then
    printf 'surface cursor updates must use local cursor rects\n' >&2
    exit 1
fi

if grep -Eq 'MainActor\.assumeIsolated|Thread\.isMainThread' "$bridge" "$surface"; then
    printf 'runtime callback path contains an unsafe actor/thread workaround\n' >&2
    exit 1
fi

if grep -Eq '@unchecked[[:space:]]+Sendable' QuickTTY/Integration/GhosttyBridge/*.swift; then
    printf 'GhosttyBridge callback context must remain checked Sendable\n' >&2
    exit 1
fi
