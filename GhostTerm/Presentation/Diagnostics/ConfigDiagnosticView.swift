import AppKit

@MainActor
final class ConfigDiagnosticView: NSView {
    private static let maximumMessageCount = 8

    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true

        messageLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.usesSingleLineMode = false
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func apply(_ presentation: ConfigDiagnosticPresentation?) {
        guard let presentation, !presentation.messages.isEmpty else {
            messageLabel.stringValue = ""
            isHidden = true
            return
        }

        let displayedMessages = presentation.messages.prefix(Self.maximumMessageCount)
        var lines = [presentation.path] + displayedMessages
        let remainingCount = presentation.messages.count - displayedMessages.count
        if remainingCount > 0 {
            lines.append("… and \(remainingCount) more")
        }
        messageLabel.stringValue = lines.joined(separator: "\n")
        isHidden = false
    }

    func applyChromePalette(_ palette: GhosttyChromePalette) {
        let foregroundColor = NSColor(ghosttyRGB: palette.foreground)
        messageLabel.textColor = foregroundColor
        layer?.backgroundColor = foregroundColor.withAlphaComponent(0.2).cgColor
        appearance = NSAppearance(named: palette.usesDarkAppearance ? .darkAqua : .aqua)
    }

    #if DEBUG
        var textForTesting: String {
            messageLabel.stringValue
        }
    #endif
}
