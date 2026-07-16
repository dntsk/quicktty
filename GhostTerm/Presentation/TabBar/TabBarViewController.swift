import AppKit

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
    private let newTabButton = NSButton()
    private var tabs: [TerminalTab] = []
    private var destinations: [WorkspaceDestination] = []
    private var selection = TabSelectionModel()

    override func loadView() {
        let rootView = NSView()
        rootView.identifier = NSUserInterfaceItemIdentifier("tab-bar")

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)

        collectionView.collectionViewLayout = layout
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

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.title = "+"
        newTabButton.bezelStyle = .texturedRounded
        newTabButton.controlSize = .small
        newTabButton.target = self
        newTabButton.action = #selector(createNewTab)
        newTabButton.identifier = NSUserInterfaceItemIdentifier("new-tab-button")
        newTabButton.setAccessibilityLabel("New Tab")
        newTabButton.toolTip = "New Tab (Command+T)"
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(scrollView)
        rootView.addSubview(newTabButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            newTabButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -4),
            newTabButton.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 26),
        ])
        view = rootView
    }

    func apply(
        tabs: [TerminalTab],
        activeTabID: TabID?,
        destinations: [WorkspaceDestination]
    ) {
        self.tabs = tabs
        self.destinations = destinations
        selection.synchronize(tabIDs: tabs.map(\.id), activeTabID: activeTabID)
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
            isActive: selection.activeTabID == tab.id,
            isSelected: selection.selectedTabIDs.contains(tab.id),
            isBroadcasting: tab.isBroadcasting,
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
        let titleWidth = (tabs[indexPath.item].title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        ).width
        return NSSize(width: min(max(titleWidth + 70, 120), 220), height: 34)
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

    #if DEBUG
        var newTabButtonForTesting: NSButton {
            newTabButton
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

extension NSPasteboard.PasteboardType {
    fileprivate static let ghostTermTab = NSPasteboard.PasteboardType(
        "com.dntsk.GhostTerm.tab"
    )
}
