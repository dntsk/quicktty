import Foundation

enum SplitFocusDirection: String, Codable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

enum SplitCommand: Equatable, Sendable {
    case split(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        axis: SplitAxis,
        newPane: TerminalPaneDescriptor,
        ratio: Double
    )
    case closePane(workspaceID: WorkspaceID, tabID: TabID, paneID: PaneID)
    case updateRatio(
        workspaceID: WorkspaceID,
        tabID: TabID,
        splitID: UUID,
        ratio: Double
    )
    case equalize(workspaceID: WorkspaceID, tabID: TabID)
    case focusNext(workspaceID: WorkspaceID, tabID: TabID, from: PaneID)
    case focusPrevious(workspaceID: WorkspaceID, tabID: TabID, from: PaneID)
    case focus(
        workspaceID: WorkspaceID,
        tabID: TabID,
        from: PaneID,
        direction: SplitFocusDirection
    )
}

enum SplitDelta: Equatable, Sendable {
    case paneSplit(
        workspaceID: WorkspaceID,
        tabID: TabID,
        splitID: UUID,
        sourcePaneID: PaneID,
        newPane: TerminalPaneDescriptor,
        axis: SplitAxis,
        ratio: Double,
        root: SplitNode,
        activePaneID: PaneID
    )
    case paneClosed(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        root: SplitNode,
        activePaneID: PaneID
    )
    case tabClosed(
        workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        activeTabID: TabID?
    )
    case ratioUpdated(
        workspaceID: WorkspaceID,
        tabID: TabID,
        splitID: UUID,
        ratio: Double,
        root: SplitNode
    )
    case splitsEqualized(
        workspaceID: WorkspaceID,
        tabID: TabID,
        splitIDs: [UUID],
        root: SplitNode
    )
    case focusChanged(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sourcePaneID: PaneID,
        activePaneID: PaneID
    )
}

enum SplitCoordinatorError: Error, Equatable, Sendable {
    case workspaceNotFound(WorkspaceID)
    case tabNotFound(TabID)
    case tabNotInWorkspace(tabID: TabID, workspaceID: WorkspaceID)
    case paneNotFound(PaneID)
    case splitNotFound(UUID)
    case paneAlreadyExists(PaneID)
    case tabMutationFailed(TerminalTabError)
    case workspaceMutationFailed(WorkspaceError)
}
