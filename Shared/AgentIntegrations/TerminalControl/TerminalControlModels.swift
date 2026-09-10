import Foundation

public enum TerminalTaskLifecyclePolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case closeOnSuccess = "close-on-success"
}

public enum TerminalTaskState: String, Codable, CaseIterable, Equatable, Sendable {
    case creating
    case running
    case waitingForUser = "waiting-for-user"
    case succeeded
    case failed
    case finishedUnknown = "finished-unknown"
    case cancelled
}

public enum TerminalPaneControlOwner: String, Codable, CaseIterable, Equatable, Sendable {
    case agent
    case user
    case finished
}

public enum TerminalSplitDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum TerminalControlKey: String, Codable, CaseIterable, Equatable, Sendable {
    case enter
    case tab
    case escape
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case backspace
    case delete
    case controlC = "ctrl-c"
    case controlD = "ctrl-d"
}

public enum TerminalControlErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case permissionRequired
    case permissionDenied
    case permissionRevoked
    case permissionUnavailable
    case invalidSession
    case staleSession
    case targetNotFound
    case targetNotOwned
    case staleTerminalRevision
    case userControlsPane
    case processFinished
    case resourceLimit
    case invalidLaunchRequest
    case invalidRequest
    case requestIDConflict
    case surfaceCreationFailed
    case modelMutationFailed
    case closeConfirmationDenied
    case timeout
    case cancelled
    case internalFailure
}

public struct TerminalControlLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let cwd: String

    public init(executable: String, arguments: [String], cwd: String) throws {
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(executable) else {
            throw TerminalControlValidationError.invalidExecutable
        }
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(cwd) else {
            throw TerminalControlValidationError.invalidWorkingDirectory
        }
        guard arguments.count <= TerminalControlLimits.maximumArgumentCount else {
            throw TerminalControlValidationError.invalidArguments
        }

        var aggregateByteCount = 0
        for argument in arguments {
            let byteCount = argument.utf8.count
            guard byteCount <= TerminalControlLimits.maximumArgumentSize,
                !argument.contains("\0")
            else {
                throw TerminalControlValidationError.invalidArguments
            }
            aggregateByteCount += byteCount
        }
        guard aggregateByteCount <= TerminalControlLimits.maximumAggregateArgumentSize else {
            throw TerminalControlValidationError.invalidArguments
        }

        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
    }
}

public struct TerminalControlRequest: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case list
        case createTab(
            launch: TerminalControlLaunch,
            policy: TerminalTaskLifecyclePolicy,
            focus: Bool
        )
        case split(
            anchorPaneID: UUID?,
            direction: TerminalSplitDirection,
            ratio: Double,
            launch: TerminalControlLaunch,
            policy: TerminalTaskLifecyclePolicy,
            focus: Bool
        )
        case read(taskID: UUID)
        case wait(taskID: UUID, revision: UInt64, timeoutMilliseconds: Int)
        case sendText(taskID: UUID, expectedRevision: UInt64, text: String)
        case sendKey(taskID: UUID, expectedRevision: UInt64, key: TerminalControlKey)
        case requestUserInput(taskID: UUID)
        case focus(taskID: UUID)
        case resize(taskID: UUID, ratio: Double)
        case interrupt(taskID: UUID, expectedRevision: UInt64)
        case close(taskID: UUID)

        var requiresRequestID: Bool {
            switch self {
            case .list, .read, .wait:
                false
            case .createTab, .split, .sendText, .sendKey, .requestUserInput, .focus,
                .resize, .interrupt, .close:
                true
            }
        }
    }

    public let version: Int
    public let requestID: UUID?
    public let operation: Operation

    public init(operation: Operation, requestID: UUID? = nil) throws {
        if operation.requiresRequestID {
            guard requestID != nil else {
                throw TerminalControlValidationError.missingRequestID
            }
        } else {
            guard requestID == nil else {
                throw TerminalControlValidationError.unexpectedRequestID
            }
        }

        switch operation {
        case .split(_, _, let ratio, _, _, _), .resize(_, let ratio):
            try TerminalControlValueValidator.validateRatio(ratio)
        case .wait(_, _, let timeoutMilliseconds):
            guard TerminalControlLimits.timeoutRange.contains(timeoutMilliseconds) else {
                throw TerminalControlValidationError.invalidTimeout
            }
        case .sendText(_, _, let text):
            let byteCount = text.utf8.count
            guard (1...TerminalControlLimits.maximumTextSize).contains(byteCount) else {
                throw TerminalControlValidationError.invalidText
            }
        case .list, .createTab, .read, .sendKey, .requestUserInput, .focus, .interrupt,
            .close:
            break
        }

        version = TerminalControlProtocol.version
        self.requestID = requestID
        self.operation = operation
    }
}

public struct TerminalControlTask: Equatable, Sendable {
    public let taskID: UUID
    public let paneID: UUID
    public let tabID: UUID
    public let workspaceID: UUID
    public let state: TerminalTaskState
    public let owner: TerminalPaneControlOwner
    public let policy: TerminalTaskLifecyclePolicy
    public let revision: UInt64
    public let exitCode: Int32?

    public init(
        taskID: UUID,
        paneID: UUID,
        tabID: UUID,
        workspaceID: UUID,
        state: TerminalTaskState,
        owner: TerminalPaneControlOwner,
        policy: TerminalTaskLifecyclePolicy,
        revision: UInt64,
        exitCode: Int32?
    ) {
        self.taskID = taskID
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.state = state
        self.owner = owner
        self.policy = policy
        self.revision = revision
        self.exitCode = exitCode
    }
}

public struct TerminalControlSnapshot: Equatable, Sendable {
    public let task: TerminalControlTask
    public let text: String
    public let isTruncated: Bool

    public init(task: TerminalControlTask, text: String, isTruncated: Bool) throws {
        guard text.utf8.count <= TerminalControlLimits.maximumSnapshotSize else {
            throw TerminalControlValidationError.snapshotTooLarge
        }
        self.task = task
        self.text = text
        self.isTruncated = isTruncated
    }
}

public struct TerminalControlWorkspaceMetadata: Equatable, Sendable {
    public let workspaceID: UUID
    public let name: String
    public let originPaneID: UUID
    public let activeTabID: UUID
    public let tabCount: Int
    public let paneCount: Int

    public init(
        workspaceID: UUID,
        name: String,
        originPaneID: UUID,
        activeTabID: UUID,
        tabCount: Int,
        paneCount: Int
    ) throws {
        let nameByteCount = name.utf8.count
        guard (1...TerminalControlLimits.maximumWorkspaceNameSize).contains(nameByteCount),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            tabCount >= 0,
            paneCount >= 0
        else {
            throw TerminalControlValidationError.invalidWorkspaceMetadata
        }

        self.workspaceID = workspaceID
        self.name = name
        self.originPaneID = originPaneID
        self.activeTabID = activeTabID
        self.tabCount = tabCount
        self.paneCount = paneCount
    }
}

public struct TerminalControlError: Error, Equatable, Sendable {
    public let code: TerminalControlErrorCode
    public let message: String

    public init(code: TerminalControlErrorCode, message: String) throws {
        let byteCount = message.utf8.count
        guard (1...TerminalControlLimits.maximumErrorMessageSize).contains(byteCount),
            !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw TerminalControlValidationError.invalidErrorMessage
        }
        self.code = code
        self.message = message
    }
}

public struct TerminalControlResponse: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case list(
            workspace: TerminalControlWorkspaceMetadata,
            tasks: [TerminalControlTask]
        )
        case task(TerminalControlTask)
        case snapshot(TerminalControlSnapshot)
        case acknowledged(taskID: UUID, revision: UInt64)
        case failure(TerminalControlError)
    }

    public let version: Int
    public let result: Result

    public init(result: Result) {
        version = TerminalControlProtocol.version
        self.result = result
    }
}

public enum TerminalControlValidationError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidWorkingDirectory
    case invalidArguments
    case missingRequestID
    case unexpectedRequestID
    case invalidRatio
    case invalidTimeout
    case invalidText
    case snapshotTooLarge
    case invalidWorkspaceMetadata
    case invalidErrorMessage
    case tooManyTasks
}

enum TerminalControlLimits {
    static let maximumArgumentCount = TerminalControlProtocol.maximumArgumentCount
    static let maximumArgumentSize = TerminalControlProtocol.maximumArgumentSize
    static let maximumAggregateArgumentSize =
        TerminalControlProtocol.maximumAggregateArgumentSize
    static let maximumTextSize = TerminalControlProtocol.maximumTextSize
    static let maximumSnapshotSize = TerminalControlProtocol.maximumSnapshotSize
    static let maximumWorkspaceNameSize = 256
    static let maximumErrorMessageSize = 1_024
    static let maximumRetainedTaskCount = 32
    static let timeoutRange =
        TerminalControlProtocol
        .minimumTimeoutMilliseconds...TerminalControlProtocol.maximumTimeoutMilliseconds
    static let ratioRange =
        TerminalControlProtocol.minimumRatio...TerminalControlProtocol.maximumRatio
}

enum TerminalControlValueValidator {
    static func validateRatio(_ ratio: Double) throws {
        guard ratio.isFinite, TerminalControlLimits.ratioRange.contains(ratio) else {
            throw TerminalControlValidationError.invalidRatio
        }
    }
}
