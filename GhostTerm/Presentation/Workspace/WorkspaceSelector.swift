import AppKit

@MainActor
final class WorkspaceSelector: NSView {
    enum Action: Int, Hashable {
        case new = 1
        case rename
        case delete
    }

    static let workspaceMenuItemAction = #selector(WorkspaceSelector.selectWorkspace(_:))
    static let workspaceManagementMenuItemAction = #selector(
        WorkspaceSelector.performWorkspaceAction(_:)
    )

    var onSelection: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: (() -> Void)?
    var onDeleteWorkspace: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private let button = NSButton(frame: .zero)
    private let workspaceMenu = NSMenu()
    private var menuPresenter: ((NSMenu, NSButton) -> Void)?
    private var workspaceNames: [String] = []
    private var activeWorkspaceID: WorkspaceID?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let buttonPoint = convert(point, to: button)
        guard button.bounds.contains(buttonPoint) else {
            return super.hitTest(point)
        }
        return button.hitTest(buttonPoint) ?? button
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        button.identifier = NSUserInterfaceItemIdentifier("workspace-selector")
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        button.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Workspace menu"
        )
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(presentWorkspaceMenu(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])

        workspaceMenu.autoenablesItems = false
    }

    func apply(workspaces: [Workspace], activeWorkspaceID: WorkspaceID) {
        self.activeWorkspaceID = activeWorkspaceID
        workspaceNames = workspaces.map(\.name)
        workspaceMenu.removeAllItems()
        for (index, workspace) in workspaces.enumerated() {
            addWorkspaceItem(
                workspace,
                index: index,
                isActive: workspace.id == activeWorkspaceID
            )
        }
        workspaceMenu.addItem(.separator())
        addActionItem(.new, title: "New Workspace…")
        addActionItem(.rename, title: "Rename Workspace…")
        addActionItem(.delete, title: "Delete Workspace…", isEnabled: workspaces.count > 1)
        button.title = workspaces.first(where: { $0.id == activeWorkspaceID })?.name ?? ""
    }

    var displayedWorkspaceNames: [String] {
        workspaceNames
    }

    var selectedWorkspaceID: WorkspaceID? {
        activeWorkspaceID
    }

    private func addWorkspaceItem(
        _ workspace: Workspace,
        index: Int,
        isActive: Bool
    ) {
        let item = NSMenuItem(
            title: workspace.name,
            action: Self.workspaceMenuItemAction,
            keyEquivalent: index < 9 ? "\(index + 1)" : ""
        )
        if index < 9 {
            item.keyEquivalentModifierMask = [.command, .option]
        }
        item.target = self
        item.representedObject = workspace.id.rawValue as NSUUID
        item.state = isActive ? .on : .off
        workspaceMenu.addItem(item)
    }

    private func addActionItem(
        _ action: Action,
        title: String,
        isEnabled: Bool = true
    ) {
        let item = NSMenuItem(
            title: title,
            action: Self.workspaceManagementMenuItemAction,
            keyEquivalent: ""
        )
        item.target = self
        item.tag = action.rawValue
        item.isEnabled = isEnabled
        workspaceMenu.addItem(item)
    }

    @objc private func presentWorkspaceMenu(_: Any?) {
        if let menuPresenter {
            menuPresenter(workspaceMenu, button)
            return
        }
        workspaceMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height),
            in: button
        )
    }

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard
            sender.isEnabled,
            let rawID = sender.representedObject as? NSUUID
        else {
            return
        }
        onSelection?(WorkspaceID(rawValue: rawID as UUID))
    }

    @objc private func performWorkspaceAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let action = Action(rawValue: sender.tag) else { return }

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
            workspaceMenu.items.map { item in
                ItemDescriptor(
                    title: item.title,
                    isSeparator: item.isSeparatorItem,
                    action: Action(rawValue: item.tag),
                    isEnabled: item.isEnabled
                )
            }
        }

        var allRealItemsHaveExplicitTargetAndActionForTesting: Bool {
            workspaceMenu.items
                .filter { !$0.isSeparatorItem }
                .allSatisfy { $0.target === self && $0.action != nil }
        }

        var menuItemsForTesting: [NSMenuItem] {
            workspaceMenu.items
        }

        var menuForTesting: NSMenu {
            workspaceMenu
        }

        var buttonForTesting: NSButton {
            button
        }

        var buttonTitleForTesting: String {
            button.title
        }

        var menuPresenterForTesting: ((NSMenu, NSButton) -> Void)? {
            get { menuPresenter }
            set { menuPresenter = newValue }
        }

        func performWorkspaceSelectionForTesting(_ workspaceID: WorkspaceID) {
            guard
                let item = workspaceMenu.items.first(where: { item in
                    guard let rawID = item.representedObject as? NSUUID else { return false }
                    return WorkspaceID(rawValue: rawID as UUID) == workspaceID
                })
            else {
                return
            }
            dispatchMenuItemActionForTesting(item)
        }

        func triggerActionForTesting(_ action: Action) {
            guard let item = workspaceMenu.items.first(where: { $0.tag == action.rawValue })
            else {
                return
            }
            dispatchMenuItemActionForTesting(item)
        }

        func performButtonActionForTesting() {
            guard let action = button.action else { return }
            NSApp.sendAction(action, to: button.target, from: button)
        }

        private func dispatchMenuItemActionForTesting(_ item: NSMenuItem) {
            guard let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }

        func isActionEnabledForTesting(_ action: Action) -> Bool {
            workspaceMenu.items.first(where: { $0.tag == action.rawValue })?.isEnabled ?? false
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
