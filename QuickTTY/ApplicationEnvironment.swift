import Foundation

enum ApplicationEnvironment {
    static var isRunningHostedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
