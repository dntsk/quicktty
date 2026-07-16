#!/bin/sh
set -eu

bridge='GhostTerm/Integration/GhosttyBridge/GhosttyBridge.swift'
surface='GhostTerm/Integration/GhosttyBridge/GhosttySurfaceView.swift'

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

if grep -Eq 'MainActor\.assumeIsolated|Thread\.isMainThread' "$bridge" "$surface"; then
    printf 'runtime callback path contains an unsafe actor/thread workaround\n' >&2
    exit 1
fi

if grep -Eq '@unchecked[[:space:]]+Sendable' GhostTerm/Integration/GhosttyBridge/*.swift; then
    printf 'GhosttyBridge callback context must remain checked Sendable\n' >&2
    exit 1
fi
