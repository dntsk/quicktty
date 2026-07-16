import AppKit

struct TabBarEqualWidthLayout {
    struct Metrics: Equatable {
        let horizontalInset: CGFloat
        let spacing: CGFloat
        let itemWidth: CGFloat

        var occupiedWidth: CGFloat {
            itemWidth * CGFloat(tabCount) + spacing * CGFloat(max(0, tabCount - 1))
                + horizontalInset * 2
        }

        fileprivate let tabCount: Int
    }

    static let preferredHorizontalInset: CGFloat = 3
    static let preferredSpacing: CGFloat = 2

    static func metrics(availableWidth: CGFloat, tabCount: Int) -> Metrics {
        guard tabCount > 0 else {
            return Metrics(horizontalInset: 0, spacing: 0, itemWidth: 0, tabCount: 0)
        }

        let width = max(0, availableWidth)
        let horizontalInset = min(preferredHorizontalInset, width / 2)
        let contentWidth = max(0, width - horizontalInset * 2)
        let spacing = min(
            preferredSpacing,
            tabCount > 1 ? contentWidth / CGFloat(tabCount - 1) : 0
        )
        let itemWidth = max(
            0,
            (contentWidth - spacing * CGFloat(tabCount - 1)) / CGFloat(tabCount)
        )
        return Metrics(
            horizontalInset: horizontalInset,
            spacing: spacing,
            itemWidth: itemWidth,
            tabCount: tabCount
        )
    }
}

@MainActor
final class TabBarViewController: NSViewController, NSCollectionViewDataSource,
    NSCollectionViewDelegateFlowLayout
{
    struct WorkspaceDestination: Equatable {
        let id: WorkspaceID
        let name: String
    }

    var onActivateTab: ((TabID) -> Void)?
    var onCloseTab: ((TabID) -> Void)?
    var onNewTab: (() -> Void)?
    var onMoveToNewWorkspace: (([TabID]) -> Void)?
    var onMoveToWorkspace: (([TabID], WorkspaceID) -> Void)?
    var onReorderTabs: (([TabID]) -> Void)?

    private let collectionView = NSCollectionView()
    private let collectionViewLayout = NSCollectionViewFlowLayout()
    private let newTabButton: NSButton = CircularOutlineButton()
    private var tabs: [TerminalTab] = []
    private var destinations: [WorkspaceDestination] = []
    private var chromePalette = GhosttyChromePalette.fallback
    private var selection = TabSelectionModel()

    override func loadView() {
        let rootView = NSView()
        rootView.identifier = NSUserInterfaceItemIdentifier("tab-bar")

        collectionViewLayout.scrollDirection = .horizontal
        collectionViewLayout.minimumInteritemSpacing = TabBarEqualWidthLayout.preferredSpacing
        collectionViewLayout.minimumLineSpacing = TabBarEqualWidthLayout.preferredSpacing
        collectionViewLayout.sectionInset = NSEdgeInsets(
            top: 0,
            left: TabBarEqualWidthLayout.preferredHorizontalInset,
            bottom: 0,
            right: TabBarEqualWidthLayout.preferredHorizontalInset
        )

        collectionView.collectionViewLayout = collectionViewLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            TabItemView.self,
            forItemWithIdentifier: TabItemView.reuseIdentifier
        )
        collectionView.registerForDraggedTypes([.ghostTermTab])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New Tab"
        )
        newTabButton.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.isBordered = false
        newTabButton.focusRingType = .none
        newTabButton.target = self
        newTabButton.action = #selector(createNewTab)
        newTabButton.identifier = NSUserInterfaceItemIdentifier("new-tab-button")
        newTabButton.setAccessibilityLabel("New Tab")
        newTabButton.toolTip = "New Tab (Command+T)"
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(collectionView)
        rootView.addSubview(newTabButton)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: rootView.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            collectionView.trailingAnchor.constraint(
                equalTo: newTabButton.leadingAnchor, constant: -4),
            newTabButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -4),
            newTabButton.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 28),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = rootView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateLayoutMetrics()
    }

    func applyChromePalette(_ palette: GhosttyChromePalette) {
        chromePalette = palette
        guard isViewLoaded else { return }
        collectionView.reloadData()
        newTabButton.needsDisplay = true
    }

    func apply(
        tabs: [TerminalTab],
        activeTabID: TabID?,
        destinations: [WorkspaceDestination]
    ) {
        self.tabs = tabs
        self.destinations = destinations
        selection.synchronize(tabIDs: tabs.map(\.id), activeTabID: activeTabID)
        updateLayoutMetrics()
        collectionView.reloadData()
    }

    func clearSelectionAfterMove() {
        selection.clearSelectionAfterMove()
        collectionView.reloadData()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        tabs.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard
            let item = collectionView.makeItem(
                withIdentifier: TabItemView.reuseIdentifier,
                for: indexPath
            ) as? TabItemView
        else {
            preconditionFailure("TabItemView registration is invalid")
        }
        let tab = tabs[indexPath.item]
        item.configure(
            title: tab.title,
            tabIndex: indexPath.item,
            isActive: selection.activeTabID == tab.id,
            isSelected: selection.selectedTabIDs.contains(tab.id),
            isBroadcasting: tab.isBroadcasting,
            chromePalette: chromePalette,
            selectHandler: { [weak self] gesture in
                self?.select(tab.id, gesture: gesture)
            },
            closeHandler: { [weak self] in
                self?.onCloseTab?(tab.id)
            },
            menuProvider: { [weak self] in
                self?.menu(for: tab.id) ?? NSMenu()
            }
        )
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let metrics = TabBarEqualWidthLayout.metrics(
            availableWidth: collectionView.bounds.width,
            tabCount: tabs.count
        )
        return NSSize(width: metrics.itemWidth, height: 34)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(tabs[indexPath.item].id.rawValue.uuidString, forType: .ghostTermTab)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        dropOperation.pointee = .before
        return draggingInfo.draggingSource as? NSCollectionView === collectionView ? .move : []
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let rawID = draggingInfo.draggingPasteboard.string(forType: .ghostTermTab),
            let uuid = UUID(uuidString: rawID)
        else { return false }

        let draggedID = TabID(rawValue: uuid)
        if !selection.selectedTabIDs.contains(draggedID) {
            selection.select(draggedID, gesture: .click)
        }
        let reorderedIDs = selection.reorderSelection(to: indexPath.item)
        onReorderTabs?(reorderedIDs)
        collectionView.reloadData()
        return true
    }

    @objc private func createNewTab() {
        onNewTab?()
    }

    private func select(_ tabID: TabID, gesture: TabSelectionModel.Gesture) {
        let previousActiveID = selection.activeTabID
        selection.select(tabID, gesture: gesture)
        collectionView.reloadData()
        if selection.activeTabID != previousActiveID, let activeTabID = selection.activeTabID {
            onActivateTab?(activeTabID)
        }
    }

    private func menu(for tabID: TabID) -> NSMenu {
        if !selection.selectedTabIDs.contains(tabID) {
            selection.select(tabID, gesture: .click)
            collectionView.reloadData()
            onActivateTab?(tabID)
        }

        let menu = NSMenu()
        let moveToNew = NSMenuItem(
            title: "Move to New Workspace…",
            action: #selector(moveToNewWorkspace),
            keyEquivalent: ""
        )
        moveToNew.target = self
        menu.addItem(moveToNew)

        let moveToWorkspace = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        let destinationMenu = NSMenu()
        for destination in destinations {
            let item = NSMenuItem(
                title: destination.name,
                action: #selector(moveToWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = destination.id.rawValue as NSUUID
            destinationMenu.addItem(item)
        }
        moveToWorkspace.submenu = destinationMenu
        moveToWorkspace.isEnabled = !destinations.isEmpty
        menu.addItem(moveToWorkspace)

        menu.addItem(.separator())
        let duplicate = NSMenuItem(
            title: "Duplicate into Workspace",
            action: nil,
            keyEquivalent: ""
        )
        duplicate.isEnabled = false
        menu.addItem(duplicate)
        return menu
    }

    private func updateLayoutMetrics() {
        let metrics = TabBarEqualWidthLayout.metrics(
            availableWidth: collectionView.bounds.width,
            tabCount: tabs.count
        )
        let sectionInset = NSEdgeInsets(
            top: 0,
            left: metrics.horizontalInset,
            bottom: 0,
            right: metrics.horizontalInset
        )
        guard
            collectionViewLayout.minimumInteritemSpacing != metrics.spacing
                || collectionViewLayout.minimumLineSpacing != metrics.spacing
                || !Self.areEqual(collectionViewLayout.sectionInset, sectionInset)
        else { return }
        collectionViewLayout.minimumInteritemSpacing = metrics.spacing
        collectionViewLayout.minimumLineSpacing = metrics.spacing
        collectionViewLayout.sectionInset = sectionInset
        collectionViewLayout.invalidateLayout()
    }

    private static func areEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }

    #if DEBUG
        var newTabButtonForTesting: NSButton {
            newTabButton
        }

        var usesScrollViewForTesting: Bool {
            collectionView.superview is NSScrollView
        }

        var newTabButtonIsCircularForTesting: Bool {
            newTabButton is CircularOutlineButton
        }

        var newTabButtonSizeForTesting: NSSize {
            NSSize(width: 28, height: 28)
        }
    #endif

    @objc private func moveToNewWorkspace() {
        let selectedIDs = selection.selectedTabIDsInOrder
        guard !selectedIDs.isEmpty else { return }
        onMoveToNewWorkspace?(selectedIDs)
    }

    @objc private func moveToWorkspace(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? NSUUID else { return }
        let selectedIDs = selection.selectedTabIDsInOrder
        guard !selectedIDs.isEmpty else { return }
        onMoveToWorkspace?(selectedIDs, WorkspaceID(rawValue: rawID as UUID))
    }
}

@MainActor
private final class CircularOutlineButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()

        guard let image else { return }
        let imageSize = image.size
        let imageRect = NSRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

extension NSPasteboard.PasteboardType {
    fileprivate static let ghostTermTab = NSPasteboard.PasteboardType(
        "com.dntsk.GhostTerm.tab"
    )
}
