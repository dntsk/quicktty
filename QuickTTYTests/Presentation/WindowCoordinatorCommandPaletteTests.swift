import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct WindowCoordinatorCommandPaletteTests {
    @Test
    func paletteContainsEveryWorkspaceAndTabAndActivatesCrossWorkspaceTabAtomically() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let fixture = try makeStore()
        var snapshots: [WorkspaceStore] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "/bin/cat"),
            initialWorkspaceStore: fixture.store,
            persistWorkspaceStore: { snapshots.append($0) }
        )
        defer { coordinator.prepareForApplicationTermination() }
        var performedCommands: [CommandPaletteCommandID] = []
        coordinator.installCommandPalette(
            shortcutConfiguration: { .defaults },
            performCommand: { performedCommands.append($0) }
        )
        try coordinator.start()
        let surfaceIDs = coordinator.surfaceIDsForTesting

        let items = coordinator.commandPaletteItemsForTesting
        #expect(items.filter { $0.category == .workspaces }.count == 2)
        #expect(items.filter { $0.category == .tabs }.count == 2)
        #expect(
            items.contains {
                $0.id == .tab(fixture.secondTab.id)
                    && $0.title == "Backend Tab"
                    && $0.subtitle == "Backend"
            }
        )

        snapshots.removeAll()
        coordinator.executeCommandPaletteTargetForTesting(
            .tab(workspaceID: fixture.secondWorkspaceID, tabID: fixture.secondTab.id)
        )

        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == fixture.secondWorkspaceID)
        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: fixture.secondWorkspaceID)?
                .activeTabID
                == fixture.secondTab.id
        )
        #expect(snapshots.count == 1)
        #expect(Set(coordinator.surfaceIDsForTesting) == Set(surfaceIDs))
        #expect(performedCommands.isEmpty)
    }

    @Test
    func paletteRevalidatesDisabledCommandsAndStaleDestinations() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        defer { coordinator.prepareForApplicationTermination() }
        var performedCommands: [CommandPaletteCommandID] = []
        coordinator.installCommandPalette(
            shortcutConfiguration: { .defaults },
            performCommand: { performedCommands.append($0) }
        )
        try coordinator.start()
        let before = coordinator.workspaceStoreForTesting

        let zoom = try #require(
            coordinator.commandPaletteItemsForTesting.first { $0.id == .command(.togglePaneZoom) }
        )
        #expect(zoom.availability == .disabled(reason: "Requires multiple panes"))
        coordinator.executeCommandPaletteTargetForTesting(.command(.togglePaneZoom))
        coordinator.executeCommandPaletteTargetForTesting(
            .tab(workspaceID: WorkspaceID(), tabID: TabID())
        )

        #expect(performedCommands.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == before)
    }

    @Test
    func paletteTogglePreservesSurfaceIdentityAndSecondToggleDismisses() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        defer { coordinator.prepareForApplicationTermination() }
        coordinator.installCommandPalette(
            shortcutConfiguration: { .defaults },
            performCommand: { _ in }
        )
        try coordinator.start()
        let surfaces = coordinator.surfaceIDsForTesting

        coordinator.toggleCommandPalette()
        #expect(coordinator.isCommandPalettePresented)
        #expect(coordinator.surfaceIDsForTesting == surfaces)

        coordinator.toggleCommandPalette()
        #expect(!coordinator.isCommandPalettePresented)
        #expect(coordinator.surfaceIDsForTesting == surfaces)
    }

    private func makeStore() throws -> (
        store: WorkspaceStore,
        secondWorkspaceID: WorkspaceID,
        secondTab: TerminalTab
    ) {
        var store = WorkspaceStore()
        let firstWorkspaceID = store.activeWorkspaceID
        let firstTab = TerminalTab(
            title: "Frontend Tab",
            pane: TerminalPaneDescriptor(id: PaneID(), cwd: "/tmp")
        )
        try store.addTab(firstTab, to: firstWorkspaceID)
        try store.activateTab(firstTab.id, in: firstWorkspaceID)

        let secondWorkspaceID = try store.createWorkspace(named: "Backend")
        let secondTab = TerminalTab(
            title: "Backend Tab",
            pane: TerminalPaneDescriptor(id: PaneID(), cwd: "/tmp")
        )
        try store.addTab(secondTab, to: secondWorkspaceID)
        try store.activateTab(secondTab.id, in: secondWorkspaceID)
        try store.activateWorkspace(firstWorkspaceID)
        return (store, secondWorkspaceID, secondTab)
    }
}
