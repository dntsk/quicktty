import AppKit

@MainActor
final class TabItemView: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TabItemView")

    private let backgroundView = TabItemBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let broadcastIndicator = NSImageView()
    private let closeButton = NSButton()
    private var closeHandler: (() -> Void)?

    override func loadView() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view = backgroundView

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        broadcastIndicator.image = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "Broadcast input enabled"
        )
        broadcastIndicator.contentTintColor = .systemOrange
        broadcastIndicator.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        broadcastIndicator.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close tab"
        )
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close Tab"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.addSubview(broadcastIndicator)
        backgroundView.addSubview(titleLabel)
        backgroundView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            broadcastIndicator.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor, constant: 9),
            broadcastIndicator.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            broadcastIndicator.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(
                equalTo: broadcastIndicator.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            closeButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 5),
            closeButton.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 17),
            closeButton.heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    func configure(
        title: String,
        isActive: Bool,
        isSelected: Bool,
        isBroadcasting: Bool,
        selectHandler: @escaping (TabSelectionModel.Gesture) -> Void,
        closeHandler: @escaping () -> Void,
        menuProvider: @escaping () -> NSMenu
    ) {
        titleLabel.stringValue = title
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        broadcastIndicator.isHidden = !isBroadcasting
        backgroundView.isActive = isActive
        backgroundView.isSelected = isSelected
        backgroundView.selectHandler = selectHandler
        backgroundView.menuProvider = menuProvider
        self.closeHandler = closeHandler
        view.toolTip = title
        view.identifier = NSUserInterfaceItemIdentifier("tab-\(title)")
    }

    @objc private func closeTab() {
        closeHandler?()
    }
}

@MainActor
private final class TabItemBackgroundView: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    var selectHandler: ((TabSelectionModel.Gesture) -> Void)?
    var menuProvider: (() -> NSMenu)?

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()
        } else if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let gesture: TabSelectionModel.Gesture
        if event.modifierFlags.contains(.shift) {
            gesture = .shiftClick
        } else if event.modifierFlags.contains(.command) {
            gesture = .commandClick
        } else {
            gesture = .click
        }
        selectHandler?(gesture)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
