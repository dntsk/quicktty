import Foundation

struct GhosttySurfaceConfiguration: Equatable, Sendable {
    enum Context: Equatable, Sendable {
        case window
        case newTab
        case split
    }

    var workingDirectory: String?
    var command: String?
    // WHY: This creation-only opt-in must never be inferred from command or environment.
    var managedHelperPath: String?
    var environment: [String: String]
    var initialInput: String?
    var waitAfterCommand: Bool
    var context: Context

    init(
        workingDirectory: String? = nil,
        command: String? = nil,
        managedHelperPath: String? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        context: Context = .window
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.managedHelperPath = managedHelperPath
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.context = context
    }
}
