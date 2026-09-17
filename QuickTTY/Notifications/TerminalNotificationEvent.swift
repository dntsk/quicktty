import Foundation

enum TerminalNotificationEvent: Equatable, Sendable {
    case activity(TerminalActivityEffect)
    case commandCompleted(paneID: PaneID, durationNanoseconds: UInt64)
    case commandFailed(paneID: PaneID, durationNanoseconds: UInt64)

    var paneID: PaneID {
        switch self {
        case .activity(let effect):
            effect.paneID
        case .commandCompleted(let paneID, _), .commandFailed(let paneID, _):
            paneID
        }
    }

    var notificationBody: String {
        switch self {
        case .activity(let effect):
            effect.notificationBody
        case .commandCompleted:
            "A command completed."
        case .commandFailed:
            "A command failed."
        }
    }
}

extension TerminalActivityEffect {
    var paneID: PaneID {
        switch self {
        case .waiting(let paneID), .failed(let paneID), .completed(let paneID, _),
            .cleared(let paneID):
            paneID
        }
    }

    fileprivate var notificationBody: String {
        switch self {
        case .waiting:
            "A terminal task needs attention."
        case .failed:
            "A terminal task failed."
        case .completed:
            "A terminal task completed."
        case .cleared:
            preconditionFailure("Cleared terminal activity is not notification eligible")
        }
    }
}
