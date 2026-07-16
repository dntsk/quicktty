import AppKit

@MainActor
final class WorkspaceSelector: NSView {
    var onSelection: ((WorkspaceID) -> Void)?

    private let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        popUpButton.identifier = NSUserInterfaceItemIdentifier("workspace-selector")
        popUpButton.controlSize = .small
        popUpButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        popUpButton.target = self
        popUpButton.action = #selector(selectionChanged)
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popUpButton)
        NSLayoutConstraint.activate([
            popUpButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            popUpButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            popUpButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func apply(workspaces: [Workspace], activeWorkspaceID: WorkspaceID) {
        popUpButton.removeAllItems()
        for workspace in workspaces {
            popUpButton.addItem(withTitle: workspace.name)
            popUpButton.lastItem?.representedObject = workspace.id.rawValue as NSUUID
        }
        if let activeIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            popUpButton.selectItem(at: activeIndex)
        }
    }

    var displayedWorkspaceNames: [String] {
        popUpButton.itemArray.map(\.title)
    }

    var selectedWorkspaceID: WorkspaceID? {
        guard let rawID = popUpButton.selectedItem?.representedObject as? NSUUID else { return nil }
        return WorkspaceID(rawValue: rawID as UUID)
    }

    @objc private func selectionChanged() {
        guard let selectedWorkspaceID else { return }
        onSelection?(selectedWorkspaceID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
