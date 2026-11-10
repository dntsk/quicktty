import Foundation

@MainActor
struct AgentMessagingHostContract {
    static func run() async throws {
        try await startupWithoutSettingsSheet()
        let state = MessagingHostState()
        let network = MessagingHostNetwork()
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let token = try TelegramBotToken("123456:host-contract-token")
        let credentials = TelegramCredentialStore(
            load: { TelegramSavedConnection(token: token, peer: peer) },
            save: { _, _ in throw HostFailure() }, remove: { throw HostFailure() }
        )
        let sessions = try AgentSessionController(
            socketPath: "/tmp/quicktty-host-test.sock", helperPath: "/test/quicktty"
        ) { action in
            switch action {
            case .register(_, let binding), .replace(_, _, let binding): state.binding = binding
            case .unregister: state.binding = nil
            }
            return true
        }
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { state.workspaces },
            paneIsLive: { $0 == state.pane && state.live },
            credentials: credentials, preferences: .transient(),
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            }
        )
        defer { service.shutdown() }
        let environment = sessions.register(paneID: state.pane)!
        let endpoint = environment["QUICKTTY_MESSAGE_SOCKET"]!
        try AgentMessagingContract.require(
            endpoint != environment["QUICKTTY_AGENT_SOCKET"], "Messaging reused lifecycle endpoint")
        guard
            let identity = TerminalControlEnvironment.read(
                socketKey: "QUICKTTY_MESSAGE_SOCKET",
                value: { key, _ in environment[key].map { Data($0.utf8) } })
        else { throw HostFailure() }
        let request = AgentMessagingRequest(
            version: 1, operation: .question, requestID: UUID(),
            text: "A real session-scoped question?", sessionID: "host-session")
        let unregistered = try await send(request, identity: identity)
        try AgentMessagingContract.require(
            unregistered.code == "unavailable", "Unregistered pane gained messaging access")
        let lifecycleIdentity = try AgentIPCIdentity(
            instanceID: sessions.instanceID, paneID: state.pane.rawValue,
            paneToken: environment["QUICKTTY_PANE_TOKEN"]!, adapterID: "pi")
        let register = AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: lifecycleIdentity, sessionID: "host-session", cwd: "/tmp",
                    metadata: [:])))
        let registered = await sessions.handle(register)
        try AgentMessagingContract.require(registered, "Test lifecycle registration failed")
        let origin = service.origins().first!.origin
        let beforeGrant = try await send(request, identity: identity)
        try AgentMessagingContract.require(
            beforeGrant.code == "permissionRequired",
            "Lifecycle registration silently granted Telegram access")
        await service.connection.restoreSavedConnection()
        try AgentMessagingContract.require(
            service.isAuthorized(origin),
            "Connected bot did not automatically authorize a live agent")
        var stale = request
        stale.sessionID = "old-session"
        let staleResult = try await send(stale, identity: identity)
        try AgentMessagingContract.require(
            staleResult.code == "unavailable", "Stale native session borrowed a live session grant")
        let submitted = try await send(request, identity: identity)
        try AgentMessagingContract.require(
            submitted.state == "pending", "Authenticated host did not submit question")
        let userAnswer = "User answered locally"
        _ = try service.connection.answerLocally(request.requestID, answer: .text(userAnswer))
        let statusRequest = AgentMessagingRequest(
            version: 1, operation: .status, requestID: request.requestID)
        let status = try await send(statusRequest, identity: identity)
        try AgentMessagingContract.require(
            status.state == "text" && status.text == userAnswer,
            "Agent did not receive the accepted answer")
        var changed = request
        changed.text = "Different question with same request ID"
        let conflict = try await send(changed, identity: identity)
        try AgentMessagingContract.require(
            conflict.code == "requestIDConflict", "Host accepted a changed payload")
        let action = AgentMessagingRequest(
            version: 1, operation: .action, requestID: UUID(), text: "Restart exact service",
            resources: "test-service", consequences: "Brief interruption")
        _ = try await send(action, identity: identity)
        guard let actionSnapshot = service.connection.snapshot(action.requestID),
            case .action(let actionDescription) = actionSnapshot.request.prompt
        else { throw HostFailure() }
        try AgentMessagingContract.require(
            actionDescription.risk == .elevated, "Action did not default to elevated risk")
        state.live = false
        let closed = try await send(
            AgentMessagingRequest(version: 1, operation: .status, requestID: action.requestID),
            identity: identity)
        try AgentMessagingContract.require(
            closed.code == "unavailable", "Closed pane retained access")
        try AgentMessagingContract.require(
            service.connection.snapshot(action.requestID)?.state == .resolved(.revoked),
            "Closed pane left an approvable request")
        state.live = true
        let rotated = sessions.rotate(paneID: state.pane)!
        try AgentMessagingContract.require(
            service.origins().isEmpty, "Credential rotation retained registration")
        let nextIdentity = try AgentIPCIdentity(
            instanceID: sessions.instanceID, paneID: state.pane.rawValue,
            paneToken: rotated["QUICKTTY_PANE_TOKEN"]!, adapterID: "pi")
        let reRegister = AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: nextIdentity, sessionID: "host-session", cwd: "/tmp", metadata: [:])))
        let reRegistered = await sessions.handle(reRegister)
        try AgentMessagingContract.require(reRegistered, "Re-registration failed")
        let replacement = service.origins().first!.origin
        try AgentMessagingContract.require(
            replacement.generation > origin.generation && service.isAuthorized(replacement),
            "Token rotation did not create a fresh automatic session grant")
        try await automaticAccessContract(
            state: state, sessions: sessions, service: service, identity: nextIdentity)
        try await registryContract(state: state, sessions: sessions, service: service)
        try await AgentMessagingClaudeCLIContract.run(
            sessions: sessions, service: service, pane: state.pane)
        sessions.freeze()
        try AgentMessagingContract.require(
            service.origins().isEmpty, "Freeze kept a registered origin")
        service.shutdown()
        await network.drain()
        print(
            "PASS: host-to-CLI messaging contract (real authenticated socket and session lifecycle; no GUI)"
        )
    }

    private static func startupWithoutSettingsSheet() async throws {
        let state = MessagingHostState()
        let network = MessagingHostNetwork()
        let sessions = try AgentSessionController(
            socketPath: "/tmp/quicktty-host-autoconnect.sock", helperPath: "/test/quicktty"
        ) { action in
            switch action {
            case .register(_, let binding), .replace(_, _, let binding): state.binding = binding
            case .unregister: state.binding = nil
            }
            return true
        }
        let token = try TelegramBotToken("123456:automatic-host-fixture")
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { state.workspaces },
            paneIsLive: { $0 == state.pane },
            credentials: TelegramCredentialStore(
                load: { TelegramSavedConnection(token: token, peer: peer) }, save: { _, _ in },
                remove: {}),
            preferences: .transient(enabled: true),
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            })
        defer { service.shutdown() }
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        service.onChange = { events.continuation.yield(()) }
        let environment = sessions.register(paneID: state.pane)!
        let identity = try AgentIPCIdentity(
            instanceID: sessions.instanceID, paneID: state.pane.rawValue,
            paneToken: environment["QUICKTTY_PANE_TOKEN"]!, adapterID: "pi")
        let registered = await sessions.handle(
            AgentIPCMessage(
                event: .register(
                    try AgentIPCRegisterPayload(
                        identity: identity, sessionID: "automatic-service-startup", cwd: "/tmp",
                        metadata: [:]))))
        if service.connection.phase != .connected(peer) {
            for await _ in events.stream where service.connection.phase == .connected(peer) {
                break
            }
        }
        let origin = service.origins().first!.origin
        try AgentMessagingContract.require(
            registered && service.isAuthorized(origin),
            "Application startup required a settings sheet, reconnect button or session checkbox")
        let request = try AgentInteractionRequest(
            id: UUID(), origin: origin,
            prompt: .question(text: "Automatic service startup", choices: []))
        try service.connection.submit(request)
        try AgentMessagingContract.require(
            service.connection.snapshot(request.id)?.state == .pending,
            "Automatic channel access changed request approval semantics")
        service.shutdown()
        await network.drain()
        events.continuation.finish()
    }

    private static func automaticAccessContract(
        state: MessagingHostState, sessions: AgentSessionController, service: AgentMessagingService,
        identity: AgentIPCIdentity
    ) async throws {
        let previous = service.origins().first!.origin
        let pending = try AgentInteractionRequest(
            id: UUID(), origin: previous,
            prompt: .question(text: "Before session replacement", choices: []))
        try service.connection.submit(pending)
        let replacement = AgentIPCMessage(
            event: .register(
                try AgentIPCRegisterPayload(
                    identity: identity, sessionID: "new-automatic-session", cwd: "/tmp",
                    metadata: [:])))
        let accepted = await sessions.handle(replacement)
        let next = service.origins().first!.origin
        try AgentMessagingContract.require(
            accepted && next != previous && service.isAuthorized(next)
                && !service.isAuthorized(previous),
            "Session replacement did not rotate automatic channel access")
        try AgentMessagingContract.require(
            service.connection.snapshot(pending.id)?.state == .resolved(.revoked),
            "Automatic session grant resurrected an old pending question")
        try service.setAuthorized(next, allowed: false)
        _ = service.connection.snapshots()
        try AgentMessagingContract.require(
            !service.isAuthorized(next), "Automatic refresh undid explicit revoke")
        try service.setAuthorized(next, allowed: true)
        service.connection.disconnect()
        try AgentMessagingContract.require(
            !service.isAuthorized(next), "Global pause kept session access")
        await service.connection.restoreSavedConnection()
        try AgentMessagingContract.require(
            service.isAuthorized(next), "Resume required manual session permission")
        state.workspaceID = WorkspaceID()
        let environment = sessions.environment(for: state.pane)!
        let transport = TerminalControlEnvironment.read(
            socketKey: "QUICKTTY_MESSAGE_SOCKET",
            value: { key, _ in environment[key].map { Data($0.utf8) } })!
        let question = AgentMessagingRequest(
            version: 1, operation: .question, requestID: UUID(), text: "Question in a new workspace"
        )
        let response = try await send(question, identity: transport)
        let moved = service.origins().first!.origin
        try AgentMessagingContract.require(
            response.state == "pending" && moved.workspaceID == state.workspaceID.rawValue
                && service.isAuthorized(moved) && !service.isAuthorized(next),
            "New workspace required manual opt-in or retained old workspace access")
        _ = try service.connection.answerLocally(question.requestID, answer: .cancel)
    }

    private static func registryContract(
        state: MessagingHostState, sessions: AgentSessionController, service: AgentMessagingService
    ) async throws {
        var acceptedCount = 0
        var blockedCount = 0
        for definition in AgentIntegrationRegistry.definitions {
            if let binding = state.binding, let environment = sessions.environment(for: state.pane)
            {
                let identity = try AgentIPCIdentity(
                    instanceID: sessions.instanceID, paneID: state.pane.rawValue,
                    paneToken: environment["QUICKTTY_PANE_TOKEN"]!,
                    adapterID: binding.adapterID.rawValue)
                let event = AgentIPCMessage(
                    event: .unregister(
                        try AgentIPCUnregisterPayload(
                            identity: identity, sessionID: binding.sessionID)))
                let removed = await sessions.handle(event)
                try AgentMessagingContract.require(
                    removed, "Previous registry origin was not unregistered")
            }
            let environment = sessions.rotate(paneID: state.pane)!
            let identity = try AgentIPCIdentity(
                instanceID: sessions.instanceID, paneID: state.pane.rawValue,
                paneToken: environment["QUICKTTY_PANE_TOKEN"]!, adapterID: definition.id.rawValue)
            let event = AgentIPCMessage(
                event: .register(
                    try AgentIPCRegisterPayload(
                        identity: identity, sessionID: "registry-session", cwd: "/tmp",
                        metadata: [:])))
            let accepted = await sessions.handle(event)
            if case .blocked = definition.capability {
                blockedCount += 1
                try AgentMessagingContract.require(
                    !accepted && service.origins().isEmpty,
                    "Blocked registry entry gained messaging access")
                continue
            }
            acceptedCount += 1
            try AgentMessagingContract.require(
                accepted, "Launch-capable registry origin was rejected")
            let origin = service.origins().first!.origin
            try AgentMessagingContract.require(
                origin.adapterID == definition.id.rawValue && service.isAuthorized(origin),
                "Registered agent did not receive its own automatic channel grant")
            guard
                let transport = TerminalControlEnvironment.read(
                    socketKey: "QUICKTTY_MESSAGE_SOCKET",
                    value: { key, _ in environment[key].map { Data($0.utf8) } })
            else { throw HostFailure() }
            let question = AgentMessagingRequest(
                version: 1, operation: .question, requestID: UUID(),
                text: "Backend registry routing test")
            let pending = try await send(question, identity: transport)
            try AgentMessagingContract.require(
                pending.state == "pending", "Registry request was not routed")
            _ = try service.connection.answerLocally(
                question.requestID, answer: .text("Answer for this origin"))
            let response = try await send(
                AgentMessagingRequest(
                    version: 1, operation: .status, requestID: question.requestID),
                identity: transport)
            try AgentMessagingContract.require(
                response.state == "text" && response.text == "Answer for this origin",
                "Registry origin received another session result")
        }
        try AgentMessagingContract.require(
            acceptedCount == 14 && blockedCount == 6, "Registry messaging capability totals changed"
        )
        let capabilities = AgentIntegrationRegistry.definitions.map(\.messagingCapability)
        try AgentMessagingContract.require(
            capabilities.filter { $0 == .piTools }.count == 1, "Pi tool capability mismatch")
        try AgentMessagingContract.require(
            capabilities.filter { $0 == .claudeQuestions }.count == 1
                && AgentMessagingCapability.claudeQuestions.label.contains("2.1.318")
                && AgentMessagingCapability.claudeQuestions.explanation.contains("verified"),
            "Claude capability omitted its runtime limitation")
        try AgentMessagingContract.require(
            capabilities.filter { $0 == .cli }.count == 12, "Generic CLI capability mismatch")
    }

    private static func send(_ request: AgentMessagingRequest, identity: TerminalControlEnvironment)
        async throws -> AgentMessagingResponse
    {
        try await Task.detached { try AgentMessagingSocketClient(identity: identity).send(request) }
            .value
    }
}

@MainActor
private final class MessagingHostState {
    let pane = PaneID()
    var workspaceID = WorkspaceID()
    let tabID = TabID()
    var binding: AgentResumeBinding?
    var live = true
    var workspaces: [Workspace] {
        [
            Workspace(
                id: workspaceID, name: "Host test",
                tabs: [
                    TerminalTab(
                        id: tabID, title: "Agent",
                        pane: TerminalPaneDescriptor(
                            id: pane, cwd: "/tmp", agentResumeBinding: binding))
                ])
        ]
    }
}

private actor MessagingHostNetwork {
    private var polls: [CheckedContinuation<TelegramHTTPResponse, any Error>] = []
    private var nextMessageID = 100
    func send(_ request: URLRequest) async throws -> TelegramHTTPResponse {
        let result: String
        switch request.url!.lastPathComponent {
        case "getUpdates": return try await withCheckedThrowingContinuation { polls.append($0) }
        case "getMe": result = "{\"id\":1,\"is_bot\":true}"
        case "sendMessage":
            result =
                "{\"message_id\":\(nextMessageID),\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
            nextMessageID += 1
        case "editMessageReplyMarkup":
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            result =
                "{\"message_id\":\(body["message_id"] as! Int),\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
        default: result = "true"
        }
        return TelegramHTTPResponse(
            data: Data("{\"ok\":true,\"result\":\(result)}".utf8),
            response: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func drain() {
        for poll in polls { poll.resume(throwing: CancellationError()) }
        polls.removeAll()
    }
}

private struct HostFailure: Error {}
