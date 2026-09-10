import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct TerminalControlPermissionControllerTests {
    @Test
    func disclosureUsesRegistryNameWithoutSessionIdentity() throws {
        let currentSession = try session()
        let presentation = TerminalControlPermissionPresentation(
            adapterID: currentSession.identity.adapterID)
        let alert = TerminalControlPermissionController.makeAlert(presentation)
        #expect(
            alert.informativeText
                == "Агент и запускаемые им инструменты смогут создавать terminal panes, читать их содержимое и отправлять в них ввод до завершения этой agent-сессии."
        )
        #expect(alert.messageText.contains(presentation.adapterDisplayName))
        #expect(!alert.messageText.contains(currentSession.identity.sessionID))
        #expect(alert.buttons.map(\.title) == ["Не разрешать", "Разрешить"])
    }

    @Test
    func productionSheetAttachesToExistingParentAndDismissesOnlyItself() async throws {
        let currentSession = try session()
        let window = makeWindow()
        let controller = TerminalControlPermissionController(timeout: 1)
        defer {
            controller.cancel()
            window.close()
        }
        var result: TerminalAutomationPermissionDecision?
        let request = Task { result = await controller.present(for: currentSession, on: window) }
        defer { request.cancel() }
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        #expect(sheet.sheetParent === window)
        controller.cancel(session: currentSession.identity)
        try await waitUntil { result != nil }
        #expect(result == .unavailable)
        #expect(sheet.sheetParent == nil)

        let unrelated = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            window.endSheet(unrelated)
            unrelated.orderOut(nil)
        }
        window.beginSheet(unrelated, completionHandler: nil)
        #expect(await controller.present(for: currentSession, on: window) == .unavailable)
        controller.cancel()
        #expect(window.attachedSheet === unrelated)
    }

    @Test
    func productionAllowAndDenyButtonsResolveSheet() async throws {
        let currentSession = try session()
        for allow in [false, true] {
            let window = makeWindow()
            let controller = TerminalControlPermissionController(timeout: 1)
            defer {
                controller.cancel()
                window.close()
            }
            var result: TerminalAutomationPermissionDecision?
            let request = Task {
                result = await controller.present(for: currentSession, on: window)
            }
            defer { request.cancel() }
            try await waitUntil { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            window.endSheet(
                sheet, returnCode: allow ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            try await waitUntil { result != nil }
            #expect(result == (allow ? .allowed : .denied))
        }
    }

    @Test
    func missingHiddenMiniaturizedAndOccupiedWindowsFailClosed() async throws {
        let currentSession = try session()
        let controller = TerminalControlPermissionController(timeout: 0.1)
        let window = makeWindow()
        defer {
            controller.cancel()
            window.close()
        }
        var calls = 0
        let presenter: TerminalControlPermissionController.AsyncPresenter = { _ in
            calls += 1
            return .allowed
        }
        #expect(
            await controller.present(for: currentSession, on: nil, using: presenter) == .unavailable
        )
        window.orderOut(nil)
        #expect(
            await controller.present(for: currentSession, on: window, using: presenter)
                == .unavailable)
        window.orderFront(nil)
        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized }
        #expect(
            await controller.present(for: currentSession, on: window, using: presenter)
                == .unavailable)
        #expect(calls == 0)
    }

    @Test
    func timeoutDoesNotWaitForUncooperativePresenterAndIgnoresLateAllow() async throws {
        let currentSession = try session()
        let window = makeWindow()
        let probe = PermissionSheetProbe()
        let controller = TerminalControlPermissionController(timeout: 0.05)
        defer {
            controller.cancel()
            probe.resolve(.denied)
            window.close()
        }
        var result: TerminalAutomationPermissionDecision?
        let request = Task {
            result = await controller.present(for: currentSession, on: window, using: probe.present)
        }
        defer { request.cancel() }
        try await waitUntil { result != nil }
        #expect(result == .unavailable)
        probe.resolve(.allowed)
        try await waitUntil { probe.didReturn }
        #expect(
            await controller.present(for: currentSession, on: window, using: { _ in .denied })
                == .denied
        )
        #expect(result == .unavailable)
    }

    @Test
    func exactCancellationAndStaleCallbackCannotResolveNextPrompt() async throws {
        let currentSession = try session()
        let nextSession = try session(generation: 2)
        let window = makeWindow()
        let probe = PermissionSheetProbe()
        let controller = TerminalControlPermissionController(timeout: 1)
        defer {
            controller.cancel()
            probe.resolve(.denied)
            window.close()
        }
        var first: TerminalAutomationPermissionDecision?
        let request = Task {
            first = await controller.present(for: currentSession, on: window, using: probe.present)
        }
        defer { request.cancel() }
        try await waitUntil { probe.continuation != nil }
        controller.cancel(session: nextSession.identity)
        #expect(first == nil)
        #expect(await controller.present(for: nextSession, on: window) == .unavailable)
        controller.cancel(session: currentSession.identity)
        try await waitUntil { first != nil }
        #expect(first == .unavailable)
        var second: TerminalAutomationPermissionDecision?
        let next = Task {
            second = await controller.present(for: nextSession, on: window)
        }
        defer { next.cancel() }
        try await waitUntil { window.attachedSheet != nil }
        probe.resolve(.allowed)
        try await waitUntil { probe.didReturn }
        #expect(second == nil)
        controller.cancel()
        try await waitUntil { second != nil }
        #expect(second == .unavailable)
    }

    @Test
    func injectedSheetDismissalIsReentrantAndLateCallbackCannotAllow() async throws {
        let currentSession = try session()
        let window = makeWindow()
        var callback: TerminalControlPermissionController.Completion?
        var dismissals = 0
        let controller = TerminalControlPermissionController(
            timeout: 0.05,
            sheetPresenter: { _, parent, completion in
                #expect(parent === window)
                callback = completion
                return TerminalControlPermissionController.Sheet(
                    isAttached: { true },
                    dismiss: {
                        dismissals += 1
                        completion(.allowed)
                    })
            })
        defer {
            controller.cancel()
            window.close()
        }
        var result: TerminalAutomationPermissionDecision?
        let request = Task { result = await controller.present(for: currentSession, on: window) }
        defer { request.cancel() }
        try await waitUntil { result != nil }
        #expect(result == .unavailable)
        #expect(dismissals == 1)
        callback?(.allowed)
        #expect(result == .unavailable)
        #expect(dismissals == 1)
    }

    @Test
    func productionTimeoutDismissesAttachedSheet() async throws {
        let currentSession = try session()
        let window = makeWindow()
        let controller = TerminalControlPermissionController(timeout: 1)
        defer {
            controller.cancel()
            window.close()
        }
        var result: TerminalAutomationPermissionDecision?
        let request = Task { result = await controller.present(for: currentSession, on: window) }
        defer { request.cancel() }
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await waitUntil { result != nil }
        #expect(result == .unavailable)
        #expect(sheet.sheetParent == nil)
        #expect(window.attachedSheet == nil)
    }

    @Test
    func cancellationAndParentLossDismissProductionSheet() async throws {
        let currentSession = try session()
        for cancelTask in [false, true] {
            let window = makeWindow()
            let controller = TerminalControlPermissionController(timeout: 1)
            defer {
                controller.cancel()
                window.close()
            }
            var result: TerminalAutomationPermissionDecision?
            let request = Task {
                result = await controller.present(for: currentSession, on: window)
            }
            defer { request.cancel() }
            try await waitUntil { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            if cancelTask { request.cancel() } else { window.orderOut(nil) }
            try await waitUntil { result != nil }
            #expect(result == .unavailable)
            #expect(sheet.sheetParent == nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func session(generation: UInt64 = 1) throws -> TerminalAutomationResolvedSession {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tab = TabID(rawValue: id)
        return TerminalAutomationResolvedSession(
            identity: TerminalAutomationSessionIdentity(
                instanceID: id, originPaneID: PaneID(rawValue: id),
                adapterID: try AgentAdapterID(rawValue: "claude-code"),
                sessionID: "never-display-session-secret",
                paneCredentialGeneration: generation),
            workspace: TerminalAutomationWorkspaceContext(
                workspaceID: WorkspaceID(rawValue: id), name: "Main", originTabID: tab,
                activeTabID: tab, tabCount: 1, paneCount: 1))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw PermissionTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class PermissionSheetProbe {
    var continuation: CheckedContinuation<TerminalAutomationPermissionDecision, Never>?
    var didReturn = false

    func present(_ session: TerminalAutomationResolvedSession) async
        -> TerminalAutomationPermissionDecision
    {
        let decision = await withCheckedContinuation { continuation = $0 }
        didReturn = true
        return decision
    }

    func resolve(_ decision: TerminalAutomationPermissionDecision) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: decision)
    }
}

private enum PermissionTestError: Error { case timeout }
