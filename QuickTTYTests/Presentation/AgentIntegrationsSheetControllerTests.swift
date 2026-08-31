import AppKit
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct AgentIntegrationsSheetControllerTests {
    @Test
    func oneSheetReopensAndReattachesBetweenNormalAndQuakeWindows() {
        let viewController = makeViewController()
        let focusRecorder = TerminalFocusRestorationRecorder()
        let controller = AgentIntegrationsSheetController(
            viewController: viewController,
            restoreTerminalFocus: focusRecorder.restore
        )
        let normal = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let quake = QuakeWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))

        controller.present(on: normal)
        let sheet = normal.attachedSheet
        controller.present(on: normal)

        #expect(controller.isPresented)
        #expect(normal.attachedSheet === sheet)
        #expect(sheet === controller.sheetWindow)

        let wasPresented = controller.detachForWindowTransition()
        controller.reattachAfterWindowTransition(to: quake, wasPresented: wasPresented)

        #expect(normal.attachedSheet == nil)
        #expect(quake.attachedSheet === sheet)
        #expect(controller.parentWindowForTesting === quake)
        controller.close()
        #expect(!controller.isPresented)
        #expect(quake.attachedSheet == nil)
        #expect(focusRecorder.restoreCallCount == 1)
    }

    @Test
    func coordinatorNormalToQuakeThenCloseFocusesCurrentSurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            hotKeyController: SheetTestHotKeyController()
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.installAgentIntegrations(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient()
        )
        let initialStore = coordinator.workspaceStoreForTesting
        let initialSurfaceIDs = coordinator.surfaceIDsForTesting
        let initialSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.presentAgentIntegrations()
        let sheetController = try #require(
            coordinator.agentIntegrationsSheetControllerForTesting
        )
        let sheet = try #require(coordinator.activeWindowForTesting?.attachedSheet)
        coordinator.presentAgentIntegrations()

        #expect(coordinator.activeWindowForTesting?.attachedSheet === sheet)
        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting == initialSurfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === initialSurface)

        coordinator.togglePresentationMode()

        #expect(coordinator.presentationMode == .quake)
        #expect(coordinator.activeWindowForTesting?.attachedSheet === sheet)
        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting == initialSurfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === initialSurface)

        let quakeWindow = try #require(coordinator.activeWindowForTesting)
        let currentSurface = try #require(coordinator.activeSurfaceForTesting)
        sheetController.close()

        #expect(quakeWindow.firstResponder === currentSurface)
    }

    @Test
    func coordinatorRetryReplacementThenCloseFocusesCurrentSurface() throws {
        let helper = try AgentIntegrationsResumeHelperFixture()
        defer { helper.remove() }
        let paneID = PaneID()
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude"),
            sessionID: "focus-retry-session",
            workingDirectory: "/tmp",
            registeredAt: Date(timeIntervalSinceReferenceDate: 100),
            launchMetadata: [:],
            restoreState: .active
        )
        let tab = TerminalTab(
            title: "Retry",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp",
                agentResumeBinding: binding
            )
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let sessionController = try AgentSessionController(
            socketPath: "/tmp/quicktty-focus-\(UUID().uuidString).sock",
            helperPath: helper.path,
            tokenGenerator: { Array(repeating: 0xAB, count: 32) },
            onAction: { _ in false }
        )
        let scheduler = AgentResumeManualScheduler()
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: sessionController,
            initialWorkspaceStore: store,
            agentRestoreCompatibilityResolver: { adapterIDs in
                Dictionary(
                    uniqueKeysWithValues: adapterIDs.map {
                        (
                            $0,
                            AgentRestoreCompatibility(
                                status: .compatible(version: "1.0"),
                                resolvedExecutablePath: "/bin/echo"
                            )
                        )
                    }
                )
            },
            agentResumeScheduler: scheduler,
            agentResumeRegistrationTimeout: 1
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.applyConfiguration(QuickTTYConfig())
        try coordinator.start()
        coordinator.installAgentIntegrations(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient()
        )
        let originalSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.presentAgentIntegrations()
        scheduler.advance(by: 1)
        coordinator.retryAgentResumeForTesting(paneID)

        let replacementSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(replacementSurface !== originalSurface)
        let sheetController = try #require(
            coordinator.agentIntegrationsSheetControllerForTesting
        )
        sheetController.close()

        #expect(coordinator.activeWindowForTesting?.firstResponder === replacementSurface)
    }

    @Test
    func closingRequestsTerminalFocusRestoration() {
        let focusRecorder = TerminalFocusRestorationRecorder()
        let controller = AgentIntegrationsSheetController(
            viewController: makeViewController(),
            restoreTerminalFocus: focusRecorder.restore
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        controller.present(on: parent)
        controller.close()

        #expect(focusRecorder.restoreCallCount == 1)
    }

    private func makeViewController() -> AgentIntegrationsViewController {
        AgentIntegrationsViewController(
            installer: makeInstallerClient(),
            launcherInstaller: makeLauncherClient(),
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
    }

    private func makeInstallerClient() -> AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [] },
            prepare: { _ in AgentIntegrationPreparedSummary(planID: "plan", adapters: []) },
            apply: { _ in AgentIntegrationApplySummary(adapters: []) }
        )
    }

    private func makeLauncherClient() -> CommandLineLauncherInstallerClient {
        CommandLineLauncherInstallerClient(
            prepare: {
                CommandLineLauncherSummary(
                    planID: "launcher",
                    displayPath: "~/.local/bin/quicktty",
                    kind: "symlinkCreate",
                    createsBackup: false,
                    status: .available
                )
            },
            apply: { _ in .succeeded }
        )
    }
}

@MainActor
private final class TerminalFocusRestorationRecorder {
    private(set) var restoreCallCount = 0

    func restore() {
        restoreCallCount += 1
    }
}

@MainActor
private final class AgentIntegrationsResumeHelperFixture {
    let directoryURL: URL
    let path: String

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-AgentIntegrationsFocus-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let helperURL = directoryURL.appending(path: "quicktty")
        try Data("#!/bin/sh\nwhile :; do sleep 60; done\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )
        path = helperURL.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private final class SheetTestHotKeyController: HotKeyControlling {
    private(set) var registeredChord: ShortcutChord?

    func replace(with chord: ShortcutChord) throws {
        registeredChord = chord
    }

    func unregister() throws {
        registeredChord = nil
    }
}
