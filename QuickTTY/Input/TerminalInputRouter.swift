struct TerminalInputRouter {
    static func targetPaneIDs(
        for action: TerminalShortcutAction,
        sourcePaneID: PaneID,
        broadcastPaneIDs: [PaneID]
    ) -> [PaneID] {
        guard action == .paste || action == .pasteSelection else {
            return [sourcePaneID]
        }

        var seen = Set<PaneID>()
        var targets = broadcastPaneIDs.filter { seen.insert($0).inserted }
        if seen.insert(sourcePaneID).inserted {
            targets.insert(sourcePaneID, at: 0)
        }
        return targets
    }

    static func targetPaneIDs(
        in workspaceStore: WorkspaceStore,
        sourcePaneID: PaneID
    ) -> [PaneID] {
        guard
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID),
            let activeTabID = workspace.activeTabID,
            let activeTab = workspaceStore.tab(id: activeTabID),
            activeTab.root.contains(sourcePaneID),
            activeTab.isBroadcasting
        else {
            return [sourcePaneID]
        }

        var seen = Set<PaneID>()
        return activeTab.root.leaves.filter { seen.insert($0).inserted }
    }
}
