import Foundation
import Testing

@testable import GhostTerm

struct BroadcastSemanticsTests {
    @Test
    func closingRememberedActiveTabInBackgroundPreservesForegroundBroadcast() throws {
        let foregroundWorkspaceID = workspaceID(1)
        let backgroundWorkspaceID = workspaceID(2)
        let foregroundTab = makeTab(1)
        let backgroundActiveTab = makeTab(2)
        let backgroundNextTab = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: foregroundWorkspaceID,
                    name: "Foreground",
                    tabs: [foregroundTab]
                ),
                Workspace(
                    id: backgroundWorkspaceID,
                    name: "Background",
                    tabs: [backgroundActiveTab, backgroundNextTab],
                    activeTabID: backgroundActiveTab.id
                ),
            ],
            activeWorkspaceID: foregroundWorkspaceID
        )
        try store.setBroadcasting(true, for: foregroundTab.id, in: foregroundWorkspaceID)

        _ = try store.closeTab(backgroundActiveTab.id, in: backgroundWorkspaceID)

        #expect(store.tab(id: foregroundTab.id)?.isBroadcasting == true)
        #expect(store.workspace(id: backgroundWorkspaceID)?.activeTabID == backgroundNextTab.id)
    }

    @Test
    func activatingRememberedTabInBackgroundPreservesForegroundBroadcast() throws {
        let foregroundWorkspaceID = workspaceID(1)
        let backgroundWorkspaceID = workspaceID(2)
        let foregroundTab = makeTab(1)
        let backgroundFirstTab = makeTab(2)
        let backgroundSecondTab = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: foregroundWorkspaceID,
                    name: "Foreground",
                    tabs: [foregroundTab]
                ),
                Workspace(
                    id: backgroundWorkspaceID,
                    name: "Background",
                    tabs: [backgroundFirstTab, backgroundSecondTab],
                    activeTabID: backgroundFirstTab.id
                ),
            ],
            activeWorkspaceID: foregroundWorkspaceID
        )
        try store.setBroadcasting(true, for: foregroundTab.id, in: foregroundWorkspaceID)

        try store.activateTab(backgroundSecondTab.id, in: backgroundWorkspaceID)

        #expect(store.tab(id: foregroundTab.id)?.isBroadcasting == true)
        #expect(store.workspace(id: backgroundWorkspaceID)?.activeTabID == backgroundSecondTab.id)
    }

    @Test
    func closingNonactiveForegroundTabPreservesBroadcastButClosingActiveResetsIt() throws {
        let workspaceID = workspaceID(1)
        let activeTab = makeTab(1)
        let nonactiveTab = makeTab(2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: "Default",
                    tabs: [activeTab, nonactiveTab],
                    activeTabID: activeTab.id
                )
            ],
            activeWorkspaceID: workspaceID
        )
        try store.setBroadcasting(true, for: activeTab.id, in: workspaceID)

        _ = try store.closeTab(nonactiveTab.id, in: workspaceID)
        #expect(store.tab(id: activeTab.id)?.isBroadcasting == true)

        let removed = try store.closeTab(activeTab.id, in: workspaceID)
        #expect(removed.isBroadcasting == false)
    }

    @Test
    func moveReturnsPostResetTabsWhenVisibleSelectionChanges() throws {
        let sourceWorkspaceID = workspaceID(1)
        let destinationWorkspaceID = workspaceID(2)
        let movedTab = makeTab(1)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: sourceWorkspaceID, name: "Source", tabs: [movedTab]),
                Workspace(id: destinationWorkspaceID, name: "Destination"),
            ],
            activeWorkspaceID: sourceWorkspaceID
        )
        try store.setBroadcasting(true, for: movedTab.id, in: sourceWorkspaceID)

        let moved = try store.moveTabs(
            [movedTab.id],
            from: sourceWorkspaceID,
            to: destinationWorkspaceID
        )

        #expect(moved.count == 1)
        #expect(moved[0].isBroadcasting == false)
        #expect(store.tab(id: movedTab.id)?.isBroadcasting == false)
        #expect(moved[0].root == movedTab.root)
        #expect(moved[0].paneDescriptors == movedTab.paneDescriptors)
    }

    @Test
    func sameVisibleMoveSelectionDoesNotResetBroadcast() throws {
        let workspaceID = workspaceID(1)
        let activeTab = makeTab(1)
        let otherTab = makeTab(2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: "Default",
                    tabs: [activeTab, otherTab],
                    activeTabID: activeTab.id
                )
            ],
            activeWorkspaceID: workspaceID
        )
        try store.setBroadcasting(true, for: activeTab.id, in: workspaceID)

        let moved = try store.moveTabs(
            [activeTab.id],
            from: workspaceID,
            to: workspaceID
        )

        #expect(store.tab(id: activeTab.id)?.isBroadcasting == true)
        #expect(moved.first?.isBroadcasting == true)
    }

    private func makeTab(_ value: Int) -> TerminalTab {
        let paneID = PaneID(rawValue: uuid(value))
        return TerminalTab(
            id: TabID(rawValue: uuid(1_000 + value)),
            title: "Tab \(value)",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp/tab-\(value)")
        )
    }

    private func workspaceID(_ value: Int) -> WorkspaceID {
        WorkspaceID(rawValue: uuid(2_000 + value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
