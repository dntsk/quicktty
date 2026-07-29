import AppKit

enum SearchNavigation: Equatable {
    case next
    case previous
}

final class SearchOverlayView: NSView {
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var localKeyMonitor: Any?

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
        searchField.font = .systemFont(
            ofSize: NSFont.systemFontSize)

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
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                if self?.handleSearchKeyEvent(event) == true {
                    return nil
                }
                return event
            }
        }
    }

    func dismiss() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func handleSearchKeyEvent(_ event: NSEvent) -> Bool {
        let editor = searchField.currentEditor()
        guard
            window?.firstResponder === searchField
                || window?.firstResponder === editor
        else { return false }

        // Only intercept when no modifier keys are held
        guard
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == []
        else {
            return false
        }

        switch event.keyCode {
        case 126:  // Up arrow
            onNavigate?(.previous)
            return true
        case 125:  // Down arrow
            onNavigate?(.next)
            return true
        case 53:  // Escape
            onClose?(true)
            return true
        case 36, 76:  // Return, Enter
            onClose?(false)
            return true
        default:
            return false
        }
    }

    @objc private func searchFieldDidChange() {
        onNeedleChange?(searchField.stringValue)
    }
}
