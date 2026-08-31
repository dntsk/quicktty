import Darwin
import Foundation
import Synchronization
import Testing

@testable import QuickTTY

@MainActor
struct AgentSessionControllerTests {
    private let instanceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let socketPath = "/tmp/quicktty-test/agent.sock"
    private let helperPath = "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
    private let date = Date(timeIntervalSinceReferenceDate: 123_456)

    @Test
    func exposesExactEnvironmentWithDistinct256BitLowercaseHexTokens() throws {
        let recorder = AgentLifecycleActionRecorder()
        let tokens = AgentTokenSequence([
            Array(0..<32),
            Array(32..<64),
        ])
        let controller = try makeController(tokens: tokens, recorder: recorder)
        let firstPaneID = paneID("11111111-2222-3333-4444-555555555555")
        let secondPaneID = paneID("66666666-7777-8888-9999-AAAAAAAAAAAA")

        let firstEnvironment = try #require(controller.register(paneID: firstPaneID))
        let secondEnvironment = try #require(controller.register(paneID: secondPaneID))
        let firstToken = try #require(firstEnvironment["QUICKTTY_PANE_TOKEN"])
        let secondToken = try #require(secondEnvironment["QUICKTTY_PANE_TOKEN"])

        #expect(
            firstEnvironment == [
                "QUICKTTY_PANE_ID": firstPaneID.rawValue.uuidString,
                "QUICKTTY_AGENT_SOCKET": socketPath,
                "QUICKTTY_INSTANCE_ID": instanceID.uuidString,
                "QUICKTTY_PANE_TOKEN":
                    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                "QUICKTTY_AGENT_HELPER": helperPath,
            ])
        #expect(firstToken.count == 64)
        #expect(firstToken.allSatisfy { $0.isNumber || ("a"..."f").contains($0) })
        #expect(secondToken.count == 64)
        #expect(secondToken != firstToken)
        #expect(controller.environment(for: firstPaneID) == firstEnvironment)
        #expect(controller.environment(for: secondPaneID) == secondEnvironment)
    }

    @Test
    func rotatesSamePaneImmediatelyAndRevokesCredentials() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let controller = try makeController(
            tokens: AgentTokenSequence([
                Array(repeating: 0x11, count: 32),
                Array(repeating: 0x22, count: 32),
            ]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let oldEnvironment = try #require(controller.register(paneID: paneID))
        let oldMessage = try registerMessage(
            paneID: paneID,
            token: try #require(oldEnvironment["QUICKTTY_PANE_TOKEN"])
        )

        let rotatedEnvironment = try #require(controller.rotate(paneID: paneID))
        #expect(rotatedEnvironment["QUICKTTY_PANE_TOKEN"] == String(repeating: "22", count: 32))
        #expect(await !controller.handle(oldMessage))
        #expect(controller.rotate(paneID: PaneID()) == nil)

        controller.revoke(paneID: paneID)
        #expect(controller.environment(for: paneID) == nil)
        #expect(await !controller.handle(oldMessage))
    }

    @Test
    func deliversExactRegisterReplaceAndUnregisterActions() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let controller = try makeController(
            tokens: AgentTokenSequence([Array(repeating: 0xab, count: 32)]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let token = try #require(environment["QUICKTTY_PANE_TOKEN"])
        let adapterID = try AgentAdapterID(rawValue: "claude")

        let register = try registerMessage(
            paneID: paneID,
            token: token,
            sessionID: "session-1",
            cwd: "/tmp/project"
        )
        let replace = try replaceMessage(
            paneID: paneID,
            token: token,
            previousSessionID: "session-1",
            sessionID: "session-2",
            cwd: "/tmp/replacement"
        )
        let unregister = try unregisterMessage(
            paneID: paneID,
            token: token,
            sessionID: "session-2"
        )
        let expectedActions: [AgentSessionLifecycleAction] = [
            .register(
                paneID: paneID,
                binding: try binding(
                    adapterID: adapterID,
                    sessionID: "session-1",
                    cwd: "/tmp/project"
                )
            ),
            .replace(
                paneID: paneID,
                previousSessionID: "session-1",
                binding: try binding(
                    adapterID: adapterID,
                    sessionID: "session-2",
                    cwd: "/tmp/replacement"
                )
            ),
            .unregister(
                paneID: paneID,
                adapterID: adapterID,
                sessionID: "session-2"
            ),
        ]

        #expect(await controller.handle(register))
        #expect(await controller.handle(replace))
        #expect(await controller.handle(unregister))
        #expect(recorder.actions == expectedActions)
    }

    @Test
    func controllerActionsAtomicallyUpdateOnlyMatchingLivePaneBindingAndPersistOnce() async throws {
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let tab = TerminalTab(
            title: "Agent",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Agent", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let actionRouter = AgentLifecycleActionRouter()
        let controller = try AgentSessionController(
            socketPath: socketPath,
            helperPath: helperPath,
            instanceID: instanceID,
            tokenGenerator: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]).next,
            dateProvider: { date },
            onAction: actionRouter.route
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var snapshots: [WorkspaceStore] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            agentSessionController: controller,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        actionRouter.install(coordinator)
        try coordinator.start()
        snapshots.removeAll()
        let token = try #require(
            controller.environment(for: paneID)?["QUICKTTY_PANE_TOKEN"]
        )
        let adapterID = try AgentAdapterID(rawValue: "claude")

        #expect(
            await controller.handle(
                try registerMessage(
                    paneID: paneID,
                    token: token,
                    sessionID: "session-1",
                    cwd: "/tmp/one"
                ))
        )
        let registeredBinding = try binding(
            adapterID: adapterID,
            sessionID: "session-1",
            cwd: "/tmp/one"
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == registeredBinding
        )
        #expect(snapshots.count == 1)

        #expect(
            await !controller.handle(
                try replaceMessage(
                    paneID: paneID,
                    token: token,
                    previousSessionID: "stale-session",
                    sessionID: "session-2"
                ))
        )
        #expect(snapshots.count == 1)

        #expect(
            await controller.handle(
                try replaceMessage(
                    paneID: paneID,
                    token: token,
                    previousSessionID: "session-1",
                    sessionID: "session-2",
                    cwd: "/tmp/two"
                ))
        )
        let replacementBinding = try binding(
            adapterID: adapterID,
            sessionID: "session-2",
            cwd: "/tmp/two"
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == replacementBinding
        )
        #expect(snapshots.count == 2)

        #expect(
            await !controller.handle(
                try registerMessage(
                    paneID: paneID,
                    token: token,
                    sessionID: "session-1",
                    cwd: "/tmp/one"
                ))
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == replacementBinding
        )
        #expect(snapshots.count == 2)

        #expect(
            await controller.handle(
                try registerMessage(
                    paneID: paneID,
                    token: token,
                    sessionID: "session-2",
                    cwd: "/tmp/two"
                ))
        )
        #expect(snapshots.count == 2)

        let mismatchedAdapterBinding = try binding(
            adapterID: AgentAdapterID(rawValue: "codex"),
            sessionID: "session-3",
            cwd: "/tmp/three"
        )
        #expect(
            !coordinator.handleAgentSessionLifecycleAction(
                .replace(
                    paneID: paneID,
                    previousSessionID: "session-2",
                    binding: mismatchedAdapterBinding
                ))
        )
        #expect(
            !coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: paneID, binding: mismatchedAdapterBinding)
            )
        )
        #expect(snapshots.count == 2)
        #expect(
            !coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: PaneID(), binding: mismatchedAdapterBinding)
            )
        )
        #expect(snapshots.count == 2)

        #expect(
            await !controller.handle(
                try unregisterMessage(
                    paneID: paneID,
                    token: token,
                    sessionID: "session-1"
                ))
        )
        #expect(snapshots.count == 2)
        #expect(
            await controller.handle(
                try unregisterMessage(
                    paneID: paneID,
                    token: token,
                    sessionID: "session-2"
                ))
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == nil
        )
        #expect(snapshots.count == 3)

        #expect(
            coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: paneID, binding: mismatchedAdapterBinding)
            )
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == mismatchedAdapterBinding
        )
        #expect(snapshots.count == 4)
    }

    @Test
    func rejectsInvalidIdentityCredentialAndAdapterBeforeCallback() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let controller = try makeController(
            tokens: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let token = try #require(environment["QUICKTTY_PANE_TOKEN"])

        let rejectedMessages = try [
            registerMessage(
                instanceID: UUID(),
                paneID: paneID,
                token: token
            ),
            registerMessage(
                paneID: PaneID(),
                token: token
            ),
            registerMessage(
                paneID: paneID,
                token: String(repeating: "b", count: 64)
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                adapterID: "unknown-agent"
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                adapterID: "grok"
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                sessionID: "--leading-option"
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                metadata: ["model": "opus"]
            ),
        ]

        for message in rejectedMessages {
            #expect(await !controller.handle(message))
        }
        #expect(recorder.actions.isEmpty)
    }

    @Test
    func routerRejectsInvalidSemanticsBeforeMainActorHop() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let hopCount = Mutex(0)
        let controller = try AgentSessionController(
            socketPath: socketPath,
            helperPath: helperPath,
            instanceID: instanceID,
            tokenGenerator: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]).next,
            dateProvider: { self.date },
            onMainActorHop: { hopCount.withLock { $0 += 1 } },
            onAction: recorder.record
        )
        let router = AgentMessageRouter()
        router.install(controller)
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let token = try #require(environment["QUICKTTY_PANE_TOKEN"])
        let rejectedMessages = try [
            registerMessage(
                paneID: paneID,
                token: String(repeating: "b", count: 64)
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                adapterID: "unknown-agent"
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                adapterID: "grok"
            ),
            registerMessage(
                paneID: paneID,
                token: token,
                sessionID: "--leading-option"
            ),
        ]

        let rejectedResults = await Task.detached {
            var results: [Bool] = []
            for message in rejectedMessages {
                results.append(await router.route(message))
            }
            return results
        }.value

        #expect(rejectedResults == Array(repeating: false, count: rejectedMessages.count))
        #expect(hopCount.withLock { $0 } == 0)
        #expect(recorder.actions.isEmpty)

        let validMessage = try registerMessage(paneID: paneID, token: token)
        #expect(await Task.detached { await router.route(validMessage) }.value)
        #expect(hopCount.withLock { $0 } == 1)
        #expect(recorder.actions.count == 1)
    }

    @Test
    func rejectsInvalidPreviousReplacementAndUnregisterSessionIDs() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let controller = try makeController(
            tokens: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let token = try #require(environment["QUICKTTY_PANE_TOKEN"])

        let invalidPrevious = try replaceMessage(
            paneID: paneID,
            token: token,
            previousSessionID: "--old",
            sessionID: "new"
        )
        let sameSession = try replaceMessage(
            paneID: paneID,
            token: token,
            previousSessionID: "same",
            sessionID: "same"
        )
        let invalidUnregister = try unregisterMessage(
            paneID: paneID,
            token: token,
            sessionID: "--invalid"
        )

        #expect(await !controller.handle(invalidPrevious))
        #expect(await !controller.handle(sameSession))
        #expect(await !controller.handle(invalidUnregister))
        #expect(recorder.actions.isEmpty)
    }

    @Test
    func definitionReturnsTypedLifecycleValidationWithoutChangingResumePolicy() throws {
        let definition = try #require(
            AgentIntegrationRegistry.definition(for: AgentAdapterID(rawValue: "claude"))
        )

        #expect(
            definition.validateLifecycle(
                sessionID: "session",
                cwd: "/tmp",
                metadata: [:]
            ) == .valid)
        #expect(
            definition.validateLifecycle(
                sessionID: "--help",
                cwd: "/tmp",
                metadata: [:]
            ) == .invalid(.invalidSessionID))
        for cwd in ["/", "/Volumes/External/猫-é", "/missing/canonical/project"] {
            #expect(
                definition.validateLifecycle(
                    sessionID: "session",
                    cwd: cwd,
                    metadata: [:]
                ) == .valid)
        }
        for cwd in [
            "relative", "//tmp", "/tmp//project", "/./tmp", "/tmp/../project", "/tmp/",
            "/tmp/e\u{301}",
        ] {
            #expect(
                definition.validateLifecycle(
                    sessionID: "session",
                    cwd: cwd,
                    metadata: [:]
                ) == .invalid(.invalidWorkingDirectory))
        }
        #expect(
            definition.validateLifecycle(
                sessionID: "session",
                cwd: "/tmp",
                metadata: ["model": "opus"]
            ) == .invalid(.invalidMetadata))
        #expect(definition.validateUnregister(sessionID: "") == .invalid(.invalidSessionID))
        #expect(definition.validateUnregister(sessionID: "session") == .valid)
    }

    @Test
    func callbackRejectionReturnsFalseWithoutChangingCredentials() async throws {
        let recorder = AgentLifecycleActionRecorder(acceptsActions: false)
        let controller = try makeController(
            tokens: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let message = try registerMessage(
            paneID: paneID,
            token: #require(environment["QUICKTTY_PANE_TOKEN"])
        )

        #expect(await !controller.handle(message))
        #expect(recorder.actions.count == 1)
        #expect(controller.environment(for: paneID) == environment)
    }

    @Test
    func freezeIsIdempotentAndRejectsQueuedMessagesAndEnvironmentAccess() async throws {
        let recorder = AgentLifecycleActionRecorder()
        let controller = try makeController(
            tokens: AgentTokenSequence([Array(repeating: 0xaa, count: 32)]),
            recorder: recorder
        )
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let environment = try #require(controller.register(paneID: paneID))
        let message = try registerMessage(
            paneID: paneID,
            token: #require(environment["QUICKTTY_PANE_TOKEN"])
        )
        let queued = Task { @MainActor in
            await Task.yield()
            return await controller.handle(message)
        }

        controller.freeze()
        controller.freeze()

        #expect(await !queued.value)
        #expect(await !controller.handle(message))
        #expect(controller.environment(for: paneID) == nil)
        #expect(controller.register(paneID: paneID) == nil)
        #expect(controller.rotate(paneID: paneID) == nil)
        #expect(recorder.actions.isEmpty)
    }

    @Test
    func subsystemRoutersRejectMessagesAndActionsUntilTheirTargetsAreReady() async throws {
        let messageRouter = AgentMessageRouter()
        let actionRouter = AgentLifecycleActionRouter()
        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let message = try registerMessage(
            paneID: paneID,
            token: String(repeating: "a", count: 64)
        )
        let action = AgentSessionLifecycleAction.register(
            paneID: paneID,
            binding: try binding(
                adapterID: AgentAdapterID(rawValue: "claude"),
                sessionID: "session-1",
                cwd: "/tmp"
            )
        )

        #expect(await !messageRouter.route(message))
        #expect(!actionRouter.route(action))
        messageRouter.disable()
        actionRouter.disable()
        #expect(await !messageRouter.route(message))
        #expect(!actionRouter.route(action))
    }

    @Test
    func realSocketAcknowledgesCurrentMessageAndRejectsStaleToken() async throws {
        let baseDirectory = "/tmp/qtt-controller-test-\(UUID().uuidString)"
        guard mkdir(baseDirectory, 0o700) == 0 else {
            throw AgentSessionControllerTestError.couldNotCreateTemporaryDirectory(errno)
        }
        defer { _ = rmdir(baseDirectory) }

        let messageRouter = AgentMessageRouter()
        let server = AgentSocketServer(
            temporaryBaseDirectory: baseDirectory,
            credentialProvider: messageRouter.credential
        ) { message in
            await messageRouter.route(message)
        }
        let actualSocketPath = try server.start()
        let recorder = AgentLifecycleActionRecorder()
        let controller = try AgentSessionController(
            socketPath: actualSocketPath,
            helperPath: helperPath,
            instanceID: instanceID,
            tokenGenerator: AgentTokenSequence([
                Array(repeating: 0xaa, count: 32),
                Array(repeating: 0xbb, count: 32),
            ]).next,
            dateProvider: { self.date },
            onAction: recorder.record
        )
        messageRouter.install(controller)

        let paneID = paneID("11111111-2222-3333-4444-555555555555")
        let firstEnvironment = try #require(controller.register(paneID: paneID))
        let firstToken = try #require(firstEnvironment["QUICKTTY_PANE_TOKEN"])
        let validMessage = try registerMessage(paneID: paneID, token: firstToken)
        let validAcknowledgement = try await Task.detached {
            try AgentSocketClient.send(validMessage, to: actualSocketPath)
        }.value

        #expect(validAcknowledgement)
        #expect(recorder.actions.count == 1)

        let frameWriteReached = DispatchSemaphore(value: 0)
        let frameWriteRelease = DispatchSemaphore(value: 0)
        let racedSend = Task.detached {
            try AgentSocketClient(
                socketPath: actualSocketPath,
                timeoutMilliseconds: 2_000,
                nonceGenerator: {
                    Data(repeating: 0x42, count: AgentIPCProtocol.nonceSize)
                },
                phaseObserver: { phase in
                    guard phase == .frameWrite else { return }
                    frameWriteReached.signal()
                    _ = frameWriteRelease.wait(timeout: .now() + 1)
                }
            ).send(validMessage)
        }
        let reachedFrameWrite = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: frameWriteReached.wait(timeout: .now() + 1) == .success
                )
            }
        }
        #expect(reachedFrameWrite)
        _ = controller.rotate(paneID: paneID)
        frameWriteRelease.signal()

        #expect(try await !racedSend.value)
        #expect(recorder.actions.count == 1)

        let staleError = try await Task.detached { () -> AgentSocketClientError? in
            do {
                _ = try AgentSocketClient.send(validMessage, to: actualSocketPath)
                return nil
            } catch let error as AgentSocketClientError {
                return error
            }
        }.value

        #expect(staleError == .serverAuthenticationFailed)
        #expect(recorder.actions.count == 1)
        await server.stop()
    }

    @Test
    func rejectsInvalidControllerPaths() {
        #expect(throws: AgentSessionControllerValidationError.invalidSocketPath) {
            try AgentSessionController(
                socketPath: "relative/socket",
                helperPath: helperPath,
                onAction: { _ in true }
            )
        }
        #expect(throws: AgentSessionControllerValidationError.invalidHelperPath) {
            try AgentSessionController(
                socketPath: socketPath,
                helperPath: "relative/helper",
                onAction: { _ in true }
            )
        }
    }

    private func makeController(
        tokens: AgentTokenSequence,
        recorder: AgentLifecycleActionRecorder
    ) throws -> AgentSessionController {
        try AgentSessionController(
            socketPath: socketPath,
            helperPath: helperPath,
            instanceID: instanceID,
            tokenGenerator: tokens.next,
            dateProvider: { date },
            onAction: recorder.record
        )
    }

    private func paneID(_ rawValue: String) -> PaneID {
        PaneID(rawValue: UUID(uuidString: rawValue)!)
    }

    private func identity(
        instanceID: UUID? = nil,
        paneID: PaneID,
        token: String,
        adapterID: String = "claude"
    ) throws -> AgentIPCIdentity {
        try AgentIPCIdentity(
            instanceID: instanceID ?? self.instanceID,
            paneID: paneID.rawValue,
            paneToken: token,
            adapterID: adapterID
        )
    }

    private func registerMessage(
        instanceID: UUID? = nil,
        paneID: PaneID,
        token: String,
        adapterID: String = "claude",
        sessionID: String = "session-1",
        cwd: String = "/tmp",
        metadata: [String: String] = [:]
    ) throws -> AgentIPCMessage {
        AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: identity(
                        instanceID: instanceID,
                        paneID: paneID,
                        token: token,
                        adapterID: adapterID
                    ),
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: metadata
                )
            )
        )
    }

    private func replaceMessage(
        paneID: PaneID,
        token: String,
        previousSessionID: String,
        sessionID: String,
        cwd: String = "/tmp"
    ) throws -> AgentIPCMessage {
        AgentIPCMessage(
            event: .replaceSession(
                try AgentIPCReplaceSessionPayload(
                    identity: identity(paneID: paneID, token: token),
                    previousSessionID: previousSessionID,
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: [:]
                )
            )
        )
    }

    private func unregisterMessage(
        paneID: PaneID,
        token: String,
        sessionID: String
    ) throws -> AgentIPCMessage {
        AgentIPCMessage(
            event: .unregister(
                try AgentIPCUnregisterPayload(
                    identity: identity(paneID: paneID, token: token),
                    sessionID: sessionID
                )
            )
        )
    }

    private func binding(
        adapterID: AgentAdapterID,
        sessionID: String,
        cwd: String
    ) throws -> AgentResumeBinding {
        try AgentResumeBinding(
            adapterID: adapterID,
            sessionID: sessionID,
            workingDirectory: cwd,
            registeredAt: date,
            launchMetadata: [:],
            restoreState: .active
        )
    }
}

@MainActor
private final class AgentLifecycleActionRecorder {
    private(set) var actions: [AgentSessionLifecycleAction] = []
    private let acceptsActions: Bool

    init(acceptsActions: Bool = true) {
        self.acceptsActions = acceptsActions
    }

    func record(_ action: AgentSessionLifecycleAction) -> Bool {
        actions.append(action)
        return acceptsActions
    }
}

@MainActor
private final class AgentTokenSequence {
    private var values: [[UInt8]]

    init(_ values: [[UInt8]]) {
        self.values = values
    }

    func next() -> [UInt8] {
        values.removeFirst()
    }
}

private actor AgentSessionControllerRelay {
    private var controller: AgentSessionController?

    func install(_ controller: AgentSessionController) {
        self.controller = controller
    }

    func handle(_ message: AgentIPCMessage) async -> Bool {
        guard let controller else {
            return false
        }
        return await controller.handle(message)
    }
}

private enum AgentSessionControllerTestError: Error {
    case couldNotCreateTemporaryDirectory(Int32)
}
