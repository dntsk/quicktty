import AppKit
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct WorkspacePresentationTests {
    @Test
    func workspaceSelectorKeepsStoreOrderAndActiveSelection() throws {
        var store = WorkspaceStore()
        let backendID = try store.createWorkspace(named: "Backend")
        try store.activateWorkspace(backendID)
        let selector = WorkspaceSelector()

        selector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )

        #expect(selector.displayedWorkspaceNames == ["Default", "Backend"])
        #expect(selector.selectedWorkspaceID == backendID)
    }

    @Test
    func workspaceNameValidationTrimsAndRejectsCaseInsensitiveDuplicates() throws {
        let trimmed = try WorkspaceNameValidator.validate(
            "  Backend\n",
            existingNames: ["Default"]
        )
        #expect(trimmed == "Backend")

        #expect(throws: WorkspaceNameValidator.ValidationError.empty) {
            try WorkspaceNameValidator.validate(" \n", existingNames: ["Default"])
        }
        #expect(throws: WorkspaceNameValidator.ValidationError.duplicate) {
            try WorkspaceNameValidator.validate(" default ", existingNames: ["Default"])
        }
    }

    @Test
    func workspaceControllerHostsTerminalBelowVisibleChrome() {
        let controller = WorkspaceViewController()
        let terminal = NSView()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(terminal)

        #expect(controller.workspaceSelector.displayedWorkspaceNames == ["Default"])
        #expect(terminal.superview?.identifier?.rawValue == "terminal-content")
        #expect(controller.view.subviews.count == 3)
    }
}
