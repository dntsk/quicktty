import Foundation
import Testing

@testable import QuickTTY

struct TerminalTabTests {
    @Test
    func fullInitializerRejectsDuplicateRootLeaves() {
        let paneID = paneID(1)
        let root = SplitNode.split(
            id: uuid(100),
            axis: .horizontal,
            ratio: 0.5,
            first: .pane(paneID),
            second: .pane(paneID)
        )

        expectError(.duplicatePaneLeaf(paneID)) {
            try TerminalTab(
                title: "Invalid",
                root: root,
                paneDescriptors: [descriptor(paneID)],
                activePaneID: paneID
            )
        }
    }

    @Test
    func fullInitializerRejectsDuplicatePaneDescriptors() {
        let paneID = paneID(1)

        expectError(.duplicatePaneDescriptor(paneID)) {
            try TerminalTab(
                title: "Invalid",
                root: .pane(paneID),
                paneDescriptors: [descriptor(paneID), descriptor(paneID)],
                activePaneID: paneID
            )
        }
    }

    @Test
    func fullInitializerRejectsMissingAndUnexpectedPaneDescriptors() {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        let unexpectedPaneID = paneID(3)
        let root = splitRoot(firstPaneID, secondPaneID)

        expectError(.missingPaneDescriptor(secondPaneID)) {
            try TerminalTab(
                title: "Missing",
                root: root,
                paneDescriptors: [descriptor(firstPaneID)],
                activePaneID: firstPaneID
            )
        }
        expectError(.unexpectedPaneDescriptor(unexpectedPaneID)) {
            try TerminalTab(
                title: "Unexpected",
                root: root,
                paneDescriptors: [
                    descriptor(firstPaneID),
                    descriptor(secondPaneID),
                    descriptor(unexpectedPaneID),
                ],
                activePaneID: firstPaneID
            )
        }
    }

    @Test
    func fullInitializerNormalizesStaleAndMissingActivePaneToFirstRootLeaf() throws {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        let root = splitRoot(firstPaneID, secondPaneID)
        let descriptors = [descriptor(firstPaneID), descriptor(secondPaneID)]

        let stale = try TerminalTab(
            title: "Stale",
            root: root,
            paneDescriptors: descriptors,
            activePaneID: paneID(999)
        )
        let missing = try TerminalTab(
            title: "Missing",
            root: root,
            paneDescriptors: descriptors,
            activePaneID: nil
        )

        #expect(stale.activePaneID == firstPaneID)
        #expect(missing.activePaneID == firstPaneID)
    }

    @Test
    func decoderRejectsDuplicateLeaves() throws {
        let tab = try makeSplitTab()
        var object = try encodedObject(tab)
        var root = try #require(object["root"] as? [String: Any])
        let first = try #require(root["first"] as? [String: Any])
        var second = try #require(root["second"] as? [String: Any])
        second["paneID"] = first["paneID"]
        root["second"] = second
        object["root"] = root

        try expectDecodingError(object)
    }

    @Test
    func decoderRejectsMissingAndDuplicateDescriptors() throws {
        let tab = try makeSplitTab()
        let original = try encodedObject(tab)
        let originalDescriptors = try #require(
            original["paneDescriptors"] as? [[String: Any]]
        )

        var missing = original
        missing["paneDescriptors"] = [originalDescriptors[0]]
        try expectDecodingError(missing)

        var duplicate = original
        duplicate["paneDescriptors"] = [originalDescriptors[0], originalDescriptors[0]]
        try expectDecodingError(duplicate)
    }

    @Test(arguments: [false, true])
    func decoderNormalizesMissingOrStaleActivePaneAndIgnoresBroadcast(
        removesActivePane: Bool
    ) throws {
        let tab = try makeSplitTab()
        var object = try encodedObject(tab)
        if removesActivePane {
            object.removeValue(forKey: "activePaneID")
        } else {
            object["activePaneID"] = ["rawValue": paneID(999).rawValue.uuidString]
        }
        object["isBroadcasting"] = true

        let decoded = try JSONDecoder().decode(
            TerminalTab.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.activePaneID == tab.root.leaves[0])
        #expect(decoded.isBroadcasting == false)
    }

    @Test
    func splitPaneUpdatesLayoutDescriptorsAndFocusAtomically() throws {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        var tab = TerminalTab(title: "Tab", pane: descriptor(firstPaneID))

        let didSplit = try tab.splitPane(
            firstPaneID,
            with: descriptor(secondPaneID),
            axis: .vertical,
            ratio: 0.35
        )

        #expect(didSplit)
        #expect(tab.root.leaves == [firstPaneID, secondPaneID])
        #expect(tab.paneDescriptors.map(\.id) == [firstPaneID, secondPaneID])
        #expect(tab.activePaneID == secondPaneID)
    }

    @Test
    func splitPaneFailureLeavesTabUnchanged() throws {
        let paneID = paneID(1)
        var tab = TerminalTab(title: "Tab", pane: descriptor(paneID))

        let beforeMissingTarget = tab
        let didSplit = try tab.splitPane(
            self.paneID(999),
            with: descriptor(self.paneID(2)),
            axis: .horizontal,
            ratio: 0.5
        )
        #expect(!didSplit)
        #expect(tab == beforeMissingTarget)

        let beforeDuplicate = tab
        expectError(.paneAlreadyExists(paneID)) {
            try tab.splitPane(
                paneID,
                with: descriptor(paneID),
                axis: .horizontal,
                ratio: 0.5
            )
        }
        #expect(tab == beforeDuplicate)
    }

    @Test
    func removingActivePaneSelectsNextThenPreviousAndCollapsesRoot() throws {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        let thirdPaneID = paneID(3)
        var tab = TerminalTab(title: "Tab", pane: descriptor(firstPaneID))
        _ = try tab.splitPane(
            firstPaneID,
            with: descriptor(secondPaneID),
            axis: .horizontal,
            ratio: 0.5
        )
        _ = try tab.splitPane(
            secondPaneID,
            with: descriptor(thirdPaneID),
            axis: .vertical,
            ratio: 0.5
        )

        let didRemoveSecondPane = tab.removePane(secondPaneID)
        #expect(didRemoveSecondPane)
        #expect(tab.root.leaves == [firstPaneID, thirdPaneID])
        #expect(tab.paneDescriptors.map(\.id) == [firstPaneID, thirdPaneID])
        #expect(tab.activePaneID == thirdPaneID)

        let didRemoveThirdPane = tab.removePane(thirdPaneID)
        #expect(didRemoveThirdPane)
        #expect(tab.root == .pane(firstPaneID))
        #expect(tab.activePaneID == firstPaneID)
    }

    @Test
    func removingLastOrUnknownPaneDoesNotCreateAnEmptyTab() {
        let paneID = paneID(1)
        var tab = TerminalTab(title: "Tab", pane: descriptor(paneID))
        let original = tab

        let didRemoveLastPane = tab.removePane(paneID)
        let didRemoveUnknownPane = tab.removePane(self.paneID(999))
        #expect(!didRemoveLastPane)
        #expect(!didRemoveUnknownPane)
        #expect(tab == original)
    }

    @Test
    func activatePaneAndUpdateSplitRatioOnlyMutateExistingTargets() throws {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        var tab = TerminalTab(title: "Tab", pane: descriptor(firstPaneID))
        _ = try tab.splitPane(
            firstPaneID,
            with: descriptor(secondPaneID),
            axis: .horizontal,
            ratio: 0.5
        )
        guard case .split(let splitID, _, _, _, _) = tab.root else {
            Issue.record("Expected a split root")
            return
        }

        let didActivateFirstPane = tab.activatePane(firstPaneID)
        #expect(didActivateFirstPane)
        #expect(tab.activePaneID == firstPaneID)
        let beforeUnknownPane = tab
        let didActivateUnknownPane = tab.activatePane(paneID(999))
        #expect(!didActivateUnknownPane)
        #expect(tab == beforeUnknownPane)

        let didUpdateRatio = tab.updateSplitRatio(splitID, ratio: 2)
        #expect(didUpdateRatio)
        guard case .split(_, _, let ratio, _, _) = tab.root else {
            Issue.record("Expected a split root")
            return
        }
        #expect(ratio == 0.9)
        let beforeUnknownSplit = tab
        let didUpdateUnknownSplit = tab.updateSplitRatio(uuid(999), ratio: 0.2)
        #expect(!didUpdateUnknownSplit)
        #expect(tab == beforeUnknownSplit)
    }

    private func makeSplitTab() throws -> TerminalTab {
        let firstPaneID = paneID(1)
        let secondPaneID = paneID(2)
        return try TerminalTab(
            id: tabID(1),
            title: "Split",
            root: splitRoot(firstPaneID, secondPaneID),
            paneDescriptors: [descriptor(firstPaneID), descriptor(secondPaneID)],
            activePaneID: secondPaneID,
            isBroadcasting: true
        )
    }

    private func splitRoot(_ first: PaneID, _ second: PaneID) -> SplitNode {
        .split(
            id: uuid(100),
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(first),
            second: .pane(second)
        )
    }

    private func descriptor(_ paneID: PaneID) -> TerminalPaneDescriptor {
        TerminalPaneDescriptor(id: paneID, cwd: "/tmp/\(paneID.rawValue.uuidString)")
    }

    private func encodedObject(_ tab: TerminalTab) throws -> [String: Any] {
        let data = try JSONEncoder().encode(tab)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectDecodingError(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TerminalTab.self, from: data)
        }
    }

    private func expectError<T>(
        _ expected: TerminalTabError,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            Issue.record("Expected TerminalTabError")
        } catch let error as TerminalTabError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected TerminalTabError, got \(error)")
        }
    }

    private func paneID(_ value: Int) -> PaneID {
        PaneID(rawValue: uuid(value))
    }

    private func tabID(_ value: Int) -> TabID {
        TabID(rawValue: uuid(1_000 + value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
