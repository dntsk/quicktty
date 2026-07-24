import Foundation

enum TerminalActivityPhase: Equatable, Sendable {
    case working(progress: UInt8?)
    case waiting(progress: UInt8?)
    case failed(progress: UInt8?)
    case completed
}

struct TerminalActivityState: Equatable, Sendable {
    let phase: TerminalActivityPhase
    let startedAt: TimeInterval
}

enum TerminalActivityEffect: Equatable, Sendable {
    case waiting(paneID: PaneID)
    case failed(paneID: PaneID)
    case completed(paneID: PaneID, elapsed: TimeInterval)
    case cleared(paneID: PaneID)

    var isNotificationEligible: Bool {
        switch self {
        case .waiting, .failed:
            true
        case .completed(_, let elapsed):
            elapsed >= 5
        case .cleared:
            false
        }
    }
}
