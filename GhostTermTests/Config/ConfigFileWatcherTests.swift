import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct ConfigFileWatcherTests {
    @Test
    func productionSourceDeliversFileChangesOnMainActor() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "GhostTerm-ConfigFileWatcherTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let fileURL = directoryURL.appending(path: "config")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("initial\n".utf8).write(to: fileURL)

        let (changes, continuation) = AsyncStream.makeStream(of: Bool.self)
        let watcher = ConfigFileWatcher(url: fileURL) {
            MainActor.preconditionIsolated()
            continuation.yield(Thread.isMainThread)
        }
        defer {
            watcher.stop()
            continuation.finish()
        }
        try watcher.start()

        try Data("updated\n".utf8).write(to: fileURL, options: .atomic)

        let deliveredOnMainThread = try await firstConfigFileWatcherChange(
            from: changes,
            timeout: .seconds(2)
        )
        #expect(deliveredOnMainThread)
    }
}

private enum ConfigFileWatcherTestError: Error {
    case eventStreamEnded
    case timeout
}

private func firstConfigFileWatcherChange(
    from stream: AsyncStream<Bool>,
    timeout: Duration
) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await change in stream {
                return change
            }
            throw ConfigFileWatcherTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ConfigFileWatcherTestError.timeout
        }

        guard let change = try await group.next() else {
            throw ConfigFileWatcherTestError.eventStreamEnded
        }
        group.cancelAll()
        return change
    }
}
