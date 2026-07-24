import AppKit

@MainActor
final class WorkspaceSelector: NSView, NSMenuDelegate {
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
    var onMenuTrackingChanged: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private let button = NSButton(frame: .zero)
    private let statusBadge = TerminalStatusBadgeView(frame: .zero)
    private let contentStack = NSStackView()
    private let workspaceMenu = NSMenu()
    private var menuPresenter: ((NSMenu, NSButton) -> Void)?
    private var workspaceNames: [String] = []
    private var workspaceIDs: [WorkspaceID] = []
    private var statuses: [WorkspaceID: TerminalStatusPresentation] = [:]
    private var activeWorkspaceID: WorkspaceID?
    private var isMenuTracking = false

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

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.distribution = .fill
        contentStack.spacing = 4
        contentStack.addArrangedSubview(button)
        contentStack.addArrangedSubview(statusBadge)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])

        workspaceMenu.autoenablesItems = false
        workspaceMenu.delegate = self
    }

    func apply(
        workspaces: [Workspace],
        activeWorkspaceID: WorkspaceID,
        statuses: [WorkspaceID: TerminalStatusPresentation] = [:]
    ) {
        self.activeWorkspaceID = activeWorkspaceID
        workspaceNames = workspaces.map(\.name)
        workspaceIDs = workspaces.map(\.id)
        self.statuses = Self.resolvedStatuses(workspaceIDs: workspaceIDs, statuses: statuses)
        workspaceMenu.removeAllItems()
        for workspace in workspaces {
            addWorkspaceItem(
                workspace,
                isActive: workspace.id == activeWorkspaceID
            )
        }
        workspaceMenu.addItem(.separator())
        addActionItem(.new, title: "New Workspace…")
        addActionItem(.rename, title: "Rename Workspace…")
        addActionItem(.delete, title: "Delete Workspace…", isEnabled: workspaces.count > 1)
        button.title = workspaces.first(where: { $0.id == activeWorkspaceID })?.name ?? ""
        statusBadge.apply(self.statuses[activeWorkspaceID])
    }

    func refreshStatuses(_ statuses: [WorkspaceID: TerminalStatusPresentation]) {
        let resolvedStatuses = Self.resolvedStatuses(
            workspaceIDs: workspaceIDs,
            statuses: statuses
        )
        guard resolvedStatuses != self.statuses else { return }
        self.statuses = resolvedStatuses
        statusBadge.apply(activeWorkspaceID.flatMap { resolvedStatuses[$0] })

        for item in workspaceMenu.items {
            guard let rawID = item.representedObject as? NSUUID else { continue }
            let workspaceID = WorkspaceID(rawValue: rawID as UUID)
            item.badge = resolvedStatuses[workspaceID].map {
                NSMenuItemBadge(string: $0.compactString)
            }
        }
    }

    var displayedWorkspaceNames: [String] {
        workspaceNames
    }

    var selectedWorkspaceID: WorkspaceID? {
        activeWorkspaceID
    }

    private func addWorkspaceItem(
        _ workspace: Workspace,
        isActive: Bool
    ) {
        let item = NSMenuItem(
            title: workspace.name,
            action: Self.workspaceMenuItemAction,
            keyEquivalent: ""
        )
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = workspace.id.rawValue as NSUUID
        item.state = isActive ? .on : .off
        item.badge = statuses[workspace.id].map {
            NSMenuItemBadge(string: $0.compactString)
        }
        workspaceMenu.addItem(item)
    }

    private static func resolvedStatuses(
        workspaceIDs: [WorkspaceID],
        statuses: [WorkspaceID: TerminalStatusPresentation]
    ) -> [WorkspaceID: TerminalStatusPresentation] {
        Dictionary(
            uniqueKeysWithValues: workspaceIDs.compactMap { workspaceID in
                statuses[workspaceID].map { (workspaceID, $0) }
            }
        )
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
        item.keyEquivalentModifierMask = []
        item.target = self
        item.tag = action.rawValue
        item.isEnabled = isEnabled
        workspaceMenu.addItem(item)
    }

    @objc private func presentWorkspaceMenu(_: Any?) {
        beginMenuTracking()

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

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === workspaceMenu else { return }
        beginMenuTracking()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === workspaceMenu else { return }
        endMenuTracking()
    }

    private func beginMenuTracking() {
        guard !isMenuTracking else { return }
        isMenuTracking = true
        onMenuTrackingChanged?(true)
    }

    private func endMenuTracking() {
        guard isMenuTracking else { return }
        isMenuTracking = false
        onMenuTrackingChanged?(false)
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

        var buttonBadgeRepresentationForTesting: String? {
            statusBadge.representationForTesting
        }

        var statusesForTesting: [WorkspaceID: TerminalStatusPresentation] {
            statuses
        }

        var menuIsTrackingForTesting: Bool {
            isMenuTracking
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
