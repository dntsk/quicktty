import Foundation
import Testing

@testable import QuickTTY

struct AgentRestorePlannerTests {
    private let claudeID = try! AgentAdapterID(rawValue: "claude")

    @Test
    func noBindingStartsFresh() throws {
        let pane = TerminalPaneDescriptor(cwd: "/tmp")
        let decisions = plannerInput(panes: [pane]).planned()

        #expect(decisions[pane.id] == .freshShell(binding: nil))
    }

    @Test
    func disabledPolicyStartsFreshAndRetainsEveryBindingState() throws {
        for state in statesForDisabledPolicy {
            let pane = try makePane(state: state)
            let decisions = plannerInput(panes: [pane], policyEnabled: false).planned()

            #expect(decisions[pane.id] == .freshShell(binding: pane.agentResumeBinding))
        }
    }

    @Test
    func onlyActiveBindingsResumeAutomatically() throws {
        let active = try makePane(sessionID: "active", state: .active)
        let failed = try makePane(
            sessionID: "failed",
            state: .failed(
                diagnosticCode: .immediateExit,
                failedAt: Date(timeIntervalSinceReferenceDate: 100)
            )
        )
        let unverified = try makePane(sessionID: "unverified", state: .unverified)

        let decisions = plannerInput(panes: [active, failed, unverified]).planned()

        #expect(decisions[active.id]?.attempt?.binding.restoreState == .restoring)
        #expect(decisions[failed.id] == .freshShell(binding: failed.agentResumeBinding))
        #expect(decisions[unverified.id] == .freshShell(binding: unverified.agentResumeBinding))
    }

    @Test
    func persistedRestoringBecomesInterruptedFailure() throws {
        let pane = try makePane(state: .restoring)
        let decision = try #require(plannerInput(panes: [pane]).planned()[pane.id])

        assertBlocked(decision, code: .interruptedRestore, original: pane)
    }

    @Test
    func explicitRetryMakesFailedAndUnverifiedEligible() throws {
        for state in [
            AgentResumeState.failed(
                diagnosticCode: .surfaceCreation,
                failedAt: Date(timeIntervalSinceReferenceDate: 100)
            ),
            .unverified,
        ] {
            let pane = try makePane(state: state)
            let decision = try #require(
                plannerInput(panes: [pane], explicitRetry: [pane.id]).planned()[pane.id]
            )

            let attempt = try #require(decision.attempt)
            #expect(attempt.paneID == pane.id)
            #expect(attempt.binding.restoreState == .restoring)
        }
    }

    @Test
    func retryDoesNotMakePersistedRestoringEligible() throws {
        let pane = try makePane(state: .restoring)
        let decision = try #require(
            plannerInput(panes: [pane], explicitRetry: [pane.id]).planned()[pane.id]
        )

        assertBlocked(decision, code: .interruptedRestore, original: pane)
    }

    @Test(arguments: ["grok", "campfire", "kiro", "rovo-dev", "codebuddy", "ollama"])
    func blockedAdaptersFallBackWithBoundedFailure(adapterID: String) throws {
        let pane = try makePane(adapterID: adapterID)
        let decision = try #require(plannerInput(panes: [pane]).planned()[pane.id])

        assertBlocked(decision, code: .missingAdapter, original: pane)
    }

    @Test
    func unknownAdapterFallsBackWithBoundedFailure() throws {
        let pane = try makePane(adapterID: "unknown-agent")
        let decision = try #require(plannerInput(panes: [pane]).planned()[pane.id])

        assertBlocked(decision, code: .missingAdapter, original: pane)
    }

    @Test
    func invalidSessionAndMetadataAreRejected() throws {
        let invalidSession = try makePane(sessionID: "--help")
        let invalidMetadata = try makePane(metadata: ["model.name": "fixture"])
        let decisions = plannerInput(panes: [invalidSession, invalidMetadata]).planned()

        assertBlocked(
            try #require(decisions[invalidSession.id]),
            code: .invalidSessionID,
            original: invalidSession
        )
        assertBlocked(
            try #require(decisions[invalidMetadata.id]),
            code: .invalidMetadata,
            original: invalidMetadata
        )
    }

    @Test(arguments: [
        AgentCompatibilityStatus.missingExecutable,
        .unverifiedVersion,
        .unsupportedVersion,
    ])
    func allCompatibilityFailuresAreBounded(status: AgentCompatibilityStatus) throws {
        let pane = try makePane()
        let expectedCode: AgentResumeDiagnosticCode =
            status == .missingExecutable ? .missingExecutable : .unsupportedVersion
        let decision = try #require(
            plannerInput(
                panes: [pane],
                compatibility: [
                    claudeID: AgentRestoreCompatibility(
                        status: status,
                        resolvedExecutablePath: "/usr/local/bin/claude"
                    )
                ]
            ).planned()[pane.id]
        )

        assertBlocked(decision, code: expectedCode, original: pane)
    }

    @Test
    func absentCompatibilityAndResolvedExecutableAreMissingExecutable() throws {
        let missingCompatibilityPane = try makePane(sessionID: "session-a")
        let missingPathPane = try makePane(sessionID: "session-b")
        let missingCompatibility = plannerInput(
            panes: [missingCompatibilityPane],
            compatibility: [:]
        ).planned()
        assertBlocked(
            try #require(missingCompatibility[missingCompatibilityPane.id]),
            code: .missingExecutable,
            original: missingCompatibilityPane
        )

        let missingPath = plannerInput(
            panes: [missingPathPane],
            compatibility: [
                claudeID: AgentRestoreCompatibility(
                    status: .compatible(version: "1.0"),
                    resolvedExecutablePath: nil
                )
            ]
        ).planned()
        assertBlocked(
            try #require(missingPath[missingPathPane.id]),
            code: .missingExecutable,
            original: missingPathPane
        )
    }

    @Test(arguments: [
        "bin/claude", "/usr/local/bin/cl\0aude", "/" + String(repeating: "a", count: 4_096),
    ])
    func invalidResolvedExecutableIsMissingExecutable(path: String) throws {
        let pane = try makePane()
        let decision = try #require(
            plannerInput(
                panes: [pane],
                compatibility: [
                    claudeID: AgentRestoreCompatibility(
                        status: .compatible(version: "1.0"),
                        resolvedExecutablePath: path
                    )
                ]
            ).planned()[pane.id]
        )

        assertBlocked(decision, code: .missingExecutable, original: pane)
    }

    @Test(arguments: ["", "version\nvalue", String(repeating: "v", count: 129)])
    func invalidCompatibleVersionIsUnsupported(version: String) throws {
        let pane = try makePane()
        let decision = try #require(
            plannerInput(
                panes: [pane],
                compatibility: [
                    claudeID: AgentRestoreCompatibility(
                        status: .compatible(version: version),
                        resolvedExecutablePath: "/usr/local/bin/claude"
                    )
                ]
            ).planned()[pane.id]
        )

        assertBlocked(decision, code: .unsupportedVersion, original: pane)
    }

    @Test
    func missingWorkingDirectoryUsesHomeWithoutRewritingBindingIdentity() throws {
        let pane = try makePane(workingDirectory: "/missing/project")
        let decision = try #require(
            plannerInput(
                panes: [pane],
                workingDirectoryAvailability: [pane.id: false],
                homeDirectory: "/Users/example"
            ).planned()[pane.id]
        )
        let attempt = try #require(decision.attempt)

        #expect(attempt.invocation.workingDirectory == "/Users/example")
        #expect(attempt.binding.workingDirectory == "/missing/project")
        #expect(attempt.claimKey.sessionID == pane.agentResumeBinding?.sessionID)
    }

    @Test
    func canonicalWorkingDirectoryOutsideHomeNamespaceIsPreservedExactly() throws {
        let pane = try makePane(workingDirectory: "/Volumes/External/猫-é")
        let attempt = try #require(plannerInput(panes: [pane]).planned()[pane.id]?.attempt)

        #expect(attempt.invocation.workingDirectory == "/Volumes/External/猫-é")
        #expect(attempt.binding.workingDirectory == "/Volumes/External/猫-é")
    }

    @Test
    func attemptIdentityAndStructuredInvocationAreInjected() throws {
        let pane = try makePane()
        let identity = AgentResumeAttemptIdentity(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            generation: 42
        )
        let attempt = try #require(
            plannerInput(panes: [pane], identities: [pane.id: identity]).planned()[pane.id]?.attempt
        )

        #expect(attempt.id == identity.id)
        #expect(attempt.generation == 42)
        #expect(attempt.invocation.arguments == ["--resume", "session-123"])
        let storedFields = Set(Mirror(reflecting: attempt).children.compactMap(\.label))
        #expect(!storedFields.contains("command"))
        #expect(!storedFields.contains("environment"))
        #expect(!storedFields.contains("token"))
    }

    @Test
    func duplicateClaimBlocksAllPanesInEveryPermutation() throws {
        let first = try makePane(sessionID: "duplicate")
        let second = try makePane(sessionID: "duplicate")
        let third = try makePane(sessionID: "unique")
        let permutations = [
            [first, second, third],
            [second, third, first],
            [third, first, second],
            [second, first, third],
        ]

        let identities = Dictionary(
            uniqueKeysWithValues: [first, second, third].enumerated().map { index, pane in
                (
                    pane.id,
                    AgentResumeAttemptIdentity(
                        id: UUID(
                            uuidString: String(
                                format: "00000000-0000-0000-0000-%012d",
                                index + 1
                            )
                        )!,
                        generation: UInt64(index + 1)
                    )
                )
            }
        )
        let decisions = permutations.map {
            plannerInput(panes: $0, identities: identities).planned()
        }
        for result in decisions {
            assertBlocked(
                try #require(result[first.id]),
                code: .duplicateBinding,
                original: first
            )
            assertBlocked(
                try #require(result[second.id]),
                code: .duplicateBinding,
                original: second
            )
            #expect(result[third.id]?.attempt != nil)
        }
        for result in decisions.dropFirst() {
            #expect(result == decisions[0])
        }
    }

    @Test
    func duplicateScanCoversEveryPersistedStateInEveryPermutationAndIgnoresRetry()
        throws
    {
        let panes = [
            try makePane(sessionID: "duplicate", state: .active),
            try makePane(
                sessionID: "duplicate",
                state: .failed(
                    diagnosticCode: .immediateExit,
                    failedAt: Date(timeIntervalSinceReferenceDate: 10)
                )
            ),
            try makePane(sessionID: "duplicate", state: .unverified),
            try makePane(sessionID: "duplicate", state: .restoring),
        ]
        let permutations = [
            panes,
            [panes[1], panes[3], panes[0], panes[2]],
            [panes[3], panes[2], panes[1], panes[0]],
            [panes[2], panes[0], panes[3], panes[1]],
        ]

        for permutation in permutations {
            let withoutRetry = plannerInput(panes: permutation).planned()
            let withRetry = plannerInput(
                panes: permutation,
                explicitRetry: Set(panes.map(\.id))
            ).planned()

            #expect(withRetry == withoutRetry)
            for pane in panes {
                assertBlocked(
                    try #require(withoutRetry[pane.id]),
                    code: .duplicateBinding,
                    original: pane
                )
            }
        }
    }

    @Test
    func activeAndInactiveDuplicateBlockEachOtherWithoutRetry() throws {
        let active = try makePane(sessionID: "duplicate", state: .active)
        let failed = try makePane(
            sessionID: "duplicate",
            state: .failed(
                diagnosticCode: .immediateExit,
                failedAt: Date(timeIntervalSinceReferenceDate: 10)
            )
        )
        let decisions = plannerInput(panes: [failed, active]).planned()

        assertBlocked(
            try #require(decisions[active.id]),
            code: .duplicateBinding,
            original: active
        )
        assertBlocked(
            try #require(decisions[failed.id]),
            code: .duplicateBinding,
            original: failed
        )
    }

    @Test
    func disabledPolicyLeavesDuplicateBindingsFreshAndUnchanged() throws {
        let active = try makePane(sessionID: "duplicate", state: .active)
        let unverified = try makePane(sessionID: "duplicate", state: .unverified)
        let decisions = plannerInput(
            panes: [unverified, active],
            policyEnabled: false,
            explicitRetry: [unverified.id]
        ).planned()

        #expect(decisions[active.id] == .freshShell(binding: active.agentResumeBinding))
        #expect(decisions[unverified.id] == .freshShell(binding: unverified.agentResumeBinding))
    }

    private var statesForDisabledPolicy: [AgentResumeState] {
        [
            .active,
            .restoring,
            .unverified,
            .failed(
                diagnosticCode: .immediateExit,
                failedAt: Date(timeIntervalSinceReferenceDate: 100)
            ),
        ]
    }

    private func plannerInput(
        panes: [TerminalPaneDescriptor],
        policyEnabled: Bool = true,
        explicitRetry: Set<PaneID> = [],
        compatibility: [AgentAdapterID: AgentRestoreCompatibility]? = nil,
        workingDirectoryAvailability: [PaneID: Bool] = [:],
        homeDirectory: String = "/Users/example",
        identities: [PaneID: AgentResumeAttemptIdentity] = [:]
    ) -> AgentRestorePlanner.Input {
        let paneInputs = panes.map {
            AgentRestorePaneInput(
                descriptor: $0,
                bindingWorkingDirectoryExists: workingDirectoryAvailability[$0.id] ?? true
            )
        }
        let defaultCompatibility = Dictionary(
            uniqueKeysWithValues: AgentIntegrationRegistry.definitions.map {
                (
                    $0.id,
                    AgentRestoreCompatibility(
                        status: .compatible(version: "1.0"),
                        resolvedExecutablePath: "/usr/local/bin/\($0.executableCandidates[0])"
                    )
                )
            }
        )
        let defaultIdentities = Dictionary(
            uniqueKeysWithValues: panes.enumerated().map { index, pane in
                (
                    pane.id,
                    AgentResumeAttemptIdentity(
                        id: UUID(
                            uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                        generation: UInt64(index + 1)
                    )
                )
            }
        )

        return AgentRestorePlanner.Input(
            panes: paneInputs,
            effectivePolicyEnabled: policyEnabled,
            registry: Dictionary(
                uniqueKeysWithValues: AgentIntegrationRegistry.definitions.map { ($0.id, $0) }
            ),
            compatibilityByAdapter: compatibility ?? defaultCompatibility,
            homeDirectory: homeDirectory,
            explicitRetry: explicitRetry,
            attemptIdentityByPane: identities.merging(defaultIdentities) { supplied, _ in supplied
            },
            failedAt: Date(timeIntervalSinceReferenceDate: 999)
        )
    }

    private func makePane(
        adapterID: String = "claude",
        sessionID: String = "session-123",
        workingDirectory: String = "/project",
        metadata: [String: String] = [:],
        state: AgentResumeState = .active
    ) throws -> TerminalPaneDescriptor {
        TerminalPaneDescriptor(
            cwd: "/shell",
            agentResumeBinding: try AgentResumeBinding(
                adapterID: AgentAdapterID(rawValue: adapterID),
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                registeredAt: Date(timeIntervalSinceReferenceDate: 123),
                launchMetadata: metadata,
                restoreState: state
            )
        )
    }

    private func assertBlocked(
        _ decision: AgentRestoreDecision,
        code: AgentResumeDiagnosticCode,
        original: TerminalPaneDescriptor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .blocked(let binding, let diagnostic) = decision else {
            Issue.record("Expected blocked decision", sourceLocation: sourceLocation)
            return
        }
        #expect(diagnostic == AgentResumeDiagnostic(code: code), sourceLocation: sourceLocation)
        #expect(
            binding.adapterID == original.agentResumeBinding?.adapterID,
            sourceLocation: sourceLocation)
        #expect(
            binding.sessionID == original.agentResumeBinding?.sessionID,
            sourceLocation: sourceLocation)
        #expect(
            binding.workingDirectory == original.agentResumeBinding?.workingDirectory,
            sourceLocation: sourceLocation
        )
        #expect(
            binding.restoreState
                == .failed(
                    diagnosticCode: code,
                    failedAt: Date(timeIntervalSinceReferenceDate: 999)
                ),
            sourceLocation: sourceLocation
        )
    }
}

extension AgentRestorePlanner.Input {
    fileprivate func planned() -> [PaneID: AgentRestoreDecision] {
        AgentRestorePlanner().plan(self)
    }
}

extension AgentRestoreDecision {
    fileprivate var attempt: AgentResumeAttempt? {
        guard case .resume(let attempt) = self else { return nil }
        return attempt
    }
}
