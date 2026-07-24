import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct TerminalActivityControllerTests {
    @Test
    func firstWorkingStartsActivityAtCurrentMonotonicInstant() {
        let clock = ManualActivityClock(now: 12.5)
        let controller = TerminalActivityController(now: { clock.now })
        let paneID = PaneID()

        let effects = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 10),
            for: paneID
        )

        #expect(effects.isEmpty)
        #expect(
            controller.statuses[paneID]
                == TerminalActivityState(phase: .working(progress: 10), startedAt: 12.5)
        )
    }

    @Test
    func workingKeepalivePreservesStartAndUpdatesPercentage() {
        let clock = ManualActivityClock(now: 1)
        let controller = TerminalActivityController(now: { clock.now })
        let paneID = PaneID()

        _ = controller.handleProgress(
            GhosttyProgressReport(state: .indeterminate, progress: nil),
            for: paneID
        )
        clock.now = 8
        let effects = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 80),
            for: paneID
        )

        #expect(effects.isEmpty)
        #expect(
            controller.statuses[paneID]
                == TerminalActivityState(phase: .working(progress: 80), startedAt: 1)
        )
    }

    @Test
    func resumedWorkingPreservesStartForCompletionEligibility() throws {
        let clock = ManualActivityClock(now: 0)
        let controller = TerminalActivityController(now: { clock.now })
        let paneID = PaneID()

        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 10),
            for: paneID
        )
        clock.now = 2
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .pause, progress: 10),
            for: paneID
        )
        clock.now = 4
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 90),
            for: paneID
        )
        clock.now = 5
        let effect = try #require(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: paneID
            ).first
        )

        #expect(effect == .completed(paneID: paneID, elapsed: 5))
        #expect(effect.isNotificationEligible)
    }

    @Test
    func pauseAndErrorEffectsAreOneShotTransitions() {
        let controller = TerminalActivityController(now: { 2 })
        let paneID = PaneID()
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 20),
            for: paneID
        )

        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .pause, progress: 25),
                for: paneID
            ) == [.waiting(paneID: paneID)]
        )
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .pause, progress: 30),
                for: paneID
            ).isEmpty
        )
        #expect(
            controller.statuses[paneID]
                == TerminalActivityState(phase: .waiting(progress: 30), startedAt: 2)
        )
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .error, progress: 30),
                for: paneID
            ) == [.failed(paneID: paneID)]
        )
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .error, progress: 35),
                for: paneID
            ).isEmpty
        )
        #expect(
            controller.statuses[paneID]
                == TerminalActivityState(phase: .failed(progress: 35), startedAt: 2)
        )
    }

    @Test
    func removeCompletesLiveActivityButClearsFailureWithoutSuccess() {
        let clock = ManualActivityClock(now: 0)
        let controller = TerminalActivityController(now: { clock.now })
        let workingPaneID = PaneID()
        let waitingPaneID = PaneID()
        let failedPaneID = PaneID()
        let unknownPaneID = PaneID()
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 50),
            for: workingPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 25),
            for: waitingPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .pause, progress: 25),
            for: waitingPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .indeterminate, progress: nil),
            for: failedPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .error, progress: nil),
            for: failedPaneID
        )

        clock.now = 2
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: workingPaneID
            ) == [.completed(paneID: workingPaneID, elapsed: 2)]
        )
        #expect(controller.statuses[workingPaneID]?.phase == .completed)
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: waitingPaneID
            ) == [.completed(paneID: waitingPaneID, elapsed: 2)]
        )
        #expect(controller.statuses[waitingPaneID]?.phase == .completed)
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: failedPaneID
            ) == [.cleared(paneID: failedPaneID)]
        )
        #expect(controller.statuses[failedPaneID] == nil)
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: unknownPaneID
            ).isEmpty
        )
    }

    @Test
    func commandFinishedFallsBackOnlyForExistingActivity() {
        let clock = ManualActivityClock(now: 10)
        let controller = TerminalActivityController(now: { clock.now })
        let successPaneID = PaneID()
        let failurePaneID = PaneID()
        let unknownPaneID = PaneID()

        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 1),
                for: unknownPaneID
            ).isEmpty
        )
        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: 1, durationNanoseconds: 1),
                for: unknownPaneID
            ).isEmpty
        )
        #expect(controller.statuses[unknownPaneID] == nil)

        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 40),
            for: successPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .pause, progress: 40),
            for: successPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 70),
            for: failurePaneID
        )
        clock.now = 12

        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: nil, durationNanoseconds: 2_000_000_000),
                for: successPaneID
            ) == [.completed(paneID: successPaneID, elapsed: 2)]
        )
        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: 2, durationNanoseconds: 2_000_000_000),
                for: failurePaneID
            ) == [.failed(paneID: failurePaneID)]
        )
        #expect(controller.statuses[successPaneID]?.phase == .completed)
        #expect(controller.statuses[failurePaneID]?.phase == .failed(progress: 70))

        clock.now = 13
        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 3_000_000_000),
                for: failurePaneID
            ).isEmpty
        )
        #expect(controller.statuses[failurePaneID]?.phase == .failed(progress: 70))
    }

    @Test
    func completionEligibilityUsesExactFiveSecondBoundary() throws {
        let clock = ManualActivityClock(now: 0)
        let controller = TerminalActivityController(now: { clock.now })
        let shortPaneID = PaneID()
        let eligiblePaneID = PaneID()
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 1),
            for: shortPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 1),
            for: eligiblePaneID
        )

        clock.now = 4.999
        let shortEffect = try #require(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: shortPaneID
            ).first
        )
        clock.now = 5
        let eligibleEffect = try #require(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: eligiblePaneID
            ).first
        )

        #expect(!shortEffect.isNotificationEligible)
        #expect(eligibleEffect.isNotificationEligible)
        #expect(TerminalActivityEffect.waiting(paneID: shortPaneID).isNotificationEligible)
        #expect(TerminalActivityEffect.failed(paneID: shortPaneID).isNotificationEligible)
        #expect(!TerminalActivityEffect.cleared(paneID: shortPaneID).isNotificationEligible)
    }

    @Test
    func acknowledgedTerminalStatesCleanUpAfterThreeSecondsAndCancellationIsDeterministic() {
        let scheduler = ManualActivityScheduler()
        let effectRecorder = ActivityEffectRecorder()
        let controller = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule,
            scheduledEffectHandler: { effectRecorder.effects.append($0) }
        )
        let completedPaneID = PaneID()
        let failedPaneID = PaneID()
        let restartedPaneID = PaneID()
        let explicitlyRemovedPaneID = PaneID()
        let waitingPaneID = PaneID()

        makeCompleted(completedPaneID, in: controller)
        controller.acknowledge(completedPaneID, selectedAndVisible: false)
        #expect(controller.statuses[completedPaneID] != nil)
        #expect(scheduler.activeRequests.isEmpty)
        controller.acknowledge(completedPaneID, selectedAndVisible: true)
        #expect(scheduler.activeRequests.map(\.delay) == [3])
        scheduler.runActiveRequests()
        #expect(controller.statuses[completedPaneID] == nil)
        #expect(effectRecorder.effects == [.cleared(paneID: completedPaneID)])

        makeFailed(failedPaneID, in: controller)
        controller.acknowledge(failedPaneID, selectedAndVisible: true)
        #expect(scheduler.activeRequests.map(\.delay) == [3])
        scheduler.runActiveRequests()
        #expect(controller.statuses[failedPaneID] == nil)
        #expect(
            effectRecorder.effects
                == [.cleared(paneID: completedPaneID), .cleared(paneID: failedPaneID)]
        )

        makeCompleted(restartedPaneID, in: controller)
        controller.acknowledge(restartedPaneID, selectedAndVisible: true)
        controller.acknowledge(restartedPaneID, selectedAndVisible: false)
        controller.acknowledge(restartedPaneID, selectedAndVisible: true)
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 9),
            for: restartedPaneID
        )
        scheduler.runActiveRequests()
        #expect(controller.statuses[restartedPaneID]?.phase == .working(progress: 9))

        makeCompleted(explicitlyRemovedPaneID, in: controller)
        controller.acknowledge(explicitlyRemovedPaneID, selectedAndVisible: true)
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .remove, progress: nil),
                for: explicitlyRemovedPaneID
            ) == [.cleared(paneID: explicitlyRemovedPaneID)]
        )
        #expect(scheduler.activeRequests.isEmpty)

        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 60),
            for: waitingPaneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .pause, progress: 60),
            for: waitingPaneID
        )
        controller.acknowledge(waitingPaneID, selectedAndVisible: true)
        scheduler.runActiveRequests()
        #expect(controller.statuses[waitingPaneID]?.phase == .waiting(progress: 60))
        #expect(effectRecorder.effects.count == 2)
    }

    @Test
    func paneRemovalCancelsCleanupWithoutEffect() {
        let scheduler = ManualActivityScheduler()
        let effectRecorder = ActivityEffectRecorder()
        let controller = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule,
            scheduledEffectHandler: { effectRecorder.effects.append($0) }
        )
        let paneID = PaneID()
        makeCompleted(paneID, in: controller)
        controller.acknowledge(paneID, selectedAndVisible: true)
        #expect(scheduler.activeRequests.count == 1)

        controller.removePane(paneID)
        scheduler.runActiveRequests()

        #expect(controller.statuses[paneID] == nil)
        #expect(scheduler.activeRequests.isEmpty)
        #expect(effectRecorder.effects.isEmpty)
    }

    @Test
    func unknownAndRedundantTransitionsDoNotDuplicateEffects() {
        let controller = TerminalActivityController(now: { 0 })
        let paneID = PaneID()
        let pause = GhosttyProgressReport(state: .pause, progress: nil)
        let error = GhosttyProgressReport(state: .error, progress: nil)
        let remove = GhosttyProgressReport(state: .remove, progress: nil)

        #expect(controller.handleProgress(pause, for: paneID).isEmpty)
        #expect(controller.handleProgress(error, for: paneID).isEmpty)
        #expect(controller.handleProgress(remove, for: paneID).isEmpty)
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 1),
            for: paneID
        )
        #expect(
            controller.handleProgress(
                GhosttyProgressReport(state: .set, progress: 2),
                for: paneID
            ).isEmpty
        )
        #expect(controller.handleProgress(pause, for: paneID) == [.waiting(paneID: paneID)])
        #expect(controller.handleProgress(pause, for: paneID).isEmpty)
        #expect(controller.handleProgress(error, for: paneID) == [.failed(paneID: paneID)])
        #expect(controller.handleProgress(error, for: paneID).isEmpty)
        #expect(
            controller.handleCommandFinished(
                GhosttyCommandFinished(exitCode: 1, durationNanoseconds: 1),
                for: paneID
            ).isEmpty
        )
        #expect(controller.handleProgress(remove, for: paneID) == [.cleared(paneID: paneID)])
        #expect(controller.handleProgress(remove, for: paneID).isEmpty)
    }

    private func makeCompleted(_ paneID: PaneID, in controller: TerminalActivityController) {
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .set, progress: 100),
            for: paneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .remove, progress: nil),
            for: paneID
        )
    }

    private func makeFailed(_ paneID: PaneID, in controller: TerminalActivityController) {
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .indeterminate, progress: nil),
            for: paneID
        )
        _ = controller.handleProgress(
            GhosttyProgressReport(state: .error, progress: nil),
            for: paneID
        )
    }
}

@MainActor
private final class ActivityEffectRecorder {
    var effects: [TerminalActivityEffect] = []
}

@MainActor
private final class ManualActivityClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

@MainActor
private final class ManualActivityScheduler {
    @MainActor
    final class Cancellation {
        var isCancelled = false
    }

    struct Request {
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
        let cancellation: Cancellation
    }

    private(set) var requests: [Request] = []

    var activeRequests: [Request] {
        requests.filter { !$0.cancellation.isCancelled }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let cancellation = Cancellation()
        requests.append(Request(delay: delay, action: action, cancellation: cancellation))
        return {
            cancellation.isCancelled = true
        }
    }

    func runActiveRequests() {
        let pending = requests
        requests.removeAll()
        for request in pending where !request.cancellation.isCancelled {
            request.action()
        }
    }
}
