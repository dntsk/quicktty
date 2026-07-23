import AppKit

@MainActor
final class TabItemView: NSCollectionViewItem, NSTextFieldDelegate {
    struct DisplayState: Equatable {
        enum BackgroundStyle: Equatable {
            case transparent
            case hover
            case activeCapsule
            case selectionOutline
        }

        let shortcut: String?
        let showsCloseButton: Bool
        let showsBroadcastIndicator: Bool
        let backgroundStyle: BackgroundStyle
    }

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TabItemView")

    private let backgroundView = TabItemBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let renameEditor = NSTextField(string: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let broadcastIndicator = NSImageView()
    private let closeButton = NSButton()
    private struct RenameSession {
        let commit: (String) -> Void
        let finish: () -> Void
    }

    private var closeHandler: (() -> Void)?
    private var renameSession: RenameSession?
    private var isStartingRename = false
    private var tabIndex = 0
    private var isBroadcasting = false

    override func loadView() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view = backgroundView

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        renameEditor.isBordered = false
        renameEditor.drawsBackground = false
        renameEditor.focusRingType = .none
        renameEditor.font = titleLabel.font
        renameEditor.lineBreakMode = .byTruncatingTail
        renameEditor.maximumNumberOfLines = 1
        renameEditor.usesSingleLineMode = true
        renameEditor.delegate = self
        renameEditor.isHidden = true
        renameEditor.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.alignment = .right
        shortcutLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        broadcastIndicator.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "Broadcast input enabled"
        )
        broadcastIndicator.contentTintColor = .systemOrange
        broadcastIndicator.symbolConfiguration = .init(pointSize: 7, weight: .semibold)
        broadcastIndicator.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close tab"
        )
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Tab"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.onHoverChanged = { [weak self] in
            self?.updatePresentation()
        }

        backgroundView.addSubview(titleLabel)
        backgroundView.addSubview(renameEditor)
        backgroundView.addSubview(shortcutLabel)
        backgroundView.addSubview(broadcastIndicator)
        backgroundView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            broadcastIndicator.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            broadcastIndicator.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            broadcastIndicator.widthAnchor.constraint(equalToConstant: 10),
            broadcastIndicator.heightAnchor.constraint(equalToConstant: 10),
            shortcutLabel.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor, constant: -8),
            shortcutLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 27),
            titleLabel.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: backgroundView.leadingAnchor,
                constant: 25
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutLabel.leadingAnchor,
                constant: -4
            ),
            renameEditor.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            renameEditor.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            renameEditor.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
    }

    func configure(
        title: String,
        tabIndex: Int,
        isActive: Bool,
        isSelected: Bool,
        isPartOfMultiSelection: Bool,
        isBroadcasting: Bool,
        chromePalette: GhosttyChromePalette,
        dragSessionGenerationProvider: @escaping () -> Int,
        beginSelectionHandler: @escaping (TabSelectionModel.Gesture) -> Void,
        finishSelectionHandler: @escaping () -> Void,
        closeHandler: @escaping () -> Void,
        renameHandler: @escaping () -> Void,
        menuProvider: @escaping () -> NSMenu
    ) {
        updateTitle(title)
        self.tabIndex = tabIndex
        self.isBroadcasting = isBroadcasting
        backgroundView.isActive = isActive
        backgroundView.isSelected = isSelected
        backgroundView.isPartOfMultiSelection = isPartOfMultiSelection
        backgroundView.chromePalette = chromePalette
        backgroundView.dragSessionGenerationProvider = dragSessionGenerationProvider
        backgroundView.beginSelectionHandler = beginSelectionHandler
        backgroundView.finishSelectionHandler = finishSelectionHandler
        backgroundView.plainDoubleClickHandler = renameHandler
        backgroundView.menuProvider = menuProvider
        self.closeHandler = closeHandler
        updatePresentation()
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        view.toolTip = title
        view.identifier = NSUserInterfaceItemIdentifier("tab-\(title)")
    }

    func beginRenaming(
        title: String,
        commit: @escaping (String) -> Void,
        finish: @escaping () -> Void
    ) {
        guard renameSession == nil else { return }
        renameSession = RenameSession(commit: commit, finish: finish)
        renameEditor.stringValue = title
        titleLabel.isHidden = true
        renameEditor.isHidden = false
        isStartingRename = true
        view.window?.makeFirstResponder(renameEditor)
        renameEditor.selectText(nil)
        isStartingRename = false
    }

    func cancelRenaming() {
        finishRenaming(commit: false)
    }

    override func prepareForReuse() {
        cancelRenaming()
        closeHandler = nil
        backgroundView.beginSelectionHandler = nil
        backgroundView.finishSelectionHandler = nil
        backgroundView.plainDoubleClickHandler = nil
        backgroundView.menuProvider = nil
        renameEditor.stringValue = ""
        super.prepareForReuse()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isStartingRename else { return }
        finishRenaming(commit: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    static func displayState(
        tabIndex: Int,
        isActive: Bool,
        isSelected: Bool,
        isHovered: Bool,
        isBroadcasting: Bool
    ) -> DisplayState {
        let shortcut = tabIndex < 9 ? "⌘\(tabIndex + 1)" : nil
        let showsCloseButton = isHovered
        let showsBroadcastIndicator = isBroadcasting && !showsCloseButton
        let backgroundStyle: DisplayState.BackgroundStyle
        if isActive {
            backgroundStyle = .activeCapsule
        } else if isSelected {
            backgroundStyle = .selectionOutline
        } else if isHovered {
            backgroundStyle = .hover
        } else {
            backgroundStyle = .transparent
        }
        return DisplayState(
            shortcut: shortcut,
            showsCloseButton: showsCloseButton,
            showsBroadcastIndicator: showsBroadcastIndicator,
            backgroundStyle: backgroundStyle
        )
    }

    #if DEBUG
        var backgroundViewForTesting: TabItemBackgroundView {
            backgroundView
        }

        var renameEditorForTesting: NSTextField? {
            renameEditor
        }

        var isRenamingForTesting: Bool {
            renameSession != nil
        }

        var latestDisplayedTitleForTesting: String {
            titleLabel.stringValue
        }

        var visibleTitleForTesting: String? {
            titleLabel.isHidden ? nil : titleLabel.stringValue
        }

        func invokeRenameCommandForTesting(_ commandSelector: Selector) {
            _ = control(renameEditor, textView: NSTextView(), doCommandBy: commandSelector)
        }

        func endRenameEditingForTesting() {
            controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        }
    #endif

    @objc private func closeTab() {
        closeHandler?()
    }

    private func finishRenaming(commit shouldCommit: Bool) {
        guard let renameSession else { return }
        self.renameSession = nil
        let value = renameEditor.stringValue
        titleLabel.isHidden = false
        renameEditor.isHidden = true
        if renameEditor.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        if shouldCommit {
            renameSession.commit(value)
        }
        renameSession.finish()
    }

    private func updatePresentation() {
        let state = Self.displayState(
            tabIndex: tabIndex,
            isActive: backgroundView.isActive,
            isSelected: backgroundView.isSelected,
            isHovered: backgroundView.isHovered,
            isBroadcasting: isBroadcasting
        )
        titleLabel.textColor = backgroundView.isActive ? .labelColor : .secondaryLabelColor
        titleLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: backgroundView.isActive ? .medium : .regular
        )
        shortcutLabel.stringValue = state.shortcut ?? ""
        shortcutLabel.isHidden = state.shortcut == nil
        closeButton.isHidden = !state.showsCloseButton
        broadcastIndicator.isHidden = !state.showsBroadcastIndicator
    }
}

@MainActor
final class TabItemBackgroundView: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    var isPartOfMultiSelection = false
    var chromePalette = GhosttyChromePalette.fallback {
        didSet { needsDisplay = true }
    }
    private(set) var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            needsDisplay = true
            onHoverChanged?()
        }
    }
    var beginSelectionHandler: ((TabSelectionModel.Gesture) -> Void)?
    var finishSelectionHandler: (() -> Void)?
    var plainDoubleClickHandler: (() -> Void)?
    var dragSessionGenerationProvider: () -> Int = { 0 }
    var menuProvider: (() -> NSMenu)?
    var onHoverChanged: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 0)
        let path = NSBezierPath(
            roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)

        if isActive {
            NSColor(
                ghosttyRGB: chromePalette.background.blended(
                    with: chromePalette.foreground,
                    fraction: 0.16
                )
            ).setFill()
            path.fill()
            NSColor(
                ghosttyRGB: chromePalette.background.blended(
                    with: chromePalette.foreground,
                    fraction: 0.20
                )
            ).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            return
        }

        if isSelected {
            NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let doubleClickHandler = plainDoubleClickHandler
        let gesture: TabSelectionModel.Gesture
        if event.modifierFlags.contains(.shift) {
            gesture = .shiftClick
        } else if event.modifierFlags.contains(.command) {
            gesture = .commandClick
        } else {
            gesture = .click
        }
        guard gesture == .click, isPartOfMultiSelection else {
            let dragSessionGeneration = dragSessionGenerationProvider()
            beginSelectionHandler?(gesture)
            super.mouseDown(with: nativeSelectionMouseDownEvent(from: event, gesture: gesture))
            finishSelectionHandler?()
            if isPlainDoubleClick(event), dragSessionGeneration == dragSessionGenerationProvider() {
                doubleClickHandler?()
            }
            return
        }

        let dragSessionGeneration = dragSessionGenerationProvider()
        super.mouseDown(with: event)
        if dragSessionGeneration == dragSessionGenerationProvider() {
            beginSelectionHandler?(.click)
        }
        finishSelectionHandler?()
        if isPlainDoubleClick(event), dragSessionGeneration == dragSessionGenerationProvider() {
            doubleClickHandler?()
        }
    }

    private func isPlainDoubleClick(_ event: NSEvent) -> Bool {
        event.clickCount == 2
            && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    private func nativeSelectionMouseDownEvent(
        from event: NSEvent,
        gesture: TabSelectionModel.Gesture
    ) -> NSEvent {
        guard gesture != .click else { return event }
        return NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting([.command, .shift]),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
