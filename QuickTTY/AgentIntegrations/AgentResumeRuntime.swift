import Foundation

@MainActor
protocol AgentResumeScheduling: AnyObject {
    var now: TimeInterval { get }
    var date: Date { get }

    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> UUID

    func cancel(_ id: UUID)
}

@MainActor
final class AgentResumeProductionScheduler: AgentResumeScheduling {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    var date: Date {
        Date()
    }

    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> UUID {
        precondition(interval >= 0)
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard let self, tasks.removeValue(forKey: id) != nil else { return }
            action()
        }
        tasks[id] = task
        return id
    }

    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }
}

@MainActor
final class AgentResumeManualScheduler: AgentResumeScheduling {
    private struct ScheduledAction {
        let id: UUID
        let deadline: TimeInterval
        let sequence: UInt64
        let action: @MainActor () -> Void
    }

    private let startDate: Date
    private var actions: [ScheduledAction] = []
    private var nextSequence: UInt64 = 0
    private(set) var now: TimeInterval = 0

    var date: Date {
        startDate.addingTimeInterval(now)
    }

    init(startDate: Date = Date(timeIntervalSinceReferenceDate: 700)) {
        self.startDate = startDate
    }

    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> UUID {
        precondition(interval >= 0)
        let id = UUID()
        actions.append(
            ScheduledAction(
                id: id,
                deadline: now + interval,
                sequence: nextSequence,
                action: action
            )
        )
        nextSequence += 1
        return id
    }

    func cancel(_ id: UUID) {
        actions.removeAll { $0.id == id }
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        let target = now + interval

        while let index = nextActionIndex(through: target) {
            let scheduled = actions.remove(at: index)
            now = scheduled.deadline
            scheduled.action()
        }

        now = target
    }

    private func nextActionIndex(through target: TimeInterval) -> Int? {
        actions.indices
            .filter { actions[$0].deadline <= target }
            .min { left, right in
                let lhs = actions[left]
                let rhs = actions[right]
                if lhs.deadline == rhs.deadline {
                    return lhs.sequence < rhs.sequence
                }
                return lhs.deadline < rhs.deadline
            }
    }
}

enum AgentResumeRuntimeAction: Equatable, Sendable {
    case updateBinding(paneID: PaneID, binding: AgentResumeBinding)
    case removeBinding(paneID: PaneID)
}

@MainActor
final class AgentResumeRuntime {
    private struct AttemptKey: Equatable, Hashable {
        let paneID: PaneID
        let attemptID: UUID
    }

    private struct Claim {
        let owner: AttemptKey
        let expiresAt: TimeInterval
    }

    private enum Phase: Equatable {
        case restoring
        case registeredPendingStability
        case active
        case unverified
    }

    private struct AttemptState {
        let attempt: AgentResumeAttempt
        var phase: Phase = .restoring
        var hasLiveSurface = false
        var expiryReached = false
        var timeoutTaskID: UUID?
        var expiryTaskID: UUID?
        var stabilityTaskID: UUID?
    }

    private let scheduler: any AgentResumeScheduling
    private let registrationTimeout: TimeInterval
    private let stableConfirmationThreshold: TimeInterval
    private let claimLifetime: TimeInterval
    private let actionHandler: @MainActor (AgentResumeRuntimeAction) -> Void

    private var attempts: [AttemptKey: AttemptState] = [:]
    private var currentAttemptByPane: [PaneID: AttemptKey] = [:]
    private var latestIdentityByPane: [PaneID: AgentResumeAttemptIdentity] = [:]
    private var claims: [AgentResumeClaimKey: Claim] = [:]

    init(
        scheduler: any AgentResumeScheduling,
        registrationTimeout: TimeInterval,
        stableConfirmationThreshold: TimeInterval,
        claimLifetime: TimeInterval,
        actionHandler: @escaping @MainActor (AgentResumeRuntimeAction) -> Void
    ) {
        precondition(registrationTimeout > 0)
        precondition(stableConfirmationThreshold > 0)
        precondition(claimLifetime > 0)
        self.scheduler = scheduler
        self.registrationTimeout = registrationTimeout
        self.stableConfirmationThreshold = stableConfirmationThreshold
        self.claimLifetime = claimLifetime
        self.actionHandler = actionHandler
    }

    @discardableResult
    func begin(_ attempt: AgentResumeAttempt) -> Bool {
        let key = AttemptKey(paneID: attempt.paneID, attemptID: attempt.id)
        guard currentAttemptByPane[attempt.paneID] == nil,
            claims[attempt.claimKey] == nil,
            isNewIdentity(attempt),
            attempt.binding.adapterID == attempt.claimKey.adapterID,
            attempt.binding.sessionID == attempt.claimKey.sessionID
        else {
            return false
        }

        claims[attempt.claimKey] = Claim(
            owner: key,
            expiresAt: scheduler.now + claimLifetime
        )
        currentAttemptByPane[attempt.paneID] = key
        latestIdentityByPane[attempt.paneID] = AgentResumeAttemptIdentity(
            id: attempt.id,
            generation: attempt.generation
        )
        var state = AttemptState(attempt: attempt)
        state.timeoutTaskID = scheduler.schedule(after: registrationTimeout) { [weak self] in
            self?.registrationTimedOut(attempt.reference)
        }
        state.expiryTaskID = scheduler.schedule(after: claimLifetime) { [weak self] in
            self?.claimExpired(attempt.reference)
        }
        attempts[key] = state
        actionHandler(
            .updateBinding(
                paneID: attempt.paneID,
                binding: attempt.binding.updatingRestoreState(.restoring)
            )
        )
        return true
    }

    @discardableResult
    func retry(_ attempt: AgentResumeAttempt) -> Bool {
        let replacementKey = AttemptKey(paneID: attempt.paneID, attemptID: attempt.id)
        guard isNewIdentity(attempt),
            attempt.binding.adapterID == attempt.claimKey.adapterID,
            attempt.binding.sessionID == attempt.claimKey.sessionID
        else {
            return false
        }
        if let existingClaim = claims[attempt.claimKey],
            existingClaim.owner != currentAttemptByPane[attempt.paneID],
            existingClaim.owner != replacementKey
        {
            return false
        }

        invalidateCurrentAttempt(for: attempt.paneID)
        return begin(attempt)
    }

    func surfaceDidBecomeLive(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), var state = attempts[key] else { return }
        state.hasLiveSurface = true
        attempts[key] = state
        releaseExpiredClaimIfNeeded(for: key)
    }

    func surfaceCreationFailed(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), let state = attempts[key] else { return }
        fail(state, key: key, code: .surfaceCreation)
    }

    func register(
        _ reference: AgentResumeAttemptReference,
        adapterID: AgentAdapterID,
        sessionID: String
    ) {
        guard let key = matchingKey(reference), var state = attempts[key],
            state.attempt.claimKey
                == AgentResumeClaimKey(adapterID: adapterID, sessionID: sessionID),
            state.phase == .restoring || state.phase == .unverified
        else {
            return
        }

        state.phase = .registeredPendingStability
        if let timeoutTaskID = state.timeoutTaskID {
            scheduler.cancel(timeoutTaskID)
            state.timeoutTaskID = nil
        }
        state.stabilityTaskID = scheduler.schedule(after: stableConfirmationThreshold) {
            [weak self] in
            self?.stableConfirmationReached(reference)
        }
        attempts[key] = state
        releaseExpiredClaimIfNeeded(for: key)
    }

    func unregister(
        _ reference: AgentResumeAttemptReference,
        adapterID: AgentAdapterID,
        sessionID: String
    ) {
        guard let key = matchingKey(reference),
            attempts[key]?.attempt.claimKey
                == AgentResumeClaimKey(adapterID: adapterID, sessionID: sessionID)
        else {
            return
        }
        processExited(reference)
    }

    func processExited(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), let state = attempts[key] else { return }

        switch state.phase {
        case .restoring, .registeredPendingStability, .unverified:
            fail(state, key: key, code: .immediateExit)
        case .active:
            invalidate(state, key: key)
            actionHandler(.removeBinding(paneID: state.attempt.paneID))
        }
    }

    func surfaceDidClose(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), let state = attempts[key] else { return }
        invalidate(state, key: key)
    }

    func forget(paneID: PaneID) {
        invalidateCurrentAttempt(for: paneID)
        actionHandler(.removeBinding(paneID: paneID))
    }

    func hasClaim(_ key: AgentResumeClaimKey) -> Bool {
        claims[key] != nil
    }

    func isCurrent(_ reference: AgentResumeAttemptReference) -> Bool {
        matchingKey(reference) != nil
    }

    private func registrationTimedOut(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), var state = attempts[key],
            state.phase == .restoring
        else {
            return
        }

        state.phase = .unverified
        state.timeoutTaskID = nil
        attempts[key] = state
        releaseExpiredClaimIfNeeded(for: key)
        actionHandler(
            .updateBinding(
                paneID: state.attempt.paneID,
                binding: state.attempt.binding.updatingRestoreState(.unverified)
            )
        )
    }

    private func claimExpired(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), var state = attempts[key],
            let claim = claims[state.attempt.claimKey],
            claim.owner == key,
            claim.expiresAt <= scheduler.now
        else {
            return
        }

        state.expiryReached = true
        state.expiryTaskID = nil
        attempts[key] = state
        releaseExpiredClaimIfNeeded(for: key)
    }

    private func stableConfirmationReached(_ reference: AgentResumeAttemptReference) {
        guard let key = matchingKey(reference), var state = attempts[key],
            state.phase == .registeredPendingStability
        else {
            return
        }

        state.phase = .active
        state.stabilityTaskID = nil
        attempts[key] = state
        releaseExpiredClaimIfNeeded(for: key)
        actionHandler(
            .updateBinding(
                paneID: state.attempt.paneID,
                binding: state.attempt.binding.updatingRestoreState(.active)
            )
        )
    }

    private func fail(
        _ state: AttemptState,
        key: AttemptKey,
        code: AgentResumeDiagnosticCode
    ) {
        let action = AgentResumeRuntimeAction.updateBinding(
            paneID: state.attempt.paneID,
            binding: state.attempt.binding.updatingRestoreState(
                .failed(diagnosticCode: code, failedAt: scheduler.date)
            )
        )
        invalidate(state, key: key)
        actionHandler(action)
    }

    private func releaseExpiredClaimIfNeeded(for key: AttemptKey) {
        guard let state = attempts[key],
            state.expiryReached,
            !state.hasLiveSurface,
            state.phase == .unverified
        else {
            return
        }
        invalidate(state, key: key)
    }

    private func isNewIdentity(_ attempt: AgentResumeAttempt) -> Bool {
        guard let latest = latestIdentityByPane[attempt.paneID] else { return true }
        return latest.id != attempt.id && latest.generation < attempt.generation
    }

    private func matchingKey(_ reference: AgentResumeAttemptReference) -> AttemptKey? {
        let key = AttemptKey(paneID: reference.paneID, attemptID: reference.attemptID)
        guard currentAttemptByPane[reference.paneID] == key,
            let state = attempts[key],
            state.attempt.generation == reference.generation
        else {
            return nil
        }
        return key
    }

    private func invalidateCurrentAttempt(for paneID: PaneID) {
        guard let key = currentAttemptByPane[paneID], let state = attempts[key] else { return }
        invalidate(state, key: key)
    }

    private func invalidate(_ state: AttemptState, key: AttemptKey) {
        for taskID in [state.timeoutTaskID, state.expiryTaskID, state.stabilityTaskID].compactMap({
            $0
        }) {
            scheduler.cancel(taskID)
        }
        if claims[state.attempt.claimKey]?.owner == key {
            claims.removeValue(forKey: state.attempt.claimKey)
        }
        attempts.removeValue(forKey: key)
        if currentAttemptByPane[state.attempt.paneID] == key {
            currentAttemptByPane.removeValue(forKey: state.attempt.paneID)
        }
    }
}
