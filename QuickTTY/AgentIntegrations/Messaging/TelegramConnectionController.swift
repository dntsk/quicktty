import Foundation

private enum TelegramContinuousTime {
    static let epoch = ContinuousClock.now

    static func milliseconds() -> UInt64 {
        let epoch = Self.epoch
        let elapsed = epoch.duration(to: ContinuousClock.now).components
        // Uptime clocks can pause during sleep and keep an old approval window alive after wake.
        return UInt64(elapsed.seconds) * 1_000 + UInt64(elapsed.attoseconds) / 1_000_000_000_000_000
    }
}

enum TelegramConnectionPhase: Equatable, Sendable {
    case disconnected
    case verifying
    case pairing(code: String, candidate: TelegramPairingCandidate?)
    case connected(TelegramPeer)
    case failed(TelegramConnectionFailure)
}

enum TelegramConnectionFailure: Equatable, Sendable {
    case credentials
    case pairingExpired
    case network(TelegramBotClientError)
}

enum TelegramDeliveryState: Equatable, Sendable {
    case sending
    case sent
    case failed(TelegramBotClientError)
}

@MainActor
final class TelegramConnectionController {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Clock = @Sendable () -> UInt64
    typealias ClientFactory = @Sendable (TelegramBotToken) -> TelegramBotClient

    private let credentials: TelegramCredentialStore
    private let preferences: TelegramConnectionPreferences
    private let makeClient: ClientFactory
    private let clock: Clock
    private let sleep: Sleep
    private let originIsCurrent: @MainActor (AgentInteractionOrigin) -> Bool
    private var ledger = AgentInteractionLedger()
    private var generation = UUID()
    private var client: TelegramBotClient?
    private var pendingToken: TelegramBotToken?
    private var pairing: TelegramPairingChallenge?
    private var pollTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var hasStarted = false
    private var sendTasks: [UUID: Task<Void, Never>] = [:]
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var clearedRequests: Set<UUID> = []
    private var deferredUpdates: [TelegramUpdate] = []
    private var isFrozen = false
    private(set) var phase: TelegramConnectionPhase = .disconnected
    private(set) var isEnabled: Bool
    private(set) var isRetryingConnection = false
    private(set) var lastError: TelegramBotClientError?
    private(set) var deliveries: [UUID: TelegramDeliveryState] = [:]
    private(set) var enabledWorkspaces: Set<UUID> = []
    var onChange: (@MainActor () -> Void)?

    init(
        credentials: TelegramCredentialStore = .keychain(),
        preferences: TelegramConnectionPreferences = .transient(),
        makeClient: @escaping ClientFactory = { TelegramBotClient(token: $0) },
        clock: @escaping Clock = { TelegramContinuousTime.milliseconds() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        originIsCurrent: @escaping @MainActor (AgentInteractionOrigin) -> Bool = { _ in false }
    ) {
        self.credentials = credentials
        self.preferences = preferences
        isEnabled = preferences.loadEnabled()
        self.makeClient = makeClient
        self.clock = clock
        self.sleep = sleep
        self.originIsCurrent = originIsCurrent
    }

    isolated deinit {
        restoreTask?.cancel()
        pollTask?.cancel()
        for task in sendTasks.values { task.cancel() }
        for task in maintenanceTasks.values { task.cancel() }
    }

    func start() {
        guard !isFrozen, !hasStarted else { return }
        hasStarted = true
        if isEnabled { resume() }
    }

    func resume() {
        guard !isFrozen else { return }
        restoreTask?.cancel()
        setEnabled(true)
        restoreTask = Task { [weak self] in
            await self?.restoreSavedConnection(retryTransientFailures: true)
        }
    }

    func connect(tokenText: String) async {
        guard !isFrozen else { return }
        restoreTask?.cancel()
        restoreTask = nil
        setEnabled(false)
        invalidate()
        let attempt = generation
        phase = .verifying
        changed()
        guard isCurrent(attempt) else { return }
        do {
            let token = try TelegramBotToken(tokenText)
            let client = makeClient(token)
            _ = try await client.getMe()
            guard isCurrent(attempt), !Task.isCancelled else { return }
            self.client = client
            pendingToken = token
            let challenge = try TelegramPairingChallenge(now: clock())
            pairing = challenge
            phase = .pairing(code: challenge.code, candidate: nil)
            changed()
            guard isCurrent(attempt) else { return }
            beginPolling(client, generation: attempt)
        } catch {
            guard isCurrent(attempt) else { return }
            phase = .failed(.network(Self.clientError(error)))
            changed()
        }
    }

    func restoreSavedConnection(retryTransientFailures: Bool = false) async {
        guard !isFrozen, !Task.isCancelled else { return }
        invalidate()
        let attempt = generation
        phase = .verifying
        changed()
        var saved: TelegramSavedConnection?
        var failures = 0
        while isCurrent(attempt), !Task.isCancelled {
            do {
                if saved == nil { saved = try credentials.load() }
                guard let saved else {
                    setEnabled(false)
                    phase = .disconnected
                    changed()
                    return
                }
                let client = makeClient(saved.token)
                _ = try await client.getMe()
                guard isCurrent(attempt), !Task.isCancelled else { return }
                self.client = client
                setEnabled(true)
                isRetryingConnection = false
                lastError = nil
                phase = .connected(saved.peer)
                ledger.setEnabledWorkspaces(enabledWorkspaces, now: clock())
                changed()
                guard isCurrent(attempt) else { return }
                beginPolling(client, generation: attempt)
                return
            } catch {
                guard isCurrent(attempt), !Task.isCancelled else { return }
                let clientError = Self.clientError(error)
                let retryable: Bool
                if let credentialError = error as? TelegramCredentialError {
                    retryable = credentialError == .temporarilyUnavailable
                } else {
                    switch clientError {
                    case .transportFailure, .unavailable, .rateLimited: retryable = true
                    default: retryable = false
                    }
                }
                guard retryTransientFailures, retryable else {
                    phase = .failed(
                        error is TelegramCredentialError ? .credentials : .network(clientError))
                    changed()
                    return
                }
                failures = min(failures + 1, 6)
                isRetryingConnection = true
                lastError = clientError
                changed()
                guard isCurrent(attempt), !Task.isCancelled else { return }
                let seconds: Int
                if case .rateLimited(let retryAfter) = clientError {
                    seconds = retryAfter
                } else {
                    seconds = min(1 << (failures - 1), 30)
                }
                do { try await sleep(.seconds(seconds)) } catch { return }
            }
        }
    }

    func confirmPairing(candidateID: UUID) {
        guard !isFrozen, case .pairing(_, let candidate?) = phase, candidate.id == candidateID,
            let token = pendingToken,
            let peer = pairing?.confirm(candidateID: candidateID, now: clock())
        else { return }
        do {
            try credentials.save(token, peer)
            setEnabled(true)
            pendingToken = nil
            pairing = nil
            phase = .connected(peer)
            ledger.setEnabledWorkspaces(enabledWorkspaces, now: clock())
        } catch {
            invalidate()
            phase = .failed(.credentials)
        }
        changed()
    }

    func toggleEnabled() {
        if isEnabled { disconnect() } else { resume() }
    }

    func disconnect(forget: Bool = false) {
        guard !isFrozen else { return }
        restoreTask?.cancel()
        restoreTask = nil
        setEnabled(false)
        invalidate()
        phase = .disconnected
        if forget {
            do { try credentials.remove() } catch { phase = .failed(.credentials) }
        }
        changed()
    }

    func shutdown() {
        guard !isFrozen else { return }
        isFrozen = true
        restoreTask?.cancel()
        restoreTask = nil
        invalidate()
        phase = .disconnected
        onChange = nil
    }

    func setEnabledWorkspaces(_ ids: Set<UUID>) {
        guard !isFrozen else { return }
        enabledWorkspaces = ids
        ledger.setEnabledWorkspaces(ids, now: clock())
        cancelRevokedSends()
        cleanResolvedButtons()
        changed()
    }

    func authorize(_ origin: AgentInteractionOrigin, workspaceName: String, agentName: String)
        throws
    {
        guard !isFrozen, case .connected = phase, originIsCurrent(origin) else {
            throw AgentInteractionError.notAuthorized
        }
        try ledger.authorize(
            origin, workspaceName: workspaceName, agentName: agentName, now: clock())
        cancelRevokedSends()
        cleanResolvedButtons()
        changed()
    }

    func revoke(_ origin: AgentInteractionOrigin) {
        ledger.revoke(origin, now: clock())
        cancelRevokedSends()
        cleanResolvedButtons()
        changed()
    }

    func hasGrant(_ origin: AgentInteractionOrigin) -> Bool {
        !isFrozen && ledger.presentation(for: origin) != nil
    }

    func snapshots() -> [AgentInteractionSnapshot] {
        reconcileOrigins()
        return ledger.snapshots(now: clock())
    }

    func snapshot(_ id: UUID) -> AgentInteractionSnapshot? {
        reconcileOrigins()
        return ledger.snapshot(id, now: clock())
    }

    @discardableResult
    func submit(_ request: AgentInteractionRequest) throws -> AgentInteractionSnapshot {
        guard !isFrozen, originIsCurrent(request.origin), case .connected(let peer) = phase,
            let client
        else { throw AgentInteractionError.notAuthorized }
        let snapshot = try ledger.submit(request, now: clock())
        guard snapshot.state == .pending, deliveries[request.id] == nil else { return snapshot }
        let attempt = generation
        deliveries[request.id] = .sending
        sendTasks[request.id] = Task { [weak self] in
            guard self?.isCurrent(attempt) == true else { return }
            guard self?.canDeliver(request.origin) == true,
                self?.ledger.snapshot(request.id, now: self?.clock() ?? 0)?.state == .pending
            else {
                self?.failSend(request.id, error: .cancelled, generation: attempt)
                return
            }
            do {
                let reference = try await client.sendPrompt(snapshot, to: peer)
                self?.finishSend(request.id, reference: reference, generation: attempt)
            } catch {
                self?.failSend(request.id, error: Self.clientError(error), generation: attempt)
            }
        }
        changed()
        return snapshot
    }

    @discardableResult
    func answerLocally(_ id: UUID, answer: AgentInteractionAnswer) throws
        -> AgentInteractionSnapshot
    {
        guard !isFrozen else { throw AgentInteractionError.requestUnavailable }
        reconcileOrigins()
        let result = try ledger.resolveLocal(id, answer: answer, now: clock())
        cleanResolvedButtons()
        changed()
        return result
    }

    func notify(_ origin: AgentInteractionOrigin, status: TelegramAgentStatus, summary: String)
        throws
    {
        guard !isFrozen, originIsCurrent(origin), case .connected(let peer) = phase,
            let client, let presentation = ledger.presentation(for: origin)
        else { throw AgentInteractionError.notAuthorized }
        try AgentInteractionText.validate(summary, maximumBytes: 512)
        // Working updates remain visible locally without generating a stream of phone notifications.
        guard status != .working else { return }
        maintain(origin: origin) {
            _ = try await client.sendStatus(
                presentation: presentation, status: status, summary: summary, to: peer)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        preferences.saveEnabled(enabled)
    }

    private func invalidate() {
        generation = UUID()
        isRetryingConnection = false
        pollTask?.cancel()
        pollTask = nil
        for task in sendTasks.values { task.cancel() }
        for task in maintenanceTasks.values { task.cancel() }
        sendTasks.removeAll()
        maintenanceTasks.removeAll()
        deferredUpdates.removeAll()
        ledger.revokeAll(now: clock())
        pendingToken = nil
        pairing = nil
        client = nil
        lastError = nil
    }

    private func isCurrent(_ attempt: UUID) -> Bool { !isFrozen && generation == attempt }
    private func changed() { onChange?() }

    private func reconcileOrigins() {
        for snapshot in ledger.snapshots(now: clock()) where snapshot.state == .pending {
            if !originIsCurrent(snapshot.request.origin) {
                ledger.revoke(snapshot.request.origin, now: clock())
            }
        }
        cancelRevokedSends()
        cleanResolvedButtons()
    }

    private func canDeliver(_ origin: AgentInteractionOrigin) -> Bool {
        guard !isFrozen, case .connected = phase, originIsCurrent(origin) else { return false }
        return ledger.presentation(for: origin) != nil
    }

    private func cancelRevokedSends() {
        for (id, task) in sendTasks {
            switch ledger.snapshot(id, now: clock())?.state {
            case .resolved(.revoked), .resolved(.expired): task.cancel()
            default: break
            }
        }
    }

    private func finishSend(
        _ id: UUID, reference: TelegramMessageReference, generation attempt: UUID
    ) {
        guard isCurrent(attempt) else { return }
        sendTasks.removeValue(forKey: id)
        deliveries[id] = .sent
        reconcileOrigins()
        do {
            try ledger.bindTelegram(id, message: reference, now: clock())
        } catch {
            if let client { maintain { try await client.clearButtons(reference) } }
        }
        let deferred = deferredUpdates
        deferredUpdates.removeAll()
        for update in deferred { route(update) }
        changed()
    }

    private func failSend(_ id: UUID, error: TelegramBotClientError, generation attempt: UUID) {
        guard isCurrent(attempt) else { return }
        sendTasks.removeValue(forKey: id)
        deliveries[id] = .failed(error)
        if sendTasks.isEmpty { deferredUpdates.removeAll() }
        changed()
    }

    private func cleanResolvedButtons() {
        guard !isFrozen, let client else { return }
        for snapshot in ledger.snapshots(now: clock()) where snapshot.state != .pending {
            guard let message = snapshot.telegramMessage,
                clearedRequests.insert(snapshot.request.id).inserted
            else { continue }
            maintain { try await client.clearButtons(message) }
        }
    }

    private func maintain(
        origin: AgentInteractionOrigin? = nil,
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        guard maintenanceTasks.count < 64, !isFrozen else { return }
        let id = UUID()
        let attempt = generation
        maintenanceTasks[id] = Task { [weak self] in
            guard self?.isCurrent(attempt) == true else { return }
            if let origin, self?.canDeliver(origin) != true {
                self?.maintenanceTasks.removeValue(forKey: id)
                return
            }
            do { try await operation() } catch {}
            guard self?.isCurrent(attempt) == true else { return }
            self?.maintenanceTasks.removeValue(forKey: id)
        }
    }

    private func route(_ update: TelegramUpdate) {
        guard case .connected(let peer) = phase else { return }
        do {
            let resolved = try TelegramInteractionRouter(peer: peer).route(
                update, ledger: &ledger, now: clock())
            if resolved == nil, shouldDefer(update, peer: peer), deferredUpdates.count < 64 {
                deferredUpdates.append(update)
                return
            }
            if let callback = update.callbackQuery, let client {
                let text = resolved == nil ? "Запрос недоступен или уже закрыт" : "Ответ принят"
                maintain { try await client.answerCallbackQuery(callback.id, text: text) }
            } else {
                replyFeedback(update, accepted: resolved != nil, peer: peer)
            }
        } catch {
            if let callback = update.callbackQuery, let client {
                maintain {
                    try await client.answerCallbackQuery(
                        callback.id, text: "Ответ не принят: проверьте запрос")
                }
            } else {
                replyFeedback(update, accepted: false, peer: peer)
            }
        }
        cleanResolvedButtons()
    }

    private func replyFeedback(_ update: TelegramUpdate, accepted: Bool, peer: TelegramPeer) {
        guard update.callbackQuery == nil, let message = update.message,
            peer.accepts(message.from, in: message.chat), !message.isRelayed,
            message.messageID > 0, message.date > 0,
            let text = message.text, (1...4_096).contains(text.utf8.count), let client,
            accepted || ledger.snapshots(now: clock()).contains(where: { $0.state == .pending })
        else { return }
        // An unthreaded answer cannot identify an origin, even when only one request is pending.
        maintain { try await client.sendReplyFeedback(accepted: accepted, to: peer) }
    }

    private func shouldDefer(_ update: TelegramUpdate, peer: TelegramPeer) -> Bool {
        if let callback = update.callbackQuery, let message = callback.message,
            peer.accepts(callback.from, in: message.chat), !message.isRelayed,
            let data = callback.data, let parsed = TelegramCallbackData(encoded: data)
        {
            return sendTasks[parsed.requestID] != nil
        }
        if let message = update.message, peer.accepts(message.from, in: message.chat),
            !message.isRelayed,
            message.replyToMessage != nil, let text = message.text, text.utf8.count <= 4_096
        {
            return !sendTasks.isEmpty
        }
        return false
    }

    private func consume(_ updates: [TelegramUpdate], generation attempt: UUID) -> Bool {
        guard isCurrent(attempt) else { return false }
        lastError = nil
        reconcileOrigins()
        if let pairing, clock() >= pairing.expiresAtMilliseconds {
            invalidate()
            phase = .failed(.pairingExpired)
            changed()
            return false
        }
        for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
            if let candidate = pairing?.propose(update, now: clock()), let pairing {
                phase = .pairing(code: pairing.code, candidate: candidate)
            } else {
                route(update)
            }
        }
        changed()
        return isCurrent(attempt)
    }

    private func pollFailed(_ error: TelegramBotClientError, generation attempt: UUID) -> Bool {
        guard isCurrent(attempt) else { return false }
        lastError = error
        switch error {
        case .unauthorized, .conflict, .rejected, .invalidResponse, .invalidToken, .invalidRequest:
            phase = .failed(.network(error))
            changed()
            return false
        case .cancelled: return false
        default:
            changed()
            return isCurrent(attempt)
        }
    }

    private func beginPolling(_ client: TelegramBotClient, generation attempt: UUID) {
        let sleep = sleep
        pollTask = Task { [weak self] in
            await Self.poll(
                client: client, sleep: sleep,
                consume: { [weak self] in await self?.consume($0, generation: attempt) == true },
                failed: { [weak self] in await self?.pollFailed($0, generation: attempt) == true }
            )
        }
    }

    private nonisolated static func poll(
        client: TelegramBotClient,
        sleep: Sleep,
        consume: @escaping @Sendable ([TelegramUpdate]) async -> Bool,
        failed: @escaping @Sendable (TelegramBotClientError) async -> Bool
    ) async {
        var offset: Int64?
        var failures = 0
        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(offset: offset)
                guard !Task.isCancelled, await consume(updates) else { return }
                if let highest = updates.map(\.updateID).max() { offset = highest + 1 }
                failures = 0
                if updates.isEmpty { try await sleep(.milliseconds(100)) }
            } catch {
                let error = clientError(error)
                guard !Task.isCancelled, await failed(error) else { return }
                failures = min(failures + 1, 5)
                let seconds: Int
                if case .rateLimited(let retryAfter) = error {
                    seconds = retryAfter
                } else {
                    seconds = min(1 << (failures - 1), 30)
                }
                do { try await sleep(.seconds(seconds)) } catch { return }
            }
        }
    }

    private nonisolated static func clientError(_ error: any Error) -> TelegramBotClientError {
        if error is CancellationError { return .cancelled }
        return error as? TelegramBotClientError ?? .transportFailure
    }
}
