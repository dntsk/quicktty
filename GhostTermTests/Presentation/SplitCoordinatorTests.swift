import Foundation
import Testing

@testable import GhostTerm

struct SplitCoordinatorTests {
    @Test
    func splitCommandsBuildExactNestedLayoutAndKeepDescriptorsAtomic() throws {
        var store = try makeSingleTabStore()
        let coordinator = SplitCoordinator()
        let secondDescriptor = descriptor(paneID(2))
        let thirdDescriptor = descriptor(paneID(3))

        let horizontalDelta = try coordinator.apply(
            .split(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(1),
                axis: .horizontal,
                newPane: secondDescriptor,
                ratio: 0.3
            ),
            to: &store
        )
        guard
            case .paneSplit(
                _,
                _,
                let horizontalSplitID,
                let sourcePaneID,
                let reportedDescriptor,
                .horizontal,
                0.3,
                _,
                let activePaneID
            ) = horizontalDelta
        else {
            Issue.record("Expected a horizontal split delta")
            return
        }
        #expect(sourcePaneID == paneID(1))
        #expect(reportedDescriptor == secondDescriptor)
        #expect(activePaneID == paneID(2))

        let verticalDelta = try coordinator.apply(
            .split(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(2),
                axis: .vertical,
                newPane: thirdDescriptor,
                ratio: 0.7
            ),
            to: &store
        )
        guard
            case .paneSplit(
                _,
                _,
                let verticalSplitID,
                _,
                _,
                .vertical,
                0.7,
                let reportedRoot,
                let reportedActivePaneID
            ) = verticalDelta
        else {
            Issue.record("Expected a vertical split delta")
            return
        }

        let expectedRoot = SplitNode.split(
            id: horizontalSplitID,
            axis: .horizontal,
            ratio: 0.3,
            first: .pane(paneID(1)),
            second: .split(
                id: verticalSplitID,
                axis: .vertical,
                ratio: 0.7,
                first: .pane(paneID(2)),
                second: .pane(paneID(3))
            )
        )
        let tab = try #require(store.tab(id: tabID(1)))
        #expect(reportedRoot == expectedRoot)
        #expect(reportedActivePaneID == paneID(3))
        #expect(tab.root == expectedRoot)
        #expect(tab.paneDescriptors == [descriptor(paneID(1)), secondDescriptor, thirdDescriptor])
        #expect(tab.activePaneID == paneID(3))
        try tab.validateInvariant()
    }

    @Test
    func ratioUpdateClampsAndReportsTheStoredValue() throws {
        var store = try makeGridStore()
        let coordinator = SplitCoordinator()

        let highDelta = try coordinator.apply(
            .updateRatio(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                splitID: splitID(1),
                ratio: 4
            ),
            to: &store
        )
        guard case .ratioUpdated(_, _, let splitID, let ratio, let root) = highDelta else {
            Issue.record("Expected a ratio delta")
            return
        }
        #expect(splitID == self.splitID(1))
        #expect(ratio == 0.9)
        #expect(self.ratio(in: root, splitID: self.splitID(1)) == 0.9)

        let nonFiniteDelta = try coordinator.apply(
            .updateRatio(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                splitID: self.splitID(2),
                ratio: .nan
            ),
            to: &store
        )
        guard case .ratioUpdated(_, _, _, let normalizedRatio, let updatedRoot) = nonFiniteDelta
        else {
            Issue.record("Expected a normalized ratio delta")
            return
        }
        #expect(normalizedRatio == 0.5)
        #expect(self.ratio(in: updatedRoot, splitID: self.splitID(2)) == 0.5)
        try #require(store.tab(id: tabID(1))).validateInvariant()
    }

    @Test
    func equalizeUpdatesEveryNestedSplitInPreorder() throws {
        var store = try makeGridStore()
        let coordinator = SplitCoordinator()

        let delta = try coordinator.apply(
            .equalize(workspaceID: workspaceID(1), tabID: tabID(1)),
            to: &store
        )

        let expectedRoot = gridRoot(ratios: (0.5, 0.5, 0.5))
        #expect(
            delta
                == .splitsEqualized(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    splitIDs: [splitID(1), splitID(2), splitID(3)],
                    root: expectedRoot
                ))
        #expect(store.tab(id: tabID(1))?.root == expectedRoot)
        try #require(store.tab(id: tabID(1))).validateInvariant()
    }

    @Test
    func activatePaneSelectsAnExistingPaneForExternalFocus() throws {
        var store = try makeGridStore(activePaneID: paneID(1))
        let coordinator = SplitCoordinator()

        let delta = try coordinator.apply(
            .activatePane(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(4)
            ),
            to: &store
        )

        #expect(
            delta
                == .focusChanged(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    sourcePaneID: paneID(1),
                    activePaneID: paneID(4)
                ))
        #expect(store.tab(id: tabID(1))?.activePaneID == paneID(4))
    }

    @Test
    func sequentialFocusUsesDepthFirstOrderAndWraps() throws {
        var store = try makeGridStore()
        let coordinator = SplitCoordinator()

        let next = try coordinator.apply(
            .focusNext(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                from: paneID(1)
            ),
            to: &store
        )
        #expect(
            next
                == .focusChanged(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    sourcePaneID: paneID(1),
                    activePaneID: paneID(2)
                ))

        let wrappedNext = try coordinator.apply(
            .focusNext(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                from: paneID(4)
            ),
            to: &store
        )
        #expect(
            wrappedNext
                == .focusChanged(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    sourcePaneID: paneID(4),
                    activePaneID: paneID(1)
                ))

        let wrappedPrevious = try coordinator.apply(
            .focusPrevious(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                from: paneID(1)
            ),
            to: &store
        )
        #expect(
            wrappedPrevious
                == .focusChanged(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    sourcePaneID: paneID(1),
                    activePaneID: paneID(4)
                ))
        #expect(store.tab(id: tabID(1))?.activePaneID == paneID(4))
    }

    @Test
    func directionalFocusUsesNestedTreeGeometryInEveryDirection() throws {
        var store = try makeGridStore()
        let coordinator = SplitCoordinator()
        let moves: [(PaneID, SplitFocusDirection, PaneID)] = [
            (paneID(1), .right, paneID(3)),
            (paneID(3), .down, paneID(4)),
            (paneID(4), .left, paneID(2)),
            (paneID(2), .up, paneID(1)),
        ]

        for (sourcePaneID, direction, expectedPaneID) in moves {
            let delta = try coordinator.apply(
                .focus(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    from: sourcePaneID,
                    direction: direction
                ),
                to: &store
            )

            #expect(
                delta
                    == .focusChanged(
                        workspaceID: workspaceID(1),
                        tabID: tabID(1),
                        sourcePaneID: sourcePaneID,
                        activePaneID: expectedPaneID
                    ))
            #expect(store.tab(id: tabID(1))?.activePaneID == expectedPaneID)
        }

        let edgeDelta = try coordinator.apply(
            .focus(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                from: paneID(1),
                direction: .up
            ),
            to: &store
        )
        #expect(
            edgeDelta
                == .focusChanged(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    sourcePaneID: paneID(1),
                    activePaneID: paneID(1)
                ))
    }

    @Test
    func closingPaneCollapsesItsBranchAndUsesTabFocusCorrection() throws {
        var store = try makeGridStore(activePaneID: paneID(2))
        let coordinator = SplitCoordinator()

        let delta = try coordinator.apply(
            .closePane(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(2)
            ),
            to: &store
        )

        let expectedRoot = SplitNode.split(
            id: splitID(1),
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(paneID(1)),
            second: .split(
                id: splitID(3),
                axis: .vertical,
                ratio: 0.6,
                first: .pane(paneID(3)),
                second: .pane(paneID(4))
            )
        )
        #expect(
            delta
                == .paneClosed(
                    workspaceID: workspaceID(1),
                    tabID: tabID(1),
                    paneID: paneID(2),
                    root: expectedRoot,
                    activePaneID: paneID(3)
                ))
        let tab = try #require(store.tab(id: tabID(1)))
        #expect(tab.root == expectedRoot)
        #expect(tab.paneDescriptors.map(\.id) == [paneID(1), paneID(3), paneID(4)])
        #expect(tab.activePaneID == paneID(3))
        try tab.validateInvariant()
    }

    @Test
    func closingLastPaneClosesTabThenLeavesWorkspaceEmpty() throws {
        let firstTab = singleTab(1, pane: 1)
        let secondTab = singleTab(2, pane: 2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID(1),
                    name: "Default",
                    tabs: [firstTab, secondTab],
                    activeTabID: firstTab.id
                )
            ],
            activeWorkspaceID: workspaceID(1)
        )
        let coordinator = SplitCoordinator()

        let firstDelta = try coordinator.apply(
            .closePane(
                workspaceID: workspaceID(1),
                tabID: firstTab.id,
                paneID: paneID(1)
            ),
            to: &store
        )
        #expect(
            firstDelta
                == .tabClosed(
                    workspaceID: workspaceID(1),
                    tabID: firstTab.id,
                    paneID: paneID(1),
                    activeTabID: secondTab.id
                ))
        #expect(store.workspace(id: workspaceID(1))?.tabs.map(\.id) == [secondTab.id])

        let secondDelta = try coordinator.apply(
            .closePane(
                workspaceID: workspaceID(1),
                tabID: secondTab.id,
                paneID: paneID(2)
            ),
            to: &store
        )
        #expect(
            secondDelta
                == .tabClosed(
                    workspaceID: workspaceID(1),
                    tabID: secondTab.id,
                    paneID: paneID(2),
                    activeTabID: nil
                ))
        #expect(store.workspace(id: workspaceID(1))?.tabs.isEmpty == true)
        #expect(store.workspace(id: workspaceID(1))?.activeTabID == nil)
    }

    @Test
    func unknownAndForeignIDsReturnTypedErrorsWithoutMutation() throws {
        let foreignTab = singleTab(2, pane: 20)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID(1),
                    name: "First",
                    tabs: [singleTab(1, pane: 1)]
                ),
                Workspace(
                    id: workspaceID(2),
                    name: "Second",
                    tabs: [foreignTab]
                ),
            ],
            activeWorkspaceID: workspaceID(1)
        )
        let coordinator = SplitCoordinator()

        try expectAtomicError(
            .workspaceNotFound(workspaceID(999)),
            command: .equalize(workspaceID: workspaceID(999), tabID: tabID(1)),
            coordinator: coordinator,
            store: &store
        )
        try expectAtomicError(
            .tabNotFound(tabID(999)),
            command: .equalize(workspaceID: workspaceID(1), tabID: tabID(999)),
            coordinator: coordinator,
            store: &store
        )
        try expectAtomicError(
            .tabNotInWorkspace(tabID: foreignTab.id, workspaceID: workspaceID(1)),
            command: .equalize(workspaceID: workspaceID(1), tabID: foreignTab.id),
            coordinator: coordinator,
            store: &store
        )
        try expectAtomicError(
            .paneNotFound(paneID(999)),
            command: .closePane(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(999)
            ),
            coordinator: coordinator,
            store: &store
        )
        try expectAtomicError(
            .splitNotFound(splitID(999)),
            command: .updateRatio(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                splitID: splitID(999),
                ratio: 0.2
            ),
            coordinator: coordinator,
            store: &store
        )
        try expectAtomicError(
            .paneAlreadyExists(paneID(20)),
            command: .split(
                workspaceID: workspaceID(1),
                tabID: tabID(1),
                paneID: paneID(1),
                axis: .horizontal,
                newPane: descriptor(paneID(20)),
                ratio: 0.5
            ),
            coordinator: coordinator,
            store: &store
        )
    }

    private func expectAtomicError(
        _ expectedError: SplitCoordinatorError,
        command: SplitCommand,
        coordinator: SplitCoordinator,
        store: inout WorkspaceStore
    ) throws {
        let before = store
        do {
            _ = try coordinator.apply(command, to: &store)
            Issue.record("Expected SplitCoordinatorError")
        } catch let error as SplitCoordinatorError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected SplitCoordinatorError, got \(error)")
        }
        #expect(store == before)
    }

    private func makeSingleTabStore() throws -> WorkspaceStore {
        try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID(1),
                    name: "Default",
                    tabs: [singleTab(1, pane: 1)],
                    activeTabID: tabID(1)
                )
            ],
            activeWorkspaceID: workspaceID(1)
        )
    }

    private func makeGridStore(activePaneID: PaneID? = nil) throws -> WorkspaceStore {
        let descriptors = (1...4).map { descriptor(paneID($0)) }
        let tab = try TerminalTab(
            id: tabID(1),
            title: "Grid",
            root: gridRoot(ratios: (0.4, 0.3, 0.6)),
            paneDescriptors: descriptors,
            activePaneID: activePaneID ?? paneID(1)
        )
        return try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID(1),
                    name: "Default",
                    tabs: [tab],
                    activeTabID: tab.id
                )
            ],
            activeWorkspaceID: workspaceID(1)
        )
    }

    private func gridRoot(ratios: (Double, Double, Double)) -> SplitNode {
        .split(
            id: splitID(1),
            axis: .horizontal,
            ratio: ratios.0,
            first: .split(
                id: splitID(2),
                axis: .vertical,
                ratio: ratios.1,
                first: .pane(paneID(1)),
                second: .pane(paneID(2))
            ),
            second: .split(
                id: splitID(3),
                axis: .vertical,
                ratio: ratios.2,
                first: .pane(paneID(3)),
                second: .pane(paneID(4))
            )
        )
    }

    private func singleTab(_ tab: Int, pane: Int) -> TerminalTab {
        TerminalTab(
            id: tabID(tab),
            title: "Tab \(tab)",
            pane: descriptor(paneID(pane))
        )
    }

    private func descriptor(_ paneID: PaneID) -> TerminalPaneDescriptor {
        TerminalPaneDescriptor(
            id: paneID,
            cwd: "/tmp/\(paneID.rawValue.uuidString)",
            startupCommand: .shell
        )
    }

    private func ratio(in node: SplitNode, splitID: UUID) -> Double? {
        switch node {
        case .pane:
            nil
        case .split(let id, _, let ratio, let first, let second):
            id == splitID
                ? ratio
                : self.ratio(in: first, splitID: splitID)
                    ?? self.ratio(in: second, splitID: splitID)
        }
    }

    private func paneID(_ value: Int) -> PaneID {
        PaneID(rawValue: uuid(value))
    }

    private func tabID(_ value: Int) -> TabID {
        TabID(rawValue: uuid(1_000 + value))
    }

    private func workspaceID(_ value: Int) -> WorkspaceID {
        WorkspaceID(rawValue: uuid(2_000 + value))
    }

    private func splitID(_ value: Int) -> UUID {
        uuid(3_000 + value)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
