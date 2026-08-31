import Darwin
import Foundation
import Testing

@testable import QuickTTY

struct AgentRestoreCompatibilityResolverTests {
    private let piID = try! AgentAdapterID(rawValue: "pi")
    private let claudeID = try! AgentAdapterID(rawValue: "claude")

    @Test
    func registryKeepsExactPiVersionContractWithAdapterDefinition() throws {
        let definitions = AgentIntegrationRegistry.definitions
        let pi = try #require(AgentIntegrationRegistry.definition(for: piID))

        #expect(
            pi.versionProbePolicy
                == .exact(
                    arguments: ["--version"],
                    acceptedLine: "0.83.0",
                    version: "0.83.0"
                )
        )

        let launchCapable = definitions.filter { definition in
            switch definition.capability {
            case .nativeLifecycle, .wrapperLifecycle:
                true
            case .blocked:
                false
            }
        }
        #expect(
            Set(launchCapable.map(\.id.rawValue))
                == [
                    "amp", "antigravity", "claude", "codex", "copilot", "cursor", "droid",
                    "gemini", "hermes", "kimi", "omp", "opencode", "pi", "qoder",
                ]
        )
        for definition in launchCapable where definition.id != piID {
            #expect(definition.versionProbePolicy == .unverified)
        }

        let expectedBlockedReasons: [String: AgentIntegrationBlockedReason] = [
            "campfire": .notSessionfulAgent,
            "codebuddy": .betaLifecycleOnly,
            "grok": .ambiguousOfficialIdentity,
            "kiro": .incompatibleLifecycleGenerations,
            "ollama": .missingPersistentSessionAPI,
            "rovo-dev": .missingSessionIdentity,
        ]
        let blocked = definitions.compactMap {
            definition -> (String, AgentIntegrationBlockedReason)? in
            guard case .blocked(let reason) = definition.capability else { return nil }
            #expect(definition.versionProbePolicy == .blocked(reason))
            return (definition.id.rawValue, reason)
        }
        #expect(Dictionary(uniqueKeysWithValues: blocked) == expectedBlockedReasons)
    }

    @Test
    func adversarialPathIgnoresEmptyRelativeAndOversizedEntriesAndCanonicalizesSymlink()
        async
        throws
    {
        let fixture = try ExecutablePathFixture(name: "pi")
        defer { fixture.remove() }
        let symlinkDirectory = try fixture.makeSymlinkDirectory()
        let path = [
            "",
            "relative/bin",
            String(repeating: "x", count: 1_025),
            "/tmp/control\npath",
            symlinkDirectory.path,
        ].joined(separator: ":")
        let resolver = AgentRestoreCompatibilityResolver { request, _ in
            #expect(request.arguments == ["--version"])
            #expect(request.executablePath == fixture.canonicalExecutablePath)
            return .exited(status: 0, output: Data("0.83.0\n".utf8))
        }

        let result = await resolver.resolve(adapterIDs: [piID], path: path)

        #expect(
            result[piID]
                == AgentRestoreCompatibility(
                    status: .compatible(version: "0.83.0"),
                    resolvedExecutablePath: fixture.canonicalExecutablePath
                )
        )
    }

    @Test
    func productionProbeAcceptsRealisticPiVersionFixture() async throws {
        let fixture = try ExecutablePathFixture(
            name: "pi",
            contents: "#!/bin/sh\nprintf '0.83.0\\n'\n"
        )
        defer { fixture.remove() }

        let result = await AgentRestoreCompatibilityResolver().resolve(
            adapterIDs: [piID],
            path: fixture.directoryURL.path
        )

        #expect(result[piID]?.status == .compatible(version: "0.83.0"))
        #expect(result[piID]?.resolvedExecutablePath == fixture.canonicalExecutablePath)
    }

    @Test
    func cancellingProductionProbeTerminatesChildAndReturnsUnverified() async throws {
        let fixture = try ExecutablePathFixture(name: "pi")
        defer { fixture.remove() }
        let startedURL = fixture.directoryURL.appending(path: "started")
        let script = """
            #!/bin/sh
            printf started > "\(startedURL.path)"
            while :; do :; done
            """
        try Data(script.utf8).write(to: fixture.executableURL)

        let task = Task {
            await AgentRestoreCompatibilityResolver().resolve(
                adapterIDs: [piID],
                path: fixture.directoryURL.path
            )
        }
        while !FileManager.default.fileExists(atPath: startedURL.path) {
            await Task.yield()
        }

        task.cancel()
        let result = await task.value

        #expect(result[piID]?.status == .unverifiedVersion)
    }

    @Test
    func absentExecutableIsMissing() async {
        let resolver = AgentRestoreCompatibilityResolver { _, _ in
            Issue.record("An absent executable must not be probed")
            return .failedToLaunch
        }

        #expect(
            await resolver.resolve(adapterIDs: [piID], path: "/definitely/missing")[piID]
                == AgentRestoreCompatibility(
                    status: .missingExecutable,
                    resolvedExecutablePath: nil
                )
        )
    }

    @Test(arguments: [
        "",
        "0.83.0\nsecond line\n",
        "0.83.0\u{0007}\n",
        "pi 0.83.0\n",
        "0.83.1\n",
        String(repeating: "1", count: 129) + "\n",
    ])
    func malformedPiOutputIsUnverified(output: String) async throws {
        let fixture = try ExecutablePathFixture(name: "pi")
        defer { fixture.remove() }
        let resolver = AgentRestoreCompatibilityResolver { _, _ in
            .exited(status: 0, output: Data(output.utf8))
        }

        #expect(
            await resolver.resolve(adapterIDs: [piID], path: fixture.directoryURL.path)[piID]
                == AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: fixture.canonicalExecutablePath
                )
        )
    }

    @Test(arguments: [
        AgentVersionProbeResult.timedOut,
        .outputOverflow,
        .exited(status: 9, output: Data("0.83.0\n".utf8)),
        .failedToLaunch,
    ])
    func probeFailuresAreUnverified(result: AgentVersionProbeResult) async throws {
        let fixture = try ExecutablePathFixture(name: "pi")
        defer { fixture.remove() }
        let resolver = AgentRestoreCompatibilityResolver { _, _ in result }

        #expect(
            await resolver.resolve(adapterIDs: [piID], path: fixture.directoryURL.path)[piID]?
                .status
                == .unverifiedVersion
        )
    }

    @Test
    func launchCapableAdaptersWithoutVerifiedPolicyRemainUnverifiedWithoutProbe() async throws {
        let fixture = try ExecutablePathFixture(name: "claude")
        defer { fixture.remove() }
        let resolver = AgentRestoreCompatibilityResolver { _, _ in
            Issue.record("An unverified policy must not execute a probe")
            return .failedToLaunch
        }

        #expect(
            await resolver.resolve(adapterIDs: [claudeID], path: fixture.directoryURL.path)[
                claudeID]
                == AgentRestoreCompatibility(
                    status: .unverifiedVersion,
                    resolvedExecutablePath: fixture.canonicalExecutablePath
                )
        )
    }

    @Test
    func unknownAndDuplicateIDsCannotChangeDeterministicResult() async throws {
        let fixture = try ExecutablePathFixture(name: "pi")
        defer { fixture.remove() }
        let unknown = try AgentAdapterID(rawValue: "unknown")
        let resolver = AgentRestoreCompatibilityResolver { _, _ in
            .exited(status: 0, output: Data("0.83.0\n".utf8))
        }

        let result = await resolver.resolve(
            adapterIDs: [unknown, piID, piID],
            path: fixture.directoryURL.path
        )

        #expect(Set(result.keys) == [piID])
        #expect(result[piID]?.status == .compatible(version: "0.83.0"))
    }
}

private struct ExecutablePathFixture {
    let directoryURL: URL
    let executableURL: URL

    init(name: String, contents: String = "fixture") throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Compatibility-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        executableURL = directoryURL.appending(path: name)
        try Data(contents.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    var canonicalExecutablePath: String {
        executableURL.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return executableURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    func makeSymlinkDirectory() throws -> URL {
        let directory = directoryURL.appending(path: "links", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: executableURL.lastPathComponent),
            withDestinationURL: executableURL
        )
        return directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
