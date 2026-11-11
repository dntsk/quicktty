import Darwin
import Foundation
import Synchronization

@MainActor
struct AgentMessagingPiE2EContract {
    static func run(
        repository: String, rootPath: String, node: String, package: String, helper: String
    )
        async throws
    {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let state = PiE2EState(root: root)
        let controller = Mutex<AgentSessionController?>(nil)
        let lifecycle = AgentSocketServer(
            credentialProvider: { preflight in
                controller.withLock { $0?.credential(for: preflight) }
            },
            handler: { message in
                guard let sessions = controller.withLock({ $0 }) else { return false }
                return await sessions.handle(message)
            })
        let socket = try lifecycle.start()
        defer { lifecycle.stopImmediately() }
        let sessions = try AgentSessionController(socketPath: socket, helperPath: helper) {
            action in
            switch action {
            case .register(_, let binding), .replace(_, _, let binding): state.binding = binding
            case .unregister: state.binding = nil
            }
            return true
        }
        controller.withLock { $0 = sessions }
        let network = PiE2ENetwork()
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let token = try TelegramBotToken("123456:e2e-fixture-not-a-real-token")
        let credentials = TelegramCredentialStore(
            load: { TelegramSavedConnection(token: token, peer: peer) },
            save: { _, _ in throw PiE2EFailure(message: "Unexpected credential write") },
            remove: { throw PiE2EFailure(message: "Unexpected credential removal") })
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { state.workspaces },
            paneIsLive: { $0 == state.pane }, credentials: credentials, preferences: .transient(),
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            })
        defer {
            sessions.freeze()
            service.shutdown()
            Task { await network.drain() }
        }
        await service.connection.restoreSavedConnection()
        let environment = sessions.register(paneID: state.pane)!
        try stageExtension(repository: repository, root: root, helper: helper)
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [
            repository + "/scripts/tests/fixtures/agent-messaging-pi-e2e-contract.mjs", rootPath,
            package,
        ]
        process.currentDirectoryURL = root.appending(
            path: "sdk-workspace", directoryHint: .isDirectory)
        process.environment = environment.merging([
            "PATH": URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "HOME": root.appending(path: "sdk-home").path,
            "TMPDIR": root.appending(path: "sdk-tmp").path,
            "XDG_CACHE_HOME": root.appending(path: "sdk-cache").path,
            "XDG_CONFIG_HOME": root.appending(path: "sdk-config").path,
            "PI_CODING_AGENT_DIR": root.appending(path: "sdk-agent").path,
            "PI_CODING_AGENT_SESSION_DIR": root.appending(path: "sdk-sessions").path,
            "PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PI_SKIP_VERSION_CHECK": "1",
            "CI": "1", "TERM": "dumb",
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            let remaining = output.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                let diagnostic = String(decoding: remaining, as: UTF8.self)
                    .replacingOccurrences(
                        of: environment["QUICKTTY_PANE_TOKEN"]!, with: "<redacted>")
                print(diagnostic, terminator: "")
                fflush(nil)
            }
        }
        try await waitUntil { exists(root, "sdk-ready") || !process.isRunning }
        try require(process.isRunning && exists(root, "sdk-ready"), "SDK lifecycle startup failed")
        guard let origin = service.origins().first?.origin else {
            throw PiE2EFailure(message: "Real lifecycle did not create an origin")
        }
        try require(service.isAuthorized(origin), "Connected bot required a manual session grant")
        try mark(root, "host-granted")

        let question = try await prompt("E2E fixture: choose", service: service, network: network)
        let questionID = question.snapshot.request.id
        guard let choice = await network.button(message: question.message, label: "Two"),
            let forged = await network.button(message: question.message, label: "One")
        else { throw PiE2EFailure(message: "Real Telegram choice keyboard was missing") }
        let wrongSender = await network.callback(message: question.message, data: forged, user: 43)
        try await waitUntil { await network.offset > wrongSender }
        try require(
            service.connection.snapshot(questionID)?.state == .pending,
            "Foreign Telegram sender resolved a real SDK request")
        try require(!exists(root, "sdk-question-done"), "SDK continued before the valid reply")
        _ = await network.callback(message: question.message, data: choice)
        try await waitUntil { exists(root, "sdk-question-done") }

        let textQuestion = try await prompt(
            "E2E fixture: free text", service: service, network: network)
        let beforeText = await network.messageBodies.count
        _ = await network.reply(text: "Foreign text", user: 43)
        _ = await network.reply(text: "Group text", chatType: "group")
        let forwarded = await network.reply(text: "Relayed text", relayed: true)
        try await waitUntil { await network.offset > forwarded }
        try require(
            await network.messageBodies.count == beforeText,
            "Untrusted text generated Telegram feedback")
        let orphan = await network.reply(text: "Unthreaded private fixture answer")
        try await waitUntil { await network.offset > orphan }
        try await waitUntil { await network.contains("Ответ не передан агенту") }
        try require(
            service.connection.snapshot(textQuestion.snapshot.request.id)?.state == .pending,
            "Unthreaded text guessed an origin")
        try require(!exists(root, "sdk-text-done"), "SDK continued after unthreaded text")
        _ = await network.reply(
            message: textQuestion.message, text: "Explicit private fixture answer")
        try await waitUntil { exists(root, "sdk-text-done") }
        try await waitUntil { await network.contains("Ответ принят и передан агенту") }

        let approve = try await prompt("E2E fixture: approve", service: service, network: network)
        guard case .action(let action) = approve.snapshot.request.prompt else {
            throw PiE2EFailure(message: "SDK action became another prompt type")
        }
        try require(action.risk == .elevated, "Real SDK action did not default to elevated")
        let beforeInvalidAction = await network.messageBodies.count
        let wrongPhrase = await network.reply(message: approve.message, text: "yes")
        try await waitUntil { await network.offset > wrongPhrase }
        try require(
            service.connection.snapshot(approve.snapshot.request.id)?.state == .pending,
            "Elevated SDK action accepted an inexact phrase")
        try require(!exists(root, "sdk-approved"), "SDK completed the action before approval")
        try await waitUntil { await network.messageBodies.count == beforeInvalidAction + 1 }
        guard
            let approval = await network.button(
                message: approve.message, label: "Подтвердить один раз")
        else {
            throw PiE2EFailure(message: "Elevated action requires copying text instead of a button")
        }
        let foreignApproval = await network.callback(
            message: approve.message, data: approval, user: 43)
        try await waitUntil { await network.offset > foreignApproval }
        try require(
            service.connection.snapshot(approve.snapshot.request.id)?.state == .pending,
            "Foreign callback approved an elevated action")
        _ = await network.callback(message: approve.message, data: approval)
        try await waitUntil { exists(root, "sdk-approved") }

        let deny = try await prompt("E2E fixture: deny", service: service, network: network)
        guard let denial = await network.button(message: deny.message, label: "Отказать") else {
            throw PiE2EFailure(message: "Real Telegram denial button was missing")
        }
        _ = await network.callback(message: deny.message, data: denial)
        try await waitUntil { exists(root, "sdk-denied") }
        try await waitUntil { await network.contains("E2E fixture: completed") }
        let abort = try await prompt("E2E fixture: abort", service: service, network: network)
        try mark(root, "host-abort")
        try await waitUntil {
            exists(root, "sdk-aborted")
                && service.connection.snapshot(abort.snapshot.request.id)?.state
                    == .resolved(.cancelled)
        }
        try mark(root, "host-cancel-checked")
        let revoke = try await prompt("E2E fixture: revoke", service: service, network: network)
        try service.setAuthorized(origin, allowed: false)
        let lateReply = await network.reply(message: revoke.message, text: "Late fixture answer")
        try await waitUntil { await network.offset > lateReply }
        try await waitUntil { !process.isRunning }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let transcript = String(decoding: result, as: UTF8.self)
        try require(
            !transcript.contains(origin.sessionID)
                && !transcript.contains(environment["QUICKTTY_PANE_TOKEN"]!),
            "SDK output exposed internal identity")
        try require(
            process.terminationStatus == 0, "Authenticated SDK fixture failed: \(transcript)")
        try require(service.origins().isEmpty, "Real SDK shutdown did not unregister")
        try require(
            service.connection.snapshot(revoke.snapshot.request.id)?.state == .resolved(.revoked),
            "Revocation left an answerable SDK request")
        let bodies = await network.messageBodies
        for body in bodies {
            let text = String(describing: try JSONSerialization.jsonObject(with: body)).lowercased()
            for privateValue in [
                origin.sessionID, origin.paneID.uuidString,
                environment["QUICKTTY_PANE_TOKEN"]!, environment["QUICKTTY_MESSAGE_SOCKET"]!,
            ] {
                try require(
                    !text.contains(privateValue.lowercased()), "Telegram received internal identity"
                )
            }
        }
        try require(bodies.count == 10, "SDK integration duplicated or omitted a prompt/feedback")
        for body in bodies {
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let text = json["text"] as! String
            let markup = json["reply_markup"] as! [String: Any]
            if text.contains("E2E fixture: free text") {
                try require(
                    markup["force_reply"] as? Bool == true, "SDK free question missed Reply")
            }
            try require(
                !text.contains("Unthreaded private fixture answer")
                    && !text.contains("Explicit private fixture answer"),
                "Text feedback echoed the private answer")
        }
        service.shutdown()
        await network.drain()
        await lifecycle.stop()
        try await waitUntil {
            !FileManager.default.fileExists(atPath: socket)
                && !FileManager.default.fileExists(atPath: environment["QUICKTTY_MESSAGE_SOCKET"]!)
        }
        print(transcript, terminator: "")
    }

    private static func prompt(
        _ text: String, service: AgentMessagingService, network: PiE2ENetwork
    ) async throws -> (snapshot: AgentInteractionSnapshot, message: Int) {
        try await waitUntil(stage: text) { await network.contains(text) }
        guard let message = await network.message(containing: text),
            let snapshot = service.connection.snapshots().first(where: {
                switch $0.request.prompt {
                case .question(let value, _): value == text
                case .action(let value): value.operation == text
                }
            })
        else { throw PiE2EFailure(message: "SDK prompt was not present in the real ledger") }
        try await waitUntil { service.connection.deliveries[snapshot.request.id] == .sent }
        return (snapshot, message)
    }

    private static func waitUntil(
        stage: String = "host", line: UInt = #line, _ condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw PiE2EFailure(
                    message: "Authenticated SDK fixture stage '\(stage)' timed out at line \(line)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: name).path)
    }

    private static func mark(_ root: URL, _ name: String) throws {
        try Data("fixture-stage\n".utf8).write(to: root.appending(path: name), options: .atomic)
    }

    private static func stageExtension(repository: String, root: URL, helper: String) throws {
        for name in [
            "sdk-workspace", "sdk-home", "sdk-tmp", "sdk-cache", "sdk-config", "sdk-agent",
            "sdk-sessions",
        ] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name), withIntermediateDirectories: false)
        }
        let source = try String(
            contentsOfFile: repository + "/QuickTTY/Resources/AgentSessionIntegrations/pi/index.ts",
            encoding: .utf8)
        let placeholder = "\"__QUICKTTY_HELPER_PATH__\""
        try require(
            source.components(separatedBy: placeholder).count == 2, "Ambiguous helper placeholder")
        let path = String(decoding: try JSONEncoder().encode(helper), as: UTF8.self)
        try source.replacingOccurrences(of: placeholder, with: path).write(
            to: root.appending(path: "index.ts"), atomically: true, encoding: .utf8)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PiE2EFailure(message: message) }
    }
}

@MainActor
private final class PiE2EState {
    let pane = PaneID()
    let workspace = WorkspaceID()
    let tab = TabID()
    let root: URL
    var binding: AgentResumeBinding?
    init(root: URL) { self.root = root }
    var workspaces: [Workspace] {
        [
            Workspace(
                id: workspace, name: "Isolated SDK fixture",
                tabs: [
                    TerminalTab(
                        id: tab, title: "Agent",
                        pane: TerminalPaneDescriptor(
                            id: pane, cwd: root.appending(path: "sdk-workspace").path,
                            agentResumeBinding: binding))
                ])
        ]
    }
}

private actor PiE2ENetwork {
    private var queued: [String] = []
    private var polls: [(URL, CheckedContinuation<TelegramHTTPResponse, any Error>)] = []
    private var messages: [(id: Int, text: String, buttons: [String: String])] = []
    private var nextUpdate = 1
    private(set) var offset = 0
    private(set) var messageBodies: [Data] = []

    func contains(_ text: String) -> Bool { messages.contains { $0.text.contains(text) } }
    func message(containing text: String) -> Int? { messages.first { $0.text.contains(text) }?.id }
    func button(message: Int, label: String) -> String? {
        messages.first { $0.id == message }?.buttons[label]
    }

    func callback(message: Int, data: String, user: Int = 42) -> Int {
        enqueue(
            "\"callback_query\":{\"id\":\"callback-\(nextUpdate)\",\"from\":{\"id\":\(user),\"is_bot\":false},\"data\":\"\(data)\",\"message\":\(wireMessage(message))}"
        )
    }

    func reply(
        message: Int? = nil, text: String, user: Int = 42, chatType: String = "private",
        relayed: Bool = false
    ) -> Int {
        let reference = message.map { ",\"reply_to_message\":{\"message_id\":\($0)}" } ?? ""
        let relay = relayed ? ",\"forward_origin\":{}" : ""
        return enqueue(
            "\"message\":{\"message_id\":\(1_000 + nextUpdate),\"date\":1,\"from\":{\"id\":\(user),\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"\(chatType)\"},\"text\":\"\(text)\"\(reference)\(relay)}"
        )
    }

    private func enqueue(_ body: String) -> Int {
        let id = nextUpdate
        nextUpdate += 1
        queued.append("{\"update_id\":\(id),\(body)}")
        if !polls.isEmpty {
            let (url, continuation) = polls.removeFirst()
            continuation.resume(returning: response(url, result: updates()))
        }
        return id
    }

    func send(_ request: URLRequest) async throws -> TelegramHTTPResponse {
        let url = request.url!
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let result: String
        switch url.lastPathComponent {
        case "getMe": result = "{\"id\":1,\"is_bot\":true}"
        case "getUpdates":
            offset = body["offset"] as? Int ?? 0
            if !queued.isEmpty { return response(url, result: updates()) }
            return try await withCheckedThrowingContinuation { polls.append((url, $0)) }
        case "sendMessage":
            let id = 100 + messages.count
            let markup = body["reply_markup"] as! [String: Any]
            let keyboard = markup["inline_keyboard"] as! [[[String: String]]]
            let buttons = Dictionary(
                uniqueKeysWithValues: keyboard.flatMap { $0 }.map {
                    ($0["text"]!, $0["callback_data"]!)
                })
            messages.append((id, body["text"] as! String, buttons))
            messageBodies.append(request.httpBody!)
            result = wireMessage(id)
        case "editMessageReplyMarkup": result = wireMessage(body["message_id"] as! Int)
        case "answerCallbackQuery": result = "true"
        default: throw PiE2EFailure(message: "Unexpected Telegram API method")
        }
        return response(url, result: result)
    }

    func drain() {
        for (_, poll) in polls { poll.resume(throwing: CancellationError()) }
        polls.removeAll()
    }

    private func updates() -> String {
        let result = "[\(queued.joined(separator: ","))]"
        queued.removeAll()
        return result
    }

    private func wireMessage(_ id: Int) -> String {
        "{\"message_id\":\(id),\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
    }

    private func response(_ url: URL, result: String) -> TelegramHTTPResponse {
        TelegramHTTPResponse(
            data: Data("{\"ok\":true,\"result\":\(result)}".utf8),
            response: HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct PiE2EFailure: Error { let message: String }
