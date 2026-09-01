import Foundation

struct AgentLaunchConfiguration: Equatable, Sendable {
    let command: String
    let environment: [String: String]

    init(
        invocation: ExecutableInvocation,
        bundledHelperPath: String,
        executableSearchPath: String = ApplicationEnvironment.effectiveGUIExecutableSearchPath()
    ) throws {
        guard Self.isValidHelperPath(bundledHelperPath) else {
            throw AgentLaunchConfigurationError.invalidHelperPath
        }

        let encodedPayload: String
        do {
            let payload = try AgentInvocationPayload(
                executable: invocation.executablePath,
                arguments: invocation.arguments,
                workingDirectory: invocation.workingDirectory
            )
            encodedPayload = try AgentInvocationPayloadCodec.encodeBase64(payload)
        } catch {
            throw AgentLaunchConfigurationError.invalidPayload
        }

        command = Self.quotePOSIXShellArgument(bundledHelperPath) + " internal launch"
        environment = [
            "PATH": executableSearchPath,
            AgentInvocationPayloadEnvironment.payloadKey: encodedPayload,
            AgentInvocationPayloadEnvironment.helperKey: bundledHelperPath,
        ]
    }

    func mergingPaneEnvironment(_ paneEnvironment: [String: String]) -> [String: String] {
        paneEnvironment.merging(environment) { _, appOwnedValue in appOwnedValue }
    }

    private static func isValidHelperPath(_ path: String) -> Bool {
        (1...4_096).contains(path.utf8.count)
            && path.hasPrefix("/")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func quotePOSIXShellArgument(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum AgentLaunchConfigurationError: Error, Equatable, Sendable {
    case invalidHelperPath
    case invalidPayload
}
