import Foundation

struct AgentResumeClaimKey: Equatable, Hashable, Sendable {
    let adapterID: AgentAdapterID
    let sessionID: String
}

struct AgentResumeAttemptIdentity: Equatable, Sendable {
    let id: UUID
    let generation: UInt64
}

struct AgentRestoreCompatibility: Equatable, Sendable {
    let status: AgentCompatibilityStatus
    let resolvedExecutablePath: String?
}

struct AgentRestorePaneInput: Equatable, Sendable {
    let descriptor: TerminalPaneDescriptor
    let bindingWorkingDirectoryExists: Bool
}

struct AgentResumeDiagnostic: Equatable, Sendable {
    let code: AgentResumeDiagnosticCode
}

struct AgentResumeAttempt: Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let paneID: PaneID
    let claimKey: AgentResumeClaimKey
    let invocation: ExecutableInvocation
    let binding: AgentResumeBinding

    var reference: AgentResumeAttemptReference {
        AgentResumeAttemptReference(
            paneID: paneID,
            attemptID: id,
            generation: generation
        )
    }
}

struct AgentResumeAttemptReference: Equatable, Hashable, Sendable {
    let paneID: PaneID
    let attemptID: UUID
    let generation: UInt64
}

enum AgentRestoreDecision: Equatable, Sendable {
    case freshShell(binding: AgentResumeBinding?)
    case resume(AgentResumeAttempt)
    case blocked(binding: AgentResumeBinding, diagnostic: AgentResumeDiagnostic)
}

struct AgentRestorePlanner: Sendable {
    struct Input: Sendable {
        let panes: [AgentRestorePaneInput]
        let effectivePolicyEnabled: Bool
        let registry: [AgentAdapterID: AgentIntegrationDefinition]
        let compatibilityByAdapter: [AgentAdapterID: AgentRestoreCompatibility]
        let homeDirectory: String
        let explicitRetry: Set<PaneID>
        let attemptIdentityByPane: [PaneID: AgentResumeAttemptIdentity]
        let failedAt: Date
    }

    func plan(_ input: Input) -> [PaneID: AgentRestoreDecision] {
        var decisions: [PaneID: AgentRestoreDecision] = [:]
        var eligible: [AgentRestorePaneInput] = []
        var claimCounts: [AgentResumeClaimKey: Int] = [:]

        for pane in input.panes {
            guard let binding = pane.descriptor.agentResumeBinding else { continue }
            claimCounts[
                AgentResumeClaimKey(
                    adapterID: binding.adapterID,
                    sessionID: binding.sessionID
                ),
                default: 0
            ] += 1
        }

        for pane in input.panes {
            guard let binding = pane.descriptor.agentResumeBinding else {
                decisions[pane.descriptor.id] = .freshShell(binding: nil)
                continue
            }
            guard input.effectivePolicyEnabled else {
                decisions[pane.descriptor.id] = .freshShell(binding: binding)
                continue
            }

            let claimKey = AgentResumeClaimKey(
                adapterID: binding.adapterID,
                sessionID: binding.sessionID
            )
            guard claimCounts[claimKey] == 1 else {
                decisions[pane.descriptor.id] = blocked(
                    binding,
                    code: .duplicateBinding,
                    failedAt: input.failedAt
                )
                continue
            }

            switch binding.restoreState {
            case .active:
                eligible.append(pane)
            case .failed, .unverified:
                if input.explicitRetry.contains(pane.descriptor.id) {
                    eligible.append(pane)
                } else {
                    decisions[pane.descriptor.id] = .freshShell(binding: binding)
                }
            case .restoring:
                decisions[pane.descriptor.id] = blocked(
                    binding,
                    code: .interruptedRestore,
                    failedAt: input.failedAt
                )
            }
        }

        for pane in eligible {
            guard let binding = pane.descriptor.agentResumeBinding else { continue }
            let paneID = pane.descriptor.id
            let claimKey = AgentResumeClaimKey(
                adapterID: binding.adapterID,
                sessionID: binding.sessionID
            )

            guard let definition = input.registry[binding.adapterID] else {
                decisions[paneID] = blocked(
                    binding,
                    code: .missingAdapter,
                    failedAt: input.failedAt
                )
                continue
            }
            if case .blocked = definition.capability {
                decisions[paneID] = blocked(
                    binding,
                    code: .missingAdapter,
                    failedAt: input.failedAt
                )
            } else {
                decisions[paneID] = makeDecision(
                    pane: pane,
                    binding: binding,
                    definition: definition,
                    claimKey: claimKey,
                    input: input
                )
            }
        }

        return decisions
    }

    private func makeDecision(
        pane: AgentRestorePaneInput,
        binding: AgentResumeBinding,
        definition: AgentIntegrationDefinition,
        claimKey: AgentResumeClaimKey,
        input: Input
    ) -> AgentRestoreDecision {
        guard let compatibility = input.compatibilityByAdapter[binding.adapterID] else {
            return blocked(binding, code: .missingExecutable, failedAt: input.failedAt)
        }

        let launchDirectory =
            pane.bindingWorkingDirectoryExists
            ? binding.workingDirectory
            : input.homeDirectory
        let result = definition.buildResumeInvocation(
            resolvedExecutablePath: compatibility.resolvedExecutablePath,
            compatibilityStatus: compatibility.status,
            binding: binding,
            launchWorkingDirectory: launchDirectory
        )

        switch result {
        case .invocation(let invocation):
            guard let identity = input.attemptIdentityByPane[pane.descriptor.id] else {
                return blocked(binding, code: .invalidMetadata, failedAt: input.failedAt)
            }
            return .resume(
                AgentResumeAttempt(
                    id: identity.id,
                    generation: identity.generation,
                    paneID: pane.descriptor.id,
                    claimKey: claimKey,
                    invocation: invocation,
                    binding: binding.updatingRestoreState(.restoring)
                )
            )
        case .freshShell(let failure):
            return blocked(
                binding,
                code: diagnosticCode(for: failure),
                failedAt: input.failedAt
            )
        }
    }

    private func diagnosticCode(
        for failure: AgentResumeInvocationFailure
    ) -> AgentResumeDiagnosticCode {
        switch failure {
        case .blocked, .adapterMismatch:
            .missingAdapter
        case .incompatibleStatus(let status):
            status == .missingExecutable ? .missingExecutable : .unsupportedVersion
        case .invalidSessionID:
            .invalidSessionID
        case .invalidMetadata, .invalidWorkingDirectory, .invalidInvocation:
            .invalidMetadata
        case .invalidExecutable:
            .missingExecutable
        }
    }

    private func blocked(
        _ binding: AgentResumeBinding,
        code: AgentResumeDiagnosticCode,
        failedAt: Date
    ) -> AgentRestoreDecision {
        .blocked(
            binding: binding.updatingRestoreState(
                .failed(diagnosticCode: code, failedAt: failedAt)
            ),
            diagnostic: AgentResumeDiagnostic(code: code)
        )
    }
}
