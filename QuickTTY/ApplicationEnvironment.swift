import Foundation

enum ApplicationEnvironment {
    static var isRunningHostedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func bundledAgentHelperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "quicktty")
            .standardizedFileURL
    }
}
