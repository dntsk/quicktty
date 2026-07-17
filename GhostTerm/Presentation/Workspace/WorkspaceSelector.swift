import AppKit

@MainActor
final class WorkspaceSelector: NSView {
    enum Action: Int, Hashable {
        case new = 1
        case rename
        case delete
    }

    var onSelection: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: (() -> Void)?
    var onDeleteWorkspace: (() -> Void)?

    private let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private var workspaceNames: [String] = []
    private var activeWorkspaceID: WorkspaceID?

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
        self.activeWorkspaceID = activeWorkspaceID
        workspaceNames = workspaces.map(\.name)
        popUpButton.removeAllItems()
        for workspace in workspaces {
            popUpButton.addItem(withTitle: workspace.name)
            popUpButton.lastItem?.representedObject = workspace.id.rawValue as NSUUID
        }
        popUpButton.menu?.addItem(.separator())
        addActionItem(.new, title: "New Workspace…")
        addActionItem(.rename, title: "Rename Workspace…")
        addActionItem(.delete, title: "Delete Workspace…", isEnabled: workspaces.count > 1)
        selectActiveWorkspace()
    }

    var displayedWorkspaceNames: [String] {
        workspaceNames
    }

    var selectedWorkspaceID: WorkspaceID? {
        guard let rawID = popUpButton.selectedItem?.representedObject as? NSUUID else { return nil }
        return WorkspaceID(rawValue: rawID as UUID)
    }

    private func addActionItem(
        _ action: Action,
        title: String,
        isEnabled: Bool = true
    ) {
        popUpButton.addItem(withTitle: title)
        popUpButton.lastItem?.tag = action.rawValue
        popUpButton.lastItem?.isEnabled = isEnabled
    }

    private func selectActiveWorkspace() {
        guard let activeWorkspaceID,
            let itemIndex = popUpButton.itemArray.firstIndex(where: { item in
                guard let rawID = item.representedObject as? NSUUID else { return false }
                return WorkspaceID(rawValue: rawID as UUID) == activeWorkspaceID
            })
        else {
            return
        }
        popUpButton.selectItem(at: itemIndex)
    }

    @objc private func selectionChanged() {
        if let selectedWorkspaceID {
            onSelection?(selectedWorkspaceID)
            return
        }
        guard
            let selectedItem = popUpButton.selectedItem,
            let action = Action(rawValue: selectedItem.tag),
            selectedItem.isEnabled
        else {
            selectActiveWorkspace()
            return
        }

        selectActiveWorkspace()
        switch action {
        case .new:
            onCreateWorkspace?()
        case .rename:
            onRenameWorkspace?()
        case .delete:
            onDeleteWorkspace?()
        }
    }

    #if DEBUG
        func triggerActionForTesting(_ action: Action) {
            guard let item = popUpButton.itemArray.first(where: { $0.tag == action.rawValue })
            else {
                return
            }
            popUpButton.select(item)
            selectionChanged()
        }

        func isActionEnabledForTesting(_ action: Action) -> Bool {
            popUpButton.itemArray.first(where: { $0.tag == action.rawValue })?.isEnabled ?? false
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
