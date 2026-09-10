import Foundation

struct TerminalTaskLaunchConfiguration: Equatable, Sendable {
    let helperPath: String
    let command: String
    let environment: [String: String]

    init(
        launch: TerminalControlLaunch,
        bundledHelperPath: String,
        executableSearchPath: String = ApplicationEnvironment.effectiveGUIExecutableSearchPath()
    ) throws {
        guard AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(bundledHelperPath),
            FileManager.default.isExecutableFile(atPath: bundledHelperPath)
        else {
            throw AgentLaunchConfigurationError.invalidHelperPath
        }

        // WHY: Reject unusable targets before UI mutation; searchable directories are not programs.
        // This preflight follows symlinks but cannot prevent races or guarantee eventual exec success.
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: launch.executable, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: launch.executable)
        else {
            throw AgentLaunchConfigurationError.invalidPayload
        }

        let encodedPayload: String
        do {
            let payload = try AgentInvocationPayload(
                executable: launch.executable,
                arguments: launch.arguments,
                workingDirectory: launch.cwd
            )
            encodedPayload = try AgentInvocationPayloadCodec.encodeBase64(payload)
        } catch {
            throw AgentLaunchConfigurationError.invalidPayload
        }

        helperPath = bundledHelperPath
        // WHY: Retain the legacy representation, but managed execution uses the typed helper path.
        command = Self.quotePOSIXShellArgument(bundledHelperPath) + " internal launch"
        environment = [
            "PATH": executableSearchPath,
            AgentInvocationPayloadEnvironment.payloadKey: encodedPayload,
            AgentInvocationPayloadEnvironment.helperKey: bundledHelperPath,
        ]
    }

    private static func quotePOSIXShellArgument(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
