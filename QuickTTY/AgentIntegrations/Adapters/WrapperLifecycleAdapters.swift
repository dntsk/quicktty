import Foundation

struct WrapperLifecycleAdapterPolicy: Equatable, Sendable {
    let id: String
    let executable: String
    let identityEvent: String
    let identityField: String
    let pluginResource: String
    let versionProbePolicy: AgentVersionProbePolicy
    let statusLimitation: AgentIntegrationStatusLimitation

    func wrapperMutation(contents: Data) throws -> OwnedFileMutation {
        try OwnedFileMutation(
            path: AgentIntegrationPath(
                root: .applicationSupport,
                relativePath: "AgentSessionIntegrations/wrappers/\(executable)"
            ),
            operationID: "wrapper-\(id)-v1",
            contents: contents
        )
    }

    func pluginMutation(
        relativePath: String,
        contents: Data
    ) throws -> OwnedFileMutation {
        try OwnedFileMutation(
            path: AgentIntegrationPath(root: .home, relativePath: relativePath),
            operationID: "wrapper-plugin-\(id)-v1",
            contents: contents
        )
    }
}

enum WrapperLifecycleAdapters {
    static let policies: [WrapperLifecycleAdapterPolicy] = [
        WrapperLifecycleAdapterPolicy(
            id: "amp",
            executable: "amp",
            identityEvent: "session.start",
            identityField: "thread_id",
            pluginResource: "plugin.json",
            versionProbePolicy: .unverified,
            statusLimitation: .requiresProcessLifetimeWrapper
        ),
        WrapperLifecycleAdapterPolicy(
            id: "antigravity",
            executable: "agy",
            identityEvent: "conversation.start",
            identityField: "conversation_id",
            pluginResource: "hook.json",
            versionProbePolicy: .unverified,
            statusLimitation: .requiresProcessLifetimeWrapper
        ),
        WrapperLifecycleAdapterPolicy(
            id: "opencode",
            executable: "opencode",
            identityEvent: "session.created",
            identityField: "session_id",
            pluginResource: "plugin.js",
            versionProbePolicy: .unverified,
            statusLimitation: .undocumentedSelectedSessionUnregistered
        ),
    ]

    static func policy(for id: String) -> WrapperLifecycleAdapterPolicy? {
        policies.first { $0.id == id }
    }
}
