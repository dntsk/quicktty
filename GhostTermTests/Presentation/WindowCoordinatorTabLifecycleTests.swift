import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WindowCoordinatorTabLifecycleTests {
    @Test
    func openConfigurationCreatesFocusedEditorTabWithQuotedPathAndLatestEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "GhostTerm Config's \(UUID().uuidString)",
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
        var initialConfig = GhostTermConfig()
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
            "exec \(editor) '\(configURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"

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
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.initialInput == nil)
        #expect(coordinator.activeWindowForTesting?.firstResponder === configSurface)
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
        coordinator.workspaceViewControllerForTesting.onReorderTabs?([secondTabID, firstTabID])
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.closeTabImmediatelyForTesting(secondTabID)
        persistence.expectSingleFinalSnapshot(from: coordinator)
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
        coordinator.workspaceViewControllerForTesting.onActivateWorkspace?(secondWorkspace.id)
        persistence.expectSingleFinalSnapshot(from: coordinator)
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
        coordinator.workspaceViewControllerForTesting.onReorderTabs?(orderedTabIDs)
        coordinator.workspaceViewControllerForTesting.onReorderTabs?([activeTabID])

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
                at: URL(fileURLWithPath: "/tmp/ghostterm-config"),
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
                at: URL(fileURLWithPath: "/tmp/ghostterm-config"),
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
            try coordinator.openConfiguration(at: URL(fileURLWithPath: "/tmp/ghostterm-config"))
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
    func explicitConfirmedFinalTabCloseIsIdempotentAndDoesNotCreateReplacement() throws {
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

        #expect(confirmationCount == 1)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting.workspaces.allSatisfy { $0.tabs.isEmpty })
        #expect(coordinator.activeSurfaceForTesting == nil)
        #expect(!window.isVisible)
        #expect(coordinator.windowForTesting === window)
        #expect(window.delegate === coordinator)
    }

    @Test
    func finalProcessExitCreatesOneReplacementAndIgnoresLateDuplicateClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            let replacement = try #require(coordinator.activeSurfaceForTesting)
            #expect(replacement.paneID != exitedSurface.paneID)
            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
            #expect(
                coordinator.workspaceStoreForTesting.workspaces.flatMap(\.tabs).map(\.activePaneID)
                    == [replacement.paneID]
            )

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
        }
    }

    @Test
    func finalProcessExitReportsReplacementCreationFailureWithoutClosingCoordinator() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

        bridge.failNextSurfaceCreationForTesting()
        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        #expect(!exitedSurface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting.workspaces.allSatisfy { $0.tabs.isEmpty })
        #expect(errors.count == 1)
        let error = try #require(errors.first as? GhosttyBridgeError)
        guard case .surfaceCreationFailed(let failedPaneID) = error else {
            Issue.record("Expected a surface creation failure, got \(error)")
            return
        }
        #expect(failedPaneID != exitedSurface.paneID)
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
    func workspacePersistenceTracksLiveCWDForActiveBackgroundAndStalePanes() async throws {
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

        #expect(persistence.snapshots.isEmpty)
        let activeSurface = try #require(coordinator.surfaceForTesting(id: activePaneID))
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        #expect(activeSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/active-live"))
        await Task.yield()

        let activeDescriptor = try #require(
            coordinator.workspaceStoreForPersistence.tab(id: activeTab.id)?
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
            coordinator.workspaceStoreForPersistence.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == backgroundTab.paneDescriptor(for: backgroundPaneID)
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForPersistence])
        persistence.reset()

        #expect(backgroundSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/background-live"))
        await Task.yield()

        #expect(
            coordinator.workspaceStoreForPersistence.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == TerminalPaneDescriptor(
                    id: backgroundPaneID,
                    cwd: "/tmp/background-live",
                    startupCommand: .custom("printf background")
                )
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForPersistence])
        persistence.reset()

        #expect(activeSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/active-live"))
        await Task.yield()
        #expect(activeSurface.scheduleWorkingDirectoryChangeForTesting("relative"))
        await Task.yield()
        #expect(activeSurface.currentWorkingDirectory == "relative")
        #expect(activeSurface.scheduleWorkingDirectoryChangeForTesting(""))
        await Task.yield()
        #expect(activeSurface.currentWorkingDirectory == "")
        #expect(persistence.snapshots.isEmpty)

        #expect(activeSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/stale"))
        bridge.closeSurface(id: activePaneID)
        await Task.yield()

        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceStoreForPersistence.tab(id: activeTab.id)?
                .paneDescriptor(for: activePaneID)
                == activeDescriptor
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
    func startRollsBackEveryCreatedSurfaceWhenRestorationFails() throws {
        let store = try restoredWorkspaceStore()
        let failingPaneID = try #require(
            store.workspaces.first?.tabs.first?.root.leaves.dropFirst().first
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                initialWorkspaceStore: store
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            bridge.failSurfaceCreationForTesting(id: failingPaneID)

            do {
                try coordinator.start()
                Issue.record("Expected restoration to fail")
            } catch let error as GhosttyBridgeError {
                #expect(error == .surfaceCreationFailed(failingPaneID))
            }

            #expect(bridge.activeSurfaceIDs.isEmpty)
            #expect(coordinator.surfaceIDsForTesting.isEmpty)
            #expect(coordinator.workspaceStoreForTesting == store)
        }
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
