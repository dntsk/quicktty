import AppKit
import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct WindowCoordinatorTabLifecycleTests {
    @Test
    func openConfigurationCreatesFocusedEditorTabWithQuotedPathAndLatestEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY Config's \(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config file")
        let editor = "/bin/sh -c 'exec /bin/cat'"
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let existingSurface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDsBeforeOpening = coordinator.surfaceIDsForTesting
        var initialConfig = QuickTTYConfig()
        initialConfig.configEditor = "nano"
        coordinator.applyConfiguration(initialConfig)
        var latestConfig = initialConfig
        latestConfig.configEditor = editor
        coordinator.applyConfiguration(latestConfig)

        try coordinator.openConfiguration(at: configURL)

        let configSurface = try #require(coordinator.activeSurfaceForTesting)
        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let configTab = try #require(workspace.tabs.last)
        let expectedCommand =
            "\(editor) '\(configURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"

        #expect(configSurface !== existingSurface)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(coordinator.surfaceIDsForTesting.count == surfaceIDsBeforeOpening.count + 1)
        #expect(coordinator.surfaceForTesting(id: existingSurface.paneID) === existingSurface)
        #expect(configTab.title == "Config")
        #expect(configTab.activePaneID == configSurface.paneID)
        #expect(
            configTab.paneDescriptor(for: configSurface.paneID)
                == TerminalPaneDescriptor(
                    id: configSurface.paneID,
                    cwd: directory.path,
                    startupCommand: .custom(expectedCommand)
                )
        )
        #expect(bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.context == .newTab)
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.workingDirectory
                == directory.path
        )
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.command
                == expectedCommand
        )
        #expect(!expectedCommand.hasPrefix("exec "))
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.initialInput == nil)
        #expect(coordinator.activeWindowForTesting?.firstResponder === configSurface)
    }

    @Test
    func openConfigurationUsesDefaultNanoWithoutExecPrefix() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        try coordinator.openConfiguration(at: configURL)

        let configSurface = try #require(coordinator.activeSurfaceForTesting)
        let command = try #require(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.command
        )
        #expect(command == "nano '\(configURL.path)'")
        #expect(!command.hasPrefix("exec "))
        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        #expect(
            workspace.tabs.last?.paneDescriptor(for: configSurface.paneID)?.startupCommand
                == .custom(command)
        )
    }

    @Test
    func workspacePersistenceReportsTabActivationCloseAndReorderExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()

        let tabs = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )?.tabs
        )
        let firstTabID = tabs[0].id
        let secondTabID = tabs[1].id

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onActivateTab?(firstTabID)
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                [secondTabID, firstTabID],
                secondTabID
            ) == true
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.closeTabImmediatelyForTesting(secondTabID)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func persistedTabReorderKeepsExistingSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let expectedOrder = workspace.tabs.map(\.id).reversed()
        let activeTabID = try #require(workspace.activeTabID)

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                Array(expectedOrder),
                activeTabID
            ) == true
        )

        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: workspace.id)?.tabs.map(\.id)
                == Array(expectedOrder)
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)
        #expect(bridge.activeSurfaceIDs == coordinator.surfaceIDsForTesting)
    }

    @Test
    func tabReorderCommitsOrderAndActivationOnceThenFinishesPresentation() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()

        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let firstTabID = workspace.tabs[0].id
        let secondTabID = workspace.tabs[1].id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                [secondTabID, firstTabID],
                firstTabID
            ) == true
        )

        let snapshot = try #require(persistence.snapshots.first)
        #expect(persistence.snapshots.count == 1)
        #expect(
            snapshot.workspace(id: workspace.id)?.tabs.map(\.id) == [secondTabID, firstTabID]
        )
        #expect(snapshot.workspace(id: workspace.id)?.activeTabID == firstTabID)
        #expect(tabBar.displayedTabsForTesting.map(\.id) == workspace.tabs.map(\.id))
        #expect(tabBar.activeTabIDForTesting == secondTabID)

        coordinator.workspaceViewControllerForTesting.onFinishReorderTabs?()

        #expect(tabBar.displayedTabsForTesting.map(\.id) == [secondTabID, firstTabID])
        #expect(tabBar.activeTabIDForTesting == firstTabID)
        #expect(persistence.snapshots == [snapshot])
    }

    @Test
    func workspacePersistenceReportsPaneFocusAndProcessExitExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let exitingPaneID = try #require(coordinator.activeSurfaceForTesting?.paneID)

        persistence.reset()
        coordinator.focusNextPane()
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.surfaceDidRequestCloseForTesting(id: exitingPaneID, processAlive: false)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsSplitResizeAndEqualizeExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        guard case .split(let splitID, _, _, _, _) = activeTab(of: coordinator).root else {
            Issue.record("Expected a split")
            return
        }

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: splitID,
            ratio: 0.8
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeEqualizeForTesting(splitID: splitID)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsWorkspaceActivationExactlyOnce() throws {
        let firstWorkspace = Workspace(name: "First")
        let secondWorkspace = Workspace(name: "Second")
        let store = try WorkspaceStore(
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: firstWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(secondWorkspace.id)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspaceSelectorActualMenuItemSwitchesLiveWorkspaceWithoutReplacingSurfaces() throws {
        let defaultPaneID = PaneID()
        let testPaneID = PaneID()
        let defaultTab = TerminalTab(
            title: "Default tab",
            pane: TerminalPaneDescriptor(id: defaultPaneID, cwd: "/tmp/default")
        )
        let testTab = TerminalTab(
            title: "Test tab",
            pane: TerminalPaneDescriptor(id: testPaneID, cwd: "/tmp/test")
        )
        let defaultWorkspace = Workspace(
            name: "Default",
            tabs: [defaultTab],
            activeTabID: defaultTab.id
        )
        let testWorkspace = Workspace(
            name: "Test",
            tabs: [testTab],
            activeTabID: testTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [defaultWorkspace, testWorkspace],
            activeWorkspaceID: testWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let defaultSurface = try #require(coordinator.surfaceForTesting(id: defaultPaneID))
        let testSurface = try #require(coordinator.surfaceForTesting(id: testPaneID))
        let registeredSurfaceIdentities = [
            defaultPaneID: ObjectIdentifier(defaultSurface),
            testPaneID: ObjectIdentifier(testSurface),
        ]

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(defaultWorkspace.id)

        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == defaultWorkspace.id)
        #expect(coordinator.activeSurfaceForTesting === defaultSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === defaultSurface)
        #expect(Set(coordinator.surfaceIDsForTesting) == [defaultPaneID, testPaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [defaultPaneID, testPaneID])
        #expect(
            coordinator.surfaceForTesting(id: defaultPaneID).map(ObjectIdentifier.init)
                == registeredSurfaceIdentities[defaultPaneID])
        #expect(
            coordinator.surfaceForTesting(id: testPaneID).map(ObjectIdentifier.init)
                == registeredSurfaceIdentities[testPaneID])
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [defaultPaneID: ObjectIdentifier(defaultSurface)])
        #expect(
            coordinator.workspaceViewControllerForTesting.workspaceSelector.buttonTitleForTesting
                == "Default")
        #expect(
            coordinator.workspaceViewControllerForTesting.workspaceSelector.selectedWorkspaceID
                == defaultWorkspace.id)
    }

    @Test
    func quakeWorkspaceMenuTrackingDoesNotRecreateSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let selector = coordinator.workspaceViewControllerForTesting.workspaceSelector

        selector.onMenuTrackingChanged?(true)

        #expect(coordinator.isWorkspaceMenuTrackingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)

        selector.onMenuTrackingChanged?(false)

        #expect(!coordinator.isWorkspaceMenuTrackingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)

        selector.onMenuTrackingChanged?(true)
        coordinator.prepareForBridgeShutdownForTesting()
        #expect(!coordinator.isWorkspaceMenuTrackingForTesting)
    }

    @Test
    func activateWorkspaceUsesOneBasedIndicesAndIgnoresSameAndOutOfRangeValues() throws {
        let defaultPaneID = PaneID()
        let testPaneID = PaneID()
        let defaultTab = TerminalTab(
            title: "Default tab",
            pane: TerminalPaneDescriptor(id: defaultPaneID, cwd: "/tmp/default")
        )
        let testTab = TerminalTab(
            title: "Test tab",
            pane: TerminalPaneDescriptor(id: testPaneID, cwd: "/tmp/test")
        )
        let defaultWorkspace = Workspace(
            name: "Default",
            tabs: [defaultTab],
            activeTabID: defaultTab.id
        )
        let testWorkspace = Workspace(
            name: "Test",
            tabs: [testTab],
            activeTabID: testTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [defaultWorkspace, testWorkspace],
            activeWorkspaceID: testWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let defaultSurface = try #require(coordinator.surfaceForTesting(id: defaultPaneID))
        let testSurface = try #require(coordinator.surfaceForTesting(id: testPaneID))
        let surfaceIDs = coordinator.surfaceIDsForTesting

        persistence.reset()
        coordinator.activateWorkspace(at: 1)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.activeSurfaceForTesting === defaultSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === defaultSurface)

        persistence.reset()
        coordinator.activateWorkspace(at: 2)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.activeSurfaceForTesting === testSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === testSurface)

        persistence.reset()
        coordinator.activateWorkspace(at: 2)
        coordinator.activateWorkspace(at: 9)
        coordinator.activateWorkspace(at: 0)
        coordinator.activateWorkspace(at: 10)
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.activeSurfaceForTesting === testSurface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(Set(bridge.activeSurfaceIDs) == Set(surfaceIDs))
    }

    @Test
    func workspacePersistenceReportsMoveToNewWorkspaceThroughNameSheetExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id

        persistence.reset()
        coordinator.presentMoveToNewWorkspaceForTesting([tabID])
        let sheet = try #require(coordinator.createWorkspaceControllerForTesting)
        sheet.submitForTesting(name: "Moved")
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsMoveToExistingWorkspaceAndBroadcastExactlyOnce() throws {
        let sourceWorkspace = Workspace(name: "Source")
        let destinationWorkspace = Workspace(name: "Destination")
        let store = try WorkspaceStore(
            workspaces: [sourceWorkspace, destinationWorkspace],
            activeWorkspaceID: sourceWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onMoveToWorkspace?(
            [tabID],
            destinationWorkspace.id
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onToggleBroadcast?()
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceIgnoresNoOpTabWorkspaceAndReorderCallbacks() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()
        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let activeTabID = try #require(workspace.activeTabID)
        let orderedTabIDs = workspace.tabs.map(\.id)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onActivateTab?(activeTabID)
        coordinator.workspaceViewControllerForTesting.onActivateTab?(TabID())
        coordinator.workspaceViewControllerForTesting.onActivateWorkspace?(
            coordinator.workspaceStoreForTesting.activeWorkspaceID
        )
        coordinator.workspaceViewControllerForTesting.onActivateWorkspace?(WorkspaceID())
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                orderedTabIDs,
                activeTabID
            ) == false
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?([activeTabID], activeTabID)
                == false
        )

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceIgnoresSinglePaneFocusAndEquivalentSplitRatio() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.focusNextPane()
        coordinator.focusPane(direction: .left)
        #expect(persistence.snapshots.isEmpty)

        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        guard case .split(let splitID, _, _, _, _) = activeTab(of: coordinator).root else {
            Issue.record("Expected a split")
            return
        }
        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: splitID,
            ratio: 0.5
        )

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceIgnoresInvalidAndFailedTransactionalMutations() throws {
        let sourceWorkspace = Workspace(name: "Source")
        let destinationWorkspace = Workspace(name: "Destination")
        let store = try WorkspaceStore(
            workspaces: [sourceWorkspace, destinationWorkspace],
            activeWorkspaceID: sourceWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onCloseTab?(TabID())
        coordinator.workspaceViewControllerForTesting.onMoveToWorkspace?(
            [TabID()],
            destinationWorkspace.id
        )
        coordinator.failNextSplitMutationForTesting()
        #expect(throws: SplitCoordinatorError.self) {
            try coordinator.splitActivePaneForTesting(axis: .horizontal)
        }
        #expect(throws: WorkspaceError.self) {
            try coordinator.openConfigurationForTesting(
                at: URL(fileURLWithPath: "/tmp/quicktty-config"),
                in: WorkspaceID()
            )
        }

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func openConfigurationRollsBackStoreAndRegistryForMissingDestinationWorkspace() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        let missingWorkspaceID = WorkspaceID()

        #expect(throws: WorkspaceError.workspaceNotFound(missingWorkspaceID)) {
            try coordinator.openConfigurationForTesting(
                at: URL(fileURLWithPath: "/tmp/quicktty-config"),
                in: missingWorkspaceID
            )
        }

        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(bridge.activeSurfaceIDs == surfaceIDsBeforeFailure)
    }

    @Test
    func openConfigurationRollsBackStoreAndRegistryWhenSurfaceCreationFails() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        bridge.failNextSurfaceCreationForTesting()

        #expect(throws: GhosttyBridgeError.self) {
            try coordinator.openConfiguration(at: URL(fileURLWithPath: "/tmp/quicktty-config"))
        }

        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(bridge.activeSurfaceIDs == surfaceIDsBeforeFailure)
    }

    @Test
    func createsDistinctLiveSurfacesAndSwitchesBetweenThem() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let firstSurface = try #require(coordinator.activeSurfaceForTesting)
            let firstTabID = try #require(
                coordinator.workspaceStoreForTesting.workspace(
                    id: coordinator.workspaceStoreForTesting.activeWorkspaceID
                )?.activeTabID
            )

            coordinator.createNewTab()
            await Task.yield()

            let secondSurface = try #require(coordinator.activeSurfaceForTesting)
            let store = coordinator.workspaceStoreForTesting
            let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
            let secondTabID = try #require(activeWorkspace.activeTabID)
            #expect(firstSurface.paneID != secondSurface.paneID)
            #expect(activeWorkspace.tabs.count == 2)
            #expect(activeWorkspace.tabs.last?.id == secondTabID)
            #expect(bridge.activeSurfaceCount == 2)
            #expect(
                Set(coordinator.surfaceIDsForTesting)
                    == Set([firstSurface.paneID, secondSurface.paneID])
            )
            #expect(secondSurface.isActive)
            #expect(coordinator.activeWindowForTesting?.firstResponder === secondSurface)

            coordinator.activateTabForTesting(firstTabID)
            #expect(coordinator.activeSurfaceForTesting === firstSurface)
            #expect(firstSurface.isActive)
            #expect(secondSurface.isActive)

            coordinator.activateTabForTesting(secondTabID)
            #expect(coordinator.activeSurfaceForTesting === secondSurface)
        }
    }

    @Test
    func commandNumberActivationUsesOneBasedIndexAndIgnoresOutOfRangeIndices() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        await Task.yield()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.activateTab(at: 1)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstSurface)

        coordinator.activateTab(at: 0)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        coordinator.activateTab(at: 3)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)

        coordinator.activateTab(at: 2)
        #expect(coordinator.activeSurfaceForTesting === secondSurface)
    }

    @Test
    func createNewTabActivatesAndFocusesNewSurfaceInQuakeMode() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.createNewTab()
        await Task.yield()

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(secondSurface.paneID != firstSurface.paneID)
        #expect(secondSurface.isActive)
        #expect(coordinator.activeWindowForTesting?.firstResponder === secondSurface)
    }

    @Test
    func createShellTabRollsBackNewSurfaceWhenDestinationWorkspaceIsMissing() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        let missingWorkspaceID = WorkspaceID()

        #expect(throws: WorkspaceError.workspaceNotFound(missingWorkspaceID)) {
            try coordinator.createShellTab(in: missingWorkspaceID)
        }

        #expect(bridge.activeSurfaceIDs == [activeSurface.paneID])
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
    }

    @Test
    func processExitCleansOnlyExitedTabWhenAnotherSurfaceIsLive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let firstSurface = try #require(coordinator.activeSurfaceForTesting)
            coordinator.createNewTab()
            let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            let store = coordinator.workspaceStoreForTesting
            let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
            #expect(bridge.activeSurfaceIDs == [firstSurface.paneID])
            #expect(coordinator.surfaceIDsForTesting == [firstSurface.paneID])
            #expect(activeWorkspace.tabs.count == 1)
            #expect(activeWorkspace.tabs[0].activePaneID == firstSurface.paneID)
            #expect(coordinator.activeSurfaceForTesting === firstSurface)
        }
    }

    @Test
    func configurableClosePaneUsesLiveConfirmationAndFinalPaneReplacement() throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        var confirmationCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                confirmationCount += 1
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let closedSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.requestCloseActivePane()

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let activeWorkspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        #expect(confirmationCount == 1)
        #expect(replacement.paneID != closedSurface.paneID)
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(activeWorkspace.tabs.count == 1)
        #expect(activeWorkspace.tabs[0].activePaneID == replacement.paneID)
    }

    @Test
    func configurableClosePaneClosesUnavailablePaneInModelOnly() throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Unavailable", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()

        coordinator.requestCloseActivePane()

        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
    }

    @Test
    func configurableCloseTabUsesActiveTabPaneChecksAndReplacement() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let closedPaneIDs = coordinator.surfaceIDsForTesting

        #expect(coordinator.canCloseActiveTab)
        coordinator.requestCloseActiveTab()

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        #expect(closedPaneIDs.allSatisfy { !bridge.activeSurfaceIDs.contains($0) })
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(coordinator.workspaceStoreForTesting.workspaces.flatMap(\.tabs).count == 1)
    }

    @Test
    func explicitConfirmedFinalTabCloseIsIdempotentAndCreatesOneReplacement() throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        var confirmationCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                confirmationCount += 1
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )?.activeTabID
        )

        coordinator.requestCloseTabForTesting(tabID)
        coordinator.requestCloseTabForTesting(tabID)
        coordinator.surfaceDidRequestCloseForTesting(id: surface.paneID, processAlive: true)

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let activeWorkspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )

        #expect(confirmationCount == 1)
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
        #expect(activeWorkspace.tabs.count == 1)
        #expect(activeWorkspace.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != surface.paneID)
        #expect(window.firstResponder === replacement)
        #expect(window.isVisible)
        #expect(coordinator.windowForTesting === window)
        #expect(window.delegate === coordinator)
    }

    @Test
    func closingLastTabCreatesReplacementInItsOwnerWorkspaceWithoutChangingOtherSurfaces() throws {
        let backgroundPaneID = PaneID()
        let ownerPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let ownerTab = TerminalTab(
            title: "Owner",
            pane: TerminalPaneDescriptor(id: ownerPaneID, cwd: "/tmp/owner")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let ownerWorkspace = Workspace(
            name: "Owner",
            tabs: [ownerTab],
            activeTabID: ownerTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [backgroundWorkspace, ownerWorkspace],
            activeWorkspaceID: ownerWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        let closedSurface = try #require(coordinator.surfaceForTesting(id: ownerPaneID))
        let window = try #require(coordinator.activeWindowForTesting)

        persistence.reset()
        coordinator.closeTabImmediatelyForTesting(ownerTab.id)

        let store = coordinator.workspaceStoreForTesting
        let owner = try #require(store.workspace(id: ownerWorkspace.id))
        let replacement = try #require(coordinator.activeSurfaceForTesting)
        #expect(persistence.snapshots == [store])
        #expect(owner.tabs.count == 1)
        #expect(owner.activeTabID == owner.tabs[0].id)
        #expect(owner.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != closedSurface.paneID)
        #expect(coordinator.surfaceForTesting(id: backgroundPaneID) === backgroundSurface)
        #expect(bridge.activeSurfaceIDs.contains(backgroundPaneID))
        #expect(window.firstResponder === replacement)

        let restartBridge = try GhosttyBridge()
        defer { restartBridge.shutdown() }
        let restarted = WindowCoordinator(
            ghosttyBridge: restartBridge,
            initialWorkspaceStore: try #require(persistence.snapshots.first)
        )
        defer { restarted.prepareForBridgeShutdownForTesting() }
        try restarted.start()
        #expect(
            restarted.workspaceStoreForTesting.workspace(id: ownerWorkspace.id)?.tabs.count == 1)
        #expect(restartBridge.activeSurfaceIDs.contains(replacement.paneID))
    }

    @Test
    func finalProcessExitCreatesOneReplacementAndIgnoresLateDuplicateClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let persistence = WorkspacePersistenceRecorder()
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
                persistWorkspaceStore: { persistence.snapshots.append($0) }
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let window = try #require(coordinator.windowForTesting)
            let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

            persistence.reset()
            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            let replacement = try #require(coordinator.activeSurfaceForTesting)
            #expect(persistence.snapshots.count == 1)
            let snapshot = try #require(persistence.snapshots.first)
            #expect(replacement.paneID != exitedSurface.paneID)
            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
            #expect(!bridge.activeSurfaceIDs.contains(exitedSurface.paneID))
            #expect(
                snapshot.workspaces.flatMap(\.tabs).flatMap(\.root.leaves)
                    == [replacement.paneID]
            )
            #expect(!snapshot.workspaces.flatMap(\.tabs).isEmpty)
            #expect(
                coordinator.workspaceStoreForTesting.workspaces.flatMap(\.tabs).map(\.activePaneID)
                    == [replacement.paneID]
            )
            #expect(window.firstResponder === replacement)

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            #expect(persistence.snapshots == [snapshot])
            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
        }
    }

    @Test
    func finalProcessExitReportsReplacementCreationFailureWithoutClosingCoordinator() async throws {
        let initialSurfaceContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

        persistence.reset()
        bridge.failNextSurfaceCreationForTesting()
        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        let snapshot = try #require(persistence.snapshots.first)
        #expect(!exitedSurface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(snapshot.workspaces.allSatisfy { $0.tabs.isEmpty })
        #expect(coordinator.workspaceStoreForTesting == snapshot)
        #expect(errors.count == 1)
        let error = try #require(errors.first as? GhosttyBridgeError)
        guard case .surfaceCreationFailed(let failedPaneID) = error else {
            Issue.record("Expected a surface creation failure, got \(error)")
            return
        }
        #expect(failedPaneID != exitedSurface.paneID)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount
        )

        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        #expect(errors.count == 1)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == snapshot)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount
        )
        #expect(window.isVisible)
        #expect(coordinator.windowForTesting === window)
        #expect(window.delegate === coordinator)
    }

    @Test
    func paneExitDisablesBroadcastingAndLeavesSiblingLive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let exitingSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let siblingSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.setActiveTabBroadcastingForTesting(true)

        exitingSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let activeTabID = try #require(activeWorkspace.activeTabID)
        let activeTab = try #require(store.tab(id: activeTabID))
        #expect(!activeTab.isBroadcasting)
        #expect(activeTab.root.leaves == [siblingSurface.paneID])
        #expect(bridge.activeSurfaceIDs == [siblingSurface.paneID])
    }

    @Test
    func splitActivePaneCreatesNestedLiveSurfacesWithInheritedShellContext() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp",
                command: "exec /bin/cat",
                initialInput: "echo should-not-run\n"
            )
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        try coordinator.splitActivePaneForTesting(axis: .horizontal)

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let firstSplit = try #require(split(in: activeTab(of: coordinator).root))
        #expect(firstSplit.axis == .horizontal)
        #expect(firstSplit.first == .pane(firstSurface.paneID))
        #expect(firstSplit.second == .pane(secondSurface.paneID))
        #expect(activeTab(of: coordinator).activePaneID == secondSurface.paneID)
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: secondSurface.paneID)
                == TerminalPaneDescriptor(
                    id: secondSurface.paneID,
                    cwd: "/tmp",
                    startupCommand: .shell
                ))
        #expect(bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.context == .split)
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.workingDirectory
                == "/tmp")
        #expect(bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.command == nil)
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.initialInput == nil)

        try coordinator.splitActivePaneForTesting(axis: .vertical)

        let thirdSurface = try #require(coordinator.activeSurfaceForTesting)
        let nestedRoot = activeTab(of: coordinator).root
        guard
            case .split(_, .horizontal, 0.5, .pane(let firstPaneID), let secondBranch) = nestedRoot,
            case .split(_, .vertical, 0.5, .pane(let secondPaneID), .pane(let thirdPaneID)) =
                secondBranch
        else {
            Issue.record("Expected a horizontal split with a nested vertical split")
            return
        }
        #expect(firstPaneID == firstSurface.paneID)
        #expect(secondPaneID == secondSurface.paneID)
        #expect(thirdPaneID == thirdSurface.paneID)
        #expect(activeTab(of: coordinator).activePaneID == thirdSurface.paneID)
        #expect(Set(coordinator.surfaceIDsForTesting) == Set(nestedRoot.leaves))
        #expect(bridge.activeSurfaceCount == 3)
    }

    @Test
    func applicationTerminationDetachesNestedLiveSurfacesBeforeRuntimeShutdown() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let thirdSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let storeBeforeTermination = coordinator.workspaceStoreForTesting
        let surfaceIDs = Set([firstSurface.paneID, secondSurface.paneID, thirdSurface.paneID])

        #expect(window.firstResponder === thirdSurface)
        #expect(
            Set(
                coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                    .keys
            ) == surfaceIDs
        )
        #expect(
            Set(coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting)
                == Set([
                    ObjectIdentifier(firstSurface), ObjectIdentifier(secondSurface),
                    ObjectIdentifier(thirdSurface),
                ])
        )

        coordinator.prepareForApplicationTermination()

        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        #expect(window.firstResponder === window)
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                == nil
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting.isEmpty
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                .isEmpty
        )
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeTermination)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(Set(closeObservations) == surfaceIDs)
        #expect(closeObservations.count == surfaceIDs.count)

        coordinator.prepareForApplicationTermination()

        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)

        bridge.shutdown()

        #expect(!bridge.isReady)
    }

    @Test
    func splitActivePaneUsesLiveWorkingDirectoryInsteadOfStartupDescriptor() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup",
                command: "exec /bin/cat"
            )
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        #expect(firstSurface.currentWorkingDirectory == "/tmp/startup")
        #expect(firstSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        await Task.yield()

        try coordinator.splitActivePaneForTesting(axis: .horizontal)

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let descriptor = try #require(
            activeTab(of: coordinator).paneDescriptor(for: secondSurface.paneID)
        )
        #expect(descriptor.cwd == "/tmp/live")
        #expect(secondSurface.currentWorkingDirectory == "/tmp/live")
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.workingDirectory
                == "/tmp/live"
        )
    }

    @Test
    func workspacePersistenceSnapshotOverlaysPendingWorkingDirectoryWithoutDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup",
                command: "exec /bin/cat"
            ),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)

        persistence.reset()
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/immediate"))

        let pendingSnapshot = coordinator.workspaceStoreForPersistence
        let pendingDescriptor = try #require(
            pendingSnapshot.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)
        )
        #expect(pendingDescriptor.cwd == "/tmp/immediate")
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: surface.paneID)?.cwd == "/tmp/startup"
        )
        #expect(persistence.snapshots.isEmpty)

        let finalState = AppDelegate.applicationState(
            ApplicationState(workspaceStore: coordinator.workspaceStoreForTesting),
            merging: pendingSnapshot,
            normalWindowFrame: nil
        )
        #expect(
            finalState.workspaceStore.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)?.cwd
                == "/tmp/immediate"
        )

        coordinator.prepareForApplicationTermination()
        await Task.yield()

        #expect(
            finalState.workspaceStore.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)?.cwd
                == "/tmp/immediate"
        )
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: surface.paneID)?.cwd == "/tmp/startup"
        )
        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceTracksLiveCWDForActiveBackgroundAndStalePanes() throws {
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(
                id: backgroundPaneID,
                cwd: "/tmp/background-start",
                startupCommand: .custom("printf background")
            )
        )
        let activeTab = TerminalTab(
            title: "Active",
            pane: TerminalPaneDescriptor(
                id: activePaneID,
                cwd: "/tmp/active-start",
                startupCommand: .custom("printf active")
            )
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()
        let workingDirectoryHandler = try #require(bridge.surfaceWorkingDirectoryHandler)
        bridge.surfaceWorkingDirectoryHandler = nil

        #expect(persistence.snapshots.isEmpty)
        _ = try #require(coordinator.surfaceForTesting(id: activePaneID))
        _ = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        workingDirectoryHandler(activePaneID, "/tmp/active-live")

        let activeDescriptor = try #require(
            coordinator.workspaceStoreForTesting.tab(id: activeTab.id)?
                .paneDescriptor(for: activePaneID)
        )
        #expect(
            activeDescriptor
                == TerminalPaneDescriptor(
                    id: activePaneID,
                    cwd: "/tmp/active-live",
                    startupCommand: .custom("printf active")
                )
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == backgroundTab.paneDescriptor(for: backgroundPaneID)
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        persistence.reset()

        workingDirectoryHandler(backgroundPaneID, "/tmp/background-live")

        #expect(
            coordinator.workspaceStoreForTesting.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == TerminalPaneDescriptor(
                    id: backgroundPaneID,
                    cwd: "/tmp/background-live",
                    startupCommand: .custom("printf background")
                )
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        persistence.reset()

        workingDirectoryHandler(activePaneID, "/tmp/active-live")
        workingDirectoryHandler(activePaneID, "relative")
        workingDirectoryHandler(activePaneID, "")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: activeTab.id)?
                .paneDescriptor(for: activePaneID)
                == activeDescriptor
        )

        coordinator.prepareForBridgeShutdownForTesting()
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        let storeBeforeStaleCallback = coordinator.workspaceStoreForTesting
        workingDirectoryHandler(activePaneID, "/tmp/stale")

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeStaleCallback)
    }

    @Test
    func automaticTitleRefreshIsEphemeralAndDoesNotRebuildOrRefocusTerminalPresentation()
        async throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)
        let window = try #require(coordinator.activeWindowForTesting)
        let store = coordinator.workspaceStoreForTesting
        let splitHostID = try #require(
            coordinator.workspaceViewControllerForTesting
                .splitHostingControllerIdentifierForTesting
        )
        let hostedSurfaces =
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
        let fullRefreshCount =
            coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let tabReloadGeneration =
            coordinator.workspaceViewControllerForTesting.tabBarViewController
            .dataReloadGenerationForTesting
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("  command 🚀  ".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "  command 🚀  ")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tab.id] == "  command 🚀  "
        )
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hostedSurfaces
        )
        #expect(
            coordinator.workspaceViewControllerForTesting
                .splitHostingControllerIdentifierForTesting == splitHostID
        )
        #expect(
            coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == fullRefreshCount
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .dataReloadGenerationForTesting == tabReloadGeneration
        )
        #expect(window.firstResponder === surface)
    }

    @Test
    func inactiveSplitTitleStaysHiddenUntilItsPaneBecomesActive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id

        #expect(
            secondSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("active second".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        #expect(
            firstSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest inactive 💤".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(firstSurface.currentTitle == "latest inactive 💤")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "active second"
        )

        coordinator.focusNextPane()

        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "latest inactive 💤"
        )
    }

    @Test
    func inactiveWorkspaceTitleAppearsFromItsLiveSurfaceAfterWorkspaceActivation() async throws {
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background fallback",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let activeTab = TerminalTab(
            title: "Active fallback",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp/active")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(
            coordinator.surfaceForTesting(id: backgroundPaneID)
        )
        persistence.reset()

        #expect(
            backgroundSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("background live 🌙".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(backgroundSurface.currentTitle == "background live 🌙")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[activeTab.id] == "Active fallback"
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[backgroundTab.id] == nil
        )

        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(backgroundWorkspace.id)

        #expect(coordinator.activeSurfaceForTesting === backgroundSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[backgroundTab.id] == "background live 🌙"
        )
    }

    @Test
    func inlineRenamePersistsExactTextClearsOverrideAndRestoresLiveSurfaceFocus() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let bridgeInputs = bridge.inputObservationsForTesting
        let surfaceInputs = surface.inputObservationsForTesting
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        persistence.reset()
        tabBar.beginRenameForTesting(tabID)
        var item = tabBar.tabItemForTesting(at: 0)
        #expect(
            coordinator.activeWindowForTesting?.firstResponder
                === item.renameEditorForTesting?.currentEditor())
        item.renameEditorForTesting?.stringValue = "  kept whitespace 🧷  "
        item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        #expect(persistence.snapshots.count == 1)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride
                == "  kept whitespace 🧷  "
        )
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest automatic 🌙".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        persistence.reset()
        tabBar.beginRenameForTesting(tabID)
        item = tabBar.tabItemForTesting(at: 0)
        item.renameEditorForTesting?.stringValue = ""
        item.endRenameEditingForTesting()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == nil)
        #expect(tabBar.displayedTitlesForTesting[tabID] == "latest automatic 🌙")
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(bridge.inputObservationsForTesting == bridgeInputs)
        #expect(surface.inputObservationsForTesting == surfaceInputs)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
    }

    @Test
    func contextMenuRenamePersistsSelectedInactiveTabWithoutChangingActiveTabOrFocus() async throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let activeTabID = activeTab(of: coordinator).id
        coordinator.createNewTab()
        await Task.yield()
        let inactiveSurface = try #require(coordinator.activeSurfaceForTesting)
        let inactiveTabID = activeTab(of: coordinator).id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        tabBar.beginSelectionForTesting(activeTabID, gesture: .commandClick)
        tabBar.finishSelectionForTesting()
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [activeTabID, inactiveTabID])

        persistence.reset()
        let menu = tabBar.contextMenu(for: inactiveTabID)
        let renameItem = try #require(menu.item(withTitle: "Rename Tab…"))
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)

        #expect(NSApp.sendAction(renameItem.action!, to: renameItem.target, from: renameItem))
        let item = tabBar.tabItemForTesting(at: 1)
        #expect(
            coordinator.activeWindowForTesting?.firstResponder
                === item.renameEditorForTesting?.currentEditor())
        item.renameEditorForTesting?.stringValue = "selected inactive 💤"
        item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        #expect(persistence.snapshots.count == 1)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: inactiveTabID)?.titleOverride
                == "selected inactive 💤"
        )
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [activeTabID, inactiveTabID])
        #expect(coordinator.surfaceForTesting(id: inactiveSurface.paneID) === inactiveSurface)
    }

    @Test
    func promptStartsInlineRenameOnlyForCurrentLiveTabAndDoesNotRecreateSurfaces() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        let firstTabID = activeTab(of: coordinator).id
        coordinator.createNewTab()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let secondTabID = activeTab(of: coordinator).id
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let promptHandler = try #require(bridge.surfaceTabTitlePromptHandler)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        promptHandler(firstSurface.paneID)
        #expect(tabBar.editedTabIDForTesting == nil)

        #expect(secondSurface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()

        #expect(tabBar.editedTabIDForTesting == secondTabID)
        #expect(tabBar.tabItemForTesting(at: 1).isRenamingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)

        tabBar.cancelRenameForTesting()
        coordinator.activateTabForTesting(firstTabID)
        promptHandler(secondSurface.paneID)
        #expect(tabBar.editedTabIDForTesting == nil)
    }

    @Test
    func closingEditedTabCancelsWithoutApplyingStaleEditorValue() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()
        let editedTab = activeTab(of: coordinator)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController
        tabBar.beginRenameForTesting(editedTab.id)
        let editedItem = tabBar.tabItemForTesting(at: 1)
        editedItem.renameEditorForTesting?.stringValue = "must not persist"
        persistence.reset()

        coordinator.closeTabImmediatelyForTesting(editedTab.id)
        editedItem.endRenameEditingForTesting()

        #expect(coordinator.workspaceStoreForTesting.tab(id: editedTab.id) == nil)
        #expect(tabBar.editedTabIDForTesting == nil)
        #expect(
            persistence.snapshots.allSatisfy {
                $0.workspaces.flatMap(\.tabs).allSatisfy { $0.titleOverride != "must not persist" }
            }
        )
    }

    @Test
    func quakeInlineRenameOwnsOneTransientInteractionAndTeardownEndsIt() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        tabBar.beginRenameForTesting(tabID)
        tabBar.beginRenameForTesting(tabID)

        #expect(coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 1)

        tabBar.cancelRenameForTesting()
        tabBar.cancelRenameForTesting()

        #expect(!coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)

        tabBar.beginRenameForTesting(tabID)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 1)
        coordinator.prepareForBridgeShutdownForTesting()
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
    }

    @Test
    func closedPaneTitleRequestsAndPromptsAreIgnored() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)
        let titleHandler = try #require(bridge.surfaceTitleHandler)
        let tabTitleHandler = try #require(bridge.surfaceTabTitleHandler)
        let promptHandler = try #require(bridge.surfaceTabTitlePromptHandler)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()
        #expect(tabBar.editedTabIDForTesting == tab.id)
        tabBar.cancelRenameForTesting()

        coordinator.closeTabImmediatelyForTesting(tab.id)
        let storeAfterClose = coordinator.workspaceStoreForTesting
        let displayedTitlesAfterClose =
            coordinator.workspaceViewControllerForTesting.tabBarViewController
            .displayedTitlesForTesting
        persistence.reset()

        titleHandler(surface.paneID, "stale automatic")
        tabTitleHandler(surface.paneID, "stale override")
        promptHandler(surface.paneID)
        titleHandler(PaneID(), "non-owned automatic")
        tabTitleHandler(PaneID(), "non-owned override")
        promptHandler(PaneID())

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeAfterClose)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting == displayedTitlesAfterClose
        )
        #expect(tabBar.editedTabIDForTesting == nil)
    }

    @Test
    func setTabTitlePersistsOverrideWhileAutomaticTitleContinuesUpdatingUnderIt() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("initial automatic".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("Pinned 🧷".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == "Pinned 🧷")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "Pinned 🧷"
        )
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest automatic 🚦".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "latest automatic 🚦")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "Pinned 🧷"
        )

        #expect(surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: []))
        await Task.yield()
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == nil)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "latest automatic 🚦"
        )
    }

    @Test
    func splitActivePaneRollsBackCreatedSurfaceAndStoreWhenCandidateMutationFails() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let store = coordinator.workspaceStoreForTesting

        coordinator.failNextSplitMutationForTesting()
        do {
            try coordinator.splitActivePaneForTesting(axis: .horizontal)
            Issue.record("Expected split mutation failure")
        } catch {}

        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
        #expect(coordinator.workspaceStoreForTesting == store)
    }

    @Test
    func activeTabRenderingUsesOnlyItsExactLiveSurfaceIdentities() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)

        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [
                    firstSurface.paneID: ObjectIdentifier(firstSurface),
                    secondSurface.paneID: ObjectIdentifier(secondSurface),
                ])

        coordinator.createNewTab()
        let tabSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [tabSurface.paneID: ObjectIdentifier(tabSurface)])

        let splitTabID = try #require(
            coordinator.workspaceStoreForTesting.workspaces.first?.tabs.first?.id)
        coordinator.activateTabForTesting(splitTabID)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [
                    firstSurface.paneID: ObjectIdentifier(firstSurface),
                    secondSurface.paneID: ObjectIdentifier(secondSurface),
                ])
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func surfaceFocusCallbackActivatesExistingPaneInEveryPresentationMode(
        mode: PresentationMode
    ) async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        await Task.yield()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)

        #expect(window.firstResponder === secondSurface)
        _ = window.makeFirstResponder(firstSurface)

        #expect(activeTab(of: coordinator).activePaneID == firstSurface.paneID)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(window.firstResponder === firstSurface)
    }

    @Test
    func paneNavigationMovesThroughNestedLiveSurfacesWithoutRecreatingThem() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let first = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let second = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)

        _ = window.makeFirstResponder(first)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let third = try #require(coordinator.activeSurfaceForTesting)
        _ = window.makeFirstResponder(second)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let fourth = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDs = coordinator.surfaceIDsForTesting

        _ = window.makeFirstResponder(first)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === third)
        #expect(window.firstResponder === third)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === second)
        #expect(window.firstResponder === second)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === first)
        #expect(window.firstResponder === first)
        coordinator.focusPreviousPane()
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)

        _ = window.makeFirstResponder(first)
        coordinator.focusPane(direction: .right)
        #expect(coordinator.activeSurfaceForTesting === second)
        #expect(window.firstResponder === second)
        coordinator.focusPane(direction: .down)
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)
        coordinator.focusPane(direction: .left)
        #expect(coordinator.activeSurfaceForTesting === third)
        #expect(window.firstResponder === third)
        coordinator.focusPane(direction: .up)
        #expect(coordinator.activeSurfaceForTesting === first)
        #expect(window.firstResponder === first)
        #expect(activeTab(of: coordinator).activePaneID == first.paneID)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
    }

    @Test
    func paneNavigationIsANoOpForASingleLivePane() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let store = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting

        coordinator.focusPreviousPane()
        coordinator.focusNextPane()
        coordinator.focusPane(direction: .left)
        coordinator.focusPane(direction: .right)
        coordinator.focusPane(direction: .up)
        coordinator.focusPane(direction: .down)

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(window.firstResponder === surface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
    }

    @Test
    func nestedDividerCallbacksUpdateRatiosWithoutRecreatingSurfacesAndEqualizeAll() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let surfaceIDs = coordinator.surfaceIDsForTesting

        guard
            case .split(let outerID, _, let outerRatio, _, let second) = activeTab(of: coordinator)
                .root,
            case .split(let nestedID, _, let nestedRatio, _, _) = second
        else {
            Issue.record("Expected nested split tree")
            return
        }
        #expect(outerRatio == 0.5)
        #expect(nestedRatio == 0.5)

        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: nestedID,
            ratio: 0.9
        )

        #expect(ratio(in: activeTab(of: coordinator).root, splitID: outerID) == 0.5)
        #expect(ratio(in: activeTab(of: coordinator).root, splitID: nestedID) == 0.9)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)

        coordinator.workspaceViewControllerForTesting.invokeEqualizeForTesting(splitID: outerID)

        #expect(ratio(in: activeTab(of: coordinator).root, splitID: outerID) == 0.5)
        #expect(ratio(in: activeTab(of: coordinator).root, splitID: nestedID) == 0.5)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
    }

    @Test
    func processExitClosesOnlyOnePaneAndCollapsesToItsLiveSibling() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let sibling = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let exited = try #require(coordinator.activeSurfaceForTesting)

        exited.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let tab = activeTab(of: coordinator)
        #expect(tab.root == .pane(sibling.paneID))
        #expect(tab.activePaneID == sibling.paneID)
        #expect(coordinator.activeSurfaceForTesting === sibling)
        #expect(coordinator.surfaceIDsForTesting == [sibling.paneID])
        #expect(bridge.activeSurfaceIDs == [sibling.paneID])
    }

    @Test
    func processExitReplacesLastPaneInOwnerWorkspaceWhenAnotherWorkspaceIsActive() async throws {
        let activePaneID = PaneID()
        let ownerPaneID = PaneID()
        let activeTab = TerminalTab(
            title: "Active",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp/active")
        )
        let ownerTab = TerminalTab(
            title: "Owner",
            pane: TerminalPaneDescriptor(id: ownerPaneID, cwd: "/tmp/owner")
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let ownerWorkspace = Workspace(
            name: "Owner",
            tabs: [ownerTab],
            activeTabID: ownerTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [activeWorkspace, ownerWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let ownerSurface = try #require(coordinator.surfaceForTesting(id: ownerPaneID))
        let window = try #require(coordinator.activeWindowForTesting)

        persistence.reset()
        ownerSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let owner = try #require(store.workspace(id: ownerWorkspace.id))
        let replacementPaneID = try #require(owner.tabs.first?.activePaneID)
        let replacement = try #require(coordinator.surfaceForTesting(id: replacementPaneID))
        #expect(persistence.snapshots == [store])
        #expect(owner.tabs.count == 1)
        #expect(replacement.paneID != ownerSurface.paneID)
        #expect(coordinator.surfaceForTesting(id: activePaneID) === activeSurface)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(window.firstResponder === activeSurface)
    }

    @Test
    func finalProcessExitReplacesTabInTheActiveWorkspace() async throws {
        let firstWorkspace = Workspace(name: "First")
        let activeWorkspace = Workspace(name: "Active")
        let initialStore = try WorkspaceStore(
            workspaces: [firstWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: initialStore
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let replacementWorkspace = try #require(store.workspace(id: activeWorkspace.id))
        #expect(store.activeWorkspaceID == activeWorkspace.id)
        #expect(store.workspace(id: firstWorkspace.id)?.tabs.isEmpty == true)
        #expect(replacementWorkspace.tabs.count == 1)
        #expect(replacementWorkspace.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != exitedSurface.paneID)
    }

    @Test
    func startRestoresEverySavedPaneWithoutReplayingCommands() async throws {
        let authoredStore = try restoredWorkspaceStore(isBroadcasting: true)
        let savedStore = try JSONDecoder().decode(
            WorkspaceStore.self,
            from: JSONEncoder().encode(authoredStore)
        )
        let savedActiveWorkspace = try #require(
            savedStore.workspace(id: savedStore.activeWorkspaceID)
        )
        let savedActiveTabID = try #require(savedActiveWorkspace.activeTabID)
        let savedActiveTab = try #require(savedStore.tab(id: savedActiveTabID))
        let customPaneID = savedActiveTab.root.leaves[1]

        #expect(!savedActiveTab.isBroadcasting)
        #expect(
            savedActiveTab.paneDescriptor(for: customPaneID)?.startupCommand
                == .custom("printf should-not-run")
        )

        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(
                    workingDirectory: "/tmp/ignored",
                    command: "exec /bin/cat",
                    initialInput: "echo should-not-run\\n"
                ),
                initialWorkspaceStore: savedStore
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }

            try coordinator.start()
            await Task.yield()

            let expectedPaneIDs = Set(
                savedStore.workspaces.flatMap(\.tabs).flatMap { $0.root.leaves }
            )
            #expect(Set(coordinator.surfaceIDsForTesting) == expectedPaneIDs)
            #expect(Set(bridge.activeSurfaceIDs) == expectedPaneIDs)
            #expect(bridge.activeSurfaceCount == expectedPaneIDs.count)
            #expect(coordinator.workspaceStoreForTesting == savedStore)
            #expect(
                coordinator.workspaceStoreForTesting.activeWorkspaceID
                    == savedStore.activeWorkspaceID)
            #expect(
                coordinator.workspaceStoreForTesting.workspace(id: savedStore.activeWorkspaceID)?
                    .activeTabID == savedActiveTabID
            )
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: savedActiveTabID)?.activePaneID
                    == savedActiveTab.activePaneID
            )
            #expect(!coordinator.isBroadcastingActiveTab)
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: savedActiveTabID)?
                    .paneDescriptor(for: customPaneID)?.startupCommand
                    == .custom("printf should-not-run")
            )

            var expectedActiveSurfaceIdentities: [PaneID: ObjectIdentifier] = [:]
            for paneID in savedActiveTab.root.leaves {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                expectedActiveSurfaceIdentities[paneID] = ObjectIdentifier(surface)
            }
            #expect(
                coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                    == expectedActiveSurfaceIdentities
            )
            let activeSurface = try #require(coordinator.activeSurfaceForTesting)
            #expect(activeSurface.paneID == savedActiveTab.activePaneID)
            #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)

            for workspace in savedStore.workspaces {
                for tab in workspace.tabs {
                    for (leafIndex, paneID) in tab.root.leaves.enumerated() {
                        let descriptor = try #require(tab.paneDescriptor(for: paneID))
                        let configuration = try #require(
                            bridge.surfaceConfigurationForTesting(id: paneID)
                        )
                        #expect(configuration.workingDirectory == descriptor.cwd)
                        #expect(configuration.command == nil)
                        #expect(configuration.initialInput == nil)
                        #expect(
                            configuration.context
                                == (leafIndex == 0 ? .newTab : .split)
                        )
                    }
                }
            }

            var originalSurfaceIdentities: [PaneID: ObjectIdentifier] = [:]
            for paneID in expectedPaneIDs {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                originalSurfaceIdentities[paneID] = ObjectIdentifier(surface)
            }

            try coordinator.start()

            #expect(Set(coordinator.surfaceIDsForTesting) == expectedPaneIDs)
            #expect(bridge.activeSurfaceCount == expectedPaneIDs.count)
            for (paneID, identity) in originalSurfaceIdentities {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                #expect(ObjectIdentifier(surface) == identity)
            }
        }
    }

    @Test
    func startCreatesDefaultShellOnlyWhenEveryWorkspaceIsEmpty() async throws {
        let emptyBridge = try GhosttyBridge()
        defer { emptyBridge.shutdown() }

        do {
            let emptyCoordinator = WindowCoordinator(ghosttyBridge: emptyBridge)
            defer { emptyCoordinator.prepareForBridgeShutdownForTesting() }

            try emptyCoordinator.start()
            await Task.yield()

            let defaultStore = emptyCoordinator.workspaceStoreForTesting
            let defaultWorkspace = try #require(
                defaultStore.workspace(id: defaultStore.activeWorkspaceID)
            )
            let defaultTabID = try #require(defaultWorkspace.activeTabID)
            let defaultTab = try #require(defaultStore.tab(id: defaultTabID))
            let defaultSurface = try #require(emptyCoordinator.activeSurfaceForTesting)
            #expect(defaultWorkspace.tabs.count == 1)
            #expect(defaultTab.root.leaves == [defaultSurface.paneID])
            #expect(defaultTab.paneDescriptor(for: defaultSurface.paneID)?.startupCommand == .shell)
            #expect(emptyBridge.activeSurfaceIDs == [defaultSurface.paneID])
            #expect(
                emptyBridge.surfaceConfigurationForTesting(id: defaultSurface.paneID)?.context
                    == .window
            )
            #expect(emptyCoordinator.activeWindowForTesting?.firstResponder === defaultSurface)

            emptyCoordinator.createNewTab()

            let newTabSurface = try #require(emptyCoordinator.activeSurfaceForTesting)
            #expect(
                emptyBridge.surfaceConfigurationForTesting(id: newTabSurface.paneID)?.context
                    == .newTab
            )
        }

        let backgroundPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let emptyActiveWorkspace = Workspace(name: "Active Empty")
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let mixedStore = try WorkspaceStore(
            workspaces: [emptyActiveWorkspace, backgroundWorkspace],
            activeWorkspaceID: emptyActiveWorkspace.id
        )
        let mixedBridge = try GhosttyBridge()
        defer { mixedBridge.shutdown() }

        do {
            let mixedCoordinator = WindowCoordinator(
                ghosttyBridge: mixedBridge,
                initialWorkspaceStore: mixedStore
            )
            defer { mixedCoordinator.prepareForBridgeShutdownForTesting() }

            try mixedCoordinator.start()
            await Task.yield()

            #expect(mixedCoordinator.workspaceStoreForTesting == mixedStore)
            #expect(
                mixedCoordinator.workspaceStoreForTesting.activeWorkspaceID
                    == emptyActiveWorkspace.id)
            #expect(mixedCoordinator.activeSurfaceForTesting == nil)
            #expect(mixedCoordinator.surfaceIDsForTesting == [backgroundPaneID])
            #expect(mixedBridge.activeSurfaceIDs == [backgroundPaneID])
            #expect(
                mixedCoordinator.workspaceViewControllerForTesting
                    .hostedSurfaceIdentifiersForTesting
                    .isEmpty
            )
            #expect(
                mixedCoordinator.workspaceViewControllerForTesting
                    .emptyWorkspaceLabelIsVisibleForTesting)
        }
    }

    @Test
    func startupModelMutationFailureCanRetryOnceThenRemainsIdempotent() throws {
        let initialStore = WorkspaceStore()
        let expectedError = WorkspaceError.workspaceNotFound(initialStore.activeWorkspaceID)
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.failNextStartupModelMutationForTesting()

        #expect(throws: expectedError) {
            try coordinator.start()
        }

        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )

        try coordinator.start()

        let startedStore = coordinator.workspaceStoreForTesting
        let workspace = try #require(startedStore.workspace(id: startedStore.activeWorkspaceID))
        let tab = try #require(workspace.tabs.first)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let surfaceIdentity = ObjectIdentifier(surface)
        #expect(workspace.tabs.count == 1)
        #expect(tab.activePaneID == surface.paneID)
        #expect(surfaceIDs == [surface.paneID])
        #expect(bridge.activeSurfaceIDs == [surface.paneID])
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots == [startedStore])
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        try coordinator.start()

        #expect(coordinator.workspaceStoreForTesting == startedStore)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting.map(ObjectIdentifier.init) == surfaceIdentity)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots == [startedStore])
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.prepareForBridgeShutdownForTesting()
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func emptyStoreStartupKeepsCreatedModelAndPresentationWhenSurfaceCreationFails() throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup-failure",
                command: "exec /bin/cat",
                initialInput: "printf startup"
            ),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failNextSurfaceCreationForTesting()

        do {
            try coordinator.start()
        } catch {
            Issue.record("Expected a nonfatal startup surface failure, got \(error)")
        }

        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let tab = try #require(workspace.tabs.first)
        let paneID = try #require(tab.root.leaves.first)
        #expect(workspace.tabs.count == 1)
        #expect(tab.title == "Shell")
        #expect(tab.root == .pane(paneID))
        #expect(
            tab.paneDescriptor(for: paneID)
                == TerminalPaneDescriptor(
                    id: paneID,
                    cwd: "/tmp/startup-failure",
                    startupCommand: .custom("exec /bin/cat")
                )
        )
        #expect(persistence.snapshots == [store])
        #expect(persistence.snapshots.first?.tab(id: tab.id)?.activePaneID == paneID)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting == [paneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[paneID]
                == GhosttyBridgeError.surfaceCreationFailed(paneID).localizedDescription
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                != nil
        )
        #expect(
            !coordinator.workspaceViewControllerForTesting.emptyWorkspaceLabelIsVisibleForTesting
        )
        let window = try #require(coordinator.windowForTesting)
        #expect(window.isVisible)
        #expect(window.delegate === coordinator)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )

        let failureMessages = coordinator.surfaceFailureMessagesForTesting
        let persistedSnapshots = persistence.snapshots

        try coordinator.start()

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.activePaneID == paneID)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting == [paneID])
        #expect(coordinator.surfaceFailureMessagesForTesting == failureMessages)
        #expect(persistence.snapshots == persistedSnapshots)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func unavailablePaneActionRoutesRetryWithSameIdentity() throws {
        let paneID = PaneID()
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: "/tmp",
            startupCommand: .custom("printf should-not-run")
        )
        let tab = TerminalTab(title: "Unavailable", pane: descriptor)
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/ignored",
                command: "printf base-should-not-run",
                initialInput: "printf input-should-not-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: paneID)
        try coordinator.start()
        persistence.reset()

        coordinator.invokeRetryUnavailablePanePresentationCallbackForTesting(paneID)

        let surface = try #require(coordinator.surfaceForTesting(id: paneID))
        let configuration = try #require(bridge.surfaceConfigurationForTesting(id: paneID))
        #expect(surface.paneID == paneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == tab.root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?.paneDescriptor(for: paneID)
                == descriptor
        )
        #expect(coordinator.surfaceIDsForTesting == [paneID])
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(configuration.workingDirectory == descriptor.cwd)
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .newTab)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )
    }

    @Test
    func closeUnavailablePaneCollapsesSplitWithoutTouchingLiveSurfaceAndIsIdempotent() throws {
        let livePaneID = PaneID()
        let unavailablePaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.35,
            first: .pane(livePaneID),
            second: .pane(unavailablePaneID)
        )
        let tab = try TerminalTab(
            title: "Unavailable split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: livePaneID, cwd: "/tmp/live"),
                TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp/unavailable"),
            ],
            activePaneID: unavailablePaneID,
            isBroadcasting: true
        )
        let workspace = Workspace(name: "Split", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var snapshots: [WorkspaceStore] = []
        var closeDidBeginCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let liveSurface = try #require(coordinator.surfaceForTesting(id: livePaneID))
        let liveIdentity = ObjectIdentifier(liveSurface)
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.isBroadcasting == false)
        #expect(coordinator.surfaceForTesting(id: unavailablePaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting == [unavailablePaneID])
        snapshots = []
        coordinator.setCloseUnavailablePaneDidBeginHookForTesting { [weak coordinator] paneID in
            closeDidBeginCount += 1
            coordinator?.invokeCloseUnavailablePanePresentationCallbackForTesting(paneID)
        }

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingTab = try #require(resultingStore.tab(id: tab.id))
        #expect(closeDidBeginCount == 1)
        #expect(snapshots == [resultingStore])
        #expect(resultingTab.root == .pane(livePaneID))
        #expect(resultingTab.activePaneID == livePaneID)
        #expect(resultingTab.paneDescriptor(for: unavailablePaneID) == nil)
        #expect(!resultingTab.isBroadcasting)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [livePaneID])
        #expect(bridge.activeSurfaceIDs == [livePaneID])
        #expect(
            coordinator.surfaceForTesting(id: livePaneID).map(ObjectIdentifier.init)
                == liveIdentity
        )
        #expect(coordinator.activeSurfaceForTesting === liveSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === liveSurface)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)

        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        snapshots = []
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(livePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(PaneID())

        #expect(coordinator.workspaceStoreForTesting == resultingStore)
        #expect(snapshots.isEmpty)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
    }

    @Test
    func closeUnavailablePaneInvalidatesConfirmationBeforeCommitAndClearsFailureAfterCommit() throws
    {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Confirmations", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var dismissCount = 0
        var snapshots: [WorkspaceStore] = []
        var confirmationWasClearedDuringPersistence = false
        var failureWasPresentDuringPersistence = false
        weak var coordinatorReference: WindowCoordinator?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshot in
                snapshots.append(snapshot)
                confirmationWasClearedDuringPersistence =
                    coordinatorReference?.activeConfirmationForTesting == nil
                    && coordinatorReference?.pendingConfirmationCountForTesting == 0
                    && dismissCount == 1
                failureWasPresentDuringPersistence =
                    coordinatorReference?.surfaceFailureIDsForTesting == [unavailablePaneID]
            },
            confirmationPresenter: { _, _ in
                { dismissCount += 1 }
            }
        )
        coordinatorReference = coordinator
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        snapshots = []
        coordinator.enqueueCloseConfirmationForTesting(unavailablePaneID)
        #expect(coordinator.activeConfirmationForTesting == .close(unavailablePaneID))
        #expect(coordinator.pendingConfirmationCountForTesting == 0)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        #expect(dismissCount == 1)
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(coordinator.pendingConfirmationCountForTesting == 0)
        #expect(confirmationWasClearedDuringPersistence)
        #expect(failureWasPresentDuringPersistence)
        #expect(snapshots == [resultingStore])
        #expect(resultingStore.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
    }

    @Test
    func closeUnavailablePaneRebasesAfterConfirmationDismissalMutatesWorkspace() throws {
        let unavailablePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(
            name: "Reentrant confirmation",
            tabs: [unavailableTab],
            activeTabID: unavailableTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var snapshots: [WorkspaceStore] = []
        var dismissalDidCreateTab = false
        weak var coordinatorReference: WindowCoordinator?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshots.append($0) },
            confirmationPresenter: { _, _ in
                {
                    dismissalDidCreateTab = true
                    coordinatorReference?.createNewTab()
                }
            }
        )
        coordinatorReference = coordinator
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        snapshots = []
        coordinator.enqueueCloseConfirmationForTesting(unavailablePaneID)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        let createdTab = try #require(resultingWorkspace.tabs.first)
        let createdPaneID = createdTab.activePaneID
        let createdSurface = try #require(coordinator.surfaceForTesting(id: createdPaneID))
        #expect(dismissalDidCreateTab)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.workspace(id: workspace.id)?.tabs.count == 2)
        #expect(snapshots.first?.tab(id: unavailableTab.id) != nil)
        #expect(snapshots.last == resultingStore)
        #expect(resultingWorkspace.tabs.map(\.id) == [createdTab.id])
        #expect(resultingWorkspace.activeTabID == createdTab.id)
        #expect(resultingStore.tab(id: unavailableTab.id) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [createdPaneID])
        #expect(bridge.activeSurfaceIDs == [createdPaneID])
        #expect(coordinator.activeSurfaceForTesting === createdSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === createdSurface)
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(coordinator.pendingConfirmationCountForTesting == 0)
    }

    @Test
    func genericUnavailablePaneCloseCallbackClosesModelPaneWithoutFailureEntry() throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Generic unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Generic", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        coordinator.clearSurfaceFailureForTesting(unavailablePaneID)
        persistence.reset()
        #expect(coordinator.surfaceForTesting(id: unavailablePaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        #expect(resultingStore.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(persistence.snapshots == [resultingStore])
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func closeLastUnavailablePaneLeavesWorkspaceEmptyAndPhysicalWindowOpen(
        mode: PresentationMode
    ) throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Empty after close", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: mode,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let window = try #require(coordinator.activeWindowForTesting)
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.workspaces.map(\.id) == [workspace.id])
        #expect(resultingStore.activeWorkspaceID == workspace.id)
        #expect(resultingWorkspace.tabs.isEmpty)
        #expect(resultingWorkspace.activeTabID == nil)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
        #expect(coordinator.activeSurfaceForTesting == nil)
        #expect(coordinator.activeWindowForTesting === window)
        #expect(window.isVisible)
        #expect(errors.isEmpty)
    }

    @Test
    func closeUnavailablePaneInBackgroundKeepsVisibleWorkspaceTabAndFocus() throws {
        let unavailablePaneID = PaneID()
        let backgroundLivePaneID = PaneID()
        let visiblePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp/unavailable")
        )
        let backgroundLiveTab = TerminalTab(
            title: "Background live",
            pane: TerminalPaneDescriptor(id: backgroundLivePaneID, cwd: "/tmp/background")
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp/visible")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [unavailableTab, backgroundLiveTab],
            activeTabID: unavailableTab.id
        )
        let visibleWorkspace = Workspace(
            name: "Visible",
            tabs: [visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, visibleWorkspace],
            activeWorkspaceID: visibleWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let backgroundLiveSurface = try #require(
            coordinator.surfaceForTesting(id: backgroundLivePaneID)
        )
        let visibleSurface = try #require(coordinator.surfaceForTesting(id: visiblePaneID))
        let visibleFirstResponder = coordinator.activeWindowForTesting?.firstResponder
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingBackground = try #require(
            resultingStore.workspace(id: backgroundWorkspace.id)
        )
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.activeWorkspaceID == visibleWorkspace.id)
        #expect(resultingBackground.tabs.map(\.id) == [backgroundLiveTab.id])
        #expect(resultingBackground.activeTabID == backgroundLiveTab.id)
        #expect(
            resultingStore.workspace(id: visibleWorkspace.id)?.activeTabID == visibleTab.id
        )
        #expect(coordinator.activeSurfaceForTesting === visibleSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === visibleFirstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(
            Set(coordinator.surfaceIDsForTesting) == [backgroundLivePaneID, visiblePaneID]
        )
        #expect(Set(bridge.activeSurfaceIDs) == [backgroundLivePaneID, visiblePaneID])
        #expect(coordinator.surfaceForTesting(id: backgroundLivePaneID) === backgroundLiveSurface)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [visiblePaneID: ObjectIdentifier(visibleSurface)]
        )
    }

    @Test
    func closeUnavailablePaneInInactiveTabKeepsVisibleSelectionAndFocus() throws {
        let unavailablePaneID = PaneID()
        let visiblePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(
            name: "Active",
            tabs: [unavailableTab, visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let visibleSurface = try #require(coordinator.surfaceForTesting(id: visiblePaneID))
        let window = try #require(coordinator.activeWindowForTesting)
        _ = window.makeFirstResponder(nil)
        let firstResponder = window.firstResponder
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingWorkspace.tabs.map(\.id) == [visibleTab.id])
        #expect(resultingWorkspace.activeTabID == visibleTab.id)
        #expect(coordinator.activeSurfaceForTesting === visibleSurface)
        #expect(window.firstResponder === firstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [visiblePaneID])
        #expect(bridge.activeSurfaceIDs == [visiblePaneID])
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
    }

    @Test
    func retryFailurePreservesSplitRuntimeAndRetrySuccessUsesSavedShellConfiguration() throws {
        let siblingPaneID = PaneID()
        let unavailablePaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.35,
            first: .pane(siblingPaneID),
            second: .pane(unavailablePaneID)
        )
        let unavailableDescriptor = TerminalPaneDescriptor(
            id: unavailablePaneID,
            cwd: "/tmp",
            startupCommand: .custom("printf never-run")
        )
        let tab = try TerminalTab(
            title: "Retry split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: siblingPaneID, cwd: "/"),
                unavailableDescriptor,
            ],
            activePaneID: unavailablePaneID
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/var/empty",
                command: "printf base-never-run",
                initialInput: "printf input-never-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let siblingSurface = try #require(coordinator.surfaceForTesting(id: siblingPaneID))
        let siblingIdentity = ObjectIdentifier(siblingSurface)
        let failureMessage = try #require(
            coordinator.surfaceFailureMessagesForTesting[unavailablePaneID]
        )
        persistence.reset()

        bridge.failNextSurfaceCreationForTesting()
        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: unavailablePaneID) == unavailableDescriptor
        )
        #expect(coordinator.surfaceIDsForTesting == [siblingPaneID])
        #expect(bridge.activeSurfaceIDs == [siblingPaneID])
        #expect(
            coordinator.surfaceForTesting(id: siblingPaneID).map(ObjectIdentifier.init)
                == siblingIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting == [unavailablePaneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[unavailablePaneID]
                == GhosttyBridgeError.surfaceCreationFailed(unavailablePaneID)
                .localizedDescription
        )
        #expect(coordinator.surfaceFailureMessagesForTesting[unavailablePaneID] == failureMessage)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        let retriedSurface = try #require(
            coordinator.surfaceForTesting(id: unavailablePaneID)
        )
        let configuration = try #require(
            bridge.surfaceConfigurationForTesting(id: unavailablePaneID)
        )
        #expect(retriedSurface.paneID == unavailablePaneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: unavailablePaneID) == unavailableDescriptor
        )
        #expect(Set(coordinator.surfaceIDsForTesting) == [siblingPaneID, unavailablePaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [siblingPaneID, unavailablePaneID])
        #expect(
            coordinator.surfaceForTesting(id: siblingPaneID).map(ObjectIdentifier.init)
                == siblingIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(configuration.workingDirectory == unavailableDescriptor.cwd)
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .split)
        #expect(coordinator.activeSurfaceForTesting === retriedSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === retriedSurface)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 2
        )
    }

    @Test
    func retryInInactiveTabAndWorkspaceDoesNotChangeSelectionOrFocus() throws {
        let unavailablePaneID = PaneID()
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let backgroundTab = TerminalTab(
            title: "Background active",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let activeTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [unavailableTab, backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Visible",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let activeSurface = try #require(coordinator.surfaceForTesting(id: activePaneID))
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        let retriedSurface = try #require(
            coordinator.surfaceForTesting(id: unavailablePaneID)
        )
        #expect(retriedSurface.paneID == unavailablePaneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == activeWorkspace.id)
        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: backgroundWorkspace.id)?
                .activeTabID == backgroundTab.id
        )
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
    }

    @Test
    func retryAlreadyLiveDeletedAndUnknownPanesIsNoOp() throws {
        let deletedPaneID = PaneID()
        let livePaneID = PaneID()
        let deletedTab = TerminalTab(
            title: "Delete",
            pane: TerminalPaneDescriptor(id: deletedPaneID, cwd: "/tmp")
        )
        let liveTab = TerminalTab(
            title: "Live",
            pane: TerminalPaneDescriptor(id: livePaneID, cwd: "/tmp")
        )
        let deletedWorkspace = Workspace(
            name: "Delete",
            tabs: [deletedTab],
            activeTabID: deletedTab.id
        )
        let liveWorkspace = Workspace(
            name: "Live",
            tabs: [liveTab],
            activeTabID: liveTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [deletedWorkspace, liveWorkspace],
            activeWorkspaceID: deletedWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var deletionResponse: (@MainActor (Bool) -> Void)?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { _, completion in
                deletionResponse = completion
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: deletedPaneID)
        try coordinator.start()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let respondToDeletion = try #require(deletionResponse)
        respondToDeletion(true)
        let liveSurface = try #require(coordinator.surfaceForTesting(id: livePaneID))
        let resultingStore = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let bridgeSurfaceIDs = bridge.activeSurfaceIDs
        let liveIdentity = ObjectIdentifier(liveSurface)
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        persistence.reset()

        coordinator.retryUnavailablePaneForTesting(livePaneID)
        coordinator.retryUnavailablePaneForTesting(deletedPaneID)
        coordinator.retryUnavailablePaneForTesting(PaneID())

        #expect(coordinator.workspaceStoreForTesting == resultingStore)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == bridgeSurfaceIDs)
        #expect(
            coordinator.surfaceForTesting(id: livePaneID).map(ObjectIdentifier.init)
                == liveIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [false, true])
    func startKeepsSuccessfulSplitSurfaceAndFailedPaneDuringPartialRestore(
        isBroadcasting: Bool
    ) throws {
        let successfulPaneID = PaneID()
        let failingPaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(successfulPaneID),
            second: .pane(failingPaneID)
        )
        let tab = try TerminalTab(
            title: "Restored split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: successfulPaneID, cwd: "/tmp/success"),
                TerminalPaneDescriptor(id: failingPaneID, cwd: "/tmp/failure"),
            ],
            activePaneID: failingPaneID,
            isBroadcasting: isBroadcasting
        )
        let workspace = Workspace(name: "Restored", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/ignored",
                command: "printf should-not-run",
                initialInput: "printf should-not-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: failingPaneID)

        do {
            try coordinator.start()
        } catch {
            Issue.record("Expected a nonfatal restore surface failure, got \(error)")
        }

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingTab = try #require(resultingStore.tab(id: tab.id))
        let successfulSurface = try #require(
            coordinator.surfaceForTesting(id: successfulPaneID)
        )
        #expect(resultingTab.root == root)
        #expect(resultingTab.root.leaves == [successfulPaneID, failingPaneID])
        #expect(resultingTab.paneDescriptors == tab.paneDescriptors)
        #expect(!resultingTab.isBroadcasting)
        #expect(coordinator.surfaceIDsForTesting == [successfulPaneID])
        #expect(bridge.activeSurfaceIDs == [successfulPaneID])
        #expect(coordinator.surfaceForTesting(id: successfulPaneID) === successfulSurface)
        #expect(coordinator.surfaceForTesting(id: failingPaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting == [failingPaneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[failingPaneID]
                == GhosttyBridgeError.surfaceCreationFailed(failingPaneID).localizedDescription
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [successfulPaneID: ObjectIdentifier(successfulSurface)]
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                != nil
        )
        let configuration = try #require(
            bridge.surfaceConfigurationForTesting(id: successfulPaneID)
        )
        #expect(configuration.workingDirectory == "/tmp/success")
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .newTab)
        #expect(
            persistence.snapshots == (isBroadcasting ? [resultingStore] : [])
        )
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.prepareForBridgeShutdownForTesting()

        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func workspaceCreateAndRenameCommitOnceWithoutRecreatingLiveSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.new)
        let createSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        createSheet.submitForTesting(name: "Backend")

        let createdStore = coordinator.workspaceStoreForTesting
        let backend = try #require(createdStore.workspaces.last)
        let backendTab = try #require(backend.tabs.first)
        let backendSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(persistence.snapshots == [createdStore])
        #expect(createdStore.activeWorkspaceID == backend.id)
        #expect(backend.name == "Backend")
        #expect(backendTab.activePaneID == backendSurface.paneID)
        #expect(
            bridge.surfaceConfigurationForTesting(id: backendSurface.paneID)?.context == .newTab)
        #expect(coordinator.activeWindowForTesting?.firstResponder === backendSurface)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.rename)
        let renameSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        renameSheet.submitForTesting(name: "Services")

        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.workspace(id: backend.id)?.name == "Services")
        #expect(coordinator.activeSurfaceForTesting === backendSurface)
        #expect(coordinator.surfaceIDsForTesting.contains(backendSurface.paneID))

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onRenameWorkspace?()
        let noOpSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        noOpSheet.submitForTesting(name: "Services")
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.activeSurfaceForTesting === backendSurface)

        coordinator.workspaceViewControllerForTesting.onRenameWorkspace?()
        let invalidRenameSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        invalidRenameSheet.submitForTesting(name: "default")
        #expect(
            invalidRenameSheet.errorMessageForTesting
                == "A workspace with this name already exists.")
        invalidRenameSheet.submitForTesting(name: " \n")
        #expect(invalidRenameSheet.errorMessageForTesting == "Workspace name is required.")
        #expect(persistence.snapshots.isEmpty)
        invalidRenameSheet.cancelForTesting()
    }

    @Test
    func workspaceCreateRollsBackOnSurfaceFailureWithoutPersisting() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let beforeStore = coordinator.workspaceStoreForTesting
        let beforeSurfaceIDs = coordinator.surfaceIDsForTesting

        persistence.reset()
        bridge.failNextSurfaceCreationForTesting()
        coordinator.workspaceViewControllerForTesting.onCreateWorkspace?()
        let sheet = try #require(coordinator.createWorkspaceControllerForTesting)
        sheet.submitForTesting(name: "Broken")

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == beforeStore)
        #expect(coordinator.surfaceIDsForTesting == beforeSurfaceIDs)
        #expect(bridge.activeSurfaceIDs == beforeSurfaceIDs)
        #expect(!sheet.errorMessageForTesting.isEmpty)
    }

    @Test
    func workspaceDeletionAlertUsesExactCopyPluralizationAndButtons() {
        let singular = WindowCoordinator.makeWorkspaceDeletionAlert(
            WorkspaceDeletionConfirmation(
                workspaceID: WorkspaceID(),
                workspaceName: "Backend",
                tabCount: 1,
                paneCount: 1
            )
        )
        let plural = WindowCoordinator.makeWorkspaceDeletionAlert(
            WorkspaceDeletionConfirmation(
                workspaceID: WorkspaceID(),
                workspaceName: "Services",
                tabCount: 2,
                paneCount: 3
            )
        )

        #expect(singular.alertStyle == .warning)
        #expect(singular.messageText == "Delete Workspace?")
        #expect(
            singular.informativeText
                == "Backend contains 1 tab and 1 pane. All of its terminals will be closed.")
        #expect(
            plural.informativeText
                == "Services contains 2 tabs and 3 panes. All of its terminals will be closed.")
        #expect(singular.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(singular.buttons[0].hasDestructiveAction)
        #expect(singular.buttons[0].keyEquivalent == "\r")
        #expect(!singular.buttons[1].hasDestructiveAction)
        #expect(singular.buttons[1].keyEquivalent == "\u{1B}")
    }

    @Test
    func deletingMiddleActiveWorkspaceClosesOnlyItsSurfacesAndSelectsSuccessor() throws {
        let beforePaneID = PaneID()
        let deletedFirstPaneID = PaneID()
        let deletedSecondPaneID = PaneID()
        let afterPaneID = PaneID()
        let beforeTab = TerminalTab(
            title: "Before",
            pane: TerminalPaneDescriptor(id: beforePaneID, cwd: "/tmp/before")
        )
        let deletedTab = try TerminalTab(
            title: "Deleted",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(deletedFirstPaneID),
                second: .pane(deletedSecondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: deletedFirstPaneID, cwd: "/tmp/one"),
                TerminalPaneDescriptor(id: deletedSecondPaneID, cwd: "/tmp/two"),
            ],
            activePaneID: deletedSecondPaneID
        )
        let afterTab = TerminalTab(
            title: "After",
            pane: TerminalPaneDescriptor(id: afterPaneID, cwd: "/tmp/after")
        )
        let before = Workspace(name: "Before", tabs: [beforeTab], activeTabID: beforeTab.id)
        let deleted = Workspace(name: "Deleted", tabs: [deletedTab], activeTabID: deletedTab.id)
        let after = Workspace(name: "After", tabs: [afterTab], activeTabID: afterTab.id)
        let store = try WorkspaceStore(
            workspaces: [before, deleted, after],
            activeWorkspaceID: deleted.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: deletedSecondPaneID)
        let persistence = WorkspacePersistenceRecorder()
        var closePresentations: [GhosttyConfirmationPresentation] = []
        var closeDismissalCount = 0
        var deletionConfirmations: [WorkspaceDeletionConfirmation] = []
        var respondToDeletion: ((Bool) -> Void)?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            confirmationPresenter: { presentation, _ in
                closePresentations.append(presentation)
                return { closeDismissalCount += 1 }
            },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                deletionConfirmations.append(confirmation)
                respondToDeletion = completion
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let beforeSurface = try #require(coordinator.surfaceForTesting(id: beforePaneID))
        let afterSurface = try #require(coordinator.surfaceForTesting(id: afterPaneID))
        let deletedFailureMessage = try #require(
            coordinator.surfaceFailureMessagesForTesting[deletedSecondPaneID]
        )
        #expect(
            deletedFailureMessage
                == GhosttyBridgeError.surfaceCreationFailed(deletedSecondPaneID)
                .localizedDescription
        )

        persistence.reset()
        coordinator.surfaceDidRequestCloseForTesting(id: deletedFirstPaneID, processAlive: true)
        #expect(closePresentations == [.close(deletedFirstPaneID)])
        #expect(coordinator.activeConfirmationForTesting == .close(deletedFirstPaneID))

        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let deletionConfirmation = try #require(deletionConfirmations.first)
        #expect(deletionConfirmations.count == 1)
        #expect(deletionConfirmation.workspaceName == "Deleted")
        #expect(deletionConfirmation.tabCount == 1)
        #expect(deletionConfirmation.paneCount == 2)

        respondToDeletion?(true)

        let resultingStore = coordinator.workspaceStoreForTesting
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.workspaces.map(\.id) == [before.id, after.id])
        #expect(resultingStore.activeWorkspaceID == after.id)
        #expect(Set(coordinator.surfaceIDsForTesting) == [beforePaneID, afterPaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [beforePaneID, afterPaneID])
        #expect(coordinator.surfaceForTesting(id: beforePaneID) === beforeSurface)
        #expect(coordinator.surfaceForTesting(id: afterPaneID) === afterSurface)
        #expect(coordinator.surfaceForTesting(id: deletedFirstPaneID) == nil)
        #expect(coordinator.surfaceForTesting(id: deletedSecondPaneID) == nil)
        #expect(!coordinator.surfaceFailureIDsForTesting.contains(deletedSecondPaneID))
        #expect(coordinator.surfaceFailureMessagesForTesting[deletedSecondPaneID] == nil)
        #expect(coordinator.activeSurfaceForTesting === afterSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                == [ObjectIdentifier(afterSurface)]
        )
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(closeDismissalCount == 1)
        #expect(closeObservations == [deletedFirstPaneID])
        #expect(closeObservations.filter { $0 == deletedSecondPaneID }.isEmpty)
        #expect(closeObservations.filter { $0 == beforePaneID }.isEmpty)
        #expect(closeObservations.filter { $0 == afterPaneID }.isEmpty)

        coordinator.surfaceDidRequestCloseForTesting(id: deletedFirstPaneID, processAlive: false)
        coordinator.surfaceDidRequestCloseForTesting(id: deletedSecondPaneID, processAlive: false)
        #expect(persistence.snapshots == [resultingStore])
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(Set(coordinator.surfaceIDsForTesting) == [beforePaneID, afterPaneID])
    }

    @Test
    func cancellingNonemptyWorkspaceDeletionLeavesRuntimeStateUntouchedAndCanPresentAgain() throws {
        let backgroundPaneID = PaneID()
        let deletedPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let deletedTab = TerminalTab(
            title: "Deleted",
            pane: TerminalPaneDescriptor(id: deletedPaneID, cwd: "/tmp/deleted")
        )
        let background = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let deleted = Workspace(name: "Deleted", tabs: [deletedTab], activeTabID: deletedTab.id)
        let store = try WorkspaceStore(
            workspaces: [background, deleted],
            activeWorkspaceID: deleted.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var deletionConfirmations: [WorkspaceDeletionConfirmation] = []
        var deletionResponses: [(@MainActor (Bool) -> Void)] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                deletionConfirmations.append(confirmation)
                deletionResponses.append(completion)
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        let deletedSurface = try #require(coordinator.surfaceForTesting(id: deletedPaneID))
        let activeWindow = try #require(coordinator.activeWindowForTesting)
        let storeBeforeCancellation = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeCancellation = coordinator.surfaceIDsForTesting
        let bridgeSurfaceIDsBeforeCancellation = bridge.activeSurfaceIDs
        let closeObservationsBeforeCancellation = bridge
            .successfulSurfaceCloseObservationsForTesting

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let firstResponse = try #require(deletionResponses.first)
        #expect(
            deletionConfirmations == [
                WorkspaceDeletionConfirmation(
                    workspaceID: deleted.id,
                    workspaceName: "Deleted",
                    tabCount: 1,
                    paneCount: 1
                )
            ])

        firstResponse(false)

        #expect(coordinator.workspaceStoreForTesting == storeBeforeCancellation)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeCancellation)
        #expect(bridge.activeSurfaceIDs == bridgeSurfaceIDsBeforeCancellation)
        #expect(coordinator.surfaceForTesting(id: backgroundPaneID) === backgroundSurface)
        #expect(coordinator.surfaceForTesting(id: deletedPaneID) === deletedSurface)
        #expect(coordinator.activeSurfaceForTesting === deletedSurface)
        #expect(activeWindow.firstResponder === deletedSurface)
        #expect(persistence.snapshots.isEmpty)
        #expect(
            bridge.successfulSurfaceCloseObservationsForTesting
                == closeObservationsBeforeCancellation)

        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        #expect(deletionConfirmations.count == 2)
        let secondResponse = try #require(deletionResponses.last)
        secondResponse(false)
    }

    @Test
    func deletingTheOnlyWorkspaceIsDisabledAndDoesNotPersist() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.delete)

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting.workspaces.count == 1)
        #expect(
            !coordinator.workspaceViewControllerForTesting.workspaceSelector
                .isActionEnabledForTesting(.delete)
        )
    }

    @Test
    func deletingAnEmptyActiveWorkspaceCommitsOnceWithoutPresentingAnAlert() throws {
        let backgroundPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let background = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let empty = Workspace(name: "Empty")
        let store = try WorkspaceStore(
            workspaces: [background, empty],
            activeWorkspaceID: empty.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var alertCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { _, _ in
                alertCount += 1
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.delete)

        #expect(alertCount == 0)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.workspaces.map(\.id) == [background.id])
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == background.id)
        #expect(coordinator.surfaceIDsForTesting == [backgroundPaneID])
        #expect(coordinator.activeSurfaceForTesting?.paneID == backgroundPaneID)
    }

    private func restoredWorkspaceStore(isBroadcasting: Bool = false) throws -> WorkspaceStore {
        let backgroundFirstPaneID = PaneID()
        let backgroundSecondPaneID = PaneID()
        let backgroundTab = try TerminalTab(
            title: "Background split",
            root: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.3,
                first: .pane(backgroundFirstPaneID),
                second: .pane(backgroundSecondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: backgroundFirstPaneID, cwd: "/"),
                TerminalPaneDescriptor(id: backgroundSecondPaneID, cwd: "/usr"),
            ],
            activePaneID: backgroundSecondPaneID
        )
        let hiddenPaneID = PaneID()
        let hiddenTab = TerminalTab(
            title: "Hidden tab",
            pane: TerminalPaneDescriptor(id: hiddenPaneID, cwd: "/bin")
        )
        let activeFirstPaneID = PaneID()
        let activeSecondPaneID = PaneID()
        let activeThirdPaneID = PaneID()
        let activeTab = try TerminalTab(
            title: "Active nested split",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.6,
                first: .pane(activeFirstPaneID),
                second: .split(
                    id: UUID(),
                    axis: .vertical,
                    ratio: 0.4,
                    first: .pane(activeSecondPaneID),
                    second: .pane(activeThirdPaneID)
                )
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: activeFirstPaneID, cwd: "/System"),
                TerminalPaneDescriptor(
                    id: activeSecondPaneID,
                    cwd: "/private",
                    startupCommand: .custom("printf should-not-run")
                ),
                TerminalPaneDescriptor(id: activeThirdPaneID, cwd: "/tmp"),
            ],
            activePaneID: activeThirdPaneID,
            isBroadcasting: isBroadcasting
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [hiddenTab, activeTab],
            activeTabID: activeTab.id
        )
        return try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
    }

    private func activeTab(of coordinator: WindowCoordinator) -> TerminalTab {
        let store = coordinator.workspaceStoreForTesting
        let workspace = store.workspace(id: store.activeWorkspaceID)!
        return store.tab(id: workspace.activeTabID!)!
    }

    private func split(in root: SplitNode) -> (
        id: UUID,
        axis: SplitAxis,
        ratio: Double,
        first: SplitNode,
        second: SplitNode
    )? {
        guard case .split(let id, let axis, let ratio, let first, let second) = root else {
            return nil
        }
        return (id, axis, ratio, first, second)
    }

    private func ratio(in root: SplitNode, splitID: UUID) -> Double? {
        switch root {
        case .pane:
            return nil
        case .split(let id, _, let storedRatio, let first, let second):
            if id == splitID {
                return storedRatio
            }
            return ratio(in: first, splitID: splitID) ?? ratio(in: second, splitID: splitID)
        }
    }
}

@MainActor
private final class WorkspacePersistenceRecorder {
    var snapshots: [WorkspaceStore] = []

    func reset() {
        snapshots = []
    }

    func expectSingleFinalSnapshot(from coordinator: WindowCoordinator) {
        #expect(snapshots == [coordinator.workspaceStoreForPersistence])
    }
}
