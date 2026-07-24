import AppKit

@MainActor
final class TerminalStatusBadgeView: NSView {
    private let progressIndicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private var presentation: TerminalStatusPresentation?
    private var symbolName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        for subview in [progressIndicator, label, imageView] {
            subview.setAccessibilityElement(false)
            addSubview(subview)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        NSLayoutConstraint.activate([
            progressIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 12),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    override var intrinsicContentSize: NSSize {
        guard let presentation else { return .zero }
        if presentation.percent != nil,
            presentation.phase == .working || presentation.phase == .waiting
        {
            return NSSize(width: max(20, label.intrinsicContentSize.width), height: 14)
        }
        return NSSize(width: 13, height: 14)
    }

    func apply(_ presentation: TerminalStatusPresentation?) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        label.isHidden = true
        imageView.isHidden = true
        symbolName = nil
        isHidden = presentation == nil

        guard let presentation else {
            toolTip = nil
            setAccessibilityLabel(nil)
            invalidateIntrinsicContentSize()
            return
        }

        toolTip = presentation.accessibilityLabel
        setAccessibilityLabel(presentation.accessibilityLabel)
        switch (presentation.phase, presentation.percent) {
        case (.working, nil):
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case (.working, let percent?):
            showPercent(percent, color: .controlAccentColor)
        case (.waiting, let percent?):
            showPercent(percent, color: .systemOrange)
        case (.waiting, nil):
            showSymbol("pause.fill", color: .systemOrange)
        case (.failed, _):
            showSymbol("xmark.octagon.fill", color: .systemRed)
        case (.completed, _):
            showSymbol("checkmark.circle.fill", color: .systemGreen)
        }
        invalidateIntrinsicContentSize()
    }

    private func showPercent(_ percent: Int, color: NSColor) {
        label.stringValue = "\(percent)%"
        label.textColor = color
        label.isHidden = false
    }

    private func showSymbol(_ name: String, color: NSColor) {
        symbolName = name
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        imageView.contentTintColor = color
        imageView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        imageView.isHidden = false
    }

    #if DEBUG
        var representationForTesting: String? {
            guard presentation != nil else { return nil }
            if !progressIndicator.isHidden { return "spinner" }
            if !label.isHidden { return label.stringValue }
            return symbolName
        }

        var usesNativeSpinnerForTesting: Bool {
            !progressIndicator.isHidden && progressIndicator.style == .spinning
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
