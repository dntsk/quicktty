import Foundation

struct AgentIntegrationDefinition: Equatable, Sendable {
    let id: AgentAdapterID
    let displayName: String
    let executableCandidates: [String]
    let capability: AgentIntegrationCapability
    let lifecycleStrategy: AgentLifecycleStrategy
    let installStrategy: AgentInstallStrategy
    let sessionIDPolicy: AgentSessionIDPolicy
    let cwdPolicy: AgentCWDPolicy
    let compatibilityPolicy: AgentCompatibilityPolicy
    let versionProbePolicy: AgentVersionProbePolicy
    let statusLimitation: AgentIntegrationStatusLimitation
    let launchMetadataAllowlist: Set<String>
    let resumeArgumentStrategy: AgentResumeArgumentStrategy

    func validateLifecycle(
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    ) -> AgentLifecycleValidationResult {
        if case .blocked(let reason) = capability {
            return .invalid(.blocked(reason))
        }
        guard sessionIDPolicy.accepts(sessionID) else {
            return .invalid(.invalidSessionID)
        }
        guard Set(metadata.keys).isSubset(of: launchMetadataAllowlist) else {
            return .invalid(.invalidMetadata)
        }
        guard cwdPolicy.accepts(cwd) else {
            return .invalid(.invalidWorkingDirectory)
        }
        return .valid
    }

    func validateUnregister(sessionID: String) -> AgentLifecycleValidationResult {
        if case .blocked(let reason) = capability {
            return .invalid(.blocked(reason))
        }
        guard sessionIDPolicy.accepts(sessionID) else {
            return .invalid(.invalidSessionID)
        }
        return .valid
    }

    func buildResumeInvocation(
        resolvedExecutablePath: String?,
        compatibilityStatus: AgentCompatibilityStatus,
        binding: AgentResumeBinding,
        launchWorkingDirectory: String? = nil
    ) -> AgentResumeInvocationResult {
        if case .blocked(let reason) = capability {
            return .freshShell(.blocked(reason))
        }
        guard binding.adapterID == id else {
            return .freshShell(.adapterMismatch)
        }
        guard sessionIDPolicy.accepts(binding.sessionID) else {
            return .freshShell(.invalidSessionID)
        }
        guard Set(binding.launchMetadata.keys).isSubset(of: launchMetadataAllowlist) else {
            return .freshShell(.invalidMetadata)
        }
        guard cwdPolicy.accepts(binding.workingDirectory) else {
            return .freshShell(.invalidWorkingDirectory)
        }
        guard
            (try? AgentResumeBinding(
                adapterID: binding.adapterID,
                sessionID: binding.sessionID,
                workingDirectory: binding.workingDirectory,
                registeredAt: binding.registeredAt,
                launchMetadata: binding.launchMetadata,
                restoreState: binding.restoreState
            )) != nil
        else {
            return .freshShell(.invalidInvocation)
        }

        switch compatibilityStatus {
        case .compatible(let version):
            guard AgentCompatibilityStatus.isValidVersion(version) else {
                return .freshShell(.incompatibleStatus(.unverifiedVersion))
            }
        case .missingExecutable, .unverifiedVersion, .unsupportedVersion:
            return .freshShell(.incompatibleStatus(compatibilityStatus))
        }

        guard let resolvedExecutablePath else {
            return .freshShell(.invalidExecutable)
        }
        guard let arguments = resumeArgumentStrategy.arguments(for: binding.sessionID) else {
            return .freshShell(.invalidInvocation)
        }

        do {
            return .invocation(
                try ExecutableInvocation(
                    executablePath: resolvedExecutablePath,
                    arguments: arguments,
                    workingDirectory: launchWorkingDirectory
                        ?? cwdPolicy.launchDirectory(binding.workingDirectory)
                )
            )
        } catch ExecutableInvocationValidationError.invalidExecutable {
            return .freshShell(.invalidExecutable)
        } catch ExecutableInvocationValidationError.invalidWorkingDirectory {
            return .freshShell(.invalidWorkingDirectory)
        } catch {
            return .freshShell(.invalidInvocation)
        }
    }
}

enum AgentLifecycleValidationResult: Equatable, Sendable {
    case valid
    case invalid(AgentLifecycleValidationError)
}

enum AgentLifecycleValidationError: Equatable, Sendable {
    case blocked(AgentIntegrationBlockedReason)
    case invalidSessionID
    case invalidMetadata
    case invalidWorkingDirectory
}

enum AgentIntegrationCapability: Equatable, Sendable {
    case nativeLifecycle
    case wrapperLifecycle
    case blocked(AgentIntegrationBlockedReason)
}

enum AgentIntegrationBlockedReason: String, CaseIterable, Equatable, Sendable {
    case ambiguousOfficialIdentity
    case notSessionfulAgent
    case incompatibleLifecycleGenerations
    case missingSessionIdentity
    case betaLifecycleOnly
    case missingPersistentSessionAPI
}

enum AgentLifecycleStrategy: Equatable, Sendable {
    case nativeLifecycle
    case processLifetimeWrapper
    case blocked
}

enum AgentInstallStrategy: Equatable, Sendable {
    case nativeIntegration
    case wrapperIntegration
    case none
}

enum AgentSessionIDPolicy: Equatable, Sendable {
    case opaqueSafe

    fileprivate func accepts(_ sessionID: String) -> Bool {
        switch self {
        case .opaqueSafe:
            (1...512).contains(sessionID.utf8.count)
                && !sessionID.hasPrefix("-")
                && !sessionID.containsControlCharacter
        }
    }
}

enum AgentCWDPolicy: Equatable, Sendable {
    case bindingDirectory

    fileprivate func accepts(_ workingDirectory: String) -> Bool {
        switch self {
        case .bindingDirectory:
            AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(workingDirectory)
        }
    }

    fileprivate func launchDirectory(_ workingDirectory: String) -> String {
        switch self {
        case .bindingDirectory:
            workingDirectory
        }
    }
}

enum AgentCompatibilityPolicy: Equatable, Sendable {
    case requiresVerifiedInstalledVersion
    case blocked(AgentIntegrationBlockedReason)
}

enum AgentVersionProbePolicy: Equatable, Sendable {
    case exact(arguments: [String], acceptedLine: String, version: String)
    case unverified
    case blocked(AgentIntegrationBlockedReason)
}

enum AgentIntegrationStatusLimitation: Equatable, Sendable {
    case none
    case requiresProcessLifetimeWrapper
    case undocumentedSelectedSessionUnregistered
    case blocked(AgentIntegrationBlockedReason)
}

enum AgentCompatibilityStatus: Equatable, Sendable {
    case compatible(version: String)
    case missingExecutable
    case unverifiedVersion
    case unsupportedVersion

    fileprivate static func isValidVersion(_ version: String) -> Bool {
        (1...128).contains(version.utf8.count) && !version.containsControlCharacter
    }
}

enum AgentResumeArgumentStrategy: Equatable, Sendable {
    case option(String)
    case subcommand(String)
    case joinedOption(String)
    case fixedPrefix([String])
    case blocked

    fileprivate func arguments(for sessionID: String) -> [String]? {
        switch self {
        case .option(let option), .subcommand(let option):
            [option, sessionID]
        case .joinedOption(let option):
            ["\(option)=\(sessionID)"]
        case .fixedPrefix(let prefix):
            prefix + [sessionID]
        case .blocked:
            nil
        }
    }
}

enum AgentResumeInvocationResult: Equatable, Sendable {
    case invocation(ExecutableInvocation)
    case freshShell(AgentResumeInvocationFailure)
}

enum AgentResumeInvocationFailure: Equatable, Sendable {
    case blocked(AgentIntegrationBlockedReason)
    case incompatibleStatus(AgentCompatibilityStatus)
    case adapterMismatch
    case invalidSessionID
    case invalidMetadata
    case invalidWorkingDirectory
    case invalidExecutable
    case invalidInvocation
}

extension String {
    fileprivate var containsControlCharacter: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
