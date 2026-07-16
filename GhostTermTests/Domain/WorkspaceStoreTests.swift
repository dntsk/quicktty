import Foundation
import Testing

@testable import GhostTerm

struct WorkspaceStoreTests {
    @Test
    func emptyStoreCreatesAndActivatesDefaultWorkspace() throws {
        let store = WorkspaceStore()

        #expect(store.workspaces.count == 1)
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.name == "Default")
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
        #expect(store.activeWorkspaceID == workspace.id)
    }

    @Test
    func emptyWorkspaceInputCreatesAndActivatesDefaultWorkspace() throws {
        let store = try WorkspaceStore(workspaces: [], activeWorkspaceID: nil)

        #expect(store.workspaces.count == 1)
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.name == "Default")
        #expect(store.activeWorkspaceID == workspace.id)
    }

    @Test
    func workspaceNamesAreTrimmedAndEmptyNamesAreRejectedWithoutMutation() throws {
        var store = WorkspaceStore()

        let workspaceID = try store.createWorkspace(named: "  Backend\n")

        #expect(store.workspace(id: workspaceID)?.name == "Backend")
        let beforeFailure = store
        expectError(.emptyWorkspaceName) {
            try store.createWorkspace(named: " \n\t ")
        }
        #expect(store == beforeFailure)
    }

    @Test
    func createAndRenameRejectCaseInsensitiveConflictsAndRenameTrims() throws {
        var store = WorkspaceStore()
        let backendID = try store.createWorkspace(named: "Backend")
        let frontendID = try store.createWorkspace(named: "Frontend")

        let beforeCreateFailure = store
        expectError(.duplicateWorkspaceName) {
            try store.createWorkspace(named: " backend ")
        }
        #expect(store == beforeCreateFailure)

        try store.renameWorkspace(frontendID, to: "  Client  ")
        #expect(store.workspace(id: frontendID)?.name == "Client")

        let beforeRenameFailure = store
        expectError(.duplicateWorkspaceName) {
            try store.renameWorkspace(frontendID, to: " BACKEND\n")
        }
        #expect(store == beforeRenameFailure)
        #expect(store.workspace(id: backendID)?.name == "Backend")

        let beforeEmptyRename = store
        expectError(.emptyWorkspaceName) {
            try store.renameWorkspace(frontendID, to: " \n\t ")
        }
        #expect(store == beforeEmptyRename)
    }

    @Test
    func nameComparisonUsesStablePosixCaseFolding() throws {
        var store = WorkspaceStore()
        _ = try store.createWorkspace(named: "Istanbul")
        let beforeFailure = store

        expectError(.duplicateWorkspaceName) {
            try store.createWorkspace(named: "istanbul")
        }

        #expect(store == beforeFailure)
    }

    @Test
    func renameAllowsTheSameWorkspaceNameAfterTrimmingAndCaseFolding() throws {
        var store = WorkspaceStore()
        let workspaceID = try store.createWorkspace(named: "Backend")

        try store.renameWorkspace(workspaceID, to: " backend ")

        #expect(store.workspace(id: workspaceID)?.name == "backend")
    }

    @Test
    func workspaceIDsAreFreshAndNotDerivedFromNames() throws {
        var firstStore = WorkspaceStore()
        var secondStore = WorkspaceStore()

        let firstID = try firstStore.createWorkspace(named: "Backend")
        let secondID = try secondStore.createWorkspace(named: "Backend")

        #expect(firstID != secondID)
        #expect(
            firstStore.workspace(id: firstID)?.name == secondStore.workspace(id: secondID)?.name)
    }

    @Test
    func createWorkspaceDoesNotActivateIt() throws {
        var store = WorkspaceStore()
        let originalActiveID = store.activeWorkspaceID

        let createdID = try store.createWorkspace(named: "Backend")

        #expect(createdID != originalActiveID)
        #expect(store.activeWorkspaceID == originalActiveID)
    }

    @Test
    func renameMissingWorkspaceFailsWithoutMutation() {
        var store = WorkspaceStore()
        let missingID = workspaceID(999)
        let beforeFailure = store

        expectError(.workspaceNotFound(missingID)) {
            try store.renameWorkspace(missingID, to: "Backend")
        }

        #expect(store == beforeFailure)
    }

    @Test
    func addTabRejectsASecondGlobalOwner() throws {
        var store = WorkspaceStore()
        let sourceID = store.activeWorkspaceID
        let destinationID = try store.createWorkspace(named: "Backend")
        let tab = makeTab(1)
        try store.addTab(tab, to: sourceID)
        let beforeFailure = store

        expectError(.tabAlreadyOwned(tab.id)) {
            try store.addTab(tab, to: destinationID)
        }

        #expect(store == beforeFailure)
        #expect(store.workspace(id: sourceID)?.tabs == [tab])
        #expect(store.workspace(id: destinationID)?.tabs.isEmpty == true)
    }

    @Test
    func addTabToMissingWorkspaceFailsWithoutMutation() {
        var store = WorkspaceStore()
        let missingID = workspaceID(999)
        let beforeFailure = store

        expectError(.workspaceNotFound(missingID)) {
            try store.addTab(makeTab(1), to: missingID)
        }

        #expect(store == beforeFailure)
    }

    @Test
    func firstAddedTabBecomesWorkspaceActiveTab() throws {
        var store = WorkspaceStore()
        let workspaceID = store.activeWorkspaceID
        let first = makeTab(1)
        let second = makeTab(2)

        try store.addTab(first, to: workspaceID)
        try store.addTab(second, to: workspaceID)

        #expect(store.workspace(id: workspaceID)?.tabs == [first, second])
        #expect(store.workspace(id: workspaceID)?.activeTabID == first.id)
    }

    @Test
    func movingReversedSelectionPreservesSourceOrderAndExactPersistentTabValues() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let first = try makeNestedTab(1)
        let second = makeTab(2)
        let third = try makeNestedTab(3)
        let existingDestinationTab = makeTab(4)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: sourceID,
                    name: "Source",
                    tabs: [first, second, third],
                    activeTabID: third.id
                ),
                Workspace(
                    id: destinationID,
                    name: "Destination",
                    tabs: [existingDestinationTab],
                    activeTabID: existingDestinationTab.id
                ),
            ],
            activeWorkspaceID: sourceID
        )

        let moved = try store.moveTabs(
            [third.id, first.id, third.id],
            from: sourceID,
            to: destinationID
        )

        #expect(moved == [first, third])
        #expect(store.workspace(id: sourceID)?.tabs == [second])
        #expect(store.workspace(id: sourceID)?.activeTabID == second.id)
        #expect(
            store.workspace(id: destinationID)?.tabs
                == [existingDestinationTab, first, third]
        )
        #expect(store.workspace(id: destinationID)?.activeTabID == third.id)
        #expect(store.activeWorkspaceID == destinationID)
    }

    @Test
    func moveValidationIsAtomicWhenASelectedTabBelongsToAnotherWorkspace() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let otherID = workspaceID(3)
        let sourceTab = makeTab(1)
        let otherTab = makeTab(2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: sourceID, name: "Source", tabs: [sourceTab]),
                Workspace(id: destinationID, name: "Destination"),
                Workspace(id: otherID, name: "Other", tabs: [otherTab]),
            ],
            activeWorkspaceID: sourceID
        )
        let beforeFailure = store

        expectError(.tabNotInWorkspace(tabID: otherTab.id, workspaceID: sourceID)) {
            try store.moveTabs(
                [sourceTab.id, otherTab.id],
                from: sourceID,
                to: destinationID
            )
        }

        #expect(store == beforeFailure)
    }

    @Test
    func moveValidationIsAtomicForMissingTabAndWorkspaceIDs() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let sourceTab = makeTab(1)
        let missingTabID = tabID(999)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: sourceID, name: "Source", tabs: [sourceTab]),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: sourceID
        )

        let beforeMissingTab = store
        expectError(.tabNotFound(missingTabID)) {
            try store.moveTabs(
                [sourceTab.id, missingTabID],
                from: sourceID,
                to: destinationID
            )
        }
        #expect(store == beforeMissingTab)

        let missingWorkspaceID = workspaceID(999)
        let beforeMissingWorkspace = store
        expectError(.workspaceNotFound(missingWorkspaceID)) {
            try store.moveTabs(
                [sourceTab.id],
                from: sourceID,
                to: missingWorkspaceID
            )
        }
        #expect(store == beforeMissingWorkspace)
    }

    @Test
    func moveSelectsFirstMovedTabWhenSourceActiveTabIsNotSelected() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let active = makeTab(1)
        let firstMoved = makeTab(2)
        let secondMoved = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: sourceID,
                    name: "Source",
                    tabs: [active, firstMoved, secondMoved],
                    activeTabID: active.id
                ),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: sourceID
        )

        try store.moveTabs(
            [secondMoved.id, firstMoved.id],
            from: sourceID,
            to: destinationID
        )

        #expect(store.workspace(id: sourceID)?.activeTabID == active.id)
        #expect(store.workspace(id: destinationID)?.activeTabID == firstMoved.id)
        #expect(store.activeWorkspaceID == destinationID)
    }

    @Test
    func moveCorrectsRemovedActiveTabToNextSurvivor() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let first = makeTab(1)
        let active = makeTab(2)
        let next = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: sourceID,
                    name: "Source",
                    tabs: [first, active, next],
                    activeTabID: active.id
                ),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: sourceID
        )

        try store.moveTabs([active.id], from: sourceID, to: destinationID)

        #expect(store.workspace(id: sourceID)?.activeTabID == next.id)
        #expect(store.workspace(id: destinationID)?.activeTabID == active.id)
    }

    @Test
    func moveCorrectsRemovedLastActiveTabToPreviousSurvivor() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let first = makeTab(1)
        let active = makeTab(2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: sourceID,
                    name: "Source",
                    tabs: [first, active],
                    activeTabID: active.id
                ),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: sourceID
        )

        try store.moveTabs([active.id], from: sourceID, to: destinationID)

        #expect(store.workspace(id: sourceID)?.activeTabID == first.id)
    }

    @Test
    func movingOnlyTabLeavesSourceWorkspacePresentAndEmpty() throws {
        let sourceID = workspaceID(1)
        let destinationID = workspaceID(2)
        let onlyTab = makeTab(1)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: sourceID,
                    name: "Source",
                    tabs: [onlyTab],
                    activeTabID: onlyTab.id
                ),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: sourceID
        )

        try store.moveTabs([onlyTab.id], from: sourceID, to: destinationID)

        #expect(store.workspaces.map(\.id) == [sourceID, destinationID])
        #expect(store.workspace(id: sourceID)?.tabs.isEmpty == true)
        #expect(store.workspace(id: sourceID)?.activeTabID == nil)
        #expect(store.activeWorkspaceID == destinationID)
    }

    @Test
    func movingTabsFromInactiveWorkspaceDoesNotDeleteIt() throws {
        let activeID = workspaceID(1)
        let inactiveID = workspaceID(2)
        let destinationID = workspaceID(3)
        let inactiveTab = makeTab(1)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: activeID, name: "Active"),
                Workspace(id: inactiveID, name: "Inactive", tabs: [inactiveTab]),
                Workspace(id: destinationID, name: "Destination"),
            ],
            activeWorkspaceID: activeID
        )

        try store.moveTabs([inactiveTab.id], from: inactiveID, to: destinationID)

        #expect(store.workspaces.map(\.id) == [activeID, inactiveID, destinationID])
        #expect(store.workspace(id: inactiveID)?.tabs.isEmpty == true)
        #expect(store.activeWorkspaceID == destinationID)
    }

    @Test
    func closeNonactiveTabPreservesActiveTabAndReturnsRemovedValue() throws {
        let workspaceID = workspaceID(1)
        let first = makeTab(1)
        let active = makeTab(2)
        let third = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: "Default",
                    tabs: [first, active, third],
                    activeTabID: active.id
                )
            ],
            activeWorkspaceID: workspaceID
        )

        let removed = try store.closeTab(first.id, in: workspaceID)

        #expect(removed == first)
        #expect(store.workspace(id: workspaceID)?.tabs == [active, third])
        #expect(store.workspace(id: workspaceID)?.activeTabID == active.id)
    }

    @Test
    func closeActiveFirstTabSelectsNextTab() throws {
        let workspaceID = workspaceID(1)
        let active = makeTab(1)
        let next = makeTab(2)
        var store = try makeStore(
            workspaceID: workspaceID,
            tabs: [active, next],
            active: active.id
        )

        try store.closeTab(active.id, in: workspaceID)

        #expect(store.workspace(id: workspaceID)?.activeTabID == next.id)
    }

    @Test
    func closeActiveMiddleTabSelectsNextTab() throws {
        let workspaceID = workspaceID(1)
        let first = makeTab(1)
        let active = makeTab(2)
        let next = makeTab(3)
        var store = try makeStore(
            workspaceID: workspaceID,
            tabs: [first, active, next],
            active: active.id
        )

        try store.closeTab(active.id, in: workspaceID)

        #expect(store.workspace(id: workspaceID)?.activeTabID == next.id)
    }

    @Test
    func closeActiveLastTabSelectsPreviousTab() throws {
        let workspaceID = workspaceID(1)
        let previous = makeTab(1)
        let active = makeTab(2)
        var store = try makeStore(
            workspaceID: workspaceID,
            tabs: [previous, active],
            active: active.id
        )

        try store.closeTab(active.id, in: workspaceID)

        #expect(store.workspace(id: workspaceID)?.activeTabID == previous.id)
    }

    @Test
    func closeOnlyTabLeavesWorkspacePresentWithNilActiveTab() throws {
        let workspaceID = workspaceID(1)
        let onlyTab = makeTab(1)
        var store = try makeStore(
            workspaceID: workspaceID,
            tabs: [onlyTab],
            active: onlyTab.id
        )

        try store.closeTab(onlyTab.id, in: workspaceID)

        #expect(store.workspaces.map(\.id) == [workspaceID])
        #expect(store.workspace(id: workspaceID)?.tabs.isEmpty == true)
        #expect(store.workspace(id: workspaceID)?.activeTabID == nil)
        #expect(store.activeWorkspaceID == workspaceID)
    }

    @Test
    func closeMissingAndForeignTabsFailWithoutMutation() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let foreignTab = makeTab(1)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: firstWorkspaceID, name: "First"),
                Workspace(id: secondWorkspaceID, name: "Second", tabs: [foreignTab]),
            ],
            activeWorkspaceID: firstWorkspaceID
        )

        let missingTabID = tabID(999)
        let beforeMissing = store
        expectError(.tabNotFound(missingTabID)) {
            try store.closeTab(missingTabID, in: firstWorkspaceID)
        }
        #expect(store == beforeMissing)

        let beforeForeign = store
        expectError(
            .tabNotInWorkspace(tabID: foreignTab.id, workspaceID: firstWorkspaceID)
        ) {
            try store.closeTab(foreignTab.id, in: firstWorkspaceID)
        }
        #expect(store == beforeForeign)
    }

    @Test
    func switchingActiveTabDisablesBroadcastButNoOpActivationPreservesIt() throws {
        let workspaceID = workspaceID(1)
        let first = makeTab(1)
        let second = makeTab(2)
        var store = try makeStore(
            workspaceID: workspaceID,
            tabs: [first, second],
            active: first.id
        )
        try store.setBroadcasting(true, for: first.id, in: workspaceID)

        try store.activateTab(first.id, in: workspaceID)
        #expect(store.tab(id: first.id)?.isBroadcasting == true)

        try store.activateTab(second.id, in: workspaceID)
        #expect(store.workspace(id: workspaceID)?.activeTabID == second.id)
        #expect(store.tab(id: first.id)?.isBroadcasting == false)
        #expect(store.tab(id: second.id)?.isBroadcasting == false)
    }

    @Test
    func switchingActiveWorkspaceDisablesBroadcastButNoOpActivationPreservesIt() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let firstTab = makeTab(1)
        let secondTab = makeTab(2)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: firstWorkspaceID, name: "First", tabs: [firstTab]),
                Workspace(id: secondWorkspaceID, name: "Second", tabs: [secondTab]),
            ],
            activeWorkspaceID: firstWorkspaceID
        )
        try store.setBroadcasting(true, for: firstTab.id, in: firstWorkspaceID)

        try store.activateWorkspace(firstWorkspaceID)
        #expect(store.tab(id: firstTab.id)?.isBroadcasting == true)

        try store.activateWorkspace(secondWorkspaceID)
        #expect(store.activeWorkspaceID == secondWorkspaceID)
        #expect(store.tab(id: firstTab.id)?.isBroadcasting == false)
    }

    @Test
    func invalidTabAndWorkspaceActivationDoNotMutateStore() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let foreignTab = makeTab(1)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: firstWorkspaceID, name: "First"),
                Workspace(id: secondWorkspaceID, name: "Second", tabs: [foreignTab]),
            ],
            activeWorkspaceID: firstWorkspaceID
        )

        let missingWorkspaceID = workspaceID(999)
        let beforeWorkspaceFailure = store
        expectError(.workspaceNotFound(missingWorkspaceID)) {
            try store.activateWorkspace(missingWorkspaceID)
        }
        #expect(store == beforeWorkspaceFailure)

        let beforeTabFailure = store
        expectError(
            .invalidActiveTab(workspaceID: firstWorkspaceID, tabID: foreignTab.id)
        ) {
            try store.activateTab(foreignTab.id, in: firstWorkspaceID)
        }
        #expect(store == beforeTabFailure)
    }

    @Test
    func broadcastingCanOnlyChangeForActiveTabOfActiveWorkspace() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let activeTab = makeTab(1)
        let inactiveTab = makeTab(2)
        let otherWorkspaceTab = makeTab(3)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: firstWorkspaceID,
                    name: "First",
                    tabs: [activeTab, inactiveTab],
                    activeTabID: activeTab.id
                ),
                Workspace(
                    id: secondWorkspaceID,
                    name: "Second",
                    tabs: [otherWorkspaceTab]
                ),
            ],
            activeWorkspaceID: firstWorkspaceID
        )

        let beforeInactiveTab = store
        expectError(
            .invalidBroadcastTarget(workspaceID: firstWorkspaceID, tabID: inactiveTab.id)
        ) {
            try store.setBroadcasting(true, for: inactiveTab.id, in: firstWorkspaceID)
        }
        #expect(store == beforeInactiveTab)

        let beforeInactiveWorkspace = store
        expectError(
            .invalidBroadcastTarget(
                workspaceID: secondWorkspaceID,
                tabID: otherWorkspaceTab.id
            )
        ) {
            try store.setBroadcasting(
                true,
                for: otherWorkspaceTab.id,
                in: secondWorkspaceID
            )
        }
        #expect(store == beforeInactiveWorkspace)
    }

    @Test
    func nestedModelCodableRoundTripPreservesPersistentStateAndDropsBroadcast() throws {
        let workspaceID = workspaceID(1)
        let tab = try makeNestedTab(1, isBroadcasting: true)
        let store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: " Backend ",
                    tabs: [tab],
                    activeTabID: tab.id
                )
            ],
            activeWorkspaceID: workspaceID
        )

        let encoded = try JSONEncoder().encode(store)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        let encodedTabs = try #require(workspaces.first?["tabs"] as? [[String: Any]])
        #expect(encodedTabs.first?["isBroadcasting"] == nil)

        let decoded = try JSONDecoder().decode(WorkspaceStore.self, from: encoded)
        let decodedWorkspace = try #require(decoded.workspace(id: workspaceID))
        let decodedTab = try #require(decodedWorkspace.tabs.first)

        #expect(decodedWorkspace.name == "Backend")
        #expect(decodedWorkspace.activeTabID == tab.id)
        #expect(decoded.activeWorkspaceID == workspaceID)
        #expect(decodedTab.id == tab.id)
        #expect(decodedTab.title == tab.title)
        #expect(decodedTab.root == tab.root)
        #expect(decodedTab.paneDescriptors == tab.paneDescriptors)
        #expect(decodedTab.activePaneID == tab.activePaneID)
        #expect(decodedTab.isBroadcasting == false)
    }

    @Test
    func decodingIgnoresCraftedTrueBroadcastFieldAndUnknownFields() throws {
        let workspaceID = workspaceID(1)
        let tab = makeTab(1)
        let store = try WorkspaceStore(
            workspaces: [Workspace(id: workspaceID, name: "Default", tabs: [tab])],
            activeWorkspaceID: workspaceID
        )
        let encoded = try JSONEncoder().encode(store)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        var tabs = try #require(workspaces[0]["tabs"] as? [[String: Any]])
        tabs[0]["isBroadcasting"] = true
        tabs[0]["futureTabField"] = "ignored"
        workspaces[0]["tabs"] = tabs
        object["workspaces"] = workspaces
        object["futureStoreField"] = 42
        let crafted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkspaceStore.self, from: crafted)

        #expect(decoded.tab(id: tab.id)?.isBroadcasting == false)
    }

    @Test
    func decodingNormalizesMissingActiveWorkspaceAndTabIDsToFirstValues() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let firstTab = makeTab(1)
        let secondTab = makeTab(2)
        let store = try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: firstWorkspaceID,
                    name: "First",
                    tabs: [firstTab, secondTab],
                    activeTabID: firstTab.id
                ),
                Workspace(id: secondWorkspaceID, name: "Second"),
            ],
            activeWorkspaceID: secondWorkspaceID
        )
        let encoded = try JSONEncoder().encode(store)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["activeWorkspaceID"] = ["rawValue": workspaceID(999).rawValue.uuidString]
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        workspaces[0]["activeTabID"] = ["rawValue": tabID(999).rawValue.uuidString]
        object["workspaces"] = workspaces
        let crafted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkspaceStore.self, from: crafted)

        #expect(decoded.activeWorkspaceID == firstWorkspaceID)
        #expect(decoded.workspace(id: firstWorkspaceID)?.activeTabID == firstTab.id)
        #expect(decoded.workspace(id: secondWorkspaceID)?.activeTabID == nil)
    }

    @Test
    func decodingEmptyWorkspaceListCreatesDefaultWorkspace() throws {
        let data = Data("{\"workspaces\":[],\"future\":true}".utf8)

        let decoded = try JSONDecoder().decode(WorkspaceStore.self, from: data)

        #expect(decoded.workspaces.count == 1)
        let workspace = try #require(decoded.workspaces.first)
        #expect(workspace.name == "Default")
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
        #expect(decoded.activeWorkspaceID == workspace.id)
    }

    @Test
    func startupCommandCustomUnicodeRoundTrips() throws {
        let command = StartupCommand.custom("printf '猫 Привет 👩🏽‍💻'")

        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(StartupCommand.self, from: encoded)

        #expect(decoded == command)
    }

    private func makeStore(
        workspaceID: WorkspaceID,
        tabs: [TerminalTab],
        active: TabID
    ) throws -> WorkspaceStore {
        try WorkspaceStore(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: "Default",
                    tabs: tabs,
                    activeTabID: active
                )
            ],
            activeWorkspaceID: workspaceID
        )
    }

    private func makeTab(_ value: Int) -> TerminalTab {
        let paneID = paneID(value * 10)
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: "/tmp/tab-\(value)",
            startupCommand: .shell
        )
        return TerminalTab(
            id: tabID(value),
            title: "Tab \(value)",
            pane: descriptor
        )
    }

    private func makeNestedTab(
        _ value: Int,
        isBroadcasting: Bool = false
    ) throws -> TerminalTab {
        let firstPaneID = paneID(value * 10 + 1)
        let secondPaneID = paneID(value * 10 + 2)
        let splitID = uuid(value * 10 + 3)
        let descriptors = [
            TerminalPaneDescriptor(
                id: firstPaneID,
                cwd: "/tmp/猫-\(value)",
                startupCommand: .shell
            ),
            TerminalPaneDescriptor(
                id: secondPaneID,
                cwd: "/Users/example/project-\(value)",
                startupCommand: .custom("printf 'tab-\(value)'")
            ),
        ]
        return try TerminalTab(
            id: tabID(value),
            title: "Nested \(value)",
            root: .split(
                id: splitID,
                axis: .vertical,
                ratio: 0.37,
                first: .pane(firstPaneID),
                second: .pane(secondPaneID)
            ),
            paneDescriptors: descriptors,
            activePaneID: secondPaneID,
            isBroadcasting: isBroadcasting
        )
    }

    private func expectError<T>(
        _ expected: WorkspaceError,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            Issue.record("Expected WorkspaceError")
        } catch let error as WorkspaceError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected WorkspaceError, got \(error)")
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

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
