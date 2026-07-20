import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct ConfigControllerTests {
    @Test
    func loadCreatesStarterAndAtomicEffectiveFileBesideSource() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        var reloadURLs: [URL] = []
        var updates: [GhostTermConfig] = []
        let controller = fixture.makeController(
            reloadGhostty: { reloadURLs.append($0) },
            onUpdate: { updates.append($0) }
        )

        try controller.load()

        #expect(try Data(contentsOf: fixture.configURL) == fixture.starterData)
        #expect(reloadURLs == [fixture.effectiveURL])
        #expect(updates == [GhostTermConfig()])
        #expect(
            try Data(contentsOf: fixture.effectiveURL)
                == Data("font-family = Mono\ncopy-on-select = clipboard\n".utf8)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fixture.directoryURL,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.contains(".tmp-") } == false
        )
    }

    @Test
    func reloadWritesEffectiveDataAndUpdatesActiveConfig() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        var reloadURLs: [URL] = []
        let controller = fixture.makeController(reloadGhostty: { reloadURLs.append($0) })
        try controller.load()
        try Data(
            """
            font-family = Changed\r
            ghostterm-restore-workspaces = false\r
            ghostterm-config-editor = code --wait\r
            """.utf8
        ).write(to: fixture.configURL)

        try controller.reload()

        #expect(!controller.activeConfig.restoreWorkspaces)
        #expect(controller.activeConfig.configEditor == "code --wait")
        #expect(
            try Data(contentsOf: fixture.effectiveURL)
                == Data("copy-on-select = clipboard\nfont-family = Changed\r\n".utf8)
        )
        #expect(reloadURLs == [fixture.effectiveURL, fixture.effectiveURL])
    }

    @Test
    func reloadAppliesValidAssignmentsAndReportsInvalidDiagnostics() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        try Data(
            """
            font-family = Changed
            ghostterm-presentation-mode = quake
            ghostterm-quake-height = impossible
            """.utf8
        ).write(to: fixture.configURL)
        var reloadURLs: [URL] = []
        var reportedDiagnostics: [[ConfigDiagnostic]] = []
        let controller = fixture.makeController(
            reloadGhostty: { reloadURLs.append($0) },
            onDiagnostics: { reportedDiagnostics.append($0) }
        )

        try controller.load()

        #expect(controller.activeConfig.presentationMode == .quake)
        #expect(reloadURLs == [fixture.effectiveURL])
        #expect(
            try Data(contentsOf: fixture.effectiveURL)
                == Data("copy-on-select = clipboard\nfont-family = Changed\n".utf8)
        )
        #expect(
            reportedDiagnostics
                == [
                    [
                        ConfigDiagnostic(
                            line: 3,
                            key: "ghostterm-quake-height",
                            reason: .invalidNumber(expected: "a value in 0...1 or 1%...100%")
                        )
                    ]
                ]
        )

        try controller.reload()

        #expect(reloadURLs == [fixture.effectiveURL])
        #expect(reportedDiagnostics.count == 1)
    }

    @Test
    func validReloadClearsPreviouslyReportedDiagnostics() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("ghostterm-quake-height = impossible\n".utf8).write(to: fixture.configURL)
        var reportedDiagnostics: [[ConfigDiagnostic]] = []
        let controller = fixture.makeController(
            reloadGhostty: { _ in },
            onDiagnostics: { reportedDiagnostics.append($0) }
        )
        try controller.load()
        try Data("ghostterm-presentation-mode = quake\n".utf8).write(to: fixture.configURL)

        try controller.reload()

        #expect(reportedDiagnostics.count == 2)
        #expect(reportedDiagnostics.last == [])
    }

    @Test
    func bridgeFailureRollsBackActiveConfigAndEffectiveBytes() throws {
        enum Failure: Error { case rejected }
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        let failureSwitch = ReloadFailureSwitch()
        var updates: [GhostTermConfig] = []
        var reportedDiagnostics: [[ConfigDiagnostic]] = []
        let controller = fixture.makeController(
            reloadGhostty: { _ in
                if failureSwitch.shouldFail { throw Failure.rejected }
            },
            onUpdate: { updates.append($0) },
            onDiagnostics: { reportedDiagnostics.append($0) }
        )
        try controller.load()
        let effectiveBefore = try Data(contentsOf: fixture.effectiveURL)
        try Data(
            "font-family = Changed\nghostterm-presentation-mode = quake\n".utf8
        ).write(to: fixture.configURL)
        failureSwitch.shouldFail = true

        #expect(throws: ConfigControllerError.self) {
            try controller.reload()
        }

        #expect(controller.activeConfig.presentationMode == .normal)
        #expect(try Data(contentsOf: fixture.effectiveURL) == effectiveBefore)
        #expect(updates.map(\.presentationMode) == [.normal])
        #expect(reportedDiagnostics == [[]])
    }

    @Test
    func presentationUpdatePatchesOnlyEffectiveDuplicateThenReloads() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        let source = Data(
            """
            ghostterm-presentation-mode = normal
            # preserved
            ghostterm-presentation-mode  =  normal  # effective
            font-size = 14
            """.utf8
        )
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        try source.write(to: fixture.configURL)
        var reloadCount = 0
        let controller = fixture.makeController(reloadGhostty: { _ in reloadCount += 1 })
        try controller.load()

        try controller.updatePresentationMode(.quake)

        #expect(
            try Data(contentsOf: fixture.configURL)
                == Data(
                    """
                    ghostterm-presentation-mode = normal
                    # preserved
                    ghostterm-presentation-mode  =  quake  # effective
                    font-size = 14
                    """.utf8
                )
        )
        #expect(controller.activeConfig.presentationMode == .quake)
        #expect(reloadCount == 2)
    }

    @Test
    func quakeHeightUpdateWritesAtomicallyAndAppliesDocument() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        try Data(
            "ghostterm-quake-height = 75%\r\nfont-size = 14\r\n".utf8
        ).write(to: fixture.configURL)
        var reloadCount = 0
        var updates: [GhostTermConfig] = []
        let controller = fixture.makeController(
            reloadGhostty: { _ in reloadCount += 1 },
            onUpdate: { updates.append($0) }
        )
        try controller.load()

        try controller.updateQuakeHeight(0.73125)

        #expect(
            try Data(contentsOf: fixture.configURL)
                == Data("ghostterm-quake-height = 73.125%\r\nfont-size = 14\r\n".utf8)
        )
        #expect(controller.activeConfig.quakeHeight == 0.73125)
        #expect(updates.map(\.quakeHeight) == [0.75, 0.73125])
        #expect(reloadCount == 2)
        #expect(
            try Data(contentsOf: fixture.effectiveURL)
                == Data("copy-on-select = clipboard\nfont-size = 14\r\n".utf8)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fixture.directoryURL,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.contains(".tmp-") } == false
        )
    }

    @Test
    func watcherIgnoresEchoedQuakeHeightWriteAndReloadsExternalChanges() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        let source = ManualConfigEventSource()
        let scheduler = ManualConfigScheduler()
        var reloadCount = 0
        var updates: [GhostTermConfig] = []
        let controller = fixture.makeController(
            watcherScheduler: scheduler.schedule,
            watcherEventSource: source.eventSource,
            reloadGhostty: { _ in reloadCount += 1 },
            onUpdate: { updates.append($0) }
        )
        try controller.start()

        try controller.updateQuakeHeight(0.73125)
        source.emitLatest()
        scheduler.runAllIncludingCanceled()

        #expect(reloadCount == 2)
        #expect(updates.map(\.quakeHeight) == [0.75, 0.73125])

        try Data("ghostterm-quake-height = 80%\n".utf8).write(to: fixture.configURL)
        source.emitLatest()
        scheduler.runAllIncludingCanceled()

        #expect(reloadCount == 3)
        #expect(updates.map(\.quakeHeight) == [0.75, 0.73125, 0.8])
        controller.stop()
    }

    @Test
    func quakeHeightUpdateRollsBackAppliedStateWhenBridgeReloadFails() throws {
        enum Failure: Error { case rejected }
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        let failureSwitch = ReloadFailureSwitch()
        var updates: [GhostTermConfig] = []
        let controller = fixture.makeController(
            reloadGhostty: { _ in
                if failureSwitch.shouldFail { throw Failure.rejected }
            },
            onUpdate: { updates.append($0) }
        )
        try controller.load()
        let effectiveBefore = try Data(contentsOf: fixture.effectiveURL)
        failureSwitch.shouldFail = true

        #expect(throws: ConfigControllerError.self) {
            try controller.updateQuakeHeight(0.73125)
        }

        #expect(
            try Data(contentsOf: fixture.configURL)
                == Data(
                    """
                    font-family = Mono
                    copy-on-select = clipboard
                    ghostterm-presentation-mode = normal
                    ghostterm-global-toggle = f12
                    ghostterm-quake-height = 73.125%
                    ghostterm-quake-animation-duration = 0.18
                    ghostterm-quake-padding = 0
                    ghostterm-hide-on-focus-loss = true
                    ghostterm-restore-workspaces = true
                    ghostterm-config-editor = nano
                    """.utf8
                )
        )
        #expect(controller.activeConfig.quakeHeight == 0.75)
        #expect(try Data(contentsOf: fixture.effectiveURL) == effectiveBefore)
        #expect(updates.map(\.quakeHeight) == [0.75])
    }

    @Test
    func watcherUsesInjectedSourceURLAndCoalescesWithoutSleeping() throws {
        let fixture = try ConfigFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: fixture.configURL)
        let source = ManualConfigEventSource()
        let scheduler = ManualConfigScheduler()
        var changeCount = 0
        let watcher = ConfigFileWatcher(
            url: fixture.configURL,
            scheduler: scheduler.schedule,
            eventSource: source.eventSource,
            onChange: { changeCount += 1 }
        )
        try watcher.start()

        source.emitLatest()
        source.emitLatest()
        source.emitLatest()
        scheduler.runAllIncludingCanceled()

        #expect(source.startedURLs.allSatisfy { $0 == fixture.configURL })
        #expect(changeCount == 1)
        #expect(scheduler.cancellationCount == 2)
        watcher.stop()
    }
}

@MainActor
private final class ReloadFailureSwitch {
    var shouldFail = false
}

@MainActor
private final class ManualConfigEventSource {
    private var handlers: [@MainActor @Sendable () -> Void] = []
    private(set) var startedURLs: [URL] = []

    var eventSource: ConfigFileWatcher.EventSource {
        ConfigFileWatcher.EventSource { [self] url, handler in
            startedURLs.append(url)
            handlers.append(handler)
            return {}
        }
    }

    func emitLatest() {
        handlers.last?()
    }
}

@MainActor
private final class ManualConfigScheduler {
    private var callbacks: [@MainActor () -> Void] = []
    private var canceled: [Bool] = []
    private(set) var cancellationCount = 0

    func schedule(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let index = callbacks.count
        callbacks.append(action)
        canceled.append(false)
        return { [weak self] in
            guard let self, !canceled[index] else { return }
            canceled[index] = true
            cancellationCount += 1
        }
    }

    func runAllIncludingCanceled() {
        for callback in callbacks {
            callback()
        }
    }
}

@MainActor
private struct ConfigFixture {
    let directoryURL: URL
    let configURL: URL
    let effectiveURL: URL
    let starterData = Data(
        """
        font-family = Mono
        copy-on-select = clipboard
        ghostterm-presentation-mode = normal
        ghostterm-global-toggle = f12
        ghostterm-quake-height = 75%
        ghostterm-quake-animation-duration = 0.18
        ghostterm-quake-padding = 0
        ghostterm-hide-on-focus-loss = true
        ghostterm-restore-workspaces = true
        ghostterm-config-editor = nano
        """.utf8
    )

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "GhostTerm-ConfigTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        configURL = directoryURL.appending(path: "config")
        effectiveURL = directoryURL.appending(path: ".ghostty-effective-config")
    }

    func makeController(
        watcherScheduler: ConfigFileWatcher.Scheduler? = nil,
        watcherEventSource: ConfigFileWatcher.EventSource = .production,
        reloadGhostty: @escaping ConfigController.ReloadGhostty,
        onUpdate: @escaping @MainActor (GhostTermConfig) -> Void = { _ in },
        onDiagnostics: @escaping @MainActor ([ConfigDiagnostic]) -> Void = { _ in }
    ) -> ConfigController {
        ConfigController(
            configURL: configURL,
            effectiveGhosttyURL: effectiveURL,
            starterData: starterData,
            watcherScheduler: watcherScheduler,
            watcherEventSource: watcherEventSource,
            reloadGhostty: reloadGhostty,
            onUpdate: onUpdate,
            onDiagnostics: onDiagnostics
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
