import Foundation
import Testing

@testable import GhostTerm

struct TerminalInputRouterTests {
    @Test
    func broadcastingOffRoutesOnlySource() throws {
        let fixture = try Fixture()

        #expect(
            TerminalInputRouter.targetPaneIDs(in: fixture.store, sourcePaneID: fixture.secondPane)
                == [fixture.secondPane]
        )
    }

    @Test
    func broadcastingRoutesNestedLeavesInTreeOrderFromAnyActiveTabPane() throws {
        var fixture = try Fixture()
        try fixture.store.setBroadcasting(
            true, for: fixture.activeTab.id, in: fixture.activeWorkspace.id)

        #expect(
            TerminalInputRouter.targetPaneIDs(in: fixture.store, sourcePaneID: fixture.thirdPane)
                == [fixture.firstPane, fixture.secondPane, fixture.thirdPane]
        )
    }

    @Test
    func sourceInOtherTabOrWorkspaceRemainsSourceOnlyWhileBroadcasting() throws {
        var fixture = try Fixture()
        try fixture.store.setBroadcasting(
            true, for: fixture.activeTab.id, in: fixture.activeWorkspace.id)

        #expect(
            TerminalInputRouter.targetPaneIDs(in: fixture.store, sourcePaneID: fixture.otherTabPane)
                == [fixture.otherTabPane]
        )
        #expect(
            TerminalInputRouter.targetPaneIDs(
                in: fixture.store, sourcePaneID: fixture.otherWorkspacePane)
                == [fixture.otherWorkspacePane]
        )
    }

    @Test
    func staleSourceRemainsSourceOnlyWhileBroadcasting() throws {
        var fixture = try Fixture()
        try fixture.store.setBroadcasting(
            true, for: fixture.activeTab.id, in: fixture.activeWorkspace.id)
        let stalePane = PaneID()

        #expect(
            TerminalInputRouter.targetPaneIDs(in: fixture.store, sourcePaneID: stalePane) == [
                stalePane
            ]
        )
    }

    private struct Fixture {
        let activeWorkspace: Workspace
        let activeTab: TerminalTab
        let firstPane: PaneID
        let secondPane: PaneID
        let thirdPane: PaneID
        let otherTabPane: PaneID
        let otherWorkspacePane: PaneID
        var store: WorkspaceStore

        init() throws {
            firstPane = PaneID()
            secondPane = PaneID()
            thirdPane = PaneID()
            otherTabPane = PaneID()
            otherWorkspacePane = PaneID()
            let root = SplitNode.split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(firstPane),
                second: .split(
                    id: UUID(),
                    axis: .vertical,
                    ratio: 0.5,
                    first: .pane(secondPane),
                    second: .pane(thirdPane)
                )
            )
            activeTab = try TerminalTab(
                title: "Active",
                root: root,
                paneDescriptors: [firstPane, secondPane, thirdPane].map {
                    TerminalPaneDescriptor(id: $0, cwd: "/tmp")
                },
                activePaneID: secondPane
            )
            let otherTab = TerminalTab(
                title: "Other tab",
                pane: TerminalPaneDescriptor(id: otherTabPane, cwd: "/tmp")
            )
            activeWorkspace = Workspace(
                name: "Active",
                tabs: [activeTab, otherTab],
                activeTabID: activeTab.id
            )
            let otherWorkspace = Workspace(
                name: "Other workspace",
                tabs: [
                    TerminalTab(
                        title: "Other workspace tab",
                        pane: TerminalPaneDescriptor(id: otherWorkspacePane, cwd: "/tmp")
                    )
                ]
            )
            store = try WorkspaceStore(
                workspaces: [activeWorkspace, otherWorkspace],
                activeWorkspaceID: activeWorkspace.id
            )
        }
    }
}
