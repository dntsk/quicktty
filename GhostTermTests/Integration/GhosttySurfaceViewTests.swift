import AppKit
import Foundation
import Testing

@testable import GhostTerm

extension GhosttyBridgeTests {
    @Test
    func createsSurfaceWithExplicitCommandInHiddenWindow() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        embed(surface, in: window)

        #expect(surface.paneID == paneID)
        #expect(surface.isReady)
        #expect(surface.isActive)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(bridge.activeSurfaceCount == 1)
    }

    @Test
    func pwdChangesAreDeliveredToTheirOwningSurfaces() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial-first",
                command: "exec /bin/cat"
            )
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial-second",
                command: "exec /bin/cat"
            )
        )

        #expect(first.currentWorkingDirectory == "/tmp/initial-first")
        #expect(second.currentWorkingDirectory == "/tmp/initial-second")
        #expect(first.scheduleWorkingDirectoryChangeForTesting("/tmp/live-first"))
        #expect(second.scheduleWorkingDirectoryChangeForTesting("/tmp/live-second"))

        await Task.yield()

        #expect(first.currentWorkingDirectory == "/tmp/live-first")
        #expect(second.currentWorkingDirectory == "/tmp/live-second")
    }

    @Test
    func coalescedPwdChangesKeepTheFinalWorkingDirectory() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial",
                command: "exec /bin/cat"
            )
        )

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/first"))
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/second"))
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/final"))
        await Task.yield()

        #expect(surface.currentWorkingDirectory == "/tmp/final")
    }

    @Test
    func queuedPwdChangeIsIgnoredAfterSurfaceClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial",
                command: "exec /bin/cat"
            )
        )

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        bridge.closeSurface(id: paneID)
        await Task.yield()

        #expect(surface.currentWorkingDirectory == "/tmp/initial")
    }

    @Test
    func resizeUpdatesRealCoreSurfaceMetricsInBackingPixels() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        surface.setFrameSize(NSSize(width: 360, height: 240))
        let first = try #require(surface.sizeSnapshotForTesting)
        let firstExpected = surface.convertToBacking(surface.bounds.size)

        #expect(first.widthPixels == UInt32(firstExpected.width.rounded(.down)))
        #expect(first.heightPixels == UInt32(firstExpected.height.rounded(.down)))
        #expect(first.columns > 0)
        #expect(first.rows > 0)
        #expect(first.cellWidthPixels > 0)
        #expect(first.cellHeightPixels > 0)

        surface.setFrameSize(NSSize(width: 640, height: 420))
        let second = try #require(surface.sizeSnapshotForTesting)
        let secondExpected = surface.convertToBacking(surface.bounds.size)

        #expect(second.widthPixels == UInt32(secondExpected.width.rounded(.down)))
        #expect(second.heightPixels == UInt32(secondExpected.height.rounded(.down)))
        #expect(second.widthPixels != first.widthPixels)
        #expect(second.heightPixels != first.heightPixels)
        #expect(second.columns != first.columns)
        #expect(second.rows != first.rows)
    }

    @Test
    func runtimeActionFromPTYAndProcessExitCloseSurface() async throws {
        let fixture = try SurfaceTestConfig()
        defer { fixture.remove() }
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge(configURL: fixture.url)
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let window = makeHiddenWindow()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }

        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                initialInput:
                    "printf '\\033]2;ghostterm-io-action\\007'; exec /bin/sh -lc 'printf ghostterm-ready'\n"
            )
        ) { paneID, processAlive in
            continuation.yield(SurfaceCloseEvent(paneID: paneID, processAlive: processAlive))
        }
        embed(surface, in: window)

        let event = try await firstEvent(from: events, timeout: .seconds(10))

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(!surface.isActive)
        #expect(!surface.isReady)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
    }

    @Test
    func liveProcessCloseRequestKeepsSurfaceUntilExplicitConfirmation() async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            let event = SurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            recorder.events.append(event)
            continuation.yield(event)
        }

        surface.scheduleRuntimeCloseForTesting(processAlive: true)
        let event = try await firstEvent(from: events, timeout: .seconds(2))

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: true))
        #expect(recorder.events == [event])
        #expect(surface.isReady)
        #expect(surface.isActive)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(bridge.activeSurfaceCount == 1)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        bridge.closeSurface(id: paneID)

        #expect(!surface.isReady)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)

        surface.scheduleRuntimeCloseForTesting(processAlive: false)
        #expect(recorder.events == [event])
    }

    @Test
    func processExitOverridesQueuedLiveProcessCloseRequest() async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            let event = SurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            recorder.events.append(event)
            continuation.yield(event)
        }

        surface.scheduleRuntimeCloseForTesting(processAlive: true)
        surface.scheduleRuntimeCloseForTesting(processAlive: false)

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(recorder.events == event.map { [$0] })
        #expect(!surface.isReady)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
    }

    @Test
    func explicitCloseIsIdempotentAndDoesNotInvokeRuntimeHandler() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            recorder.events.append(SurfaceCloseEvent(paneID: paneID, processAlive: processAlive))
        }

        bridge.closeSurface(id: paneID)
        bridge.closeSurface(id: paneID)

        #expect(recorder.events.isEmpty)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceCount == 0)
    }

    @Test
    func shutdownClosesSurfacesBeforeRuntimeAndRemainsIdempotent() throws {
        let initialAppContextCount = GhosttyBridge.callbackContextCountForTesting
        let initialSurfaceContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        let first = try bridge.makeSurface(
            id: PaneID(),
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            id: PaneID(),
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        bridge.shutdown()
        bridge.shutdown()

        #expect(!first.isActive)
        #expect(!second.isActive)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(!bridge.isReady)
        #expect(GhosttyBridge.callbackContextCountForTesting == initialAppContextCount)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount)
    }
}

private struct SurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

@MainActor
private final class SurfaceCloseRecorder {
    var events: [SurfaceCloseEvent] = []
}

private enum SurfaceTestError: Error {
    case eventStreamEnded
    case timeout
}

private func firstEvent(
    from stream: AsyncStream<SurfaceCloseEvent>,
    timeout: Duration
) async throws -> SurfaceCloseEvent {
    try await withThrowingTaskGroup(of: SurfaceCloseEvent.self) { group in
        group.addTask {
            for await event in stream {
                return event
            }
            throw SurfaceTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SurfaceTestError.timeout
        }

        guard let event = try await group.next() else {
            throw SurfaceTestError.eventStreamEnded
        }
        group.cancelAll()
        return event
    }
}

@MainActor
private func makeHiddenWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private func embed(_ surface: GhosttySurfaceView, in window: NSWindow) {
    guard let contentView = window.contentView else {
        Issue.record("Hidden test window has no content view")
        return
    }

    surface.frame = contentView.bounds
    surface.autoresizingMask = [.width, .height]
    contentView.addSubview(surface)
}

private struct SurfaceTestConfig {
    let directoryURL: URL
    let url: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        url = directoryURL.appending(path: "config")
        try Data("abnormal-command-exit-runtime = 0\n".utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
