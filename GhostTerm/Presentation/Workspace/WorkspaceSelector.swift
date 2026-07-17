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
            addWorkspaceItem(workspace)
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

    private func addWorkspaceItem(_ workspace: Workspace) {
        let item = NSMenuItem(
            title: workspace.name,
            action: #selector(selectWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = workspace.id.rawValue as NSUUID
        popUpButton.menu?.addItem(item)
    }

    private func addActionItem(
        _ action: Action,
        title: String,
        isEnabled: Bool = true
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(performWorkspaceAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = action.rawValue
        item.isEnabled = isEnabled
        popUpButton.menu?.addItem(item)
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

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard
            sender.isEnabled,
            let rawID = sender.representedObject as? NSUUID
        else {
            selectActiveWorkspace()
            return
        }
        let workspaceID = WorkspaceID(rawValue: rawID as UUID)
        popUpButton.select(sender)
        onSelection?(workspaceID)
    }

    @objc private func performWorkspaceAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let action = Action(rawValue: sender.tag) else { return }

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
        struct ItemDescriptor: Equatable {
            let title: String
            let isSeparator: Bool
            let action: Action?
            let isEnabled: Bool
        }

        var itemDescriptorsForTesting: [ItemDescriptor] {
            popUpButton.itemArray.map { item in
                ItemDescriptor(
                    title: item.title,
                    isSeparator: item.isSeparatorItem,
                    action: Action(rawValue: item.tag),
                    isEnabled: item.isEnabled
                )
            }
        }

        var allRealItemsHaveExplicitTargetAndActionForTesting: Bool {
            popUpButton.itemArray
                .filter { !$0.isSeparatorItem }
                .allSatisfy { $0.target != nil && $0.action != nil }
        }

        func performWorkspaceSelectionForTesting(_ workspaceID: WorkspaceID) {
            guard
                let item = popUpButton.itemArray.first(where: { item in
                    guard let rawID = item.representedObject as? NSUUID else { return false }
                    return WorkspaceID(rawValue: rawID as UUID) == workspaceID
                })
            else {
                return
            }
            dispatchMenuItemActionForTesting(item)
        }

        func triggerActionForTesting(_ action: Action) {
            guard let item = popUpButton.itemArray.first(where: { $0.tag == action.rawValue })
            else {
                return
            }
            dispatchMenuItemActionForTesting(item)
        }

        private func dispatchMenuItemActionForTesting(_ item: NSMenuItem) {
            guard let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
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
