import Foundation
import Testing

@testable import QuickTTY

struct WrapperLifecycleAdapterTests {
    @Test
    func registryPoliciesAndStatusLimitationsAreExact() throws {
        let expected: [String: (String, String, String)] = [
            "amp": ("amp", "session.start", "thread_id"),
            "antigravity": ("agy", "conversation.start", "conversation_id"),
            "opencode": ("opencode", "session.created", "session_id"),
        ]
        #expect(Set(WrapperLifecycleAdapters.policies.map(\.id)) == Set(expected.keys))

        for policy in WrapperLifecycleAdapters.policies {
            let values = try #require(expected[policy.id])
            #expect(policy.executable == values.0)
            #expect(policy.identityEvent == values.1)
            #expect(policy.identityField == values.2)
            #expect(policy.versionProbePolicy == .unverified)

            let definition = try #require(
                AgentIntegrationRegistry.definition(
                    for: try AgentAdapterID(rawValue: policy.id)
                )
            )
            #expect(definition.capability == .wrapperLifecycle)
            #expect(definition.lifecycleStrategy == .processLifetimeWrapper)
            #expect(definition.installStrategy == .wrapperIntegration)
            #expect(definition.versionProbePolicy == .unverified)
            if policy.id == "opencode" {
                #expect(
                    definition.statusLimitation
                        == .undocumentedSelectedSessionUnregistered
                )
            } else {
                #expect(definition.statusLimitation == .requiresProcessLifetimeWrapper)
            }
        }
    }

    @Test
    func wrapperAndPluginUseTask11OwnedMutationsWithoutReplacingUserFiles() throws {
        let environment = try InstallerTestEnvironment()
        defer { environment.remove() }

        for policy in WrapperLifecycleAdapters.policies {
            let wrapper = try policy.wrapperMutation(
                contents: Data("wrapper-\(policy.id)".utf8)
            )
            let first = try wrapper.prepareInstall(
                fileSystem: environment.fileSystem,
                ownership: []
            )
            _ = try environment.fileSystem.apply(
                [first.write],
                matching: [first.write.preview]
            )
            let record = try #require(first.ownershipRecord)
            let second = try wrapper.prepareInstall(
                fileSystem: environment.fileSystem,
                ownership: [record]
            )
            #expect(
                try environment.fileSystem.apply(
                    [second.write],
                    matching: [second.write.preview]
                ).changedPaths.isEmpty
            )
        }

        let userPath = try AgentIntegrationPath(
            root: .applicationSupport,
            relativePath: "AgentSessionIntegrations/wrappers/amp"
        )
        let userEnvironment = try InstallerTestEnvironment()
        defer { userEnvironment.remove() }
        try userEnvironment.writeFixture(Data("user executable".utf8), to: userPath)
        let mutation = try WrapperLifecycleAdapters.policies[0].wrapperMutation(
            contents: Data("owned wrapper".utf8)
        )
        #expect(throws: AgentIntegrationInstallerError.ownershipMismatch) {
            try mutation.prepareInstall(
                fileSystem: userEnvironment.fileSystem,
                ownership: []
            )
        }
    }

    @Test
    func resourcesAreSeparateOwnedWrappersAndPlugins() throws {
        let root = try #require(Bundle.main.resourceURL)
            .appending(path: "AgentSessionIntegrations", directoryHint: .isDirectory)
        for policy in WrapperLifecycleAdapters.policies {
            let directory = root.appending(path: policy.id, directoryHint: .isDirectory)
            let manifest = directory.appending(path: "integration.json")
            let wrapper = directory.appending(path: "wrapper").appending(
                path: policy.executable)
            #expect(FileManager.default.fileExists(atPath: manifest.path))
            #expect(FileManager.default.isExecutableFile(atPath: wrapper.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appending(path: policy.pluginResource).path
                )
            )
        }
    }

    @Test
    func unverifiedWrapperVersionsCannotBuildResumeInvocations() throws {
        for policy in WrapperLifecycleAdapters.policies {
            let definition = try #require(
                AgentIntegrationRegistry.definition(
                    for: try AgentAdapterID(rawValue: policy.id)
                )
            )
            let binding = try AgentResumeBinding(
                adapterID: definition.id,
                sessionID: "session",
                workingDirectory: "/tmp",
                registeredAt: Date(timeIntervalSince1970: 1),
                launchMetadata: [:],
                restoreState: .active
            )
            #expect(
                definition.buildResumeInvocation(
                    resolvedExecutablePath: "/usr/bin/true",
                    compatibilityStatus: .unverifiedVersion,
                    binding: binding
                ) == .freshShell(.incompatibleStatus(.unverifiedVersion))
            )
        }
    }
}
