import Foundation

struct TerminalAutomationPresentation: Equatable, Sendable {
    static let maximumAdapterNameBytes = 96
    static let returnControlTitle = "Return Control to Agent"

    let taskID: UUID
    let adapterDisplayName: String
    let taskState: TerminalTaskState
    let controlOwner: TerminalPaneControlOwner
    let isRevoked: Bool
    let canReturnControl: Bool

    init(
        taskID: UUID,
        adapterDisplayName: String,
        taskState: TerminalTaskState,
        controlOwner: TerminalPaneControlOwner,
        isRevoked: Bool = false,
        canReturnControl: Bool
    ) {
        self.taskID = taskID
        self.adapterDisplayName = Self.boundedAdapterName(adapterDisplayName)
        self.taskState = taskState
        self.controlOwner = controlOwner
        self.isRevoked = isRevoked
        self.canReturnControl =
            canReturnControl && !isRevoked && controlOwner == .user
            && (taskState == .running || taskState == .waitingForUser)
    }

    var stateText: String {
        if isRevoked { return "Revoked" }
        switch taskState {
        case .creating: return "Creating"
        case .running: return controlOwner == .user ? "User controlled" : "Running"
        case .waitingForUser: return "Waiting for user"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .finishedUnknown: return "Finished"
        case .cancelled: return "Cancelled"
        }
    }

    var ownerText: String {
        switch controlOwner {
        case .agent: "Agent controls pane"
        case .user: "User controls pane"
        case .finished: "Control finished"
        }
    }

    var badgeText: String { "\(adapterDisplayName) · \(stateText)" }
    var accessibilityLabel: String { "Managed terminal, \(adapterDisplayName)" }
    var accessibilityValue: String { "\(stateText), \(ownerText)" }

    private static func boundedAdapterName(_ name: String) -> String {
        var result = ""
        var bytes = 0
        var isTruncated = false
        // WHY: A byte budget also bounds a single adversarial combining-character cluster.
        for scalar in name.unicodeScalars {
            let safeScalar: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                safeScalar = " "
            default:
                safeScalar = scalar
            }
            let count = safeScalar.utf8.count
            guard bytes + count <= maximumAdapterNameBytes - 3 else {
                isTruncated = true
                break
            }
            result.unicodeScalars.append(safeScalar)
            bytes += count
        }
        if isTruncated { result += "…" }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent" : trimmed
    }
}
