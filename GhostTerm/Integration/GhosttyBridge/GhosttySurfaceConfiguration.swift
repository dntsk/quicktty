import Foundation

struct GhosttySurfaceConfiguration: Equatable, Sendable {
    enum Context: Equatable, Sendable {
        case window
        case tab
        case split
    }

    var workingDirectory: String?
    var command: String?
    var environment: [String: String]
    var initialInput: String?
    var waitAfterCommand: Bool
    var context: Context

    init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        context: Context = .window
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.context = context
    }
}
