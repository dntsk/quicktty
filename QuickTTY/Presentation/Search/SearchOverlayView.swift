import AppKit

enum SearchNavigation: Equatable {
    case next
    case previous
}

final class SearchOverlayView: NSView {
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var debounceWork: DispatchWorkItem?
    private let debounceDelay: DispatchTimeInterval = .milliseconds(200)

    var onNeedleChange: ((String) -> Void)?
    var onNavigate: ((SearchNavigation) -> Void)?
    var onClose: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange)
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.refusesFirstResponder = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
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
            widthAnchor.constraint(equalToConstant: 280),
            heightAnchor.constraint(equalToConstant: 28),

            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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
        debounceWork?.cancel()
        let needle = searchField.stringValue
        guard !needle.isEmpty else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.onNeedleChange?(needle)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }
}

extension SearchOverlayView: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            onNavigate?(.previous)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onNavigate?(.next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?(true)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onClose?(false)
            return true
        default:
            return false
        }
    }
}
