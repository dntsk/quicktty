import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
struct ApplicationEnvironmentTests {
    @Test
    func detectsCurrentHostedUnitTestProcess() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        #expect(ApplicationEnvironment.isRunningHostedTests)
    }
}
