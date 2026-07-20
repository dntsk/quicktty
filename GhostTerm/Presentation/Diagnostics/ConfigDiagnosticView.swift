import AppKit

@MainActor
final class ConfigDiagnosticView: NSView {
    private static let maximumMessageCount = 8
    private static let maximumVisualLineCount = 10
    private static let maximumHeight: CGFloat = 160
    private static let accessibilityAnnouncement = "Configuration diagnostics available"

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var displayedPresentation: ConfigDiagnosticPresentation?

    #if DEBUG
        var announcementObserverForTesting: ((String) -> Void)?
    #endif

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
        messageLabel.maximumNumberOfLines = Self.maximumVisualLineCount
        messageLabel.cell?.truncatesLastVisibleLine = true
        messageLabel.usesSingleLineMode = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(lessThanOrEqualToConstant: Self.maximumHeight),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        "Configuration diagnostics"
    }

    override func accessibilityValue() -> Any? {
        isHidden ? nil : messageLabel.stringValue
    }

    func apply(_ presentation: ConfigDiagnosticPresentation?) {
        guard let presentation, !presentation.messages.isEmpty else {
            displayedPresentation = nil
            messageLabel.stringValue = ""
            isHidden = true
            return
        }

        let shouldAnnounce = isHidden || displayedPresentation != presentation
        displayedPresentation = presentation
        messageLabel.stringValue = renderedText(for: presentation)
        isHidden = false

        if shouldAnnounce {
            announceDiagnostics()
        }
    }

    private func renderedText(for presentation: ConfigDiagnosticPresentation) -> String {
        let displayedMessages = presentation.messages.prefix(Self.maximumMessageCount)
        var lines = [normalizedLine(presentation.path)] + displayedMessages.map(normalizedLine)
        let remainingCount = presentation.messages.count - displayedMessages.count
        if remainingCount > 0 {
            lines.append("… and \(remainingCount) more")
        }
        return lines.joined(separator: "\n")
    }

    private func normalizedLine(_ value: String) -> String {
        var normalized = String()
        normalized.reserveCapacity(value.count)
        var previousWasWhitespace = true

        for character in value {
            if character.isWhitespace {
                if !previousWasWhitespace {
                    normalized.append(" ")
                    previousWasWhitespace = true
                }
                continue
            }

            normalized.append(character)
            previousWasWhitespace = false
        }

        if normalized.last == " " {
            normalized.removeLast()
        }

        return normalized
    }

    private func announceDiagnostics() {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: Self.accessibilityAnnouncement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )

        #if DEBUG
            announcementObserverForTesting?(Self.accessibilityAnnouncement)
        #endif
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

        var maximumNumberOfLinesForTesting: Int {
            messageLabel.maximumNumberOfLines
        }

        var maximumHeightForTesting: CGFloat {
            Self.maximumHeight
        }

        var appearanceNameForTesting: NSAppearance.Name? {
            effectiveAppearance.name
        }

        var foregroundRGBAForTesting: [CGFloat]? {
            normalizedRGBA(messageLabel.textColor)
        }

        var backgroundRGBAForTesting: [CGFloat]? {
            guard let color = layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else {
                return nil
            }
            return normalizedRGBA(color)
        }

        private func normalizedRGBA(_ color: NSColor?) -> [CGFloat]? {
            guard let color = color?.usingColorSpace(.sRGB) else { return nil }
            return [
                color.redComponent,
                color.greenComponent,
                color.blueComponent,
                color.alphaComponent,
            ]
        }
    #endif
}
