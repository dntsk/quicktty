import Foundation
import Testing

@testable import GhostTerm

struct WorkspaceSnapshotValidationTests {
    @Test
    func directAndDecodedSnapshotsRejectDuplicateWorkspaceIDs() throws {
        let duplicateID = workspaceID(1)
        let workspaces = [
            Workspace(id: duplicateID, name: "First"),
            Workspace(id: duplicateID, name: "Second"),
        ]

        try expectSnapshotError(.duplicateWorkspaceID(duplicateID), workspaces: workspaces)
    }

    @Test
    func directAndDecodedSnapshotsRejectEquivalentWorkspaceNames() throws {
        let workspaces = [
            Workspace(id: workspaceID(1), name: "Backend"),
            Workspace(id: workspaceID(2), name: " backend "),
        ]

        try expectSnapshotError(.duplicateWorkspaceName, workspaces: workspaces)
    }

    @Test
    func directAndDecodedSnapshotsRejectUnicodeCaseFoldConflicts() throws {
        let workspaces = [
            Workspace(id: workspaceID(1), name: "Straße"),
            Workspace(id: workspaceID(2), name: "STRASSE"),
        ]

        try expectSnapshotError(.duplicateWorkspaceName, workspaces: workspaces)
    }

    @Test
    func directAndDecodedSnapshotsRejectEmptyWorkspaceNames() throws {
        let workspaces = [Workspace(id: workspaceID(1), name: " \n\t ")]

        try expectSnapshotError(.emptyWorkspaceName, workspaces: workspaces)
    }

    @Test
    func directAndDecodedSnapshotsRejectDuplicateTabIDsAcrossWorkspaces() throws {
        let duplicateID = tabID(1)
        let workspaces = [
            Workspace(
                id: workspaceID(1),
                name: "First",
                tabs: [makeTab(id: duplicateID, paneID: paneID(1))]
            ),
            Workspace(
                id: workspaceID(2),
                name: "Second",
                tabs: [makeTab(id: duplicateID, paneID: paneID(2))]
            ),
        ]

        try expectSnapshotError(.tabAlreadyOwned(duplicateID), workspaces: workspaces)
    }

    @Test
    func directAndDecodedSnapshotsRejectGloballyDuplicatePaneIDs() throws {
        let duplicateID = paneID(1)
        let workspaces = [
            Workspace(
                id: workspaceID(1),
                name: "First",
                tabs: [makeTab(id: tabID(1), paneID: duplicateID)]
            ),
            Workspace(
                id: workspaceID(2),
                name: "Second",
                tabs: [makeTab(id: tabID(2), paneID: duplicateID)]
            ),
        ]

        try expectSnapshotError(.paneAlreadyOwned(duplicateID), workspaces: workspaces)
    }

    @Test(arguments: ["{}", "{\"workspaces\":null}"])
    func decodingRequiresPresentNonNullWorkspacesField(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkspaceStore.self, from: Data(json.utf8))
        }
    }

    @Test
    func directSnapshotNormalizesStaleActiveIDsAfterValidation() throws {
        let firstTab = makeTab(id: tabID(1), paneID: paneID(1))
        let firstWorkspace = Workspace(
            id: workspaceID(1),
            name: "First",
            tabs: [firstTab],
            activeTabID: tabID(999)
        )
        let secondWorkspace = Workspace(id: workspaceID(2), name: "Second")

        let store = try WorkspaceStore(
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: workspaceID(999)
        )

        #expect(store.activeWorkspaceID == firstWorkspace.id)
        #expect(store.workspace(id: firstWorkspace.id)?.activeTabID == firstTab.id)
        #expect(store.workspace(id: secondWorkspace.id)?.activeTabID == nil)
    }

    @Test
    func addTabRejectsGloballyOwnedPaneWithoutMutation() throws {
        let firstWorkspaceID = workspaceID(1)
        let secondWorkspaceID = workspaceID(2)
        let sharedPaneID = paneID(1)
        let existing = makeTab(id: tabID(1), paneID: sharedPaneID)
        var store = try WorkspaceStore(
            workspaces: [
                Workspace(id: firstWorkspaceID, name: "First", tabs: [existing]),
                Workspace(id: secondWorkspaceID, name: "Second"),
            ],
            activeWorkspaceID: firstWorkspaceID
        )
        let beforeFailure = store

        expectError(.paneAlreadyOwned(sharedPaneID)) {
            try store.addTab(
                makeTab(id: tabID(2), paneID: sharedPaneID),
                to: secondWorkspaceID
            )
        }

        #expect(store == beforeFailure)
    }

    private func expectSnapshotError(
        _ expected: WorkspaceError,
        workspaces: [Workspace]
    ) throws {
        expectError(expected) {
            try WorkspaceStore(workspaces: workspaces)
        }

        let data = try JSONEncoder().encode(SnapshotFixture(workspaces: workspaces))
        do {
            _ = try JSONDecoder().decode(WorkspaceStore.self, from: data)
            Issue.record("Expected decoded snapshot to be rejected")
        } catch let error as WorkspaceError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected WorkspaceError, got \(error)")
        }
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

    private func makeTab(id: TabID, paneID: PaneID) -> TerminalTab {
        TerminalTab(
            id: id,
            title: "Tab",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp")
        )
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

    private struct SnapshotFixture: Encodable {
        let workspaces: [Workspace]
    }
}
