struct AgentIntegrationRegistry {
    static let definitions: [AgentIntegrationDefinition] = [
        native("claude", "Claude Code", "claude", .option("--resume")),
        native("codex", "Codex", "codex", .subcommand("resume")),
        blocked("grok"),
        native(
            "pi",
            "Pi",
            "pi",
            .option("--session"),
            versionProbePolicy: .anyVersion(arguments: ["--version"])
        ),
        native("omp", "OMP", "omp", .option("--resume")),
        blocked("campfire"),
        wrapper("amp", "Amp", "amp", .fixedPrefix(["threads", "continue"])),
        native("cursor", "Cursor CLI", "agent", .option("--resume")),
        native("gemini", "Gemini CLI", "gemini", .option("--resume")),
        blocked("kiro"),
        wrapper("antigravity", "Antigravity", "agy", .option("--conversation")),
        wrapper("opencode", "OpenCode", "opencode", .option("--session")),
        blocked("rovo-dev"),
        native("hermes", "Hermes Agent", "hermes", .option("--resume")),
        native(
            "copilot",
            "GitHub Copilot CLI",
            "copilot",
            .joinedOption("--resume")
        ),
        blocked("codebuddy"),
        native("droid", "Factory/Droid", "droid", .option("--resume")),
        native("qoder", "Qoder", "qodercli", .option("--resume")),
        native("kimi", "Kimi Code", "kimi", .option("--session")),
        blocked("ollama"),
    ]

    static func definition(for id: AgentAdapterID) -> AgentIntegrationDefinition? {
        definitions.first { $0.id == id }
    }

    private static func native(
        _ rawID: String,
        _ displayName: String,
        _ executable: String,
        _ resumeArgumentStrategy: AgentResumeArgumentStrategy,
        versionProbePolicy: AgentVersionProbePolicy = .unverified
    ) -> AgentIntegrationDefinition {
        guard let policy = NativeLifecycleAdapters.policy(for: rawID),
            policy.versionProbePolicy == versionProbePolicy
        else {
            preconditionFailure("Missing or inconsistent native lifecycle policy")
        }
        return AgentIntegrationDefinition(
            id: adapterID(rawID),
            displayName: displayName,
            executableCandidates: [executable],
            capability: .nativeLifecycle,
            lifecycleStrategy: .nativeLifecycle,
            installStrategy: .nativeIntegration,
            sessionIDPolicy: .opaqueSafe,
            cwdPolicy: .bindingDirectory,
            compatibilityPolicy: .requiresVerifiedInstalledVersion,
            versionProbePolicy: versionProbePolicy,
            statusLimitation: .none,
            launchMetadataAllowlist: [],
            resumeArgumentStrategy: resumeArgumentStrategy
        )
    }

    private static func wrapper(
        _ rawID: String,
        _ displayName: String,
        _ executable: String,
        _ resumeArgumentStrategy: AgentResumeArgumentStrategy
    ) -> AgentIntegrationDefinition {
        guard let policy = WrapperLifecycleAdapters.policy(for: rawID),
            policy.executable == executable
        else {
            preconditionFailure("Missing or inconsistent wrapper lifecycle policy")
        }
        return AgentIntegrationDefinition(
            id: adapterID(rawID),
            displayName: displayName,
            executableCandidates: [executable],
            capability: .wrapperLifecycle,
            lifecycleStrategy: .processLifetimeWrapper,
            installStrategy: .wrapperIntegration,
            sessionIDPolicy: .opaqueSafe,
            cwdPolicy: .bindingDirectory,
            compatibilityPolicy: .requiresVerifiedInstalledVersion,
            versionProbePolicy: policy.versionProbePolicy,
            statusLimitation: policy.statusLimitation,
            launchMetadataAllowlist: [],
            resumeArgumentStrategy: resumeArgumentStrategy
        )
    }

    private static func blocked(_ rawID: String) -> AgentIntegrationDefinition {
        guard let definition = BlockedAdapters.definition(for: rawID) else {
            preconditionFailure("Missing blocked adapter definition")
        }
        return definition
    }

    private static func adapterID(_ rawValue: String) -> AgentAdapterID {
        guard let id = try? AgentAdapterID(rawValue: rawValue) else {
            preconditionFailure("Invalid built-in agent adapter ID")
        }
        return id
    }
}
