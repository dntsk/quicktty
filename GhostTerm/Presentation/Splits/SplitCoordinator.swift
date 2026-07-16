import Foundation

struct SplitCoordinator: Sendable {
    func apply(_ command: SplitCommand, to store: inout WorkspaceStore) throws -> SplitDelta {
        var candidate = store
        let delta = try apply(command, toCandidate: &candidate)
        store = candidate
        return delta
    }

    private func apply(
        _ command: SplitCommand,
        toCandidate store: inout WorkspaceStore
    ) throws -> SplitDelta {
        switch command {
        case .split(
            let workspaceID,
            let tabID,
            let paneID,
            let axis,
            let newPane,
            let ratio
        ):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            guard location.tab.root.contains(paneID) else {
                throw SplitCoordinatorError.paneNotFound(paneID)
            }
            guard !ownsPane(newPane.id, in: store) else {
                throw SplitCoordinatorError.paneAlreadyExists(newPane.id)
            }

            var tab = location.tab
            do {
                guard
                    try tab.splitPane(
                        paneID,
                        with: newPane,
                        axis: axis,
                        ratio: ratio
                    )
                else {
                    throw SplitCoordinatorError.paneNotFound(paneID)
                }
            } catch let error as TerminalTabError {
                throw SplitCoordinatorError.tabMutationFailed(error)
            }
            let createdSplit = try createdSplit(
                in: tab.root,
                sourcePaneID: paneID,
                newPaneID: newPane.id
            )
            try replaceTab(tab, at: location, in: &store)
            return .paneSplit(
                workspaceID: workspaceID,
                tabID: tabID,
                splitID: createdSplit.id,
                sourcePaneID: paneID,
                newPane: newPane,
                axis: axis,
                ratio: createdSplit.ratio,
                root: tab.root,
                activePaneID: tab.activePaneID
            )

        case .closePane(let workspaceID, let tabID, let paneID):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            guard location.tab.root.contains(paneID) else {
                throw SplitCoordinatorError.paneNotFound(paneID)
            }

            if location.tab.root.leaves.count == 1 {
                do {
                    _ = try store.closeTab(tabID, in: workspaceID)
                } catch let error as WorkspaceError {
                    throw SplitCoordinatorError.workspaceMutationFailed(error)
                }
                return .tabClosed(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: paneID,
                    activeTabID: store.workspace(id: workspaceID)?.activeTabID
                )
            }

            var tab = location.tab
            guard tab.removePane(paneID) else {
                throw SplitCoordinatorError.paneNotFound(paneID)
            }
            try replaceTab(tab, at: location, in: &store)
            return .paneClosed(
                workspaceID: workspaceID,
                tabID: tabID,
                paneID: paneID,
                root: tab.root,
                activePaneID: tab.activePaneID
            )

        case .updateRatio(let workspaceID, let tabID, let splitID, let ratio):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            guard location.tab.root.contains(splitID: splitID) else {
                throw SplitCoordinatorError.splitNotFound(splitID)
            }

            var tab = location.tab
            guard tab.updateSplitRatio(splitID, ratio: ratio) else {
                throw SplitCoordinatorError.splitNotFound(splitID)
            }
            let storedRatio = try self.ratio(in: tab.root, splitID: splitID)
            try replaceTab(tab, at: location, in: &store)
            return .ratioUpdated(
                workspaceID: workspaceID,
                tabID: tabID,
                splitID: splitID,
                ratio: storedRatio,
                root: tab.root
            )

        case .equalize(let workspaceID, let tabID):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            let splitIDs = preorderSplitIDs(in: location.tab.root)
            var tab = location.tab
            for splitID in splitIDs {
                guard tab.updateSplitRatio(splitID, ratio: 0.5) else {
                    throw SplitCoordinatorError.splitNotFound(splitID)
                }
            }
            try replaceTab(tab, at: location, in: &store)
            return .splitsEqualized(
                workspaceID: workspaceID,
                tabID: tabID,
                splitIDs: splitIDs,
                root: tab.root
            )

        case .activatePane(let workspaceID, let tabID, let paneID):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            guard location.tab.root.contains(paneID) else {
                throw SplitCoordinatorError.paneNotFound(paneID)
            }
            return try activate(
                paneID,
                from: location.tab.activePaneID,
                workspaceID: workspaceID,
                tabID: tabID,
                location: location,
                store: &store
            )

        case .focusNext(let workspaceID, let tabID, let sourcePaneID):
            return try focusSequentially(
                workspaceID: workspaceID,
                tabID: tabID,
                sourcePaneID: sourcePaneID,
                offset: 1,
                store: &store
            )

        case .focusPrevious(let workspaceID, let tabID, let sourcePaneID):
            return try focusSequentially(
                workspaceID: workspaceID,
                tabID: tabID,
                sourcePaneID: sourcePaneID,
                offset: -1,
                store: &store
            )

        case .focus(let workspaceID, let tabID, let sourcePaneID, let direction):
            let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
            guard location.tab.root.contains(sourcePaneID) else {
                throw SplitCoordinatorError.paneNotFound(sourcePaneID)
            }
            let frames = paneFrames(in: location.tab.root)
            let destinationPaneID =
                directionalDestination(
                    from: sourcePaneID,
                    direction: direction,
                    frames: frames
                ) ?? sourcePaneID
            return try activate(
                destinationPaneID,
                from: sourcePaneID,
                workspaceID: workspaceID,
                tabID: tabID,
                location: location,
                store: &store
            )
        }
    }

    private func focusSequentially(
        workspaceID: WorkspaceID,
        tabID: TabID,
        sourcePaneID: PaneID,
        offset: Int,
        store: inout WorkspaceStore
    ) throws -> SplitDelta {
        let location = try locateTab(workspaceID: workspaceID, tabID: tabID, in: store)
        let leaves = location.tab.root.leaves
        guard let sourceIndex = leaves.firstIndex(of: sourcePaneID) else {
            throw SplitCoordinatorError.paneNotFound(sourcePaneID)
        }
        let destinationIndex = (sourceIndex + offset + leaves.count) % leaves.count
        return try activate(
            leaves[destinationIndex],
            from: sourcePaneID,
            workspaceID: workspaceID,
            tabID: tabID,
            location: location,
            store: &store
        )
    }

    private func activate(
        _ destinationPaneID: PaneID,
        from sourcePaneID: PaneID,
        workspaceID: WorkspaceID,
        tabID: TabID,
        location: LocatedTab,
        store: inout WorkspaceStore
    ) throws -> SplitDelta {
        var tab = location.tab
        guard tab.activatePane(destinationPaneID) else {
            throw SplitCoordinatorError.paneNotFound(destinationPaneID)
        }
        try replaceTab(tab, at: location, in: &store)
        return .focusChanged(
            workspaceID: workspaceID,
            tabID: tabID,
            sourcePaneID: sourcePaneID,
            activePaneID: destinationPaneID
        )
    }

    private func locateTab(
        workspaceID: WorkspaceID,
        tabID: TabID,
        in store: WorkspaceStore
    ) throws -> LocatedTab {
        guard let workspaceIndex = store.workspaces.firstIndex(where: { $0.id == workspaceID })
        else {
            throw SplitCoordinatorError.workspaceNotFound(workspaceID)
        }
        guard
            let tabIndex = store.workspaces[workspaceIndex].tabs.firstIndex(where: {
                $0.id == tabID
            })
        else {
            if store.tab(id: tabID) == nil {
                throw SplitCoordinatorError.tabNotFound(tabID)
            }
            throw SplitCoordinatorError.tabNotInWorkspace(
                tabID: tabID,
                workspaceID: workspaceID
            )
        }
        return LocatedTab(
            workspaceIndex: workspaceIndex,
            tabIndex: tabIndex,
            tab: store.workspaces[workspaceIndex].tabs[tabIndex]
        )
    }

    private func replaceTab(
        _ tab: TerminalTab,
        at location: LocatedTab,
        in store: inout WorkspaceStore
    ) throws {
        var workspaces = store.workspaces
        workspaces[location.workspaceIndex].tabs[location.tabIndex] = tab
        do {
            store = try WorkspaceStore(
                workspaces: workspaces,
                activeWorkspaceID: store.activeWorkspaceID
            )
        } catch let error as WorkspaceError {
            throw SplitCoordinatorError.workspaceMutationFailed(error)
        }
    }

    private func ownsPane(_ paneID: PaneID, in store: WorkspaceStore) -> Bool {
        store.workspaces.contains { workspace in
            workspace.tabs.contains { tab in
                tab.root.contains(paneID)
            }
        }
    }

    private func createdSplit(
        in node: SplitNode,
        sourcePaneID: PaneID,
        newPaneID: PaneID
    ) throws -> (id: UUID, ratio: Double) {
        switch node {
        case .pane:
            throw SplitCoordinatorError.paneNotFound(newPaneID)
        case .split(let id, _, let ratio, let first, let second):
            if first == .pane(sourcePaneID), second == .pane(newPaneID) {
                return (id, ratio)
            }
            if first.contains(newPaneID) {
                return try createdSplit(
                    in: first,
                    sourcePaneID: sourcePaneID,
                    newPaneID: newPaneID
                )
            }
            return try createdSplit(
                in: second,
                sourcePaneID: sourcePaneID,
                newPaneID: newPaneID
            )
        }
    }

    private func ratio(in node: SplitNode, splitID: UUID) throws -> Double {
        switch node {
        case .pane:
            throw SplitCoordinatorError.splitNotFound(splitID)
        case .split(let id, _, let ratio, let first, let second):
            if id == splitID { return ratio }
            if first.contains(splitID: splitID) {
                return try self.ratio(in: first, splitID: splitID)
            }
            return try self.ratio(in: second, splitID: splitID)
        }
    }

    private func preorderSplitIDs(in node: SplitNode) -> [UUID] {
        switch node {
        case .pane:
            []
        case .split(let id, _, _, let first, let second):
            [id] + preorderSplitIDs(in: first) + preorderSplitIDs(in: second)
        }
    }

    private func paneFrames(in root: SplitNode) -> [PaneFrame] {
        var frames: [PaneFrame] = []
        appendPaneFrames(
            in: root,
            frame: UnitFrame(minX: 0, minY: 0, maxX: 1, maxY: 1),
            to: &frames
        )
        return frames
    }

    private func appendPaneFrames(
        in node: SplitNode,
        frame: UnitFrame,
        to frames: inout [PaneFrame]
    ) {
        switch node {
        case .pane(let paneID):
            frames.append(PaneFrame(paneID: paneID, order: frames.count, frame: frame))
        case .split(_, let axis, let ratio, let first, let second):
            let ratio = normalizedRatio(ratio)
            switch axis {
            case .horizontal:
                let boundary = frame.minX + frame.width * ratio
                appendPaneFrames(
                    in: first,
                    frame: UnitFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        maxX: boundary,
                        maxY: frame.maxY
                    ),
                    to: &frames
                )
                appendPaneFrames(
                    in: second,
                    frame: UnitFrame(
                        minX: boundary,
                        minY: frame.minY,
                        maxX: frame.maxX,
                        maxY: frame.maxY
                    ),
                    to: &frames
                )
            case .vertical:
                let boundary = frame.minY + frame.height * ratio
                appendPaneFrames(
                    in: first,
                    frame: UnitFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        maxX: frame.maxX,
                        maxY: boundary
                    ),
                    to: &frames
                )
                appendPaneFrames(
                    in: second,
                    frame: UnitFrame(
                        minX: frame.minX,
                        minY: boundary,
                        maxX: frame.maxX,
                        maxY: frame.maxY
                    ),
                    to: &frames
                )
            }
        }
    }

    private func directionalDestination(
        from sourcePaneID: PaneID,
        direction: SplitFocusDirection,
        frames: [PaneFrame]
    ) -> PaneID? {
        guard let source = frames.first(where: { $0.paneID == sourcePaneID }) else {
            return nil
        }
        return
            frames
            .filter {
                $0.paneID != sourcePaneID
                    && lies($0.frame, in: direction, from: source.frame)
            }
            .min { lhs, rhs in
                isPreferred(
                    score(for: lhs, direction: direction, source: source.frame),
                    over: score(for: rhs, direction: direction, source: source.frame)
                )
            }?
            .paneID
    }

    private func lies(
        _ candidate: UnitFrame,
        in direction: SplitFocusDirection,
        from source: UnitFrame
    ) -> Bool {
        switch direction {
        case .left:
            candidate.maxX <= source.minX
        case .right:
            candidate.minX >= source.maxX
        case .up:
            candidate.maxY <= source.minY
        case .down:
            candidate.minY >= source.maxY
        }
    }

    private func score(
        for candidate: PaneFrame,
        direction: SplitFocusDirection,
        source: UnitFrame
    ) -> FocusScore {
        let primaryGap: Double
        let orthogonalGap: Double
        let centerDistance: Double
        switch direction {
        case .left:
            primaryGap = source.minX - candidate.frame.maxX
            orthogonalGap = intervalGap(
                source.minY,
                source.maxY,
                candidate.frame.minY,
                candidate.frame.maxY
            )
            centerDistance = abs(source.centerY - candidate.frame.centerY)
        case .right:
            primaryGap = candidate.frame.minX - source.maxX
            orthogonalGap = intervalGap(
                source.minY,
                source.maxY,
                candidate.frame.minY,
                candidate.frame.maxY
            )
            centerDistance = abs(source.centerY - candidate.frame.centerY)
        case .up:
            primaryGap = source.minY - candidate.frame.maxY
            orthogonalGap = intervalGap(
                source.minX,
                source.maxX,
                candidate.frame.minX,
                candidate.frame.maxX
            )
            centerDistance = abs(source.centerX - candidate.frame.centerX)
        case .down:
            primaryGap = candidate.frame.minY - source.maxY
            orthogonalGap = intervalGap(
                source.minX,
                source.maxX,
                candidate.frame.minX,
                candidate.frame.maxX
            )
            centerDistance = abs(source.centerX - candidate.frame.centerX)
        }
        return FocusScore(
            orthogonalGap: orthogonalGap,
            primaryGap: primaryGap,
            centerDistance: centerDistance,
            order: candidate.order
        )
    }

    private func intervalGap(
        _ firstMin: Double,
        _ firstMax: Double,
        _ secondMin: Double,
        _ secondMax: Double
    ) -> Double {
        max(max(firstMin - secondMax, secondMin - firstMax), 0)
    }

    private func isPreferred(_ lhs: FocusScore, over rhs: FocusScore) -> Bool {
        if lhs.orthogonalGap != rhs.orthogonalGap {
            return lhs.orthogonalGap < rhs.orthogonalGap
        }
        if lhs.primaryGap != rhs.primaryGap {
            return lhs.primaryGap < rhs.primaryGap
        }
        if lhs.centerDistance != rhs.centerDistance {
            return lhs.centerDistance < rhs.centerDistance
        }
        return lhs.order < rhs.order
    }

    private func normalizedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, 0.1), 0.9)
    }
}

private struct LocatedTab {
    let workspaceIndex: Int
    let tabIndex: Int
    let tab: TerminalTab
}

private struct PaneFrame {
    let paneID: PaneID
    let order: Int
    let frame: UnitFrame
}

private struct UnitFrame {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }
}

private struct FocusScore {
    let orthogonalGap: Double
    let primaryGap: Double
    let centerDistance: Double
    let order: Int
}
