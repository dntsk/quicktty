enum WorkspaceError: Error, Equatable, Sendable {
    case emptyWorkspaceName
    case duplicateWorkspaceName
    case duplicateWorkspaceID(WorkspaceID)
    case workspaceNotFound(WorkspaceID)
    case cannotDeleteLastWorkspace
    case invalidTabOrder(workspaceID: WorkspaceID)
    case paneNotFound(PaneID)
    case invalidWorkingDirectory(String)
    case tabNotFound(TabID)
    case tabAlreadyOwned(TabID)
    case paneAlreadyOwned(PaneID)
    case invalidTabSnapshot(TabID)
    case tabNotInWorkspace(tabID: TabID, workspaceID: WorkspaceID)
    case invalidActiveTab(workspaceID: WorkspaceID, tabID: TabID)
    case invalidBroadcastTarget(workspaceID: WorkspaceID, tabID: TabID)
}
