import Foundation
import Testing

@testable import QuickTTY

struct BlockedAdapterTests {
    private let expectedReasons: [String: AgentIntegrationBlockedReason] = [
        "grok": .ambiguousOfficialIdentity,
        "campfire": .notSessionfulAgent,
        "kiro": .incompatibleLifecycleGenerations,
        "rovo-dev": .missingSessionIdentity,
        "codebuddy": .betaLifecycleOnly,
        "ollama": .missingPersistentSessionAPI,
    ]

    @Test
    func definitionsHaveExactReasonsAndConsistentlyBlockedPolicies() throws {
        #expect(BlockedAdapters.policies.count == 6)
        #expect(
            Set(BlockedAdapters.policies.map(\.definition.id.rawValue)) == Set(expectedReasons.keys)
        )

        for policy in BlockedAdapters.policies {
            let definition = policy.definition
            let reason = try #require(expectedReasons[definition.id.rawValue])

            #expect(definition.capability == .blocked(reason))
            #expect(definition.lifecycleStrategy == .blocked)
            #expect(definition.installStrategy == .none)
            #expect(definition.compatibilityPolicy == .blocked(reason))
            #expect(definition.versionProbePolicy == .blocked(reason))
            #expect(definition.statusLimitation == .blocked(reason))
            #expect(definition.resumeArgumentStrategy == .blocked)
            #expect(policy.installMutations.isEmpty)
        }
    }

    @Test
    func lifecycleAndResumeAlwaysReturnBoundedBlockedReason() throws {
        for policy in BlockedAdapters.policies {
            let definition = policy.definition
            let reason = try #require(expectedReasons[definition.id.rawValue])
            let binding = try AgentResumeBinding(
                adapterID: definition.id,
                sessionID: "session-123",
                workingDirectory: "/tmp",
                registeredAt: Date(timeIntervalSinceReferenceDate: 123_456),
                launchMetadata: [:],
                restoreState: .active
            )

            #expect(
                definition.validateLifecycle(sessionID: "", cwd: "relative", metadata: [:])
                    == .invalid(.blocked(reason))
            )
            #expect(
                definition.validateUnregister(sessionID: "") == .invalid(.blocked(reason))
            )
            #expect(
                definition.buildResumeInvocation(
                    resolvedExecutablePath: nil,
                    compatibilityStatus: .missingExecutable,
                    binding: binding
                ) == .freshShell(.blocked(reason))
            )
        }
    }

    @Test
    func blockedAdaptersHaveNoInstallableResources() throws {
        let resources = try #require(Bundle.main.resourceURL)
            .appending(path: "AgentSessionIntegrations", directoryHint: .isDirectory)

        for id in expectedReasons.keys {
            #expect(
                !FileManager.default.fileExists(
                    atPath: resources.appending(path: id, directoryHint: .isDirectory).path
                )
            )
        }
    }
}
