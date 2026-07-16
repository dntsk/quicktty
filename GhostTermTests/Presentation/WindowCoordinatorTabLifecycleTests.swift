import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WindowCoordinatorTabLifecycleTests {
    @Test
    func createsDistinctLiveSurfacesAndSwitchesBetweenThem() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
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
    func splitActivePaneRollsBackCreatedSurfaceAndStoreWhenCandidateMutationFails() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
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
