import Foundation

struct WorkspaceStore: Codable, Equatable, Sendable {
    private(set) var workspaces: [Workspace]
    private(set) var activeWorkspaceID: WorkspaceID

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case activeWorkspaceID
    }

    init() {
        let workspace = Self.makeDefaultWorkspace()
        workspaces = [workspace]
        activeWorkspaceID = workspace.id
    }

    init(
        workspaces: [Workspace],
        activeWorkspaceID: WorkspaceID? = nil
    ) throws {
        guard !workspaces.isEmpty else {
            let workspace = Self.makeDefaultWorkspace()
            self.workspaces = [workspace]
            self.activeWorkspaceID = workspace.id
            return
        }

        try Self.validateSnapshot(workspaces)
        var normalizedWorkspaces = workspaces
        Self.normalizeActiveTabIDs(in: &normalizedWorkspaces)
        let normalizedActiveWorkspaceID =
            activeWorkspaceID.flatMap { candidate in
                normalizedWorkspaces.contains(where: { $0.id == candidate }) ? candidate : nil
            } ?? normalizedWorkspaces[0].id

        self.workspaces = normalizedWorkspaces
        self.activeWorkspaceID = normalizedActiveWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedWorkspaces = try container.decode(
            [Workspace].self,
            forKey: .workspaces
        )
        let decodedActiveWorkspaceID = try container.decodeIfPresent(
            WorkspaceID.self,
            forKey: .activeWorkspaceID
        )

        try self.init(
            workspaces: decodedWorkspaces,
            activeWorkspaceID: decodedActiveWorkspaceID
        )
    }

    func encode(to encoder: Encoder) throws {
        try Self.validateSnapshot(workspaces)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(activeWorkspaceID, forKey: .activeWorkspaceID)
    }

    func workspace(id: WorkspaceID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func tab(id: TabID) -> TerminalTab? {
        for workspace in workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    func mappingPaneDescriptors(
        _ transform: (TerminalPaneDescriptor) -> TerminalPaneDescriptor
    ) throws -> WorkspaceStore {
        var mappedWorkspaces = workspaces
        for workspaceIndex in mappedWorkspaces.indices {
            for tabIndex in mappedWorkspaces[workspaceIndex].tabs.indices {
                mappedWorkspaces[workspaceIndex].tabs[tabIndex] = try mappedWorkspaces[
                    workspaceIndex
                ].tabs[tabIndex].mappingPaneDescriptors(transform)
            }
        }
        return try WorkspaceStore(
            workspaces: mappedWorkspaces,
            activeWorkspaceID: activeWorkspaceID
        )
    }

    @discardableResult
    mutating func createWorkspace(named name: String) throws -> WorkspaceID {
        let trimmedName = try validatedName(name)
        let workspace = Workspace(name: trimmedName)
        workspaces.append(workspace)
        return workspace.id
    }

    mutating func renameWorkspace(_ workspaceID: WorkspaceID, to name: String) throws {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        let trimmedName = try validatedName(name, excluding: workspaceID)
        workspaces[workspaceIndex].rename(to: trimmedName)
    }

    @discardableResult
    mutating func deleteWorkspace(_ workspaceID: WorkspaceID) throws -> Workspace {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard workspaces.count > 1 else {
            throw WorkspaceError.cannotDeleteLastWorkspace
        }

        if workspaceID == activeWorkspaceID {
            resetVisibleBroadcasting()
        }
        let removedWorkspace = workspaces.remove(at: workspaceIndex)
        if workspaceID == activeWorkspaceID {
            activeWorkspaceID = workspaces[min(workspaceIndex, workspaces.count - 1)].id
        }
        return removedWorkspace
    }

    mutating func reorderTabs(_ orderedTabIDs: [TabID], in workspaceID: WorkspaceID) throws {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }

        let currentTabs = workspaces[workspaceIndex].tabs
        let currentTabIDs = currentTabs.map(\.id)
        let orderedTabIDSet = Set(orderedTabIDs)
        guard orderedTabIDs.count == currentTabIDs.count,
            orderedTabIDSet.count == orderedTabIDs.count,
            orderedTabIDSet == Set(currentTabIDs)
        else {
            throw WorkspaceError.invalidTabOrder(workspaceID: workspaceID)
        }
        guard orderedTabIDs != currentTabIDs else { return }

        workspaces[workspaceIndex].tabs = orderedTabIDs.compactMap { orderedTabID in
            currentTabs.first { $0.id == orderedTabID }
        }
    }

    mutating func updateWorkingDirectory(_ cwd: String, for paneID: PaneID) throws {
        guard let location = paneDescriptorLocation(for: paneID) else {
            throw WorkspaceError.paneNotFound(paneID)
        }
        guard !cwd.isEmpty, (cwd as NSString).isAbsolutePath else {
            throw WorkspaceError.invalidWorkingDirectory(cwd)
        }

        _ = workspaces[location.workspaceIndex].tabs[location.tabIndex]
            .updateWorkingDirectory(cwd, for: paneID)
    }

    mutating func addTab(_ tab: TerminalTab, to workspaceID: WorkspaceID) throws {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard owner(of: tab.id) == nil else {
            throw WorkspaceError.tabAlreadyOwned(tab.id)
        }
        do {
            try tab.validateInvariant()
        } catch is TerminalTabError {
            throw WorkspaceError.invalidTabSnapshot(tab.id)
        }
        if let ownedPaneID = tab.root.leaves.first(where: { owns(paneID: $0) }) {
            throw WorkspaceError.paneAlreadyOwned(ownedPaneID)
        }

        workspaces[workspaceIndex].tabs.append(tab)
        if workspaces[workspaceIndex].activeTabID == nil {
            workspaces[workspaceIndex].activeTabID = tab.id
        }
    }

    @discardableResult
    mutating func moveTabs(
        _ tabIDs: [TabID],
        from sourceWorkspaceID: WorkspaceID,
        to destinationWorkspaceID: WorkspaceID
    ) throws -> [TerminalTab] {
        guard let sourceIndex = index(of: sourceWorkspaceID) else {
            throw WorkspaceError.workspaceNotFound(sourceWorkspaceID)
        }
        guard let destinationIndex = index(of: destinationWorkspaceID) else {
            throw WorkspaceError.workspaceNotFound(destinationWorkspaceID)
        }

        var selectedIDs = Set<TabID>()
        for tabID in tabIDs where selectedIDs.insert(tabID).inserted {
            guard let ownerID = owner(of: tabID) else {
                throw WorkspaceError.tabNotFound(tabID)
            }
            guard ownerID == sourceWorkspaceID else {
                throw WorkspaceError.tabNotInWorkspace(
                    tabID: tabID,
                    workspaceID: sourceWorkspaceID
                )
            }
        }

        let selectedTabs = workspaces[sourceIndex].tabs.filter {
            selectedIDs.contains($0.id)
        }
        guard let firstSelectedTab = selectedTabs.first else { return [] }

        let previousSourceActiveID = workspaces[sourceIndex].activeTabID
        let destinationActiveID =
            previousSourceActiveID.flatMap { selectedIDs.contains($0) ? $0 : nil }
            ?? firstSelectedTab.id
        let changesVisibleSelection =
            activeWorkspaceID != destinationWorkspaceID
            || visibleTabID != destinationActiveID
        if changesVisibleSelection {
            resetVisibleBroadcasting()
        }

        if sourceIndex == destinationIndex {
            workspaces[sourceIndex].activeTabID = destinationActiveID
            activeWorkspaceID = destinationWorkspaceID
            return workspaces[sourceIndex].tabs.filter { selectedIDs.contains($0.id) }
        }

        let updatedSourceTabs = workspaces[sourceIndex].tabs
        let movedTabs = updatedSourceTabs.filter { selectedIDs.contains($0.id) }
        workspaces[sourceIndex].tabs.removeAll { selectedIDs.contains($0.id) }
        workspaces[sourceIndex].activeTabID = Self.correctedActiveTabID(
            originalTabs: updatedSourceTabs,
            previousActiveID: previousSourceActiveID,
            removing: selectedIDs
        )
        workspaces[destinationIndex].tabs.append(contentsOf: movedTabs)
        workspaces[destinationIndex].activeTabID = destinationActiveID
        activeWorkspaceID = destinationWorkspaceID

        return movedTabs
    }

    @discardableResult
    mutating func closeTab(_ tabID: TabID, in workspaceID: WorkspaceID) throws -> TerminalTab {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard let ownerID = owner(of: tabID) else {
            throw WorkspaceError.tabNotFound(tabID)
        }
        guard ownerID == workspaceID else {
            throw WorkspaceError.tabNotInWorkspace(tabID: tabID, workspaceID: workspaceID)
        }

        let previousActiveID = workspaces[workspaceIndex].activeTabID
        guard let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
        else {
            throw WorkspaceError.tabNotFound(tabID)
        }
        if activeWorkspaceID == workspaceID, previousActiveID == tabID {
            resetVisibleBroadcasting()
        }

        let originalTabs = workspaces[workspaceIndex].tabs
        let removedTab = workspaces[workspaceIndex].tabs.remove(at: tabIndex)
        workspaces[workspaceIndex].activeTabID = Self.correctedActiveTabID(
            originalTabs: originalTabs,
            previousActiveID: previousActiveID,
            removing: [tabID]
        )
        return removedTab
    }

    mutating func activateWorkspace(_ workspaceID: WorkspaceID) throws {
        guard index(of: workspaceID) != nil else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard workspaceID != activeWorkspaceID else { return }

        resetVisibleBroadcasting()
        activeWorkspaceID = workspaceID
    }

    mutating func activateTab(_ tabID: TabID, in workspaceID: WorkspaceID) throws {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard let ownerID = owner(of: tabID) else {
            throw WorkspaceError.tabNotFound(tabID)
        }
        guard ownerID == workspaceID else {
            throw WorkspaceError.invalidActiveTab(workspaceID: workspaceID, tabID: tabID)
        }
        guard workspaces[workspaceIndex].activeTabID != tabID else { return }

        if activeWorkspaceID == workspaceID {
            resetVisibleBroadcasting()
        }
        workspaces[workspaceIndex].activeTabID = tabID
    }

    mutating func setBroadcasting(
        _ isBroadcasting: Bool,
        for tabID: TabID,
        in workspaceID: WorkspaceID
    ) throws {
        guard let workspaceIndex = index(of: workspaceID) else {
            throw WorkspaceError.workspaceNotFound(workspaceID)
        }
        guard let ownerID = owner(of: tabID) else {
            throw WorkspaceError.tabNotFound(tabID)
        }
        guard ownerID == workspaceID else {
            throw WorkspaceError.tabNotInWorkspace(tabID: tabID, workspaceID: workspaceID)
        }
        guard activeWorkspaceID == workspaceID,
            workspaces[workspaceIndex].activeTabID == tabID
        else {
            throw WorkspaceError.invalidBroadcastTarget(
                workspaceID: workspaceID,
                tabID: tabID
            )
        }

        guard let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
        else {
            throw WorkspaceError.tabNotFound(tabID)
        }
        workspaces[workspaceIndex].tabs[tabIndex].setBroadcasting(isBroadcasting)
    }

    private func index(of workspaceID: WorkspaceID) -> Int? {
        workspaces.firstIndex { $0.id == workspaceID }
    }

    private func owner(of tabID: TabID) -> WorkspaceID? {
        workspaces.first { workspace in
            workspace.tabs.contains { $0.id == tabID }
        }?.id
    }

    private func owns(paneID: PaneID) -> Bool {
        workspaces.contains { workspace in
            workspace.tabs.contains { tab in
                tab.root.contains(paneID)
            }
        }
    }

    private func paneDescriptorLocation(for paneID: PaneID) -> (
        workspaceIndex: Int,
        tabIndex: Int
    )? {
        for workspaceIndex in workspaces.indices {
            for tabIndex in workspaces[workspaceIndex].tabs.indices
            where workspaces[workspaceIndex].tabs[tabIndex].paneDescriptor(for: paneID) != nil {
                return (workspaceIndex, tabIndex)
            }
        }
        return nil
    }

    private var visibleTabID: TabID? {
        workspace(id: activeWorkspaceID)?.activeTabID
    }

    private func validatedName(
        _ name: String,
        excluding excludedWorkspaceID: WorkspaceID? = nil
    ) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkspaceError.emptyWorkspaceName
        }

        let foldedName = Self.foldedName(trimmedName)
        let conflicts = workspaces.contains { workspace in
            workspace.id != excludedWorkspaceID
                && Self.foldedName(workspace.name) == foldedName
        }
        guard !conflicts else {
            throw WorkspaceError.duplicateWorkspaceName
        }
        return trimmedName
    }

    private static func foldedName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private mutating func resetVisibleBroadcasting() {
        guard let workspaceIndex = index(of: activeWorkspaceID),
            let activeTabID = workspaces[workspaceIndex].activeTabID,
            let tabIndex = workspaces[workspaceIndex].tabs.firstIndex(where: {
                $0.id == activeTabID
            })
        else {
            return
        }
        workspaces[workspaceIndex].tabs[tabIndex].resetBroadcasting()
    }

    private static func validateSnapshot(_ workspaces: [Workspace]) throws {
        var workspaceIDs = Set<WorkspaceID>()
        var workspaceNames = Set<String>()
        var tabIDs = Set<TabID>()
        var paneIDs = Set<PaneID>()

        for workspace in workspaces {
            guard workspaceIDs.insert(workspace.id).inserted else {
                throw WorkspaceError.duplicateWorkspaceID(workspace.id)
            }

            let trimmedName = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw WorkspaceError.emptyWorkspaceName
            }
            guard workspaceNames.insert(foldedName(trimmedName)).inserted else {
                throw WorkspaceError.duplicateWorkspaceName
            }

            for tab in workspace.tabs {
                do {
                    try tab.validateInvariant()
                } catch is TerminalTabError {
                    throw WorkspaceError.invalidTabSnapshot(tab.id)
                }
                guard tabIDs.insert(tab.id).inserted else {
                    throw WorkspaceError.tabAlreadyOwned(tab.id)
                }
                for paneID in tab.root.leaves {
                    guard paneIDs.insert(paneID).inserted else {
                        throw WorkspaceError.paneAlreadyOwned(paneID)
                    }
                }
            }
        }
    }

    private static func normalizeActiveTabIDs(in workspaces: inout [Workspace]) {
        for workspaceIndex in workspaces.indices {
            let activeTabID = workspaces[workspaceIndex].activeTabID
            if activeTabID == nil
                || !workspaces[workspaceIndex].tabs.contains(where: { $0.id == activeTabID })
            {
                workspaces[workspaceIndex].activeTabID = workspaces[workspaceIndex].tabs.first?.id
            }
        }
    }

    private static func correctedActiveTabID(
        originalTabs: [TerminalTab],
        previousActiveID: TabID?,
        removing removedIDs: Set<TabID>
    ) -> TabID? {
        let remainingTabs = originalTabs.filter { !removedIDs.contains($0.id) }
        guard let previousActiveID else { return remainingTabs.first?.id }
        guard removedIDs.contains(previousActiveID) else {
            return remainingTabs.contains(where: { $0.id == previousActiveID })
                ? previousActiveID
                : remainingTabs.first?.id
        }
        guard let activeIndex = originalTabs.firstIndex(where: { $0.id == previousActiveID }) else {
            return remainingTabs.first?.id
        }

        let survivingTabsBeforeActive = originalTabs[..<activeIndex].count {
            !removedIDs.contains($0.id)
        }
        if survivingTabsBeforeActive < remainingTabs.count {
            return remainingTabs[survivingTabsBeforeActive].id
        }
        return remainingTabs.last?.id
    }

    private static func makeDefaultWorkspace() -> Workspace {
        Workspace(name: "Default")
    }
}
