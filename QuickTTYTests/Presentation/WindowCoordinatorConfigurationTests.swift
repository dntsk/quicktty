import AppKit
import Testing

@testable import QuickTTY

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
        var config = QuickTTYConfig()
        config.presentationMode = .quake

        coordinator.applyConfiguration(config)

        #expect(hotKeyController.replacementAttempts == [ShortcutChord(key: .f12)])
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
        coordinator.applyConfiguration(QuickTTYConfig())

        #expect(
            coordinator.workspaceViewControllerForTesting.chromePaletteForTesting
                == expectedReplacement)
    }

    @Test
    func splitAppearanceReloadUpdatesPresentationWithoutRecreatingSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialURL = directory.appending(path: "initial")
        let replacementURL = directory.appending(path: "replacement")
        try Data(
            "background = 112233\nforeground = ddeeff\nunfocused-split-opacity = 0.6\n".utf8
        ).write(to: initialURL)
        try Data(
            "background = 445566\nforeground = 102030\nunfocused-split-fill = aabbcc\nunfocused-split-opacity = 0.8\n"
                .utf8
        ).write(to: replacementURL)
        let bridge = try GhosttyBridge(configURL: initialURL)
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: RecordingHotKeyController()
        )
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceID = ObjectIdentifier(surface)
        let splitHostID = try #require(
            coordinator.workspaceViewControllerForTesting
                .splitHostingControllerIdentifierForTesting
        )
        let hostedSurfaceIDs = coordinator.workspaceViewControllerForTesting
            .hostedSurfaceIdentifiersForTesting
        let initialPresentationPalette = coordinator.workspaceViewControllerForTesting
            .splitPresentationPaletteForTesting
        let initialDividerRGB = coordinator.workspaceViewControllerForTesting
            .splitDividerRGBForTesting

        try bridge.reloadConfig(at: replacementURL)
        coordinator.applyConfiguration(QuickTTYConfig())

        let workspaceController = coordinator.workspaceViewControllerForTesting
        let appearance = workspaceController.splitAppearanceForTesting
        let replacementPalette = GhosttyChromePalette(
            background: GhosttyRGB(red: 0x44, green: 0x55, blue: 0x66),
            foreground: GhosttyRGB(red: 0x10, green: 0x20, blue: 0x30)
        )
        #expect(appearance.unfocusedFill == GhosttyRGB(red: 0xAA, green: 0xBB, blue: 0xCC))
        #expect(abs(appearance.unfocusedOverlayOpacity - 0.2) < 0.000_001)
        #expect(workspaceController.splitPresentationPaletteForTesting == replacementPalette)
        #expect(
            workspaceController.splitPresentationPaletteForTesting != initialPresentationPalette)
        #expect(
            workspaceController.splitDividerRGBForTesting
                == GhosttySplitTreeView.dividerRGB(for: replacementPalette)
        )
        #expect(workspaceController.splitDividerRGBForTesting != initialDividerRGB)
        #expect(ObjectIdentifier(try #require(coordinator.activeSurfaceForTesting)) == surfaceID)
        #expect(workspaceController.hostedSurfaceIdentifiersForTesting == hostedSurfaceIDs)
        #expect(workspaceController.splitHostingControllerIdentifierForTesting == splitHostID)
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

        var quakeConfig = QuickTTYConfig()
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
                path: "/tmp/quicktty/config",
                messages: [
                    "Line 4, quicktty-quake-height: expected a value in 0...1 or 1%...100%."
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
        var config = QuickTTYConfig()
        config.presentationMode = .quake
        config.globalToggle = ShortcutChord(key: .f10, modifiers: [.option])

        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .quake)
        #expect(hotKeyController.replacementAttempts == [config.globalToggle])

        config.presentationMode = .normal
        coordinator.applyConfiguration(config)

        #expect(coordinator.presentationMode == .normal)
        #expect(hotKeyController.unregisterCount == 1)
    }

    @Test
    func runtimeShortcutHotReloadKeepsSurfaceAndProcessContextAndSharesResolvedMap() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: RecordingHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIdentity = ObjectIdentifier(surface)
        let processContext = try #require(
            bridge.surfaceConfigurationForTesting(id: surface.paneID)
        )
        let controller = ShortcutController()
        var config = QuickTTYConfig()

        coordinator.applyConfiguration(config)
        AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: controller,
            ghosttyBridge: bridge
        )
        let oldEvent = try shortcutEvent(key: "k", modifiers: [.command])
        #expect(controller.action(matching: oldEvent) == .clearScreen)

        config.shortcuts.assign(
            ShortcutChord(key: .x, modifiers: [.control]),
            to: .clearScreen
        )
        coordinator.applyConfiguration(config)
        let resolved = AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: controller,
            ghosttyBridge: bridge
        )
        let newEvent = try shortcutEvent(key: "x", modifiers: [.control])

        #expect(controller.action(matching: oldEvent) == nil)
        #expect(controller.action(matching: newEvent) == .clearScreen)
        #expect(controller.activeConfiguration == resolved)
        #expect(bridge.shortcutConfigurationForTesting == resolved)
        #expect(coordinator.activeSurfaceForTesting.map(ObjectIdentifier.init) == surfaceIdentity)
        #expect(bridge.surfaceConfigurationForTesting(id: surface.paneID) == processContext)

        config.shortcuts.disable(.clearScreen)
        coordinator.applyConfiguration(config)
        AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: controller,
            ghosttyBridge: bridge
        )

        #expect(controller.action(matching: newEvent) == nil)
        #expect(controller.activeConfiguration == bridge.shortcutConfigurationForTesting)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(bridge.surfaceConfigurationForTesting(id: surface.paneID) == processContext)
    }

    @Test
    func normalModeConfiguredGlobalChordStillReservesLocalOwner() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            hotKeyController: RecordingHotKeyController()
        )
        let controller = ShortcutController()
        var config = QuickTTYConfig()
        config.globalToggle = ShortcutChord(key: .t, modifiers: [.command])
        config.shortcuts = config.shortcuts.resolvingGlobalPrecedence(config.globalToggle)

        coordinator.applyConfiguration(config)
        let resolved = AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: controller,
            ghosttyBridge: bridge
        )

        #expect(coordinator.registeredGlobalChord == nil)
        #expect(resolved.chord(for: .newTab) == nil)
        #expect(controller.activeConfiguration == bridge.shortcutConfigurationForTesting)
    }

    @Test
    func failedGlobalReplacementKeepsActualOldChordAndConfiguredNewChord() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        var errors: [GlobalHotKeyError] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            onError: { error in
                if let error = error as? GlobalHotKeyError {
                    errors.append(error)
                }
            },
            hotKeyController: hotKeyController
        )
        var config = QuickTTYConfig()
        config.presentationMode = .quake
        coordinator.applyConfiguration(config)
        hotKeyController.nextReplacementError = .registrationFailed(-1)
        config.globalToggle = ShortcutChord(key: .space, modifiers: [.command])
        config.configEditor = "vim"
        config.shortcuts.assign(ShortcutChord(key: .f12), to: .newTab)
        config.shortcuts.assign(config.globalToggle, to: .paste)
        config.shortcuts = config.shortcuts.resolvingGlobalPrecedence(config.globalToggle)

        coordinator.applyConfiguration(config)
        let shortcutController = ShortcutController()
        let resolved = AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: shortcutController,
            ghosttyBridge: bridge
        )

        #expect(coordinator.registeredGlobalChord == ShortcutChord(key: .f12))
        #expect(resolved.chord(for: .newTab) == nil)
        #expect(resolved.chord(for: .paste) == nil)
        #expect(shortcutController.activeConfiguration == bridge.shortcutConfigurationForTesting)
        #expect(errors == [.registrationFailed(-1)])
        #expect(coordinator.configEditorForTesting == "vim")

        coordinator.togglePresentationMode()
        coordinator.togglePresentationMode()

        #expect(hotKeyController.replacementAttempts.last == config.globalToggle)
    }

    @Test
    func failedUnregisterKeepsActualOldChordWhileConfiguredCandidateRemainsReserved() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        var errors: [GlobalHotKeyError] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            onError: { error in
                if let error = error as? GlobalHotKeyError {
                    errors.append(error)
                }
            },
            hotKeyController: hotKeyController
        )
        var config = QuickTTYConfig()
        config.presentationMode = .quake
        coordinator.applyConfiguration(config)

        config.presentationMode = .normal
        config.globalToggle = ShortcutChord(key: .t, modifiers: [.command])
        config.shortcuts.assign(ShortcutChord(key: .f12), to: .paste)
        config.shortcuts = config.shortcuts.resolvingGlobalPrecedence(config.globalToggle)
        hotKeyController.nextUnregistrationError = .unregistrationFailed(-2)

        coordinator.applyConfiguration(config)
        let shortcutController = ShortcutController()
        let resolved = AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: shortcutController,
            ghosttyBridge: bridge
        )

        #expect(coordinator.presentationMode == .normal)
        #expect(coordinator.registeredGlobalChord == ShortcutChord(key: .f12))
        #expect(resolved.chord(for: .newTab) == nil)
        #expect(resolved.chord(for: .paste) == nil)
        #expect(shortcutController.activeConfiguration == resolved)
        #expect(bridge.shortcutConfigurationForTesting == resolved)
        #expect(errors == [.unregistrationFailed(-2)])
    }

    @Test
    func replacementAndRollbackFailureExposesNoActualRegistrationOrImaginaryOldConflict() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let hotKeyController = RecordingHotKeyController()
        var errors: [GlobalHotKeyError] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            onError: { error in
                if let error = error as? GlobalHotKeyError {
                    errors.append(error)
                }
            },
            hotKeyController: hotKeyController
        )
        var config = QuickTTYConfig()
        config.presentationMode = .quake
        coordinator.applyConfiguration(config)

        let replacementError = GlobalHotKeyError.replacementAndRollbackFailed(
            registrationStatus: -3,
            rollbackStatus: -4
        )
        config.globalToggle = ShortcutChord(key: .f11)
        config.shortcuts.assign(ShortcutChord(key: .f12), to: .newTab)
        config.shortcuts.assign(config.globalToggle, to: .paste)
        config.shortcuts = config.shortcuts.resolvingGlobalPrecedence(config.globalToggle)
        hotKeyController.nextReplacementError = replacementError

        coordinator.applyConfiguration(config)
        let shortcutController = ShortcutController()
        let resolved = AppDelegate.applyRuntimeShortcutConfiguration(
            config.shortcuts,
            registeredGlobalChord: coordinator.registeredGlobalChord,
            shortcutController: shortcutController,
            ghosttyBridge: bridge
        )

        #expect(coordinator.registeredGlobalChord == nil)
        #expect(resolved.chord(for: .newTab) == ShortcutChord(key: .f12))
        #expect(resolved.chord(for: .paste) == nil)
        #expect(shortcutController.activeConfiguration == resolved)
        #expect(bridge.shortcutConfigurationForTesting == resolved)
        #expect(
            hotKeyController.replacementAttempts == [ShortcutChord(key: .f12), config.globalToggle])
        #expect(errors == [replacementError])
    }
}

@MainActor
private final class RecordingHotKeyController: HotKeyControlling {
    private(set) var replacementAttempts: [ShortcutChord] = []
    private(set) var registeredChord: ShortcutChord?
    private(set) var unregisterCount = 0
    var nextReplacementError: GlobalHotKeyError?
    var nextUnregistrationError: GlobalHotKeyError?

    func replace(with chord: ShortcutChord) throws {
        replacementAttempts.append(chord)
        if let error = nextReplacementError {
            nextReplacementError = nil
            if case .replacementAndRollbackFailed = error {
                registeredChord = nil
            }
            throw error
        }
        registeredChord = chord
    }

    func unregister() throws {
        unregisterCount += 1
        if let error = nextUnregistrationError {
            nextUnregistrationError = nil
            throw error
        }
        registeredChord = nil
    }
}

@MainActor
private func shortcutEvent(
    key: String,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: key == "k" ? 40 : 7
        )
    )
}
