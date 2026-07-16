import Foundation
import Testing

@testable import GhostTerm

struct TabSelectionModelTests {
    @Test
    func clickSelectsAndActivatesOnlyClickedTab() {
        let ids = [tabID(1), tabID(2), tabID(3)]
        var model = TabSelectionModel(tabIDs: ids, activeTabID: ids[0])

        model.select(ids[1], gesture: .click)

        #expect(model.activeTabID == ids[1])
        #expect(model.selectedTabIDs == [ids[1]])
    }

    @Test
    func commandClickAddsAndRemovesTabsWhileKeepingAnActiveSelection() {
        let ids = [tabID(1), tabID(2), tabID(3)]
        var model = TabSelectionModel(tabIDs: ids, activeTabID: ids[0])

        model.select(ids[2], gesture: .commandClick)
        #expect(model.selectedTabIDsInOrder == [ids[0], ids[2]])
        #expect(model.activeTabID == ids[2])

        model.select(ids[2], gesture: .commandClick)
        #expect(model.selectedTabIDsInOrder == [ids[0]])
        #expect(model.activeTabID == ids[0])

        model.select(ids[0], gesture: .commandClick)
        #expect(model.selectedTabIDsInOrder == [ids[0]])
        #expect(model.activeTabID == ids[0])
    }

    @Test
    func shiftClickSelectsInclusiveRangeFromAnchor() {
        let ids = [tabID(1), tabID(2), tabID(3), tabID(4)]
        var model = TabSelectionModel(tabIDs: ids, activeTabID: ids[0])
        model.select(ids[1], gesture: .click)

        model.select(ids[3], gesture: .shiftClick)

        #expect(model.selectedTabIDsInOrder == [ids[1], ids[2], ids[3]])
        #expect(model.activeTabID == ids[3])
    }

    @Test
    func moveClearDropsSelectionAndSynchronizeSelectsDestinationActiveTab() {
        let ids = [tabID(1), tabID(2)]
        var model = TabSelectionModel(tabIDs: ids, activeTabID: ids[0])
        model.select(ids[1], gesture: .commandClick)

        model.clearSelectionAfterMove()

        #expect(model.selectedTabIDs.isEmpty)
        #expect(model.activeTabID == ids[1])

        model.synchronize(tabIDs: [ids[1]], activeTabID: ids[1])
        #expect(model.selectedTabIDs == [ids[1]])
    }

    @Test
    func reorderMovesSelectedTabsTogetherAndPreservesTheirOrder() {
        let ids = [tabID(1), tabID(2), tabID(3), tabID(4)]
        var model = TabSelectionModel(tabIDs: ids, activeTabID: ids[1])
        model.select(ids[2], gesture: .commandClick)

        let reordered = model.reorderSelection(to: 4)

        #expect(reordered == [ids[0], ids[3], ids[1], ids[2]])
        #expect(model.activeTabID == ids[2])
    }

    private func tabID(_ value: Int) -> TabID {
        TabID(
            rawValue: UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", value)
            )!
        )
    }
}
