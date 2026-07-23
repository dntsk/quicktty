import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import QuickTTY

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
        #expect(surface.latestWorkingDirectoryForPersistence == "/tmp/final")
        #expect(
            bridge.latestWorkingDirectoriesForPersistence == [surface.paneID: "/tmp/final"]
        )
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
    func titleCallbacksCopyStrictUTF8AndInvokeTypedHandlersOnce() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [(PaneID, String)] = []
        var tabTitles: [(PaneID, String)] = []
        var promptPaneIDs: [PaneID] = []
        var titleAtObservation: String?
        bridge.surfaceTitleHandler = { paneID, title in
            surfaceTitles.append((paneID, title))
            titleAtObservation = surface.currentTitle
        }
        bridge.surfaceTabTitleHandler = { paneID, title in
            tabTitles.append((paneID, title))
        }
        bridge.surfaceTabTitlePromptHandler = { paneID in
            promptPaneIDs.append(paneID)
        }

        #expect(surface.currentTitle == nil)
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("build 🚀".utf8),
                overwritePayloadAfterCallback: true
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("manual 🧭".utf8),
                overwritePayloadAfterCallback: true
            )
        )
        #expect(surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: []))
        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "build 🚀")
        #expect(titleAtObservation == "build 🚀")
        #expect(surfaceTitles.count == 1)
        #expect(surfaceTitles.first?.0 == surface.paneID)
        #expect(surfaceTitles.first?.1 == "build 🚀")
        #expect(tabTitles.count == 2)
        #expect(tabTitles.map(\.0) == [surface.paneID, surface.paneID])
        #expect(tabTitles.map(\.1) == ["manual 🧭", ""])
        #expect(promptPaneIDs == [surface.paneID])
    }

    @Test
    func titleCallbacksRejectNullInvalidUTF8AndUnsupportedTargets() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(!surface.scheduleTitleCallbackForTesting(.surfaceTitle, bytes: nil))
        #expect(!surface.scheduleTitleCallbackForTesting(.surfaceTitle, bytes: [0xFF]))
        #expect(!surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: nil))
        #expect(!surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: [0xFF]))
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("ignored".utf8),
                target: .app
            )
        )
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: [],
                target: .unknown
            )
        )
        #expect(!surface.schedulePromptTitleCallbackForTesting(.surface))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.tab, target: .app))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.tab, target: .unknown))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.unknown))
        #expect(surface.currentTitle == nil)
    }

    @Test
    func automaticTitleCallbacksCoalesceToLatestValue() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var deliveredTitles: [String] = []
        bridge.surfaceTitleHandler = { _, title in
            deliveredTitles.append(title)
        }

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("first".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("second".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("final 🟢".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "final 🟢")
        #expect(deliveredTitles == ["final 🟢"])
    }

    @Test
    func queuedOldTitleEventsDoNotReachSamePaneIDReplacement() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let oldSurface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [(PaneID, String)] = []
        var tabTitles: [(PaneID, String)] = []
        var promptPaneIDs: [PaneID] = []
        bridge.surfaceTitleHandler = { surfaceTitles.append(($0, $1)) }
        bridge.surfaceTabTitleHandler = { tabTitles.append(($0, $1)) }
        bridge.surfaceTabTitlePromptHandler = { promptPaneIDs.append($0) }

        #expect(
            oldSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("stale automatic".utf8)
            )
        )
        #expect(
            oldSurface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("stale override".utf8)
            )
        )
        #expect(oldSurface.schedulePromptTitleCallbackForTesting(.tab))
        bridge.closeSurface(id: paneID)
        let replacement = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        await Task.yield()
        await Task.yield()

        #expect(replacement.currentTitle == nil)
        #expect(surfaceTitles.isEmpty)
        #expect(tabTitles.isEmpty)
        #expect(promptPaneIDs.isEmpty)

        #expect(
            replacement.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("replacement title".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(replacement.currentTitle == "replacement title")
        #expect(surfaceTitles.count == 1)
        #expect(surfaceTitles.first?.0 == paneID)
        #expect(surfaceTitles.first?.1 == "replacement title")
        #expect(tabTitles.isEmpty)
        #expect(promptPaneIDs.isEmpty)
    }

    @Test
    func inactiveSurfaceCallbackContextRejectsTitleEvents() {
        let context = SurfaceCallbackContext(paneID: PaneID()) { _, _ in }

        context.deactivateAndDrain()

        #expect(!context.scheduleTitleChange("ignored"))
        #expect(!context.scheduleTabTitleChange(""))
        #expect(!context.scheduleTabTitlePrompt())
    }

    @Test
    func queuedTitleEventsAreDroppedAfterSurfaceTeardown() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [String] = []
        var tabTitles: [String] = []
        var promptCount = 0
        bridge.surfaceTitleHandler = { _, title in
            surfaceTitles.append(title)
        }
        bridge.surfaceTabTitleHandler = { _, title in
            tabTitles.append(title)
        }
        bridge.surfaceTabTitlePromptHandler = { _ in
            promptCount += 1
        }

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("stale".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("stale override".utf8)
            )
        )
        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        bridge.closeSurface(id: surface.paneID)
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == nil)
        #expect(surfaceTitles.isEmpty)
        #expect(tabTitles.isEmpty)
        #expect(promptCount == 0)
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("inactive".utf8)
            )
        )
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

        let secondRequestedBackingSize = NSSize(width: 640, height: 420)
        surface.setFrameSize(surface.convertFromBacking(secondRequestedBackingSize))
        let second = try #require(surface.sizeSnapshotForTesting)

        #expect(second.widthPixels == UInt32(secondRequestedBackingSize.width))
        #expect(second.heightPixels == UInt32(secondRequestedBackingSize.height))
        #expect(second.widthPixels != first.widthPixels)
        #expect(second.heightPixels != first.heightPixels)
        #expect(second.columns != first.columns)
        #expect(second.rows != first.rows)
    }

    @Test
    func conservativeMinimumSurfaceSizeFallsBackForInvalidOrUnrepresentableMetrics() {
        let fallback = (widthPixels: UInt32(40), heightPixels: UInt32(32))

        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(cellWidth: 0, cellHeight: 0)
            ) == fallback
        )
        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(
                    columns: .max,
                    rows: .max,
                    widthPixels: .max,
                    heightPixels: .max,
                    cellWidth: .max,
                    cellHeight: .max
                )
            ) == fallback
        )
        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(
                    columns: 1,
                    rows: 1,
                    widthPixels: 0,
                    heightPixels: 0,
                    cellWidth: 1,
                    cellHeight: 1
                )
            ) == fallback
        )
    }

    @Test
    func transientTinySizesPreserveTheLastValidCoreSize() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        defer { window.orderOut(nil) }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        surface.setFrameSize(NSSize(width: 800, height: 600))
        let stableSize = try #require(surface.sizeSnapshotForTesting)
        let validRequestCount = surface.sizeRequestObservationsForTesting.count
        let minimumSize = conservativeMinimumSurfaceSize(
            for: syntheticSurfaceSize(
                columns: stableSize.columns,
                rows: stableSize.rows,
                widthPixels: stableSize.widthPixels,
                heightPixels: stableSize.heightPixels,
                cellWidth: stableSize.cellWidthPixels,
                cellHeight: stableSize.cellHeightPixels
            )
        )

        surface.setFrameSize(.zero)
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(surface.convertFromBacking(NSSize(width: 1, height: 1)))
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(
            surface.convertFromBacking(
                NSSize(
                    width: CGFloat(minimumSize.widthPixels - 1),
                    height: CGFloat(minimumSize.heightPixels)
                )
            )
        )
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(
            surface.convertFromBacking(
                NSSize(
                    width: CGFloat(minimumSize.widthPixels),
                    height: CGFloat(minimumSize.heightPixels)
                )
            )
        )
        let thresholdSize = try #require(surface.sizeSnapshotForTesting)
        let thresholdRequest = try #require(surface.sizeRequestObservationsForTesting.last)
        #expect(thresholdRequest.requestedWidthPixels == minimumSize.widthPixels)
        #expect(thresholdRequest.requestedHeightPixels == minimumSize.heightPixels)
        #expect(thresholdSize.columns >= 5)
        #expect(thresholdSize.rows >= 2)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount + 1)

        surface.setFrameSize(NSSize(width: 640, height: 420))
        let restoredSize = try #require(surface.sizeSnapshotForTesting)
        #expect(restoredSize != stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount + 2)
        #expect(
            surface.sizeRequestObservationsForTesting.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
    }

    @Test
    func sizeRequestObservationsKeepOnlyTheLatest256AcceptedResizes() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        defer { window.orderOut(nil) }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        let initialSurfaceIDs = bridge.activeSurfaceIDs
        let requestedBackingSizes = (0..<300).map {
            NSSize(width: CGFloat(800 + $0), height: CGFloat(600 + $0))
        }
        for requestedBackingSize in requestedBackingSizes {
            surface.setFrameSize(surface.convertFromBacking(requestedBackingSize))
        }

        let observations = surface.sizeRequestObservationsForTesting
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.activeSurfaceIDs == initialSurfaceIDs)
        #expect(observations.count == 256)
        let expectedRequests = requestedBackingSizes.suffix(256).map {
            (width: UInt32($0.width), height: UInt32($0.height))
        }
        #expect(
            zip(observations, expectedRequests).allSatisfy {
                $0.requestedWidthPixels == $1.width && $0.requestedHeightPixels == $1.height
            }
        )
        #expect(
            observations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
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
                    "printf '\\033]2;quicktty-io-action\\007'; exec /bin/sh -lc 'printf quicktty-ready'\n"
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
    func pwdChangeUpdatesSurfaceBeforeBridgeObserver() async throws {
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
        var observedPaneID: PaneID?
        var observedWorkingDirectory: String?
        var currentWorkingDirectoryAtObservation: String?
        var observationCount = 0
        bridge.surfaceWorkingDirectoryHandler = { id, workingDirectory in
            observedPaneID = id
            observedWorkingDirectory = workingDirectory
            currentWorkingDirectoryAtObservation = surface.currentWorkingDirectory
            observationCount += 1
        }

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        #expect(surface.latestWorkingDirectoryForPersistence == "/tmp/live")
        #expect(bridge.latestWorkingDirectoriesForPersistence == [paneID: "/tmp/live"])
        #expect(observationCount == 0)
        await Task.yield()

        #expect(observedPaneID == paneID)
        #expect(observedWorkingDirectory == "/tmp/live")
        #expect(currentWorkingDirectoryAtObservation == "/tmp/live")
        #expect(surface.currentWorkingDirectory == "/tmp/live")
        #expect(observationCount == 1)
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

private func syntheticSurfaceSize(
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    widthPixels: UInt32 = 800,
    heightPixels: UInt32 = 384,
    cellWidth: UInt32 = 10,
    cellHeight: UInt32 = 16
) -> ghostty_surface_size_s {
    ghostty_surface_size_s(
        columns: columns,
        rows: rows,
        width_px: widthPixels,
        height_px: heightPixels,
        cell_width_px: cellWidth,
        cell_height_px: cellHeight
    )
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
