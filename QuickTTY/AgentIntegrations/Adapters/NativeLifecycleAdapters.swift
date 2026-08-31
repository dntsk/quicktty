import Foundation

struct NativeLifecycleAdapterPolicy: Equatable, Sendable {
    let id: String
    let startEvents: [String]
    let switchEvents: [String]
    let endEvents: [String]
    let installerStrategy: NativeLifecycleInstallerStrategy
    let versionProbePolicy: AgentVersionProbePolicy
}

enum NativeLifecycleInstallerStrategy: String, Equatable, Sendable {
    case ownedFile
    case jsonHook
    case markerBlock

    func ownedFileMutation(
        path: AgentIntegrationPath,
        operationID: String,
        contents: Data
    ) throws -> OwnedFileMutation {
        guard self == .ownedFile else { throw AgentIntegrationInstallerError.conflict }
        return try OwnedFileMutation(path: path, operationID: operationID, contents: contents)
    }

    func jsonHookMutation(
        path: AgentIntegrationPath,
        jsonPointer: String,
        operationID: String,
        commandNode: Data
    ) throws -> JSONHookMutation {
        guard self == .jsonHook else { throw AgentIntegrationInstallerError.conflict }
        return try JSONHookMutation(
            path: path,
            jsonPointer: jsonPointer,
            operationID: operationID,
            commandNode: commandNode
        )
    }

    func markerBlockMutation(
        path: AgentIntegrationPath,
        operationID: String,
        markerVersion: Int,
        body: Data
    ) throws -> MarkerBlockMutation {
        guard self == .markerBlock else { throw AgentIntegrationInstallerError.conflict }
        return try MarkerBlockMutation(
            path: path,
            operationID: operationID,
            markerVersion: markerVersion,
            body: body
        )
    }
}

enum NativeLifecycleAdapters {
    static let policies: [NativeLifecycleAdapterPolicy] = [
        policy("claude", starts: ["SessionStart"], ends: ["SessionEnd"], installer: .jsonHook),
        policy("codex", starts: ["SessionStart"], ends: ["SessionEnd"], installer: .jsonHook),
        policy(
            "pi",
            starts: ["session_start"],
            switches: ["session_switch"],
            ends: ["session_shutdown"],
            installer: .ownedFile,
            versionProbePolicy: .anyVersion(arguments: ["--version"])
        ),
        policy(
            "omp",
            starts: ["session_start"],
            switches: ["session_switch"],
            ends: ["session_shutdown"],
            installer: .ownedFile
        ),
        policy("cursor", starts: ["session_start"], ends: ["session_end"], installer: .jsonHook),
        policy("gemini", starts: ["SessionStart"], ends: ["SessionEnd"], installer: .jsonHook),
        policy(
            "hermes",
            starts: ["start", "pre_llm"],
            ends: ["finalize"],
            installer: .ownedFile
        ),
        policy(
            "copilot",
            starts: ["session_start"],
            ends: ["session_end"],
            installer: .jsonHook
        ),
        policy("droid", starts: ["session_start"], ends: ["session_end"], installer: .jsonHook),
        policy("qoder", starts: ["session_start"], ends: ["session_end"], installer: .jsonHook),
        policy("kimi", starts: ["SessionStart"], ends: ["SessionEnd"], installer: .markerBlock),
    ]

    static func policy(for id: String) -> NativeLifecycleAdapterPolicy? {
        policies.first { $0.id == id }
    }

    private static func policy(
        _ id: String,
        starts: [String],
        switches: [String] = [],
        ends: [String],
        installer: NativeLifecycleInstallerStrategy,
        versionProbePolicy: AgentVersionProbePolicy = .unverified
    ) -> NativeLifecycleAdapterPolicy {
        NativeLifecycleAdapterPolicy(
            id: id,
            startEvents: starts,
            switchEvents: switches,
            endEvents: ends,
            installerStrategy: installer,
            versionProbePolicy: versionProbePolicy
        )
    }
}
