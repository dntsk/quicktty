import AppKit

enum SearchNavigation: Equatable {
    case next
    case previous
}

final class SearchOverlayView: NSView {
    private let searchField = SearchTextField()
    private let countLabel = NSTextField(labelWithString: "")

    var onNeedleChange: ((String) -> Void)?
    var onNavigate: ((SearchNavigation) -> Void)?
    var onClose: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor =
            NSColor.controlBackgroundColor
            .withAlphaComponent(0.97).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.refusesFirstResponder = false

        searchField.onNavigate = { [weak self] nav in
            self?.onNavigate?(nav)
        }
        searchField.onClose = { [weak self] clear in
            self?.onClose?(clear)
        }

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stackView = NSStackView(views: [searchField, countLabel])
        stackView.orientation = .horizontal
        stackView.spacing = 8
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 32),

            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateCount(selected: UInt?, total: UInt?) {
        let selText = selected.map { "\($0)" } ?? "-"
        let totalText = total.map { "\($0)" } ?? "-"
        countLabel.stringValue = "\(selText)/\(totalText)"
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func searchFieldDidChange() {
        onNeedleChange?(searchField.stringValue)
    }
}

// Custom NSSearchField that handles arrow keys for search navigation
private final class SearchTextField: NSSearchField {

    var onNavigate: ((SearchNavigation) -> Void)?
    var onClose: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == []
        else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 126:  // Up arrow
            onNavigate?(.previous)
        case 125:  // Down arrow
            onNavigate?(.next)
        case 53:  // Escape
            onClose?(true)
        case 36:  // Return
            onClose?(true)
        default:
            super.keyDown(with: event)
        }
    }
}
