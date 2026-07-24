import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
struct ApplicationEnvironmentTests {
    @Test
    func detectsCurrentHostedUnitTestProcess() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        #expect(ApplicationEnvironment.isRunningHostedTests)
    }

    @Test
    func hostedApplicationBundleContainsAgentIntegrationResources() throws {
        let resourceURL = try #require(Bundle.main.resourceURL)
        let integrationURL = resourceURL.appending(
            path: "AgentIntegrations",
            directoryHint: .isDirectory
        )
        let helperURL = integrationURL.appending(path: "quicktty-progress")
        let exampleNames = ["claude-settings.example.json", "codex-hooks.example.json"]

        #expect(FileManager.default.isExecutableFile(atPath: helperURL.path))
        for name in exampleNames {
            let data = try Data(contentsOf: integrationURL.appending(path: name))
            #expect((try JSONSerialization.jsonObject(with: data)) is [String: Any])
        }
    }
}
