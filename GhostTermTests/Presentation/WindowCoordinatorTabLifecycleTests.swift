import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WindowCoordinatorTabLifecycleTests {
    @Test
    func createsDistinctLiveSurfacesAndSwitchesBetweenThem() throws {
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

            coordinator.activateTabForTesting(firstTabID)
            #expect(coordinator.activeSurfaceForTesting === firstSurface)
            #expect(firstSurface.isActive)
            #expect(secondSurface.isActive)

            coordinator.activateTabForTesting(secondTabID)
            #expect(coordinator.activeSurfaceForTesting === secondSurface)
        }
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
}
