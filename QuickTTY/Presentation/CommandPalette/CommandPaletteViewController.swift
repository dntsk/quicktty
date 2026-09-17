import AppKit

@MainActor
final class CommandPaletteViewController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    var onExecute: ((CommandPaletteTarget) -> Void)?
    var onDismiss: (() -> Void)?

    private let chromeHeight: CGFloat
    private let overlayView = CommandPaletteOverlayView()
    private let scrimView = NSView()
    private let cardView = NSView()
    private let searchField = CommandPaletteSearchField()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = CommandPaletteTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private var items: [CommandPaletteItem] = []
    private var filteredItems: [CommandPaletteItem] = []
    private var selectedItemID: CommandPaletteItemID?
    private var palette = GhosttyChromePalette.fallback

    init(chromeHeight: CGFloat) {
        self.chromeHeight = chromeHeight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        overlayView.identifier = NSUserInterfaceItemIdentifier("command-palette-overlay")
        overlayView.onDismiss = { [weak self] in self?.onDismiss?() }

        scrimView.wantsLayer = true
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(scrimView)

        cardView.identifier = NSUserInterfaceItemIdentifier("command-palette-card")
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.borderWidth = 1
        cardView.layer?.masksToBounds = false
        cardView.shadow = NSShadow()
        cardView.shadow?.shadowBlurRadius = 18
        cardView.shadow?.shadowOffset = NSSize(width: 0, height: -4)
        cardView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(cardView)
        overlayView.cardView = cardView

        searchField.identifier = NSUserInterfaceItemIdentifier("command-palette-search")
        searchField.placeholderString = "Type a command, workspace, or tab"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.focusRingType = .default
        searchField.setAccessibilityLabel("Command Palette search")
        searchField.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onPerformSelection = { [weak self] in self?.performSelection() }
        searchField.onDismiss = { [weak self] in self?.onDismiss?() }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(searchField)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onActivateRow = { [weak self] row in
            self?.activateRow(row)
        }
        tableView.setAccessibilityLabel("Command Palette results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityElement(true)
        emptyLabel.setAccessibilityRole(.staticText)
        cardView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: chromeHeight),
            scrimView.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor),

            cardView.topAnchor.constraint(
                equalTo: overlayView.topAnchor, constant: chromeHeight + 12),
            cardView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            cardView.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlayView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(
                lessThanOrEqualTo: overlayView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(
                lessThanOrEqualTo: overlayView.bottomAnchor, constant: -12),
            cardView.widthAnchor.constraint(equalToConstant: 640).withPriority(.defaultHigh),
            cardView.heightAnchor.constraint(equalToConstant: 460).withPriority(.defaultHigh),

            searchField.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: cardView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: cardView.trailingAnchor, constant: -16),
        ])

        view = overlayView
        applyPaletteColors()
    }

    func apply(items: [CommandPaletteItem], palette: GhosttyChromePalette) {
        self.items = items
        self.palette = palette
        loadViewIfNeeded()
        applyPaletteColors()
        updateResults()
    }

    func applyPalette(_ palette: GhosttyChromePalette) {
        self.palette = palette
        loadViewIfNeeded()
        applyPaletteColors()
    }

    func focusSearch() {
        loadViewIfNeeded()
        guard let window = view.window else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func invalidate() {
        onExecute = nil
        onDismiss = nil
        searchField.onMoveSelection = nil
        searchField.onPerformSelection = nil
        searchField.onDismiss = nil
        tableView.onActivateRow = nil
        tableView.delegate = nil
        tableView.dataSource = nil
    }

    func numberOfRows(in _: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard filteredItems.indices.contains(row) else { return 44 }
        return startsCategory(at: row) ? 64 : 46
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredItems.indices.contains(row) else { return nil }
        let item = filteredItems[row]
        let identifier = NSUserInterfaceItemIdentifier("command-palette-row")
        let rowView =
            tableView.makeView(withIdentifier: identifier, owner: self)
            as? CommandPaletteItemView ?? CommandPaletteItemView()
        rowView.identifier = identifier
        rowView.apply(
            item,
            categoryTitle: startsCategory(at: row) ? item.category.title : nil,
            palette: palette
        )
        return rowView
    }

    func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        guard let row = proposedSelectionIndexes.first,
            filteredItems.indices.contains(row),
            filteredItems[row].availability.isEnabled
        else { return tableView.selectedRowIndexes }
        return IndexSet(integer: row)
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard filteredItems.indices.contains(tableView.selectedRow) else {
            selectedItemID = nil
            return
        }
        selectedItemID = filteredItems[tableView.selectedRow].id
    }

    func controlTextDidChange(_: Notification) {
        updateResults()
    }

    func control(
        _: NSControl,
        textView _: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            performSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
        default:
            return false
        }
        return true
    }

    private func activateRow(_ row: Int) {
        guard filteredItems.indices.contains(row), filteredItems[row].availability.isEnabled else {
            return
        }
        select(row: row)
        onExecute?(filteredItems[row].target)
    }

    private func updateResults() {
        let previousSelection = selectedItemID
        filteredItems = CommandPaletteMatcher.matches(items, query: searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !filteredItems.isEmpty
        scrollView.isHidden = filteredItems.isEmpty

        if let previousSelection,
            let row = filteredItems.firstIndex(where: {
                $0.id == previousSelection && $0.availability.isEnabled
            })
        {
            select(row: row)
        } else if let row = filteredItems.firstIndex(where: { $0.availability.isEnabled }) {
            select(row: row)
        } else {
            tableView.deselectAll(nil)
            selectedItemID = nil
        }
    }

    private func startsCategory(at row: Int) -> Bool {
        row == 0 || filteredItems[row - 1].category != filteredItems[row].category
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let enabledRows = filteredItems.indices.filter { filteredItems[$0].availability.isEnabled }
        guard !enabledRows.isEmpty else { return }
        let current = enabledRows.firstIndex(of: tableView.selectedRow)
        let targetIndex: Int
        if let current {
            targetIndex = min(max(0, current + delta), enabledRows.count - 1)
        } else {
            targetIndex = delta < 0 ? enabledRows.count - 1 : 0
        }
        select(row: enabledRows[targetIndex])
    }

    private func select(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        selectedItemID = filteredItems[row].id
    }

    private func performSelection() {
        guard filteredItems.indices.contains(tableView.selectedRow) else { return }
        let item = filteredItems[tableView.selectedRow]
        guard item.availability.isEnabled else { return }
        onExecute?(item.target)
    }

    private func applyPaletteColors() {
        let background = NSColor(ghosttyRGB: palette.background)
        let foreground = NSColor(ghosttyRGB: palette.foreground)
        view.appearance = NSAppearance(named: palette.usesDarkAppearance ? .darkAqua : .aqua)
        scrimView.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(
                palette.usesDarkAppearance ? 0.28 : 0.16
            ).cgColor
        cardView.layer?.backgroundColor =
            background.blended(
                withFraction: 0.06,
                of: foreground
            )?.cgColor ?? background.cgColor
        cardView.layer?.borderColor = foreground.withAlphaComponent(0.22).cgColor
        cardView.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.42)
        emptyLabel.textColor = foreground.withAlphaComponent(0.68)
        tableView.reloadData()
    }

    #if DEBUG
        var displayedItemsForTesting: [CommandPaletteItem] { filteredItems }
        var selectedItemIDForTesting: CommandPaletteItemID? { selectedItemID }
        var searchFieldForTesting: NSSearchField { searchField }
        var tableViewForTesting: NSTableView { tableView }
        var cardViewForTesting: NSView { cardView }
        var scrimViewForTesting: NSView { scrimView }

        func setQueryForTesting(_ query: String) {
            searchField.stringValue = query
            updateResults()
        }

        func moveSelectionForTesting(by delta: Int) { moveSelection(by: delta) }
        func performSelectionForTesting() { performSelection() }
        func activateRowForTesting(_ row: Int) { activateRow(row) }

        func handleTextCommandForTesting(_ commandSelector: Selector) -> Bool {
            control(searchField, textView: NSTextView(), doCommandBy: commandSelector)
        }
    #endif
}

@MainActor
private final class CommandPaletteOverlayView: NSView {
    weak var cardView: NSView?
    var onDismiss: (() -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let cardView, cardView.frame.contains(point) else { return self }
        return cardView.hitTest(cardView.convert(point, from: self))
    }

    override func mouseDown(with event: NSEvent) {
        guard let cardView else {
            onDismiss?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard !cardView.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        onDismiss?()
    }
}

@MainActor
private final class CommandPaletteSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onPerformSelection: (() -> Void)?
    var onDismiss: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 36, 76:
            onPerformSelection?()
        case 53:
            onDismiss?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class CommandPaletteTableView: NSTableView {
    var onActivateRow: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        super.mouseDown(with: event)
        guard event.clickCount == 1, clickedRow >= 0 else { return }
        onActivateRow?(clickedRow)
    }
}

@MainActor
private final class CommandPaletteItemView: NSTableCellView {
    private let categoryLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let activeImageView = NSImageView()
    private var titleTopConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        categoryLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryLabel)

        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.setAccessibilityElement(false)
        addSubview(symbolView)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        shortcutLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        activeImageView.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: nil)
        activeImageView.imageScaling = .scaleProportionallyDown
        activeImageView.translatesAutoresizingMaskIntoConstraints = false
        activeImageView.setAccessibilityElement(false)
        addSubview(activeImageView)

        titleTopConstraint = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            categoryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            categoryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            categoryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -14),

            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            symbolView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            titleTopConstraint,
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: activeImageView.leadingAnchor, constant: -8),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            shortcutLabel.trailingAnchor.constraint(
                equalTo: activeImageView.leadingAnchor, constant: -8),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),
            activeImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            activeImageView.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor),
            activeImageView.widthAnchor.constraint(equalToConstant: 14),
            activeImageView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func apply(
        _ item: CommandPaletteItem,
        categoryTitle: String?,
        palette: GhosttyChromePalette
    ) {
        let foreground = NSColor(ghosttyRGB: palette.foreground)
        let enabled = item.availability.isEnabled
        categoryLabel.stringValue = categoryTitle?.uppercased() ?? ""
        categoryLabel.isHidden = categoryTitle == nil
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.availability.disabledReason ?? item.subtitle ?? ""
        subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
        shortcutLabel.stringValue = item.shortcut ?? ""
        activeImageView.isHidden = !item.isActive
        symbolView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)

        let primaryAlpha: CGFloat = enabled ? 1 : 0.48
        titleLabel.textColor = foreground.withAlphaComponent(primaryAlpha)
        symbolView.contentTintColor = foreground.withAlphaComponent(primaryAlpha)
        activeImageView.contentTintColor = foreground.withAlphaComponent(primaryAlpha)
        subtitleLabel.textColor = foreground.withAlphaComponent(enabled ? 0.62 : 0.46)
        shortcutLabel.textColor = foreground.withAlphaComponent(enabled ? 0.72 : 0.42)
        categoryLabel.textColor = foreground.withAlphaComponent(0.52)

        titleTopConstraint.constant = categoryTitle == nil ? 6 : 22

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        let context = [item.subtitle, item.shortcut, item.availability.disabledReason]
            .compactMap { $0 }
            .joined(separator: ", ")
        setAccessibilityHelp(context.isEmpty ? nil : context)
        setAccessibilityEnabled(enabled)
        setAccessibilityValue(item.isActive ? "Active" : nil)
        setAccessibilityChildren([])
    }
}

extension NSLayoutConstraint {
    fileprivate func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
