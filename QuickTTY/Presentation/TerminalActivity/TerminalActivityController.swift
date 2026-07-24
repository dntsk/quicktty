import Foundation

@MainActor
final class TerminalActivityController {
    typealias CleanupSchedule =
        (
            _ delay: TimeInterval,
            _ action: @escaping @MainActor @Sendable () -> Void
        ) -> @MainActor () -> Void

    private(set) var statuses: [PaneID: TerminalActivityState] = [:]

    private let now: @MainActor () -> TimeInterval
    private let scheduleCleanup: CleanupSchedule
    var scheduledEffectHandler: (@MainActor (TerminalActivityEffect) -> Void)?
    private var cleanupCancellations: [PaneID: @MainActor () -> Void] = [:]

    init(
        now: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        scheduleCleanup: CleanupSchedule? = nil,
        scheduledEffectHandler: (@MainActor (TerminalActivityEffect) -> Void)? = nil
    ) {
        self.now = now
        self.scheduleCleanup = scheduleCleanup ?? Self.productionCleanupSchedule
        self.scheduledEffectHandler = scheduledEffectHandler
    }

    isolated deinit {
        for cancellation in cleanupCancellations.values {
            cancellation()
        }
    }

    @discardableResult
    func handleProgress(
        _ report: GhosttyProgressReport,
        for paneID: PaneID
    ) -> [TerminalActivityEffect] {
        switch report.state {
        case .set, .indeterminate:
            beginWorking(report, for: paneID)
            return []
        case .pause:
            return pause(report, for: paneID)
        case .error:
            return fail(report, for: paneID)
        case .remove:
            return removeActivity(for: paneID)
        }
    }

    @discardableResult
    func handleCommandFinished(
        _ command: GhosttyCommandFinished,
        for paneID: PaneID
    ) -> [TerminalActivityEffect] {
        guard let status = statuses[paneID] else { return [] }
        switch status.phase {
        case .failed, .completed:
            return []
        case .working(let progress), .waiting(let progress):
            if let exitCode = command.exitCode, exitCode != 0 {
                replaceStatus(
                    TerminalActivityState(
                        phase: .failed(progress: progress),
                        startedAt: status.startedAt
                    ),
                    for: paneID
                )
                return [.failed(paneID: paneID)]
            }

            let elapsed = elapsed(since: status.startedAt)
            replaceStatus(
                TerminalActivityState(phase: .completed, startedAt: status.startedAt),
                for: paneID
            )
            return [.completed(paneID: paneID, elapsed: elapsed)]
        }
    }

    func acknowledge(_ paneID: PaneID, selectedAndVisible: Bool) {
        guard let status = statuses[paneID], status.phase.isTerminal else {
            cancelCleanup(for: paneID)
            return
        }
        guard selectedAndVisible else {
            cancelCleanup(for: paneID)
            return
        }
        guard cleanupCancellations[paneID] == nil else { return }

        cleanupCancellations[paneID] = scheduleCleanup(3) { [weak self] in
            guard let self else { return }
            self.cleanupCancellations[paneID] = nil
            guard self.statuses[paneID]?.phase.isTerminal == true else { return }
            self.statuses[paneID] = nil
            self.scheduledEffectHandler?(.cleared(paneID: paneID))
        }
    }

    func removePane(_ paneID: PaneID) {
        cancelCleanup(for: paneID)
        statuses[paneID] = nil
    }

    private func beginWorking(_ report: GhosttyProgressReport, for paneID: PaneID) {
        let progress: UInt8? = report.state == .indeterminate ? nil : report.progress
        if let status = statuses[paneID] {
            switch status.phase {
            case .working, .waiting:
                cancelCleanup(for: paneID)
                statuses[paneID] = TerminalActivityState(
                    phase: .working(progress: progress),
                    startedAt: status.startedAt
                )
                return
            case .failed, .completed:
                break
            }
        }

        replaceStatus(
            TerminalActivityState(phase: .working(progress: progress), startedAt: now()),
            for: paneID
        )
    }

    private func pause(
        _ report: GhosttyProgressReport,
        for paneID: PaneID
    ) -> [TerminalActivityEffect] {
        guard let status = statuses[paneID] else { return [] }
        switch status.phase {
        case .working:
            replaceStatus(
                TerminalActivityState(
                    phase: .waiting(progress: report.progress),
                    startedAt: status.startedAt
                ),
                for: paneID
            )
            return [.waiting(paneID: paneID)]
        case .waiting:
            replaceStatus(
                TerminalActivityState(
                    phase: .waiting(progress: report.progress),
                    startedAt: status.startedAt
                ),
                for: paneID
            )
            return []
        case .failed, .completed:
            return []
        }
    }

    private func fail(
        _ report: GhosttyProgressReport,
        for paneID: PaneID
    ) -> [TerminalActivityEffect] {
        guard let status = statuses[paneID] else { return [] }
        switch status.phase {
        case .working, .waiting:
            replaceStatus(
                TerminalActivityState(
                    phase: .failed(progress: report.progress),
                    startedAt: status.startedAt
                ),
                for: paneID
            )
            return [.failed(paneID: paneID)]
        case .failed:
            replaceStatus(
                TerminalActivityState(
                    phase: .failed(progress: report.progress),
                    startedAt: status.startedAt
                ),
                for: paneID
            )
            return []
        case .completed:
            return []
        }
    }

    private func removeActivity(for paneID: PaneID) -> [TerminalActivityEffect] {
        guard let status = statuses[paneID] else { return [] }
        switch status.phase {
        case .working, .waiting:
            let elapsed = elapsed(since: status.startedAt)
            replaceStatus(
                TerminalActivityState(phase: .completed, startedAt: status.startedAt),
                for: paneID
            )
            return [.completed(paneID: paneID, elapsed: elapsed)]
        case .failed, .completed:
            cancelCleanup(for: paneID)
            statuses[paneID] = nil
            return [.cleared(paneID: paneID)]
        }
    }

    private func replaceStatus(_ status: TerminalActivityState, for paneID: PaneID) {
        cancelCleanup(for: paneID)
        statuses[paneID] = status
    }

    private func cancelCleanup(for paneID: PaneID) {
        let cancellation = cleanupCancellations.removeValue(forKey: paneID)
        cancellation?()
    }

    private func elapsed(since start: TimeInterval) -> TimeInterval {
        max(0, now() - start)
    }

    private static func productionCleanupSchedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

extension TerminalActivityPhase {
    fileprivate var isTerminal: Bool {
        switch self {
        case .failed, .completed:
            true
        case .working, .waiting:
            false
        }
    }
}
