enum WorkspaceError: Error, Equatable, Sendable {
    case emptyWorkspaceName
    case duplicateWorkspaceName
    case duplicateWorkspaceID(WorkspaceID)
    case workspaceNotFound(WorkspaceID)
    case tabNotFound(TabID)
    case tabAlreadyOwned(TabID)
    case paneAlreadyOwned(PaneID)
    case invalidTabSnapshot(TabID)
    case tabNotInWorkspace(tabID: TabID, workspaceID: WorkspaceID)
    case invalidActiveTab(workspaceID: WorkspaceID, tabID: TabID)
    case invalidBroadcastTarget(workspaceID: WorkspaceID, tabID: TabID)
}
