import AppKit
import Synchronization
import Testing

@testable import QuickTTY

@MainActor
struct AgentTelegramViewTests {
    @Test
    func unpairedSetupIsSecureAndRefreshPreservesTokenDraft() throws {
        let calls = CredentialCallRecorder()
        let service = try makeService(credentialCalls: calls)
        defer { service.shutdown() }
        let view = AgentTelegramView(service: service)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        let secureField = try #require(
            descendants(view).compactMap { $0 as? NSSecureTextField }.first)
        secureField.stringValue = "123456:not-a-real-token"
        view.refresh()

        #expect(secureField.stringValue == "123456:not-a-real-token")
        #expect(service.connection.phase == .disconnected)
        #expect(calls.value == 0)
        #expect(
            descendants(view).compactMap { $0 as? NSButton }.contains {
                $0.title == "Use Telegram for agents"
            })
        #expect(
            descendants(view).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("not end-to-end encrypted")
            })
        view.cancelSetup()
        #expect(secureField.stringValue.isEmpty)
        #expect(calls.value == 0)
    }

    @Test
    func closingDisconnectedSetupDoesNotReadOrDeleteCredentials() throws {
        let calls = CredentialCallRecorder()
        let service = try makeService(credentialCalls: calls)
        defer { service.shutdown() }
        let view = AgentTelegramView(service: service)
        view.cancelSetup()
        view.refresh()
        #expect(calls.value == 0)
        #expect(service.connection.phase == .disconnected)
    }

    @Test
    func pendingQuestionRefreshPreservesReplyAndDoesNotRenderSessionIdentity() async throws {
        let pane = PaneID()
        let sessionID = "ui-session-must-not-be-rendered"
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "pi"), sessionID: sessionID,
            workingDirectory: "/tmp", registeredAt: Date(), launchMetadata: [:],
            restoreState: .active)
        let workspace = Workspace(
            name: "Questions",
            tabs: [
                TerminalTab(
                    title: "Pi",
                    pane: TerminalPaneDescriptor(id: pane, cwd: "/tmp", agentResumeBinding: binding)
                )
            ])
        let sessions = try AgentSessionController(
            socketPath: "/tmp/telegram-ui-question.sock", helperPath: "/test/quicktty"
        ) { _ in true }
        let token = try TelegramBotToken("123456:not-a-real-token")
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { [workspace] }, paneIsLive: { $0 == pane },
            credentials: TelegramCredentialStore(
                load: { TelegramSavedConnection(token: token, peer: peer) }, save: { _, _ in },
                remove: {}),
            preferences: .transient(),
            makeClient: { token in
                TelegramBotClient(
                    token: token,
                    transport: { request in
                        let result: String
                        switch request.url!.lastPathComponent {
                        case "getMe": result = "{\"id\":1,\"is_bot\":true}"
                        case "getUpdates": result = "[]"
                        default:
                            result =
                                "{\"message_id\":100,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
                        }
                        return TelegramHTTPResponse(
                            data: Data("{\"ok\":true,\"result\":\(result)}".utf8),
                            response: HTTPURLResponse(
                                url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: nil)!)
                    })
            }
        )
        defer { service.shutdown() }
        let environment = try #require(sessions.register(paneID: pane))
        let identity = try AgentIPCIdentity(
            instanceID: sessions.instanceID, paneID: pane.rawValue,
            paneToken: #require(environment["QUICKTTY_PANE_TOKEN"]), adapterID: "pi")
        let event = AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: identity, sessionID: sessionID, cwd: "/tmp", metadata: [:])))
        #expect(await sessions.handle(event))
        await service.connection.restoreSavedConnection()
        let origin = try #require(service.origins().first?.origin)
        #expect(service.isAuthorized(origin))
        let view = AgentTelegramView(service: service)
        let request = try AgentInteractionRequest(
            id: UUID(), origin: origin, prompt: .question(text: "Which option?", choices: []))
        try service.connection.submit(request)
        let field = try #require(
            descendants(view).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && !($0 is NSSecureTextField)
            })
        field.stringValue = "My draft answer"
        view.refresh()
        #expect(descendants(view).contains { $0 === field })
        #expect(field.stringValue == "My draft answer")
        #expect(
            !descendants(view).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains(sessionID)
            })
        let send = try #require(
            descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Send reply" })
        send.performClick(nil)
        #expect(
            service.connection.snapshot(request.id)?.state == .resolved(.text("My draft answer")))
    }

    @Test
    func interfaceHasOneGlobalSwitchAndNoManualWorkspaceSessionOrCopySteps() throws {
        let calls = CredentialCallRecorder()
        let service = try makeService(credentialCalls: calls)
        defer { service.shutdown() }
        let view = AgentTelegramView(service: service)
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        let toggle = try #require(buttons.first { $0.title == "Use Telegram for agents" })
        #expect(toggle.state == .off)
        #expect(
            !buttons.contains {
                $0.title.hasPrefix("Allow ") || $0.title.hasPrefix("Copy instructions")
            })
        #expect(!buttons.contains { $0.title == "UI test" })
        #expect(buttons.contains { $0.title == "Connection settings" })
        #expect(buttons.contains { $0.title == "Privacy and compatibility" })
        #expect(calls.value == 0)
    }

    @Test
    func closingSettingsDoesNotCancelAutomaticRestore() async throws {
        let gate = TelegramViewVerificationGate()
        let sessions = try AgentSessionController(
            socketPath: "/tmp/telegram-ui-autoconnect.sock", helperPath: "/test/quicktty"
        ) { _ in true }
        let token = try TelegramBotToken("123456:ui-autoconnect-fixture")
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let preferences = TelegramConnectionPreferences.transient(enabled: true)
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { [] }, paneIsLive: { _ in false },
            credentials: TelegramCredentialStore(
                load: { TelegramSavedConnection(token: token, peer: peer) },
                save: { _, _ in }, remove: {}),
            preferences: preferences,
            makeClient: { token in
                TelegramBotClient(
                    token: token,
                    transport: { request in
                        let result: String
                        if request.url!.lastPathComponent == "getMe" {
                            await gate.verify()
                            result = "{\"id\":1,\"is_bot\":true}"
                        } else {
                            try await Task.sleep(for: .seconds(25))
                            result = "[]"
                        }
                        return TelegramHTTPResponse(
                            data: Data("{\"ok\":true,\"result\":\(result)}".utf8),
                            response: HTTPURLResponse(
                                url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: nil)!)
                    })
            })
        defer { service.shutdown() }
        let view = AgentTelegramView(service: service)
        await gate.waitForVerification()
        #expect(service.connection.phase == .verifying)
        view.cancelSetup()
        #expect(service.connection.phase == .verifying)
        #expect(preferences.loadEnabled())
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.connection.phase == .verifying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.connection.phase == .connected(peer))
        let toggle = try #require(
            descendants(view).compactMap { $0 as? NSButton }.first {
                $0.title == "Use Telegram for agents"
            })
        #expect(toggle.state == .on)
        toggle.performClick(nil)
        #expect(service.connection.phase == .disconnected)
        #expect(!preferences.loadEnabled())
    }

    private func makeService(credentialCalls recorder: CredentialCallRecorder) throws
        -> AgentMessagingService
    {
        let workspace = Workspace(name: "UI test")
        let sessions = try AgentSessionController(
            socketPath: "/tmp/telegram-ui-test.sock", helperPath: "/test/quicktty"
        ) { _ in true }
        return try AgentMessagingService(
            sessions: sessions, workspaceProvider: { [workspace] }, paneIsLive: { _ in false },
            credentials: TelegramCredentialStore(
                load: {
                    recorder.record()
                    return nil
                },
                save: { _, _ in recorder.record() },
                remove: { recorder.record() }
            ),
            preferences: .transient(),
            makeClient: { token in
                TelegramBotClient(
                    token: token, transport: { _ in throw TelegramBotClientError.transportFailure })
            }
        )
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private actor TelegramViewVerificationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var verification: CheckedContinuation<Void, Never>?
    func verify() async {
        started = true
        await withCheckedContinuation { continuation in
            verification = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitForVerification() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        verification?.resume()
        verification = nil
    }
}

private final class CredentialCallRecorder: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func record() { count.withLock { $0 += 1 } }
}
