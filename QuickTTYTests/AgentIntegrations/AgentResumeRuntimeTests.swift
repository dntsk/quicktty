import Foundation
import Testing

@testable import QuickTTY

@MainActor
struct AgentResumeRuntimeTests {
    @Test
    func beginClaimsSessionAndRejectsDuplicateOwner() throws {
        let fixture = try Fixture()
        let first = try fixture.makeAttempt(paneID: PaneID(), sessionID: "shared", generation: 1)
        let second = try fixture.makeAttempt(paneID: PaneID(), sessionID: "shared", generation: 1)

        #expect(fixture.runtime.begin(first))
        #expect(!fixture.runtime.begin(second))
        #expect(fixture.runtime.hasClaim(first.claimKey))
        #expect(fixture.actions == [.updateBinding(paneID: first.paneID, binding: first.binding)])
    }

    @Test
    func surfaceCreationFailureMarksFailedAndReleasesClaim() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))

        fixture.runtime.surfaceCreationFailed(attempt.reference)

        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
        #expect(fixture.actions.last == fixture.failedAction(for: attempt, code: .surfaceCreation))
    }

    @Test
    func exactRegistrationActivatesOnlyAfterStableConfirmationAndIgnoresStaleRegistrations()
        throws
    {
        let fixture = try Fixture(stableThreshold: 3)
        let attempt = try fixture.makeAttempt(generation: 7)
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)

        fixture.runtime.register(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: "wrong"
        )
        fixture.runtime.register(
            AgentResumeAttemptReference(
                paneID: attempt.paneID,
                attemptID: attempt.id,
                generation: 8
            ),
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )
        #expect(fixture.actions.count == 1)

        fixture.runtime.register(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )

        #expect(
            fixture.actions == [.updateBinding(paneID: attempt.paneID, binding: attempt.binding)])
        #expect(fixture.runtime.hasClaim(attempt.claimKey))

        fixture.scheduler.advance(by: 2.999)
        #expect(!fixture.actions.contains(fixture.activeAction(for: attempt)))

        fixture.scheduler.advance(by: 0.001)
        #expect(fixture.actions.last == fixture.activeAction(for: attempt))
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func retryRequiresNewUUIDAndIncreasingGeneration() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt(generation: 2)
        #expect(fixture.runtime.begin(attempt))

        #expect(!fixture.runtime.retry(attempt))
        let olderGeneration = try fixture.makeAttempt(
            paneID: attempt.paneID,
            sessionID: attempt.claimKey.sessionID,
            generation: 1
        )
        #expect(!fixture.runtime.retry(olderGeneration))
        #expect(fixture.runtime.isCurrent(attempt.reference))
    }

    @Test
    func invalidMismatchedRetryPreservesCurrentAttemptTimersAndClaim() throws {
        let fixture = try Fixture(registrationTimeout: 10, stableThreshold: 3)
        let current = try fixture.makeAttempt(generation: 1)
        let candidate = try fixture.makeAttempt(
            paneID: current.paneID,
            sessionID: current.claimKey.sessionID,
            generation: 2
        )
        let mismatchedBinding = try AgentResumeBinding(
            adapterID: candidate.binding.adapterID,
            sessionID: "different-session",
            workingDirectory: candidate.binding.workingDirectory,
            registeredAt: candidate.binding.registeredAt,
            launchMetadata: candidate.binding.launchMetadata,
            restoreState: candidate.binding.restoreState
        )
        let invalidRetry = AgentResumeAttempt(
            id: candidate.id,
            generation: candidate.generation,
            paneID: candidate.paneID,
            claimKey: candidate.claimKey,
            invocation: candidate.invocation,
            binding: mismatchedBinding
        )
        let duplicate = try fixture.makeAttempt(
            paneID: PaneID(),
            sessionID: current.claimKey.sessionID,
            generation: 1
        )

        #expect(fixture.runtime.begin(current))
        #expect(!fixture.runtime.retry(invalidRetry))
        #expect(fixture.runtime.isCurrent(current.reference))
        #expect(fixture.runtime.hasClaim(current.claimKey))
        #expect(!fixture.runtime.begin(duplicate))

        fixture.scheduler.advance(by: 10)
        #expect(fixture.actions.last == fixture.unverifiedAction(for: current))
        fixture.runtime.register(
            current.reference,
            adapterID: current.claimKey.adapterID,
            sessionID: current.claimKey.sessionID
        )
        fixture.scheduler.advance(by: 3)

        #expect(fixture.actions.last == fixture.activeAction(for: current))
        #expect(fixture.runtime.isCurrent(current.reference))
        #expect(fixture.runtime.hasClaim(current.claimKey))
    }

    @Test
    func staleCallbacksCannotMutateReplacementAttempt() throws {
        let fixture = try Fixture()
        let old = try fixture.makeAttempt(generation: 1)
        let replacement = try fixture.makeAttempt(
            paneID: old.paneID,
            sessionID: old.claimKey.sessionID,
            generation: 2
        )
        #expect(fixture.runtime.begin(old))
        #expect(fixture.runtime.retry(replacement))
        let actionCount = fixture.actions.count

        fixture.runtime.surfaceCreationFailed(old.reference)
        fixture.runtime.surfaceDidBecomeLive(old.reference)
        fixture.runtime.register(
            old.reference,
            adapterID: old.claimKey.adapterID,
            sessionID: old.claimKey.sessionID
        )
        fixture.runtime.processExited(old.reference)
        fixture.runtime.surfaceDidClose(old.reference)

        #expect(fixture.actions.count == actionCount)
        #expect(fixture.runtime.isCurrent(replacement.reference))
        #expect(fixture.runtime.hasClaim(replacement.claimKey))
    }

    @Test
    func registrationTimeoutMarksUnverifiedAndRetainsLiveClaim() throws {
        let fixture = try Fixture(registrationTimeout: 10, claimLifetime: 5)
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)

        fixture.scheduler.advance(by: 10)

        #expect(fixture.actions.last == fixture.unverifiedAction(for: attempt))
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
        fixture.scheduler.advance(by: 100)
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func expiryReleasesTimedOutNonLiveClaimAndAllowsRetry() throws {
        let fixture = try Fixture(registrationTimeout: 5, claimLifetime: 10)
        let attempt = try fixture.makeAttempt(generation: 1)
        #expect(fixture.runtime.begin(attempt))

        fixture.scheduler.advance(by: 5)
        #expect(fixture.actions.last == fixture.unverifiedAction(for: attempt))
        #expect(fixture.runtime.hasClaim(attempt.claimKey))

        fixture.scheduler.advance(by: 5)
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
        #expect(!fixture.runtime.retry(attempt))

        let retry = try fixture.makeAttempt(
            paneID: attempt.paneID,
            sessionID: attempt.claimKey.sessionID,
            generation: 2
        )
        #expect(fixture.runtime.retry(retry))
        #expect(fixture.runtime.hasClaim(retry.claimKey))
    }

    @Test
    func expiryBeforeTimeoutReleasesWhenAttemptBecomesUnverifiedAndAllowsRetry() throws {
        let fixture = try Fixture(registrationTimeout: 10, claimLifetime: 5)
        let attempt = try fixture.makeAttempt(generation: 1)
        #expect(fixture.runtime.begin(attempt))

        fixture.scheduler.advance(by: 5)
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
        #expect(fixture.runtime.isCurrent(attempt.reference))

        fixture.scheduler.advance(by: 5)
        #expect(fixture.actions.last == fixture.unverifiedAction(for: attempt))
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
        #expect(!fixture.runtime.isCurrent(attempt.reference))

        let retry = try fixture.makeAttempt(
            paneID: attempt.paneID,
            sessionID: attempt.claimKey.sessionID,
            generation: 2
        )
        #expect(fixture.runtime.retry(retry))
        #expect(fixture.runtime.hasClaim(retry.claimKey))
    }

    @Test(arguments: [true, false])
    func registrationAroundClaimExpiryHasIdenticalProtectedOutcome(registerBeforeExpiry: Bool)
        throws
    {
        let fixture = try Fixture(
            registrationTimeout: 20,
            stableThreshold: 2,
            claimLifetime: 5
        )
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))

        if registerBeforeExpiry {
            fixture.scheduler.advance(by: 4.999)
            fixture.runtime.register(
                attempt.reference,
                adapterID: attempt.claimKey.adapterID,
                sessionID: attempt.claimKey.sessionID
            )
            fixture.scheduler.advance(by: 0.001)
        } else {
            fixture.scheduler.advance(by: 5)
            fixture.runtime.register(
                attempt.reference,
                adapterID: attempt.claimKey.adapterID,
                sessionID: attempt.claimKey.sessionID
            )
        }

        #expect(fixture.runtime.hasClaim(attempt.claimKey))
        #expect(!fixture.actions.contains(fixture.activeAction(for: attempt)))

        fixture.scheduler.advance(by: 2)
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
        #expect(fixture.actions.last == fixture.activeAction(for: attempt))
    }

    @Test
    func expiryNeverReleasesActiveLiveSurface() throws {
        let fixture = try Fixture(stableThreshold: 2, claimLifetime: 5)
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)
        fixture.runtime.register(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )
        fixture.scheduler.advance(by: 2)
        fixture.scheduler.advance(by: 100)

        #expect(fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func immediateExitBeforeRegistrationFailsAndReleases() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)

        fixture.runtime.processExited(attempt.reference)

        #expect(fixture.actions.last == fixture.failedAction(for: attempt, code: .immediateExit))
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func registerThenImmediateWrapperExitPreservesFailedBinding() throws {
        let fixture = try Fixture(stableThreshold: 5)
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)
        fixture.runtime.register(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )

        fixture.runtime.unregister(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )
        let failedAction = fixture.failedAction(for: attempt, code: .immediateExit)

        #expect(fixture.actions.last == failedAction)
        #expect(!fixture.actions.contains(fixture.activeAction(for: attempt)))
        #expect(!fixture.actions.contains(.removeBinding(paneID: attempt.paneID)))
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))

        fixture.scheduler.advance(by: 100)
        #expect(fixture.actions.last == failedAction)
    }

    @Test
    func mismatchedUnregisterIsIgnored() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        let actionCount = fixture.actions.count

        fixture.runtime.unregister(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: "wrong"
        )

        #expect(fixture.actions.count == actionCount)
        #expect(fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func processExitAfterStableConfirmationRemovesBinding() throws {
        let fixture = try Fixture(stableThreshold: 5)
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        fixture.runtime.surfaceDidBecomeLive(attempt.reference)
        fixture.runtime.register(
            attempt.reference,
            adapterID: attempt.claimKey.adapterID,
            sessionID: attempt.claimKey.sessionID
        )
        fixture.scheduler.advance(by: 5)

        fixture.runtime.processExited(attempt.reference)

        #expect(fixture.actions.last == .removeBinding(paneID: attempt.paneID))
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
    }

    @Test
    func surfaceCloseReleasesClaimWithoutDeletingBinding() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))
        let actionCount = fixture.actions.count

        fixture.runtime.surfaceDidClose(attempt.reference)

        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
        #expect(fixture.actions.count == actionCount)
    }

    @Test
    func forgetRemovesBindingReleasesClaimAndInvalidatesCallbacks() throws {
        let fixture = try Fixture()
        let attempt = try fixture.makeAttempt()
        #expect(fixture.runtime.begin(attempt))

        fixture.runtime.forget(paneID: attempt.paneID)
        let actionCount = fixture.actions.count

        #expect(fixture.actions.last == .removeBinding(paneID: attempt.paneID))
        #expect(!fixture.runtime.hasClaim(attempt.claimKey))
        #expect(!fixture.runtime.isCurrent(attempt.reference))

        fixture.runtime.processExited(attempt.reference)
        fixture.scheduler.advance(by: 100)
        #expect(fixture.actions.count == actionCount)
    }

    @Test
    func reentrantFailureCallbackSeesCommittedStateAndCannotLeakReplacementClaim() throws {
        let fixture = try Fixture()
        let failed = try fixture.makeAttempt(generation: 1)
        let replacement = try fixture.makeAttempt(
            paneID: failed.paneID,
            sessionID: failed.claimKey.sessionID,
            generation: 2
        )
        #expect(fixture.runtime.begin(failed))
        let failedAction = fixture.failedAction(for: failed, code: .surfaceCreation)
        var didReenter = false
        fixture.actionHook = { action in
            guard action == failedAction else { return }
            didReenter = true
            #expect(!fixture.runtime.isCurrent(failed.reference))
            #expect(!fixture.runtime.hasClaim(failed.claimKey))
            #expect(fixture.runtime.retry(replacement))
            fixture.runtime.register(
                replacement.reference,
                adapterID: replacement.claimKey.adapterID,
                sessionID: replacement.claimKey.sessionID
            )
            fixture.runtime.forget(paneID: replacement.paneID)
        }

        fixture.runtime.surfaceCreationFailed(failed.reference)

        #expect(didReenter)
        #expect(!fixture.runtime.isCurrent(failed.reference))
        #expect(!fixture.runtime.isCurrent(replacement.reference))
        #expect(!fixture.runtime.hasClaim(failed.claimKey))
        #expect(!fixture.actions.contains(fixture.activeAction(for: replacement)))

        fixture.scheduler.advance(by: 100)
        #expect(!fixture.runtime.hasClaim(failed.claimKey))
    }

    @Test
    func retryInvalidatesOldTimersAndCallbacksAndUsesNewGeneration() throws {
        let fixture = try Fixture(registrationTimeout: 10)
        let old = try fixture.makeAttempt(generation: 1)
        let retry = try fixture.makeAttempt(
            paneID: old.paneID,
            sessionID: old.claimKey.sessionID,
            generation: 2
        )
        #expect(fixture.runtime.begin(old))
        #expect(fixture.runtime.retry(retry))
        fixture.runtime.surfaceDidBecomeLive(retry.reference)
        let countAfterRetry = fixture.actions.count

        fixture.scheduler.advance(by: 10)

        #expect(fixture.actions.count == countAfterRetry + 1)
        #expect(fixture.actions.last == fixture.unverifiedAction(for: retry))
        #expect(fixture.runtime.isCurrent(retry.reference))
        #expect(!fixture.runtime.isCurrent(old.reference))
    }

    @Test
    func manualSchedulerExecutesSameDeadlineInInsertionOrderAndSupportsCancellation() {
        let scheduler = AgentResumeManualScheduler()
        var values: [Int] = []
        let cancelled = scheduler.schedule(after: 3) { values.append(1) }
        scheduler.schedule(after: 3) { values.append(2) }
        scheduler.cancel(cancelled)

        scheduler.advance(by: 3)

        #expect(values == [2])
        #expect(scheduler.now == 3)
    }
}

@MainActor
private final class Fixture {
    let scheduler = AgentResumeManualScheduler()
    var actions: [AgentResumeRuntimeAction] = []
    var actionHook: ((AgentResumeRuntimeAction) -> Void)?
    private(set) lazy var runtime = AgentResumeRuntime(
        scheduler: scheduler,
        registrationTimeout: registrationTimeout,
        stableConfirmationThreshold: stableThreshold,
        claimLifetime: claimLifetime
    ) { [weak self] action in
        self?.actions.append(action)
        self?.actionHook?(action)
    }

    private let registrationTimeout: TimeInterval
    private let stableThreshold: TimeInterval
    private let claimLifetime: TimeInterval

    init(
        registrationTimeout: TimeInterval = 10,
        stableThreshold: TimeInterval = 3,
        claimLifetime: TimeInterval = 20
    ) throws {
        self.registrationTimeout = registrationTimeout
        self.stableThreshold = stableThreshold
        self.claimLifetime = claimLifetime
    }

    func makeAttempt(
        paneID: PaneID = PaneID(),
        sessionID: String = "session-123",
        generation: UInt64 = 1
    ) throws -> AgentResumeAttempt {
        let adapterID = try AgentAdapterID(rawValue: "claude")
        let binding = try AgentResumeBinding(
            adapterID: adapterID,
            sessionID: sessionID,
            workingDirectory: "/project",
            registeredAt: Date(timeIntervalSinceReferenceDate: 100),
            launchMetadata: [:],
            restoreState: .restoring
        )
        return AgentResumeAttempt(
            id: UUID(),
            generation: generation,
            paneID: paneID,
            claimKey: AgentResumeClaimKey(adapterID: adapterID, sessionID: sessionID),
            invocation: try ExecutableInvocation(
                executablePath: "/usr/local/bin/claude",
                arguments: ["--resume", sessionID],
                workingDirectory: "/project"
            ),
            binding: binding
        )
    }

    func failedAction(
        for attempt: AgentResumeAttempt,
        code: AgentResumeDiagnosticCode
    ) -> AgentResumeRuntimeAction {
        .updateBinding(
            paneID: attempt.paneID,
            binding: attempt.binding.updatingRestoreState(
                .failed(diagnosticCode: code, failedAt: scheduler.date)
            )
        )
    }

    func activeAction(for attempt: AgentResumeAttempt) -> AgentResumeRuntimeAction {
        .updateBinding(
            paneID: attempt.paneID,
            binding: attempt.binding.updatingRestoreState(.active)
        )
    }

    func unverifiedAction(for attempt: AgentResumeAttempt) -> AgentResumeRuntimeAction {
        .updateBinding(
            paneID: attempt.paneID,
            binding: attempt.binding.updatingRestoreState(.unverified)
        )
    }
}
