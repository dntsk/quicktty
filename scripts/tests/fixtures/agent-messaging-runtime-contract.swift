import Foundation
import Synchronization

@MainActor
struct AgentMessagingRuntimeContract {
    static func run() async throws {
        try await pairingAndDelivery()
        try await retryAndShutdown()
        try await failedPairingCannotBeConfirmed()
        print("PASS: Telegram runtime contracts (mock Keychain, mock network, deterministic gates)")
    }

    static func pairingAndDelivery() async throws {
        let network = RuntimeNetwork()
        let credentials = RuntimeCredentials()
        let current = CurrentOrigins()
        let controller = TelegramConnectionController(
            credentials: credentials.client,
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            },
            originIsCurrent: { current.origins.contains($0) }
        )
        let signal = RuntimeSignal()
        controller.onChange = { signal.changed() }
        try AgentMessagingContract.require(
            credentials.counts == [0, 0, 0], "Controller read Keychain at startup")
        await controller.connect(tokenText: "123456:runtime-test-token")
        guard case .pairing(let code, nil) = controller.phase else { throw RuntimeFailure() }
        await network.waitForPolls(1)
        let start =
            "{\"update_id\":1,\"message\":{\"message_id\":10,\"date\":1,\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"/start \(code)\"}}"
        await network.releasePoll(body: "{\"ok\":true,\"result\":[\(start)]}")
        await signal.wait {
            if case .pairing(_, .some) = controller.phase { return true }
            return false
        }
        guard case .pairing(_, let candidate?) = controller.phase else { throw RuntimeFailure() }
        try AgentMessagingContract.require(
            credentials.counts == [0, 0, 0],
            "Remote pairing saved credentials without native consent")
        controller.confirmPairing(candidateID: UUID())
        try AgentMessagingContract.require(
            credentials.counts == [0, 0, 0], "Wrong candidate saved credentials")
        controller.confirmPairing(candidateID: candidate.id)
        try AgentMessagingContract.require(
            controller.phase == .connected(candidate.peer), "Pairing did not connect")
        try AgentMessagingContract.require(
            credentials.counts == [0, 1, 0], "Explicit pairing did not save credentials once")

        let origin = try AgentMessagingContract.origin()
        current.origins.insert(origin)
        controller.setEnabledWorkspaces([origin.workspaceID])
        try controller.authorize(origin, workspaceName: "Workspace", agentName: "Pi")
        let request = try AgentMessagingContract.request(origin: origin)
        await network.holdSends(true)
        _ = try controller.submit(request)
        await network.waitForSends(1)
        await network.waitForPolls(2)
        let callback = TelegramCallbackData(requestID: request.id, answer: .choice(0)).encoded
        let update =
            "{\"update_id\":2,\"callback_query\":{\"id\":\"callback\",\"from\":{\"id\":42,\"is_bot\":false},\"data\":\"\(callback)\",\"message\":{\"message_id\":100,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}}}"
        await network.releasePoll(body: "{\"ok\":true,\"result\":[\(update)]}")
        await network.waitForPolls(3)
        try AgentMessagingContract.require(
            controller.snapshot(request.id)?.state == .pending,
            "Reply resolved before message binding")
        await network.releaseSend()
        await signal.wait { controller.snapshot(request.id)?.state != .pending }
        try AgentMessagingContract.require(
            controller.snapshot(request.id)?.state == .resolved(.choice(index: 0, label: "One")),
            "Fast reply was lost before send response")
        _ = try controller.submit(request)
        let sendCount = await network.sendCount
        try AgentMessagingContract.require(sendCount == 1, "Request replay sent a duplicate prompt")

        let local = try AgentMessagingContract.request(origin: origin)
        _ = try controller.submit(local)
        await network.waitForSends(2)
        _ = try controller.answerLocally(local.id, answer: .text("Local answer"))
        await network.releaseSend()
        await network.waitForClears(1)
        try AgentMessagingContract.require(
            controller.snapshot(local.id)?.state == .resolved(.text("Local answer")),
            "Late send overrode local answer")
        await network.holdSends(false)
        await network.failSends(true)
        let uncertain = try AgentMessagingContract.request(origin: origin)
        _ = try controller.submit(uncertain)
        await signal.wait { controller.deliveries[uncertain.id] == .failed(.deliveryUncertain) }
        _ = try controller.answerLocally(uncertain.id, answer: .text("Still works locally"))
        try AgentMessagingContract.require(
            controller.snapshot(uncertain.id)?.state == .resolved(.text("Still works locally")),
            "Network failure disabled local answer")
        let totalSends = await network.sendCount
        try AgentMessagingContract.require(totalSends == 3, "Uncertain send was retried")
        controller.disconnect()
        try AgentMessagingContract.require(
            credentials.counts == [0, 1, 0], "Disconnect unexpectedly deleted saved credentials")
        await network.drain()
        await controller.restoreSavedConnection()
        try AgentMessagingContract.require(
            controller.phase == .connected(candidate.peer), "Explicit restore failed")
        try AgentMessagingContract.require(
            credentials.counts == [1, 1, 0], "Explicit restore did not read Keychain exactly once")
        controller.disconnect(forget: true)
        try AgentMessagingContract.require(
            credentials.counts == [1, 1, 1], "Forget did not delete saved credentials")
        controller.shutdown()
        await controller.connect(tokenText: "123456:runtime-test-token")
        try AgentMessagingContract.require(
            controller.phase == .disconnected, "Frozen controller restarted")
        await network.drain()
    }

    static func failedPairingCannotBeConfirmed() async throws {
        let network = RuntimeNetwork()
        let credentials = RuntimeCredentials()
        let controller = TelegramConnectionController(
            credentials: credentials.client,
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            }
        )
        let signal = RuntimeSignal()
        controller.onChange = { signal.changed() }
        await controller.connect(tokenText: "123456:runtime-test-token")
        guard case .pairing(let code, _) = controller.phase else { throw RuntimeFailure() }
        await network.waitForPolls(1)
        let message =
            "{\"update_id\":1,\"message\":{\"message_id\":1,\"date\":1,\"from\":{\"id\":42,\"is_bot\":false},\"chat\":{\"id\":42,\"type\":\"private\"},\"text\":\"/start \(code)\"}}"
        await network.releasePoll(body: "{\"ok\":true,\"result\":[\(message)]}")
        await signal.wait {
            if case .pairing(_, .some) = controller.phase { return true }
            return false
        }
        guard case .pairing(_, let candidate?) = controller.phase else { throw RuntimeFailure() }
        await network.waitForPolls(2)
        await network.releasePoll(status: 409, body: "{\"ok\":false,\"error_code\":409}")
        await signal.wait { controller.phase == .failed(.network(.conflict)) }
        controller.confirmPairing(candidateID: candidate.id)
        try AgentMessagingContract.require(
            controller.phase == .failed(.network(.conflict)),
            "A stale confirm revived a stopped poller")
        try AgentMessagingContract.require(
            credentials.counts == [0, 0, 0],
            "Failed pairing saved credentials through a stale UI action")
        controller.shutdown()
        await network.drain()
    }

    static func retryAndShutdown() async throws {
        let network = RuntimeNetwork()
        let sleeper = RuntimeSleeper()
        let credentials = RuntimeCredentials()
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        try credentials.client.save(TelegramBotToken("123456:runtime-test-token"), peer)
        let controller = TelegramConnectionController(
            credentials: credentials.client,
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            },
            sleep: { try await sleeper.sleep($0) }
        )
        let signal = RuntimeSignal()
        controller.onChange = { signal.changed() }
        await controller.restoreSavedConnection()
        await network.waitForPolls(1)
        await network.releasePoll(
            status: 429, body: "{\"ok\":false,\"parameters\":{\"retry_after\":7}}")
        await sleeper.waitForSleep()
        let delays = await sleeper.delays
        try AgentMessagingContract.require(delays == [.seconds(7)], "Runtime ignored Retry-After")
        controller.disconnect()
        await sleeper.release()
        await controller.restoreSavedConnection()
        await network.waitForPolls(2)
        await network.releasePoll(status: 409, body: "{\"ok\":false,\"error_code\":409}")
        await signal.wait { controller.phase == .failed(.network(.conflict)) }
        let methods = await network.methods
        try AgentMessagingContract.require(
            !methods.contains("deleteWebhook"), "Runtime silently removed a foreign webhook")
        let loads = credentials.counts[0]
        controller.shutdown()
        await controller.restoreSavedConnection()
        try AgentMessagingContract.require(
            credentials.counts[0] == loads, "Shutdown read credentials again")
        await network.drain()
    }
}

private struct RuntimeFailure: Error {}

@MainActor
private final class CurrentOrigins {
    var origins: Set<AgentInteractionOrigin> = []
}

@MainActor
private final class RuntimeSignal {
    private var waiters:
        [(predicate: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func wait(_ predicate: @escaping @MainActor () -> Bool) async {
        if predicate() { return }
        await withCheckedContinuation { waiters.append((predicate, $0)) }
    }

    func changed() {
        let previous = waiters
        waiters.removeAll()
        for waiter in previous {
            if waiter.predicate() { waiter.continuation.resume() } else { waiters.append(waiter) }
        }
    }
}

private final class RuntimeCredentials: Sendable {
    private struct State {
        var saved: TelegramSavedConnection?
        var counts = [0, 0, 0]
    }
    private let state = Mutex(State())
    var counts: [Int] { state.withLock { $0.counts } }
    var client: TelegramCredentialStore {
        TelegramCredentialStore(
            load: { [self] in
                state.withLock {
                    $0.counts[0] += 1
                    return $0.saved
                }
            },
            save: { [self] token, peer in
                state.withLock {
                    $0.counts[1] += 1
                    $0.saved = TelegramSavedConnection(token: token, peer: peer)
                }
            },
            remove: { [self] in
                state.withLock {
                    $0.counts[2] += 1
                    $0.saved = nil
                }
            }
        )
    }
}

private actor RuntimeNetwork {
    private var polls: [(URLRequest, CheckedContinuation<TelegramHTTPResponse, any Error>)] = []
    private var sends: [(URLRequest, CheckedContinuation<TelegramHTTPResponse, any Error>)] = []
    private var pollWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sendWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var clearWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var holdSend = false
    private var failedSend = false
    private var pollCount = 0
    private var clearCount = 0
    private(set) var sendCount = 0
    private(set) var methods: [String] = []

    func holdSends(_ value: Bool) { holdSend = value }
    func failSends(_ value: Bool) { failedSend = value }

    func waitForPolls(_ count: Int) async {
        if pollCount >= count { return }
        await withCheckedContinuation { pollWaiters.append((count, $0)) }
    }
    func waitForSends(_ count: Int) async {
        if sendCount >= count { return }
        await withCheckedContinuation { sendWaiters.append((count, $0)) }
    }
    func waitForClears(_ count: Int) async {
        if clearCount >= count { return }
        await withCheckedContinuation { clearWaiters.append((count, $0)) }
    }

    func send(_ request: URLRequest) async throws -> TelegramHTTPResponse {
        let method = request.url!.lastPathComponent
        methods.append(method)
        switch method {
        case "getMe":
            return response(request, body: "{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true}}")
        case "getUpdates":
            return try await withCheckedThrowingContinuation { continuation in
                polls.append((request, continuation))
                pollCount += 1
                let ready = pollWaiters.filter { $0.0 <= pollCount }
                pollWaiters.removeAll { $0.0 <= pollCount }
                for waiter in ready { waiter.1.resume() }
            }
        case "sendMessage":
            sendCount += 1
            let ready = sendWaiters.filter { $0.0 <= sendCount }
            sendWaiters.removeAll { $0.0 <= sendCount }
            for waiter in ready { waiter.1.resume() }
            if failedSend { return response(request, status: 503, body: "") }
            if holdSend {
                return try await withCheckedThrowingContinuation { sends.append((request, $0)) }
            }
            return response(request, body: sentMessage)
        case "editMessageReplyMarkup":
            clearCount += 1
            let ready = clearWaiters.filter { $0.0 <= clearCount }
            clearWaiters.removeAll { $0.0 <= clearCount }
            for waiter in ready { waiter.1.resume() }
            return response(request, body: sentMessage)
        default: return response(request, body: "{\"ok\":true,\"result\":true}")
        }
    }

    func releasePoll(status: Int = 200, body: String) {
        guard !polls.isEmpty else { return }
        let pending = polls.removeFirst()
        pending.1.resume(returning: response(pending.0, status: status, body: body))
    }
    func releaseSend() {
        guard !sends.isEmpty else { return }
        let pending = sends.removeFirst()
        pending.1.resume(returning: response(pending.0, body: sentMessage))
    }
    func drain() {
        for pending in polls { pending.1.resume(throwing: CancellationError()) }
        for pending in sends { pending.1.resume(throwing: CancellationError()) }
        polls.removeAll()
        sends.removeAll()
    }
    private var sentMessage: String {
        "{\"ok\":true,\"result\":{\"message_id\":100,\"date\":1,\"chat\":{\"id\":42,\"type\":\"private\"}}}"
    }
    private func response(_ request: URLRequest, status: Int = 200, body: String)
        -> TelegramHTTPResponse
    {
        TelegramHTTPResponse(
            data: Data(body.utf8),
            response: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RuntimeSleeper {
    private(set) var delays: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(_ delay: Duration) async throws {
        delays.append(delay)
        await withCheckedContinuation { continuation in
            sleeper = continuation
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForSleep() async {
        if !delays.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        sleeper?.resume()
        sleeper = nil
    }
}
