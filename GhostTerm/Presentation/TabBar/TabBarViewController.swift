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

    static let itemHeight: CGFloat = 28

    var onActivateTab: ((TabID) -> Void)?
    var onCloseTab: ((TabID) -> Void)?
    var onToggleBroadcast: (() -> Void)?
    var onMoveToNewWorkspace: (([TabID]) -> Void)?
    var onMoveToWorkspace: (([TabID], WorkspaceID) -> Void)?
    var onReorderTabs: (([TabID]) -> Void)?

    private let collectionView = NSCollectionView()
    private let collectionViewLayout = NSCollectionViewFlowLayout()
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

        rootView.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: rootView.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            collectionView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
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

    #if DEBUG
        var displayedTabsForTesting: [TerminalTab] {
            tabs
        }

        var selectedTabIDsInOrderForTesting: [TabID] {
            selection.selectedTabIDsInOrder
        }

        var activeTabIDForTesting: TabID? {
            selection.activeTabID
        }

        var collectionViewForTesting: NSCollectionView {
            loadViewIfNeeded()
            return collectionView
        }

        func tabItemForTesting(at index: Int) -> TabItemView {
            loadViewIfNeeded()
            guard tabs.indices.contains(index),
                let item = self.collectionView(
                    collectionView,
                    itemForRepresentedObjectAt: IndexPath(item: index, section: 0)
                ) as? TabItemView
            else {
                preconditionFailure("Expected tab item is unavailable")
            }
            return item
        }
    #endif

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
        let isPartOfMultiSelection =
            selection.selectedTabIDs.count > 1
            && selection.selectedTabIDs.contains(tab.id)
        item.configure(
            title: tab.title,
            tabIndex: indexPath.item,
            isActive: selection.activeTabID == tab.id,
            isSelected: selection.selectedTabIDs.contains(tab.id),
            isPartOfMultiSelection: isPartOfMultiSelection,
            isBroadcasting: tab.isBroadcasting,
            chromePalette: chromePalette,
            selectHandler: { [weak self] gesture in
                self?.select(tab.id, gesture: gesture)
            },
            closeHandler: { [weak self] in
                self?.onCloseTab?(tab.id)
            },
            menuProvider: { [weak self] in
                self?.contextMenu(for: tab.id) ?? NSMenu()
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
        return NSSize(width: metrics.itemWidth, height: Self.itemHeight)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard indexPath.section == 0, tabs.indices.contains(indexPath.item) else { return nil }
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
        guard localDraggedTabID(from: draggingInfo) != nil else { return [] }
        dropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard
            dropOperation == .before,
            indexPath.section == 0,
            (0...tabs.count).contains(indexPath.item),
            let draggedID = localDraggedTabID(from: draggingInfo)
        else { return false }

        if !selection.selectedTabIDs.contains(draggedID) {
            selection.select(draggedID, gesture: .click)
        }
        let currentOrder = selection.orderedTabIDs
        let reorderedIDs = selection.reorderSelection(to: indexPath.item)
        guard reorderedIDs != currentOrder else { return true }

        tabs = reorderedIDs.compactMap { tabID in
            tabs.first { $0.id == tabID }
        }
        onReorderTabs?(reorderedIDs)
        collectionView.reloadData()
        return true
    }

    private func localDraggedTabID(from draggingInfo: any NSDraggingInfo) -> TabID? {
        guard
            let source = draggingInfo.draggingSource as? NSCollectionView,
            source === collectionView,
            let rawID = draggingInfo.draggingPasteboard.string(forType: .ghostTermTab),
            let uuid = UUID(uuidString: rawID)
        else { return nil }

        let draggedID = TabID(rawValue: uuid)
        guard tabs.contains(where: { $0.id == draggedID }) else { return nil }
        return draggedID
    }

    private func select(_ tabID: TabID, gesture: TabSelectionModel.Gesture) {
        let previousActiveID = selection.activeTabID
        selection.select(tabID, gesture: gesture)
        collectionView.reloadData()
        if selection.activeTabID != previousActiveID, let activeTabID = selection.activeTabID {
            onActivateTab?(activeTabID)
        }
    }

    func contextMenu(for tabID: TabID) -> NSMenu {
        if !selection.selectedTabIDs.contains(tabID) {
            selection.select(tabID, gesture: .click)
            collectionView.reloadData()
            onActivateTab?(tabID)
        }

        let menu = NSMenu()
        let isBroadcasting = tabs.first(where: { $0.id == tabID })?.isBroadcasting ?? false
        let broadcast = NSMenuItem(
            title: "Broadcast Input",
            action: #selector(toggleBroadcast),
            keyEquivalent: ""
        )
        broadcast.state = isBroadcasting ? .on : .off
        broadcast.target = self
        menu.addItem(broadcast)
        menu.addItem(.separator())

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

    @objc private func toggleBroadcast() {
        onToggleBroadcast?()
    }

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

extension NSPasteboard.PasteboardType {
    static let ghostTermTab = NSPasteboard.PasteboardType(
        "com.dntsk.GhostTerm.tab"
    )
}
