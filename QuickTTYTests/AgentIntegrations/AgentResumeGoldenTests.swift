import Foundation
import Testing

@testable import QuickTTY

struct AgentResumeGoldenTests {
    @Test
    func allGoldenFixturesBuildExactArgvOrExactBlockedReason() throws {
        let registry = try loadRegistryFixture()
        var invocationCount = 0
        var blockedCount = 0

        for expectedDefinition in registry {
            let definition = try #require(
                AgentIntegrationRegistry.definition(
                    for: AgentAdapterID(rawValue: expectedDefinition.id)
                )
            )
            let fixture = try loadResumeFixture(id: expectedDefinition.id)
            let executablePath = "/usr/local/bin/\(expectedDefinition.executable)"
            let binding = try makeBinding(
                adapterID: definition.id,
                sessionID: fixture.sessionID,
                workingDirectory: "/tmp"
            )
            let result = definition.buildResumeInvocation(
                resolvedExecutablePath: executablePath,
                compatibilityStatus: .compatible(version: "fixture-only"),
                binding: binding
            )

            if let blockedReason = fixture.blockedReason {
                blockedCount += 1
                let reason = try #require(AgentIntegrationBlockedReason(rawValue: blockedReason))
                #expect(result == .freshShell(.blocked(reason)))
            } else {
                invocationCount += 1
                let invocation = try #require(result.invocation)
                #expect(invocation.executablePath == executablePath)
                #expect(invocation.arguments == fixture.arguments)
                #expect(invocation.workingDirectory == "/tmp")
            }
        }

        #expect(invocationCount == 14)
        #expect(blockedCount == 6)
    }

    @Test(arguments: [
        AgentCompatibilityStatus.missingExecutable,
        .unverifiedVersion,
        .unsupportedVersion,
    ])
    func noncompatibleStatusCannotLaunch(status: AgentCompatibilityStatus) throws {
        let definition = try definition(id: "claude")
        let result = definition.buildResumeInvocation(
            resolvedExecutablePath: "/usr/local/bin/claude",
            compatibilityStatus: status,
            binding: try makeBinding(adapterID: definition.id)
        )

        #expect(result == .freshShell(.incompatibleStatus(status)))
    }

    @Test(arguments: [
        "",
        "version\ncontrol",
        String(repeating: "v", count: 129),
    ])
    func invalidCompatibleVersionIsUnverified(version: String) throws {
        let definition = try definition(id: "claude")
        let result = definition.buildResumeInvocation(
            resolvedExecutablePath: "/usr/local/bin/claude",
            compatibilityStatus: .compatible(version: version),
            binding: try makeBinding(adapterID: definition.id)
        )

        #expect(result == .freshShell(.incompatibleStatus(.unverifiedVersion)))
    }

    @Test
    func launchPreservesExactWorkingDirectory() throws {
        let definition = try definition(id: "claude")
        let workingDirectory = "/tmp"
        let result = definition.buildResumeInvocation(
            resolvedExecutablePath: "/usr/local/bin/claude",
            compatibilityStatus: .compatible(version: "fixture-only"),
            binding: try makeBinding(
                adapterID: definition.id,
                workingDirectory: workingDirectory
            )
        )

        #expect(result.invocation?.workingDirectory == workingDirectory)
    }

    @Test
    func blockedResumeArgumentStrategyCannotLaunch() throws {
        let definition = try definition(id: "claude")
        let blockedDefinition = AgentIntegrationDefinition(
            id: definition.id,
            displayName: definition.displayName,
            executableCandidates: definition.executableCandidates,
            capability: definition.capability,
            lifecycleStrategy: definition.lifecycleStrategy,
            installStrategy: definition.installStrategy,
            sessionIDPolicy: definition.sessionIDPolicy,
            cwdPolicy: definition.cwdPolicy,
            compatibilityPolicy: definition.compatibilityPolicy,
            versionProbePolicy: definition.versionProbePolicy,
            statusLimitation: definition.statusLimitation,
            launchMetadataAllowlist: definition.launchMetadataAllowlist,
            resumeArgumentStrategy: .blocked
        )
        let result = blockedDefinition.buildResumeInvocation(
            resolvedExecutablePath: "/usr/local/bin/claude",
            compatibilityStatus: .compatible(version: "fixture-only"),
            binding: try makeBinding(adapterID: definition.id)
        )

        #expect(result == .freshShell(.invalidInvocation))
        #expect(result.invocation == nil)
    }

    @Test
    func launchRejectsAdapterMismatchMetadataAndLeadingHyphenSession() throws {
        let definition = try definition(id: "claude")
        let mismatchedBinding = try makeBinding(adapterID: AgentAdapterID(rawValue: "codex"))
        let metadataBinding = try makeBinding(
            adapterID: definition.id,
            launchMetadata: ["model.name": "fixture"]
        )
        let leadingHyphenBinding = try makeBinding(
            adapterID: definition.id,
            sessionID: "--help"
        )

        #expect(
            definition.buildResumeInvocation(
                resolvedExecutablePath: "/usr/local/bin/claude",
                compatibilityStatus: .compatible(version: "fixture-only"),
                binding: mismatchedBinding
            ) == .freshShell(.adapterMismatch)
        )
        #expect(
            definition.buildResumeInvocation(
                resolvedExecutablePath: "/usr/local/bin/claude",
                compatibilityStatus: .compatible(version: "fixture-only"),
                binding: metadataBinding
            ) == .freshShell(.invalidMetadata)
        )
        #expect(
            definition.buildResumeInvocation(
                resolvedExecutablePath: "/usr/local/bin/claude",
                compatibilityStatus: .compatible(version: "fixture-only"),
                binding: leadingHyphenBinding
            ) == .freshShell(.invalidSessionID)
        )
    }

    @Test
    func launchRejectsMissingRelativeNULAndOversizedExecutable() throws {
        let definition = try definition(id: "claude")
        let binding = try makeBinding(adapterID: definition.id)
        let status = AgentCompatibilityStatus.compatible(version: "fixture-only")

        for path in [
            nil, "bin/claude", "/usr/local/bin/cl\0aude",
            "/" + String(repeating: "a", count: 4_096),
        ] {
            #expect(
                definition.buildResumeInvocation(
                    resolvedExecutablePath: path,
                    compatibilityStatus: status,
                    binding: binding
                ) == .freshShell(.invalidExecutable)
            )
        }
    }

    @Test
    func executableInvocationEnforcesArgumentBounds() {
        let validPath = "/usr/local/bin/agent"
        let workingDirectory = "/tmp"

        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: validPath,
                arguments: ["nul\0argument"],
                workingDirectory: workingDirectory
            )
        }
        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: validPath,
                arguments: Array(repeating: "argument", count: 65),
                workingDirectory: workingDirectory
            )
        }
        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: validPath,
                arguments: [String(repeating: "a", count: 4_097)],
                workingDirectory: workingDirectory
            )
        }
        #expect(throws: ExecutableInvocationValidationError.invalidInvocation) {
            try ExecutableInvocation(
                executablePath: validPath,
                arguments: Array(repeating: String(repeating: "a", count: 4_096), count: 9),
                workingDirectory: workingDirectory
            )
        }
    }

    @Test
    func shellSyntaxAndNewlineRemainInertArgumentData() throws {
        let argument = "space quote' \" $(touch /tmp/nope);\nnext"
        let invocation = try ExecutableInvocation(
            executablePath: "/usr/local/bin/agent",
            arguments: [argument],
            workingDirectory: "/tmp"
        )

        #expect(invocation.arguments == [argument])
    }

    @Test
    func fixtureUnknownFieldsNeverBecomeArguments() throws {
        let fixture = try loadResumeFixture(id: "claude")
        let definition = try definition(id: "claude")
        let result = definition.buildResumeInvocation(
            resolvedExecutablePath: "/usr/local/bin/claude",
            compatibilityStatus: .compatible(version: "fixture-only"),
            binding: try makeBinding(adapterID: definition.id, sessionID: fixture.sessionID)
        )
        let invocation = try #require(result.invocation)

        #expect(invocation.arguments == fixture.arguments)
        #expect(!invocation.arguments.contains("--must-not-launch"))
    }

    private var fixturesURL: URL {
        Bundle(for: GoldenFixtureBundleToken.self).resourceURL!
            .appending(path: "Fixtures/AgentIntegrations", directoryHint: .isDirectory)
    }

    private func definition(id: String) throws -> AgentIntegrationDefinition {
        try #require(
            AgentIntegrationRegistry.definition(for: AgentAdapterID(rawValue: id))
        )
    }

    private func makeBinding(
        adapterID: AgentAdapterID,
        sessionID: String = "session-123",
        workingDirectory: String = "/tmp",
        launchMetadata: [String: String] = [:]
    ) throws -> AgentResumeBinding {
        try AgentResumeBinding(
            adapterID: adapterID,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            registeredAt: Date(timeIntervalSinceReferenceDate: 123_456),
            launchMetadata: launchMetadata,
            restoreState: .active
        )
    }

    private func loadRegistryFixture() throws -> [GoldenRegistryFixtureEntry] {
        let data = try Data(contentsOf: fixturesURL.appending(path: "registry.json"))
        return try JSONDecoder().decode([GoldenRegistryFixtureEntry].self, from: data)
    }

    private func loadResumeFixture(id: String) throws -> ResumeFixture {
        let url =
            fixturesURL
            .appending(path: "Adapters", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
            .appending(path: "resume.json")
        return try JSONDecoder().decode(ResumeFixture.self, from: Data(contentsOf: url))
    }
}

extension AgentResumeInvocationResult {
    fileprivate var invocation: ExecutableInvocation? {
        guard case .invocation(let invocation) = self else { return nil }
        return invocation
    }
}

private final class GoldenFixtureBundleToken {}

private struct GoldenRegistryFixtureEntry: Decodable {
    let id: String
    let executable: String
}

private struct ResumeFixture: Decodable {
    let sessionID: String
    let arguments: [String]
    let blockedReason: String?
}
