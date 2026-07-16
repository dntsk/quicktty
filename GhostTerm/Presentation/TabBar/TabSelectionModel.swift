struct TabSelectionModel: Equatable, Sendable {
    enum Gesture: Equatable, Sendable {
        case click
        case commandClick
        case shiftClick
    }

    private(set) var orderedTabIDs: [TabID]
    private(set) var selectedTabIDs: Set<TabID>
    private(set) var activeTabID: TabID?
    private var anchorTabID: TabID?

    init(tabIDs: [TabID] = [], activeTabID: TabID? = nil) {
        orderedTabIDs = tabIDs
        let normalizedActiveID = activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
        self.activeTabID = normalizedActiveID
        selectedTabIDs = normalizedActiveID.map { [$0] } ?? []
        anchorTabID = normalizedActiveID
    }

    var selectedTabIDsInOrder: [TabID] {
        orderedTabIDs.filter(selectedTabIDs.contains)
    }

    mutating func synchronize(tabIDs: [TabID], activeTabID: TabID?) {
        let previousActiveTabID = self.activeTabID
        orderedTabIDs = tabIDs
        selectedTabIDs.formIntersection(tabIDs)
        self.activeTabID = activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
        if let anchorTabID, !tabIDs.contains(anchorTabID) {
            self.anchorTabID = nil
        }
        if let activeTabID = self.activeTabID,
            activeTabID != previousActiveTabID,
            !selectedTabIDs.contains(activeTabID)
        {
            selectedTabIDs = [activeTabID]
            anchorTabID = activeTabID
        } else if selectedTabIDs.isEmpty, let activeTabID = self.activeTabID {
            selectedTabIDs = [activeTabID]
            anchorTabID = activeTabID
        }
    }

    mutating func select(_ tabID: TabID, gesture: Gesture) {
        guard orderedTabIDs.contains(tabID) else { return }

        switch gesture {
        case .click:
            selectedTabIDs = [tabID]
            activeTabID = tabID
            anchorTabID = tabID
        case .commandClick:
            if selectedTabIDs.contains(tabID) {
                guard selectedTabIDs.count > 1 else { return }
                selectedTabIDs.remove(tabID)
                if activeTabID == tabID {
                    activeTabID = selectedTabIDsInOrder.first
                }
            } else {
                selectedTabIDs.insert(tabID)
                activeTabID = tabID
                anchorTabID = tabID
            }
        case .shiftClick:
            let anchor = anchorTabID ?? activeTabID ?? tabID
            guard let anchorIndex = orderedTabIDs.firstIndex(of: anchor),
                let targetIndex = orderedTabIDs.firstIndex(of: tabID)
            else { return }
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedTabIDs = Set(orderedTabIDs[range])
            activeTabID = tabID
        }
    }

    mutating func clearSelectionAfterMove() {
        selectedTabIDs.removeAll()
        anchorTabID = nil
    }

    @discardableResult
    mutating func reorderSelection(to proposedIndex: Int) -> [TabID] {
        let moving = selectedTabIDsInOrder
        guard !moving.isEmpty else { return orderedTabIDs }

        let destination = min(max(0, proposedIndex), orderedTabIDs.count)
        let selectedBeforeDestination = orderedTabIDs.prefix(destination).count {
            selectedTabIDs.contains($0)
        }
        var remaining = orderedTabIDs.filter { !selectedTabIDs.contains($0) }
        let insertionIndex = min(
            max(0, proposedIndex - selectedBeforeDestination),
            remaining.count
        )
        remaining.insert(contentsOf: moving, at: insertionIndex)
        orderedTabIDs = remaining
        return orderedTabIDs
    }
}
