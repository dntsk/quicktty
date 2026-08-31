import Foundation
import Testing

@testable import QuickTTY

struct AgentIntegrationRegistryTests {
    @Test
    func registryMatchesExactFixtureOrderAndDefinitions() throws {
        let fixture = try loadRegistryFixture()
        let definitions = AgentIntegrationRegistry.definitions

        #expect(definitions.count == 20)
        #expect(definitions.map(\.id.rawValue) == fixture.map(\.id))
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        #expect(Set(definitions.map(\.displayName)).count == definitions.count)

        for (definition, expected) in zip(definitions, fixture) {
            #expect(definition.displayName == expected.displayName)
            #expect(definition.executableCandidates == [expected.executable])
            #expect(definition.cwdPolicy == .bindingDirectory)
            #expect(definition.sessionIDPolicy == .opaqueSafe)
            #expect(definition.launchMetadataAllowlist.isEmpty)

            switch expected.capability {
            case "nativeLifecycle":
                #expect(definition.capability == .nativeLifecycle)
                #expect(definition.lifecycleStrategy == .nativeLifecycle)
                #expect(definition.installStrategy == .nativeIntegration)
                #expect(definition.statusLimitation == .none)
                #expect(
                    definition.compatibilityPolicy == .requiresVerifiedInstalledVersion
                )
            case "wrapperLifecycle":
                #expect(definition.capability == .wrapperLifecycle)
                #expect(definition.lifecycleStrategy == .processLifetimeWrapper)
                #expect(definition.installStrategy == .wrapperIntegration)
                if expected.id == "opencode" {
                    #expect(
                        definition.statusLimitation
                            == .undocumentedSelectedSessionUnregistered
                    )
                } else {
                    #expect(definition.statusLimitation == .requiresProcessLifetimeWrapper)
                }
                #expect(
                    definition.compatibilityPolicy == .requiresVerifiedInstalledVersion
                )
            case "blocked":
                let reason = try #require(
                    expected.blockedReason.flatMap(AgentIntegrationBlockedReason.init(rawValue:)))
                #expect(definition.capability == .blocked(reason))
                #expect(definition.lifecycleStrategy == .blocked)
                #expect(definition.installStrategy == .none)
                #expect(definition.compatibilityPolicy == .blocked(reason))
                #expect(definition.statusLimitation == .blocked(reason))
            default:
                Issue.record("Unknown fixture capability for \(expected.id)")
            }
        }
    }

    @Test
    func fixtureDirectoriesAreOneToOneWithRegistry() throws {
        let fixture = try loadRegistryFixture()
        let adaptersURL = fixturesURL.appending(path: "Adapters", directoryHint: .isDirectory)
        let directoryNames = try FileManager.default.contentsOfDirectory(
            at: adaptersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.lastPathComponent).sorted()

        #expect(directoryNames == fixture.map(\.id).sorted())
        for id in directoryNames {
            #expect(
                FileManager.default.fileExists(
                    atPath: adaptersURL.appending(path: id).appending(path: "resume.json").path
                )
            )
        }
    }

    @Test
    func registryHasExactCapabilityTotals() {
        let definitions = AgentIntegrationRegistry.definitions
        let launchCapableCount = definitions.count { definition in
            switch definition.capability {
            case .nativeLifecycle, .wrapperLifecycle: true
            case .blocked: false
            }
        }
        let blockedCount = definitions.count - launchCapableCount

        #expect(launchCapableCount == 14)
        #expect(blockedCount == 6)
    }

    private var fixturesURL: URL {
        Bundle(for: FixtureBundleToken.self).resourceURL!
            .appending(path: "Fixtures/AgentIntegrations", directoryHint: .isDirectory)
    }

    private func loadRegistryFixture() throws -> [RegistryFixtureEntry] {
        let data = try Data(contentsOf: fixturesURL.appending(path: "registry.json"))
        return try JSONDecoder().decode([RegistryFixtureEntry].self, from: data)
    }
}

private final class FixtureBundleToken {}

private struct RegistryFixtureEntry: Decodable {
    let id: String
    let displayName: String
    let capability: String
    let executable: String
    let blockedReason: String?
}
