import AppKit
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WindowCoordinatorConfigurationTests {
    @Test
    func defaultConfigurationRegistersPlainF12InQuakeMode() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: hotKeyController
        )
        var config = GhostTermConfig()
        config.presentationMode = .quake

        coordinator.applyConfiguration(config)

        #expect(hotKeyController.registeredDescriptors == [HotKeyDescriptor(key: .f12)])
    }

    @Test
    func appliesBridgePaletteInitiallyAndAfterReloadConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialURL = directory.appending(path: "initial")
        let replacementURL = directory.appending(path: "replacement")
        try Data("background = 112233\nforeground = ddeeff\n".utf8).write(to: initialURL)
        try Data("background = 445566\nforeground = aabbcc\n".utf8).write(to: replacementURL)

        let bridge = try GhosttyBridge(configURL: initialURL)
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: RecordingHotKeyController()
        )
        let expectedReplacement = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x44, green: 0x55, blue: 0x66),
            foreground: GhosttyRGB(red: 0xAA, green: 0xBB, blue: 0xCC)
        )

        #expect(
            coordinator.workspaceViewControllerForTesting.chromePaletteForTesting
                == GhosttyChromePalette(
                    background: GhosttyRGB(red: 0x11, green: 0x22, blue: 0x33),
                    foreground: GhosttyRGB(red: 0xDD, green: 0xEE, blue: 0xFF)
                )
        )

        try bridge.reloadConfig(at: replacementURL)
        coordinator.applyConfiguration(GhostTermConfig())

        #expect(
            coordinator.workspaceViewControllerForTesting.chromePaletteForTesting
                == expectedReplacement)
    }

    @Test
    func normalWindowFrameUsesSavedFrameWhileQuakeIsActive() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let savedFrame = try #require(NormalWindowFrame(x: 11, y: 22, width: 800, height: 500))
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            normalWindowFrame: savedFrame,
            hotKeyController: RecordingHotKeyController(),
            visibleScreenFrames: { [NSRect(x: 0, y: 0, width: 1_200, height: 900)] }
        )
        let hiddenNormalWindow = try #require(coordinator.windowForTesting)
        hiddenNormalWindow.setFrame(NSRect(x: 1, y: 2, width: 300, height: 200), display: false)

        #expect(coordinator.normalWindowFrame == savedFrame)
    }

    @Test
    func normalWindowMoveAndResizePersistValidatedFrameAndIgnoreOtherWindows() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var persistedFrames: [NormalWindowFrame] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            persistNormalWindowFrame: { persistedFrames.append($0) },
            hotKeyController: RecordingHotKeyController()
        )
        let normalWindow = try #require(coordinator.windowForTesting)
        let expectedFrame = try #require(NormalWindowFrame(x: 15, y: 25, width: 850, height: 550))
        normalWindow.setFrame(WindowCoordinator.windowFrame(from: expectedFrame), display: false)

        coordinator.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: normalWindow)
        )
        coordinator.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: normalWindow)
        )

        var quakeConfig = GhostTermConfig()
        quakeConfig.presentationMode = .quake
        coordinator.applyConfiguration(quakeConfig)
        let quakeWindow = try #require(coordinator.activeWindowForTesting)
        coordinator.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: quakeWindow)
        )
        coordinator.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: quakeWindow)
        )

        #expect(persistedFrames == [expectedFrame, expectedFrame])
    }

    @Test
    func configurationDiagnosticsPreserveLiveSurfacesFocusAndWorkspaceState() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var workspaceSnapshots: [WorkspaceStore] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { workspaceSnapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let workspaceStore = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let hostedSurfaceIdentifiers = coordinator.workspaceViewControllerForTesting
            .hostedSurfaceIdentifiersForTesting
        let renderedSurfaceIdentifiers = coordinator.workspaceViewControllerForTesting
            .renderedSurfaceIdentifiersForTesting
        let splitHostingControllerIdentifier = try #require(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
        )
        let firstResponder = try #require(window.firstResponder)
        let snapshotCount = workspaceSnapshots.count

        coordinator.applyConfigurationDiagnostics(
            ConfigDiagnosticPresentation(
                path: "/tmp/ghostterm/config",
                messages: [
                    "Line 4, ghostterm-quake-height: expected a value in 0...1 or 1%...100%."
                ]
            )
        )

        #expect(
            coordinator.workspaceViewControllerForTesting.configurationDiagnosticIsVisibleForTesting
        )
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.workspaceStoreForTesting == workspaceStore)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hostedSurfaceIdentifiers)
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                == renderedSurfaceIdentifiers
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                == splitHostingControllerIdentifier
        )
        #expect(window.firstResponder === firstResponder)
        #expect(workspaceSnapshots.count == snapshotCount)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)

        coordinator.applyConfigurationDiagnostics(nil)

        #expect(
            !coordinator.workspaceViewControllerForTesting
                .configurationDiagnosticIsVisibleForTesting
        )
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.workspaceStoreForTesting == workspaceStore)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hostedSurfaceIdentifiers)
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                == renderedSurfaceIdentifiers
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                == splitHostingControllerIdentifier
        )
        #expect(window.firstResponder === firstResponder)
        #expect(workspaceSnapshots.count == snapshotCount)
    }

    @Test
    func configTransitionsPresentationAndRegistersOnlyQuakeHotKey() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: hotKeyController
        )
        var config = GhostTermConfig()
        config.presentationMode = .quake
        config.globalToggle = HotKeyDescriptor(option: true, key: .f10)

        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .quake)
        #expect(hotKeyController.registeredDescriptors == [config.globalToggle])

        config.presentationMode = .normal
        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .normal)
        #expect(hotKeyController.unregisterCount == 1)
    }
}

@MainActor
private final class RecordingHotKeyController: HotKeyControlling {
    private(set) var registeredDescriptors: [HotKeyDescriptor] = []
    private(set) var unregisterCount = 0

    func register(_ descriptor: HotKeyDescriptor) throws {
        registeredDescriptors.append(descriptor)
    }

    func unregister() throws {
        unregisterCount += 1
    }
}
