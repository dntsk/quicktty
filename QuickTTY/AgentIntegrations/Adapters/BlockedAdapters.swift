struct BlockedAdapterPolicy: Sendable {
    let definition: AgentIntegrationDefinition
    let installMutations: [AgentIntegrationMutationPlan]
}

enum BlockedAdapters {
    static let policies: [BlockedAdapterPolicy] = [
        policy("grok", "Grok", "grok", .ambiguousOfficialIdentity),
        policy("campfire", "Campfire", "the-campfire", .notSessionfulAgent),
        policy("kiro", "Kiro", "kiro-cli", .incompatibleLifecycleGenerations),
        policy("rovo-dev", "Rovo Dev", "acli", .missingSessionIdentity),
        policy("codebuddy", "CodeBuddy", "codebuddy", .betaLifecycleOnly),
        policy("ollama", "Ollama", "ollama", .missingPersistentSessionAPI),
    ]

    static func definition(for id: String) -> AgentIntegrationDefinition? {
        policies.first { $0.definition.id.rawValue == id }?.definition
    }

    private static func policy(
        _ rawID: String,
        _ displayName: String,
        _ executable: String,
        _ reason: AgentIntegrationBlockedReason
    ) -> BlockedAdapterPolicy {
        BlockedAdapterPolicy(
            definition: AgentIntegrationDefinition(
                id: adapterID(rawID),
                displayName: displayName,
                executableCandidates: [executable],
                capability: .blocked(reason),
                lifecycleStrategy: .blocked,
                installStrategy: .none,
                sessionIDPolicy: .opaqueSafe,
                cwdPolicy: .bindingDirectory,
                compatibilityPolicy: .blocked(reason),
                versionProbePolicy: .blocked(reason),
                statusLimitation: .blocked(reason),
                launchMetadataAllowlist: [],
                resumeArgumentStrategy: .blocked
            ),
            installMutations: []
        )
    }

    private static func adapterID(_ rawValue: String) -> AgentAdapterID {
        guard let id = try? AgentAdapterID(rawValue: rawValue) else {
            preconditionFailure("Invalid blocked adapter ID")
        }
        return id
    }
}
