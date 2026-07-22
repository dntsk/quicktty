struct TerminalInputRouter {
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
