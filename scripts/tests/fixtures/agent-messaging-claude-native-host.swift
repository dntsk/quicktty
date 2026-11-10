import Darwin
import Foundation
import Synchronization

@MainActor
private final class ClaudeNativeState {
    let pane = PaneID()
    let workspace = WorkspaceID()
    let directory: String
    var binding: AgentResumeBinding?
    init(directory: String) { self.directory = directory }
    var workspaces: [Workspace] {
        [
            Workspace(
                id: workspace, name: "Native fixture",
                tabs: [
                    TerminalTab(
                        title: "Claude",
                        pane: TerminalPaneDescriptor(
                            id: pane, cwd: directory, agentResumeBinding: binding))
                ])
        ]
    }
}

@main
@MainActor
struct ClaudeNativeHost {
    static func main() async throws {
        guard CommandLine.arguments.count == 6 else { throw ClaudeNativeFailure() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let node = CommandLine.arguments[2]
        let sdk = CommandLine.arguments[3]
        let cli = CommandLine.arguments[4]
        let sdkFixture = CommandLine.arguments[5]
        let state = ClaudeNativeState(directory: root.appending(path: "workspace").path)
        let slot = Mutex<AgentSessionController?>(nil)
        let lifecycle = AgentSocketServer(
            credentialProvider: { value in slot.withLock { $0?.credential(for: value) } },
            handler: { value in
                guard let sessions = slot.withLock({ $0 }) else { return false }
                return await sessions.handle(value)
            })
        let path = try lifecycle.start()
        defer { lifecycle.stopImmediately() }
        let helper = root.appending(path: "quicktty").path
        let sessions = try AgentSessionController(socketPath: path, helperPath: helper) { action in
            switch action {
            case .register(_, let binding), .replace(_, _, let binding): state.binding = binding
            case .unregister: state.binding = nil
            }
            return true
        }
        slot.withLock { $0 = sessions }
        let network = ClaudeNativeNetwork()
        let token = try TelegramBotToken("123456:synthetic-native-fixture")
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let store = TelegramCredentialStore(
            load: { TelegramSavedConnection(token: token, peer: peer) },
            save: { _, _ in throw ClaudeNativeFailure() }, remove: { throw ClaudeNativeFailure() })
        let service = try AgentMessagingService(
            sessions: sessions, workspaceProvider: { state.workspaces },
            paneIsLive: { $0 == state.pane }, credentials: store, preferences: .transient(),
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            })
        defer {
            service.shutdown()
            sessions.freeze()
            Task { await network.drain() }
        }
        await service.connection.restoreSavedConnection()
        var environment = ProcessInfo.processInfo.environment
        environment.merge(sessions.register(paneID: state.pane)!) { _, new in new }
        let mode = environment["QUICKTTY_CLAUDE_FIXTURE_OUTCOME"]!
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": helper + " internal hook claude SessionStart",
                                "timeout": 5,
                            ]
                        ]
                    ]
                ],
                "SessionEnd": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": helper + " internal hook claude SessionEnd",
                                "timeout": 5,
                            ]
                        ]
                    ]
                ],
                "PreToolUse": [
                    [
                        "matcher": "^AskUserQuestion$",
                        "hooks": [
                            [
                                "type": "command",
                                "command": helper + " internal hook claude "
                                    + ClaudeQuestionRuntime.installedHookEvent,
                                "timeout": 330,
                            ]
                        ],
                    ]
                ],
            ]
        ]
        try JSONSerialization.data(withJSONObject: settings).write(
            to: root.appending(path: "host-settings.json"))
        let endpoints = [path, environment["QUICKTTY_MESSAGE_SOCKET"]!]
        let canonical = endpoints.map { path in
            let value = realpath(path, nil)!
            defer { free(value) }
            return String(cString: value)
        }
        // SBPL matches the physical /private/tmp vnode, unlike Foundation's /tmp compatibility URL.
        let sockets = Set(endpoints + canonical).map { "(literal \"\($0)\")" }.joined(
            separator: " ")
        let rules =
            "\n(allow network-outbound \(sockets))\n(allow file-read-data file-write-data \(sockets))\n"
        let profile =
            try String(contentsOf: root.appending(path: "runtime.sb"), encoding: .utf8) + rules
        try profile.write(
            to: root.appending(path: "host-runtime.sb"), atomically: true, encoding: .utf8)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-f", root.appending(path: "host-runtime.sb").path, node, sdkFixture, root.path, sdk,
            cli,
        ]
        process.environment = environment
        process.currentDirectoryURL = root.appending(path: "workspace")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await wait { !service.origins().isEmpty || !process.isRunning }
        guard let origin = service.origins().first?.origin, origin.adapterID == "claude" else {
            throw ClaudeNativeFailure()
        }
        guard service.isAuthorized(origin) else { throw ClaudeNativeFailure() }
        if mode == "fallback" { try service.setAuthorized(origin, allowed: false) }
        try Data("ready".utf8).write(to: root.appending(path: "host-ready"))
        if mode != "fallback" {
            try await wait { !service.connection.snapshots().isEmpty || !process.isRunning }
            guard let question = service.connection.snapshots().first else {
                throw ClaudeNativeFailure()
            }
            try await wait { service.connection.deliveries[question.request.id] == .sent }
            switch mode {
            case "answer": await network.answer()
            case "cancel":
                _ = try service.connection.answerLocally(question.request.id, answer: .cancel)
            case "revoke": try service.setAuthorized(origin, allowed: false)
            default: throw ClaudeNativeFailure()
            }
            try await wait { !process.isRunning }
            let expected: AgentInteractionState =
                mode == "answer"
                ? .resolved(.choice(index: 1, label: "Two"))
                : mode == "cancel" ? .resolved(.cancelled) : .resolved(.revoked)
            guard service.connection.snapshot(question.request.id)?.state == expected else {
                throw ClaudeNativeFailure()
            }
        } else {
            try await wait { !process.isRunning }
            guard service.connection.snapshots().isEmpty else { throw ClaudeNativeFailure() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0,
            !text.contains(origin.sessionID), !text.contains(environment["QUICKTTY_PANE_TOKEN"]!)
        else { throw ClaudeNativeFailure() }
        let wire = await network.body
        guard !wire.contains(origin.sessionID), !wire.contains(environment["QUICKTTY_PANE_TOKEN"]!)
        else {
            throw ClaudeNativeFailure()
        }
        FileHandle.standardOutput.write(data)
        service.shutdown()
        await network.drain()
        await lifecycle.stop()
        print(
            "PASS: native Claude → real helper/authenticated host → mock Telegram → native continuation (\(mode))"
        )
    }

    static func wait(line: UInt = #line, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw ClaudeNativeFailure(line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ClaudeNativeNetwork {
    var body = ""
    private var callback = ""
    private var queued: String?
    private var polls: [(URL, CheckedContinuation<TelegramHTTPResponse, any Error>)] = []

    func send(_ request: URLRequest) async throws -> TelegramHTTPResponse {
        let url = request.url!
        let result: String
        switch url.lastPathComponent {
        case "getMe": result = "{\"id\":1,\"is_bot\":true}"
        case "getUpdates":
            if let value = queued {
                queued = nil
                return response(url, value)
            }
            return try await withCheckedThrowingContinuation { polls.append((url, $0)) }
        case "sendMessage":
            body = String(decoding: request.httpBody!, as: UTF8.self)
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let markup = json["reply_markup"] as! [String: Any]
            let rows = markup["inline_keyboard"] as! [[[String: String]]]
            callback = rows.flatMap { $0 }.first { $0["text"] == "Two" }!["callback_data"]!
            result = message
        case "editMessageReplyMarkup": result = message
        case "answerCallbackQuery": result = "true"
        default: throw ClaudeNativeFailure()
        }
        return response(url, result)
    }

    func answer() {
        let value =
            "[{\"update_id\":1,\"callback_query\":{\"id\":\"native-callback\",\"from\":{\"id\":42,\"is_bot\":false},\"data\":\"\(callback)\",\"message\":\(message)}}]"
        if polls.isEmpty {
            queued = value
        } else {
            let (url, continuation) = polls.removeFirst()
            continuation.resume(returning: response(url, value))
        }
    }

    func drain() {
        for (_, poll) in polls { poll.resume(throwing: CancellationError()) }
        polls.removeAll()
    }

    private var message: String {
        "{\"message_id\":100,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}"
    }

    private func response(_ url: URL, _ value: String) -> TelegramHTTPResponse {
        TelegramHTTPResponse(
            data: Data("{\"ok\":true,\"result\":\(value)}".utf8),
            response: HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct ClaudeNativeFailure: Error { var line: UInt = 0 }
