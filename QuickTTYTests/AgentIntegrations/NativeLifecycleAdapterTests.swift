import Foundation
import Testing

@testable import QuickTTY

struct NativeLifecycleAdapterTests {
    @Test
    func allNativeFixturesNormalizeStartAndEnd() throws {
        let fixtures = try loadFixtures()
        #expect(fixtures.count == 11)

        for fixture in fixtures {
            let identity = try makeIdentity(adapterID: fixture.adapter)
            let sessionID = "session-\(fixture.adapter)"
            for event in fixture.startEvents {
                let start = NativeLifecycleHookNormalizer.normalize(
                    adapterID: fixture.adapter,
                    event: event,
                    input: try canonical(["cwd": "/tmp", "session_id": sessionID]),
                    identity: identity
                )
                guard case .register(let registered)? = start?.event else {
                    Issue.record("Missing start normalization for \(fixture.adapter):\(event)")
                    continue
                }
                #expect(registered.sessionID == sessionID)
                #expect(registered.cwd == "/tmp")
                #expect(registered.metadata.isEmpty)
            }

            var endPayload = ["session_id": sessionID]
            if let reason = fixture.physicalQuitReason {
                endPayload["reason"] = reason
            }
            for event in fixture.endEvents {
                let end = NativeLifecycleHookNormalizer.normalize(
                    adapterID: fixture.adapter,
                    event: event,
                    input: try canonical(endPayload),
                    identity: identity
                )
                guard case .unregister(let unregistered)? = end?.event else {
                    Issue.record("Missing end normalization for \(fixture.adapter):\(event)")
                    continue
                }
                #expect(unregistered.sessionID == sessionID)
            }
        }
    }

    @Test
    func piAndOMPSwitchAndOnlyUnregisterForPhysicalQuit() throws {
        for adapter in ["pi", "omp"] {
            let identity = try makeIdentity(adapterID: adapter)
            let replaced = NativeLifecycleHookNormalizer.normalize(
                adapterID: adapter,
                event: "session_switch",
                input: try canonical([
                    "cwd": "/tmp",
                    "previous_session_id": "old-\(adapter)",
                    "session_id": "new-\(adapter)",
                ]),
                identity: identity
            )
            guard case .replaceSession(let payload)? = replaced?.event else {
                Issue.record("Missing switch normalization for \(adapter)")
                continue
            }
            #expect(payload.previousSessionID == "old-\(adapter)")
            #expect(payload.sessionID == "new-\(adapter)")

            for reason in ["", "restart", "process_exit"] {
                #expect(
                    NativeLifecycleHookNormalizer.normalize(
                        adapterID: adapter,
                        event: "session_shutdown",
                        input: try canonical([
                            "reason": reason, "session_id": "new-\(adapter)",
                        ]),
                        identity: identity
                    ) == nil
                )
            }
        }
    }

    @Test
    func malformedMissingOversizedDuplicateAndUnrelatedInputProduceNoMessage() throws {
        let identity = try makeIdentity(adapterID: "claude")
        let oversizedSession = String(repeating: "s", count: 513)
        let oversizedCWD = "/" + String(repeating: "c", count: 4_096)
        let oversizedInput = Data(repeating: 0x20, count: 65_537)
        let oversizedMetadata = Data(
            "{\"cwd\":\"/tmp\",\"metadata\":{\"model\":\"\(String(repeating: "m", count: 1_025))\"},\"session_id\":\"s\"}"
                .utf8
        )
        let inputs = [
            Data(),
            Data("not-json".utf8),
            Data("{\"cwd\":\"/tmp\",\"cwd\":\"/tmp\",\"session_id\":\"s\"}".utf8),
            try canonical(["cwd": "/tmp"]),
            try canonical(["cwd": "/tmp", "session_id": oversizedSession]),
            try canonical(["cwd": oversizedCWD, "session_id": "s"]),
            oversizedMetadata,
            oversizedInput,
        ]
        for input in inputs {
            #expect(
                NativeLifecycleHookNormalizer.normalize(
                    adapterID: "claude",
                    event: "SessionStart",
                    input: input,
                    identity: identity
                ) == nil
            )
        }
        #expect(
            NativeLifecycleHookNormalizer.normalize(
                adapterID: "claude",
                event: "BeforeToolUse",
                input: try canonical(["cwd": "/tmp", "session_id": "secret-value"]),
                identity: identity
            ) == nil
        )
        #expect(
            NativeLifecycleHookNormalizer.normalize(
                adapterID: "claude",
                event: "SessionStart",
                input: Data("{\n  \"session_id\": \"s\", \"cwd\": \"/tmp\"\n}\n".utf8),
                identity: identity
            )?.event.name == .register
        )
    }

    @Test
    func registryPoliciesResourcesAndInstallerStrategiesAreExact() throws {
        let expectedIDs: Set<String> = [
            "claude", "codex", "pi", "omp", "cursor", "gemini", "hermes", "copilot",
            "droid", "qoder", "kimi",
        ]
        let policyIDs = NativeLifecycleAdapters.policies.map(\.id)
        #expect(policyIDs.count == 11)
        #expect(Set(policyIDs).count == policyIDs.count)
        #expect(Set(policyIDs) == expectedIDs)

        let fixtures = try loadFixtures()
        let fixtureIDs = fixtures.map(\.adapter)
        #expect(fixtureIDs.count == 11)
        #expect(Set(fixtureIDs).count == fixtureIDs.count)
        #expect(Set(fixtureIDs) == expectedIDs)

        let resources = try #require(Bundle.main.resourceURL)
            .appending(path: "AgentSessionIntegrations", directoryHint: .isDirectory)
        for fixture in fixtures {
            let policy = try #require(NativeLifecycleAdapters.policy(for: fixture.adapter))
            #expect(fixture.startEvents == policy.startEvents)
            #expect(fixture.switchEvents == policy.switchEvents)
            #expect(fixture.endEvents == policy.endEvents)
            #expect(fixture.installerStrategy == policy.installerStrategy.rawValue)

            let manifestURL = resources.appending(path: policy.id).appending(
                path: "integration.json")
            #expect(FileManager.default.fileExists(atPath: manifestURL.path))
            let manifest = try JSONDecoder().decode(
                NativeLifecycleManifestFixture.self,
                from: Data(contentsOf: manifestURL)
            )
            #expect(manifest.adapter == policy.id)
            #expect(manifest.startEvents == policy.startEvents)
            #expect(manifest.switchEvents == policy.switchEvents)
            #expect(manifest.endEvents == policy.endEvents)
            #expect(manifest.installer == policy.installerStrategy.rawValue)

            let definition = try #require(
                AgentIntegrationRegistry.definition(
                    for: try AgentAdapterID(rawValue: policy.id)
                ))
            #expect(definition.capability == .nativeLifecycle)
            #expect(definition.lifecycleStrategy == .nativeLifecycle)
            #expect(definition.installStrategy == .nativeIntegration)
            #expect(definition.versionProbePolicy == policy.versionProbePolicy)
        }

        let path = try AgentIntegrationPath(root: .home, relativePath: ".config/tool/hook")
        _ = try NativeLifecycleInstallerStrategy.ownedFile.ownedFileMutation(
            path: path,
            operationID: "native-owned",
            contents: Data("owned".utf8)
        )
        _ = try NativeLifecycleInstallerStrategy.jsonHook.jsonHookMutation(
            path: path,
            jsonPointer: "/hooks/start",
            operationID: "native-json",
            commandNode: Data("{\"command\":\"quicktty\"}".utf8)
        )
        _ = try NativeLifecycleInstallerStrategy.markerBlock.markerBlockMutation(
            path: path,
            operationID: "native-marker",
            markerVersion: 1,
            body: Data("hook = true".utf8)
        )
    }

    @Test
    func claudeAndCodexLifecycleInstallCoexistsWithRealOSCProgressFixtures() throws {
        let resources = try #require(Bundle.main.resourceURL)
            .appending(path: "AgentIntegrations", directoryHint: .isDirectory)
        let fixtures = [
            "claude": "claude-settings.example.json",
            "codex": "codex-hooks.example.json",
        ]

        for adapter in ["claude", "codex"] {
            let environment = try InstallerTestEnvironment()
            defer { environment.remove() }
            let path = try AgentIntegrationPath(
                root: .home,
                relativePath: ".config/\(adapter)/hooks.json"
            )
            let original = try Data(
                contentsOf: resources.appending(path: try #require(fixtures[adapter])))
            let originalProgressNodes = try progressHookNodes(in: original)
            #expect(!originalProgressNodes.isEmpty)
            try environment.writeFixture(original, to: path)

            let policy = try #require(NativeLifecycleAdapters.policy(for: adapter))
            let lifecycleNode = try JSONSerialization.data(
                withJSONObject: [
                    "hooks": [
                        [
                            "command":
                                "\"/Applications/QuickTTY.app/Contents/Helpers/quicktty\" internal hook \(adapter) SessionStart",
                            "type": "command",
                        ]
                    ]
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let mutation = try policy.installerStrategy.jsonHookMutation(
                path: path,
                jsonPointer: "/hooks/SessionStart",
                operationID: "native-\(adapter)-session-start",
                commandNode: lifecycleNode
            )

            let install = try mutation.prepareInstall(
                fileSystem: environment.fileSystem,
                ownership: []
            )
            _ = try environment.fileSystem.apply(
                [install.write],
                matching: [install.write.preview]
            )
            let record = try #require(install.ownershipRecord)
            let installed = try #require(try environment.fileSystem.read(path))
            #expect(try progressHookNodes(in: installed) == originalProgressNodes)
            #expect(
                try hookNodes(in: installed, event: "SessionStart").contains(
                    canonicalJSON(lifecycleNode)
                ))

            let secondInstall = try mutation.prepareInstall(
                fileSystem: environment.fileSystem,
                ownership: [record]
            )
            #expect(
                try environment.fileSystem.apply(
                    [secondInstall.write],
                    matching: [secondInstall.write.preview]
                ).changedPaths.isEmpty
            )

            let uninstall = try mutation.prepareUninstall(
                fileSystem: environment.fileSystem,
                record: record
            )
            _ = try environment.fileSystem.apply(
                [uninstall.write],
                matching: [uninstall.write.preview]
            )
            let uninstalled = try #require(try environment.fileSystem.read(path))
            #expect(try progressHookNodes(in: uninstalled) == originalProgressNodes)
            #expect(try hookNodes(in: uninstalled, event: "SessionStart").isEmpty)
        }
    }

    @Test
    func everyInstallerPolicyBuildsAnIdempotentExactTask11Plan() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }

        for policy in NativeLifecycleAdapters.policies {
            let path = try AgentIntegrationPath(
                root: .home,
                relativePath: "native-\(policy.id).json"
            )
            let first: AgentIntegrationMutationPlan
            let second: AgentIntegrationMutationPlan
            switch policy.installerStrategy {
            case .ownedFile:
                let mutation = try policy.installerStrategy.ownedFileMutation(
                    path: path,
                    operationID: "native-\(policy.id)",
                    contents: Data("owned-\(policy.id)".utf8)
                )
                first = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: []
                )
                _ = try environment.fileSystem.apply(
                    [first.write],
                    matching: [first.write.preview]
                )
                second = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: [try #require(first.ownershipRecord)]
                )
            case .jsonHook:
                let mutation = try policy.installerStrategy.jsonHookMutation(
                    path: path,
                    jsonPointer: "/hooks/start",
                    operationID: "native-\(policy.id)",
                    commandNode: Data("{\"command\":\"quicktty-\(policy.id)\"}".utf8)
                )
                first = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: []
                )
                _ = try environment.fileSystem.apply(
                    [first.write],
                    matching: [first.write.preview]
                )
                second = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: [try #require(first.ownershipRecord)]
                )
            case .markerBlock:
                let mutation = try policy.installerStrategy.markerBlockMutation(
                    path: path,
                    operationID: "native-\(policy.id)",
                    markerVersion: 1,
                    body: Data("hook = true".utf8)
                )
                first = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: []
                )
                _ = try environment.fileSystem.apply(
                    [first.write],
                    matching: [first.write.preview]
                )
                second = try mutation.prepareInstall(
                    fileSystem: environment.fileSystem,
                    ownership: [try #require(first.ownershipRecord)]
                )
            }
            #expect(
                try environment.fileSystem.apply(
                    [second.write],
                    matching: [second.write.preview]
                ).changedPaths.isEmpty
            )
        }
    }

    private func makeIdentity(adapterID: String) throws -> AgentIPCIdentity {
        try AgentIPCIdentity(
            instanceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            paneID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            paneToken: String(repeating: "ab", count: 32),
            adapterID: adapterID
        )
    }

    private func canonical(_ object: [String: String]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func loadFixtures() throws -> [NativeLifecycleFixture] {
        let url = Bundle(for: NativeLifecycleFixtureBundleToken.self).resourceURL!
            .appending(path: "Fixtures/AgentIntegrations/NativeLifecycle/events.json")
        return try JSONDecoder().decode(
            [NativeLifecycleFixture].self,
            from: Data(contentsOf: url)
        )
    }

    private func progressHookNodes(in data: Data) throws -> [String: [Data]] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        var result: [String: [Data]] = [:]
        for (event, value) in hooks {
            guard let nodes = value as? [Any] else { continue }
            let progressNodes = try nodes.map(canonicalJSON).filter { node in
                String(decoding: node, as: UTF8.self).contains(
                    "/AgentIntegrations/quicktty-progress")
            }
            if !progressNodes.isEmpty {
                result[event] = progressNodes
            }
        }
        return result
    }

    private func hookNodes(in data: Data, event: String) throws -> [Data] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        return try #require(hooks[event] as? [Any]).map(canonicalJSON)
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        try canonicalJSON(try JSONSerialization.jsonObject(with: data))
    }

    private func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private final class NativeLifecycleFixtureBundleToken {}

private struct NativeLifecycleFixture: Decodable {
    let adapter: String
    let startEvents: [String]
    let switchEvents: [String]
    let endEvents: [String]
    let installerStrategy: String
    let physicalQuitReason: String?
}

private struct NativeLifecycleManifestFixture: Decodable {
    let adapter: String
    let startEvents: [String]
    let switchEvents: [String]
    let endEvents: [String]
    let installer: String

    private enum CodingKeys: String, CodingKey {
        case adapter
        case startEvents
        case switchEvents
        case endEvents
        case installer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adapter = try container.decode(String.self, forKey: .adapter)
        startEvents = try container.decode([String].self, forKey: .startEvents)
        switchEvents = try container.decodeIfPresent([String].self, forKey: .switchEvents) ?? []
        endEvents = try container.decode([String].self, forKey: .endEvents)
        installer = try container.decode(String.self, forKey: .installer)
    }
}
