import Foundation
import Synchronization

@MainActor
struct AgentMessagingAutoconnectContract {
    static func run() async throws {
        try sessionPreferences()
        try channelStateProjection()
        try await restartAndPause()
        try await transientStartupFailure()
        try await noSavedBot()
        try await permanentFailuresStop()
        print("PASS: Telegram starts off, manual connection, restart, pause, forget and retry")
    }

    private static func sessionPreferences() throws {
        let preferences = TelegramConnectionPreferences.standard()
        try AgentMessagingContract.require(
            !preferences.loadEnabled(), "Telegram is enabled in a new application session")
        preferences.saveEnabled(true)
        try AgentMessagingContract.require(
            preferences.loadEnabled(), "Manual enable was not retained in the current session")
        let restarted = TelegramConnectionPreferences.standard()
        try AgentMessagingContract.require(
            !restarted.loadEnabled(), "A new application session inherited enabled Telegram")
        restarted.saveEnabled(true)
        restarted.saveEnabled(false)
        try AgentMessagingContract.require(
            preferences.loadEnabled() && !restarted.loadEnabled(),
            "Separate application sessions share Telegram state")
    }

    private static func channelStateProjection() throws {
        let peer = try TelegramPeer(userID: 42, chatID: 42)
        let cases: [(Bool, TelegramConnectionPhase, TelegramChannelState)] = [
            (false, .disconnected, .off), (true, .disconnected, .connecting),
            (true, .verifying, .connecting), (true, .connected(peer), .active),
            (false, .connected(peer), .off),
            (false, .pairing(code: "fixture", candidate: nil), .setup),
            (true, .failed(.network(.conflict)), .failed),
        ]
        try AgentMessagingContract.require(
            TelegramChannelState(isEnabled: true, phase: .connected(peer), hasError: true)
                == .failed,
            "Indicator reports an active connection after a poll failure")
        for (enabled, phase, expected) in cases {
            try AgentMessagingContract.require(
                TelegramChannelState(isEnabled: enabled, phase: phase) == expected,
                "Telegram indicator misrepresents connection/channel state")
        }
    }

    private static func restartAndPause() async throws {
        let preferences = TelegramConnectionPreferences.standard()
        let credentials = AutoconnectCredentials()
        let network = AutoconnectNetwork()
        let first = controller(credentials, network, preferences)
        let firstSignal = AutoconnectSignal(first)
        first.start()
        first.start()
        await Task.yield()
        let startupVerifications = await network.verifications
        try AgentMessagingContract.require(
            !first.isEnabled && first.phase == .disconnected && credentials.loads == 0
                && startupVerifications == 0,
            "Startup accessed credentials or Telegram before manual enable")
        first.toggleEnabled()
        await firstSignal.wait { if case .connected = first.phase { true } else { false } }
        try AgentMessagingContract.require(
            credentials.loads == 1, "Manual enable duplicated Keychain load")
        let origin = try AgentMessagingContract.origin()
        first.setEnabledWorkspaces([origin.workspaceID])
        try first.authorize(origin, workspaceName: "Before restart", agentName: "Pi")
        let pending = try AgentMessagingContract.request(origin: origin)
        try first.submit(pending)
        try AgentMessagingContract.require(
            first.snapshot(pending.id)?.state == .pending, "Restart fixture has no pending request")
        first.shutdown()
        await network.drain()
        try AgentMessagingContract.require(preferences.loadEnabled(), "Shutdown paused Telegram")

        let restartedPreferences = TelegramConnectionPreferences.standard()
        let second = controller(credentials, network, restartedPreferences)
        let secondSignal = AutoconnectSignal(second)
        let verificationsBeforeRestart = await network.verifications
        second.start()
        await Task.yield()
        let verificationsAfterRestart = await network.verifications
        try AgentMessagingContract.require(
            !second.isEnabled && second.phase == .disconnected && credentials.loads == 1
                && credentials.removals == 0
                && verificationsAfterRestart == verificationsBeforeRestart,
            "Restart after enabled Telegram accessed credentials, network or removed the bot")
        second.toggleEnabled()
        await secondSignal.wait { if case .connected = second.phase { true } else { false } }
        try AgentMessagingContract.require(
            credentials.loads == 2, "Manual enable after restart did not restore saved bot")
        try AgentMessagingContract.require(
            second.snapshots().isEmpty && second.snapshot(pending.id) == nil
                && !second.hasGrant(origin),
            "Restart restored old requests or grants")
        let other = try AgentMessagingContract.origin()
        second.setEnabledWorkspaces([origin.workspaceID, other.workspaceID])
        try second.authorize(origin, workspaceName: "First", agentName: "Pi")
        try second.authorize(other, workspaceName: "Second", agentName: "Pi")
        let firstQuestion = try AgentMessagingContract.request(origin: origin)
        let otherQuestion = try AgentMessagingContract.request(origin: other)
        try second.submit(firstQuestion)
        try second.submit(otherQuestion)
        second.toggleEnabled()
        try AgentMessagingContract.require(
            second.phase == .disconnected && !second.hasGrant(origin) && !second.hasGrant(other)
                && second.snapshot(firstQuestion.id)?.state == .resolved(.revoked)
                && second.snapshot(otherQuestion.id)?.state == .resolved(.revoked),
            "Global toggle did not revoke every origin and pending request")
        try AgentMessagingContract.require(
            !restartedPreferences.loadEnabled(), "Pause did not update the current session")
        second.shutdown()
        await network.drain()

        let pausedPreferences = TelegramConnectionPreferences.standard()
        let paused = controller(credentials, network, pausedPreferences)
        paused.start()
        await Task.yield()
        try AgentMessagingContract.require(
            credentials.loads == 2 && paused.phase == .disconnected,
            "Paused restart touched credentials or reconnected")
        let pausedSignal = AutoconnectSignal(paused)
        paused.toggleEnabled()
        await pausedSignal.wait { if case .connected = paused.phase { true } else { false } }
        try AgentMessagingContract.require(
            pausedPreferences.loadEnabled(), "Resume did not update the current session")
        paused.disconnect(forget: true)
        try AgentMessagingContract.require(
            !pausedPreferences.loadEnabled() && credentials.removals == 1,
            "Forget retained enabled state or saved bot")
        paused.shutdown()
        await network.drain()
    }

    private static func transientStartupFailure() async throws {
        let preferences = TelegramConnectionPreferences.transient(enabled: true)
        let credentials = AutoconnectCredentials()
        let network = AutoconnectNetwork()
        await network.failNextVerification(.rateLimited(retryAfterSeconds: 7))
        let sleeper = AutoconnectSleeper()
        let connection = controller(credentials, network, preferences, sleeper: sleeper)
        let signal = AutoconnectSignal(connection)
        connection.start()
        await sleeper.waitForSleep()
        let delays = await sleeper.delays
        try AgentMessagingContract.require(delays == [.seconds(7)], "Startup ignored Retry-After")
        try AgentMessagingContract.require(
            connection.isRetryingConnection, "Startup hid reconnect state")
        await sleeper.release()
        await signal.wait { if case .connected = connection.phase { true } else { false } }
        try AgentMessagingContract.require(
            credentials.loads == 1, "Network retry reloaded credentials")
        connection.shutdown()
        await network.drain()

        let cancelledNetwork = AutoconnectNetwork()
        await cancelledNetwork.failNextVerification(.transportFailure)
        let cancelledSleeper = AutoconnectSleeper()
        let cancelled = controller(
            credentials, cancelledNetwork, preferences, sleeper: cancelledSleeper)
        cancelled.start()
        await cancelledSleeper.waitForSleep()
        cancelled.disconnect()
        await cancelledSleeper.release()
        await Task.yield()
        let verifications = await cancelledNetwork.verifications
        try AgentMessagingContract.require(
            cancelled.phase == .disconnected && verifications == 1,
            "Pause allowed an obsolete restore task to reconnect")
        cancelled.shutdown()
        await cancelledNetwork.drain()

        let lockedCredentials = AutoconnectCredentials()
        lockedCredentials.failNextLoad()
        let lockedNetwork = AutoconnectNetwork()
        let lockedSleeper = AutoconnectSleeper()
        let locked = controller(
            lockedCredentials, lockedNetwork, .transient(enabled: true), sleeper: lockedSleeper)
        let lockedSignal = AutoconnectSignal(locked)
        locked.start()
        await lockedSleeper.waitForSleep()
        await lockedSleeper.release()
        await lockedSignal.wait { if case .connected = locked.phase { true } else { false } }
        try AgentMessagingContract.require(
            lockedCredentials.loads == 2, "Locked Keychain was not retried")
        locked.shutdown()
        await lockedNetwork.drain()
    }

    private static func noSavedBot() async throws {
        let preferences = TelegramConnectionPreferences.transient(enabled: true)
        let credentials = AutoconnectCredentials(saved: false)
        let network = AutoconnectNetwork()
        let connection = controller(credentials, network, preferences)
        let signal = AutoconnectSignal(connection)
        connection.start()
        await signal.wait { credentials.loads == 1 && connection.phase == .disconnected }
        let verifications = await network.verifications
        try AgentMessagingContract.require(
            verifications == 0 && !preferences.loadEnabled(),
            "Missing saved bot started network traffic or left Telegram enabled")
        connection.shutdown()
        await network.drain()
    }

    private static func permanentFailuresStop() async throws {
        for error in [TelegramCredentialError.unavailable, .invalidRecord] {
            let credentials = AutoconnectCredentials()
            credentials.failNextLoad(error)
            let network = AutoconnectNetwork()
            let sleeper = AutoconnectSleeper()
            let connection = controller(
                credentials, network, .transient(enabled: true), sleeper: sleeper)
            let signal = AutoconnectSignal(connection)
            connection.start()
            await signal.wait { connection.phase == .failed(.credentials) }
            let delays = await sleeper.delays
            let verifications = await network.verifications
            try AgentMessagingContract.require(
                credentials.loads == 1 && delays.isEmpty && verifications == 0,
                "Invalid credentials or missing Keychain entitlement caused an endless retry")
            connection.shutdown()
            await network.drain()
        }
        let credentials = AutoconnectCredentials()
        let network = AutoconnectNetwork()
        await network.failNextVerification(.unauthorized)
        let sleeper = AutoconnectSleeper()
        let connection = controller(
            credentials, network, .transient(enabled: true), sleeper: sleeper)
        let signal = AutoconnectSignal(connection)
        connection.start()
        await signal.wait { connection.phase == .failed(.network(.unauthorized)) }
        let delays = await sleeper.delays
        try AgentMessagingContract.require(
            delays.isEmpty, "Rejected bot token was retried automatically")
        connection.shutdown()
        await network.drain()
    }

    private static func controller(
        _ credentials: AutoconnectCredentials, _ network: AutoconnectNetwork,
        _ preferences: TelegramConnectionPreferences, sleeper: AutoconnectSleeper? = nil
    ) -> TelegramConnectionController {
        TelegramConnectionController(
            credentials: credentials.store, preferences: preferences,
            makeClient: { token in
                TelegramBotClient(token: token, transport: { try await network.send($0) })
            },
            sleep: { delay in
                if let sleeper {
                    await sleeper.sleep(delay)
                } else {
                    try await Task.sleep(for: delay)
                }
            },
            originIsCurrent: { _ in true })
    }
}

@MainActor
private final class AutoconnectSignal {
    private var waiters: [(@MainActor () -> Bool, CheckedContinuation<Void, Never>)] = []
    init(_ controller: TelegramConnectionController) {
        controller.onChange = { [weak self] in self?.changed() }
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { waiters.append((condition, $0)) }
    }
    private func changed() {
        let pending = waiters
        waiters.removeAll()
        for (condition, continuation) in pending {
            if condition() {
                continuation.resume()
            } else {
                waiters.append((condition, continuation))
            }
        }
    }
}

private final class AutoconnectCredentials: Sendable {
    private struct State {
        var saved: Bool
        var loads = 0
        var removals = 0
        var loadError: TelegramCredentialError?
    }
    private let state: Mutex<State>
    init(saved: Bool = true) { state = Mutex(State(saved: saved)) }
    var loads: Int { state.withLock { $0.loads } }
    var removals: Int { state.withLock { $0.removals } }
    func failNextLoad(_ error: TelegramCredentialError = .temporarilyUnavailable) {
        state.withLock { $0.loadError = error }
    }
    var store: TelegramCredentialStore {
        TelegramCredentialStore(
            load: { [self] in
                try state.withLock { value in
                    value.loads += 1
                    if let error = value.loadError {
                        value.loadError = nil
                        throw error
                    }
                    guard value.saved else { return nil }
                    return TelegramSavedConnection(
                        token: try TelegramBotToken("123456:autoconnect-fixture"),
                        peer: try TelegramPeer(userID: 42, chatID: 42))
                }
            },
            save: { [self] _, _ in state.withLock { $0.saved = true } },
            remove: { [self] in
                state.withLock {
                    $0.saved = false
                    $0.removals += 1
                }
            })
    }
}

private actor AutoconnectNetwork {
    private var nextFailure: TelegramBotClientError?
    private var polls: [CheckedContinuation<TelegramHTTPResponse, any Error>] = []
    private(set) var verifications = 0
    func failNextVerification(_ error: TelegramBotClientError) { nextFailure = error }
    func send(_ request: URLRequest) async throws -> TelegramHTTPResponse {
        if request.url!.lastPathComponent == "getUpdates" {
            return try await withCheckedThrowingContinuation { polls.append($0) }
        }
        verifications += 1
        if let error = nextFailure {
            nextFailure = nil
            if error == .unauthorized {
                return TelegramHTTPResponse(
                    data: Data("{\"ok\":false}".utf8),
                    response: HTTPURLResponse(
                        url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            if case .rateLimited(let seconds) = error {
                return TelegramHTTPResponse(
                    data: Data("{\"ok\":false,\"parameters\":{\"retry_after\":\(seconds)}}".utf8),
                    response: HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
            }
            throw error
        }
        return TelegramHTTPResponse(
            data: Data("{\"ok\":true,\"result\":{\"id\":1,\"is_bot\":true}}".utf8),
            response: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func drain() {
        for poll in polls { poll.resume(throwing: CancellationError()) }
        polls.removeAll()
    }
}

private actor AutoconnectSleeper {
    private(set) var delays: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(_ delay: Duration) async {
        delays.append(delay)
        await withCheckedContinuation { continuation in
            sleeper = continuation
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForSleep() async {
        if sleeper != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        sleeper?.resume()
        sleeper = nil
    }
}
