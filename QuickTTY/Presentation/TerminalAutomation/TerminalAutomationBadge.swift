import AppKit
import SwiftUI

@MainActor
struct TerminalAutomationBadge: NSViewRepresentable {
    let presentation: TerminalAutomationPresentation
    let palette: GhosttyChromePalette
    let onReturnControl: @MainActor (UUID) -> Void

    func makeNSView(context _: Context) -> TerminalAutomationBadgeView {
        TerminalAutomationBadgeView()
    }

    func updateNSView(_ view: TerminalAutomationBadgeView, context _: Context) {
        view.apply(presentation, palette: palette, onReturnControl: onReturnControl)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView _: TerminalAutomationBadgeView, context _: Context
    ) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }

    static func dismantleNSView(_ view: TerminalAutomationBadgeView, coordinator _: ()) {
        view.invalidateAction()
    }
}

@MainActor
final class TerminalAutomationBadgeView: NSView {
    private static let edgeInset: CGFloat = 6
    private static let maximumPanelHeight: CGFloat = 52
    // WHY: Reserve the action-bearing height even without its button so search never jumps on takeover.
    static let searchReservedTopInset = edgeInset + maximumPanelHeight

    private let panel = NSView()
    private let label = NSTextField(labelWithString: "")
    private let returnButton = TerminalAutomationReturnButton(
        title: TerminalAutomationPresentation.returnControlTitle, target: nil, action: nil)
    private var presentation: TerminalAutomationPresentation?
    private var onReturnControl: (@MainActor (UUID) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        panel.wantsLayer = true
        panel.clipsToBounds = true
        panel.layer?.cornerRadius = 6
        addSubview(panel)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        panel.addSubview(label)
        returnButton.bezelStyle = .rounded
        returnButton.controlSize = .small
        returnButton.font = .systemFont(ofSize: 11)
        returnButton.target = self
        returnButton.action = #selector(returnControl)
        returnButton.setAccessibilityLabel(TerminalAutomationPresentation.returnControlTitle)
        panel.addSubview(returnButton)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func apply(
        _ presentation: TerminalAutomationPresentation,
        palette: GhosttyChromePalette,
        onReturnControl: @escaping @MainActor (UUID) -> Void
    ) {
        self.presentation = presentation
        self.onReturnControl = onReturnControl
        label.stringValue = presentation.badgeText
        returnButton.isHidden = !presentation.canReturnControl
        returnButton.isEnabled = presentation.canReturnControl
        panel.setAccessibilityLabel(presentation.accessibilityLabel)
        panel.setAccessibilityValue(presentation.accessibilityValue)
        panel.setAccessibilityChildren(presentation.canReturnControl ? [returnButton] : [])
        let foreground = NSColor(ghosttyRGB: palette.foreground)
        label.textColor = foreground
        returnButton.contentTintColor = foreground
        panel.layer?.backgroundColor =
            NSColor(
                ghosttyRGB: palette.background.blended(with: palette.foreground, fraction: 0.12)
            ).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = Self.edgeInset
        let naturalWidth =
            max(
                label.intrinsicContentSize.width,
                returnButton.isHidden ? 0 : returnButton.intrinsicContentSize.width) + 12
        let width = min(300, naturalWidth, max(0, bounds.width - inset * 2))
        let height = min(
            returnButton.isHidden ? 26 : Self.maximumPanelHeight, max(0, bounds.height - inset * 2))
        panel.frame = NSRect(
            x: bounds.maxX - inset - width, y: bounds.minY + inset, width: width, height: height)
        let contentWidth = max(0, width - 12)
        // WHY: The native panel is unflipped; keep its label above the optional action.
        label.frame = NSRect(x: 6, y: max(0, height - 21), width: contentWidth, height: 16)
        returnButton.frame = NSRect(
            x: 6, y: 3, width: min(contentWidth, returnButton.intrinsicContentSize.width),
            height: 24)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // WHY: AppKit supplies superview coordinates, including nonzero-origin split leaves.
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), !returnButton.isHidden,
            returnButton.isEnabled, panel.frame.contains(local)
        else { return nil }
        let inPanel = panel.convert(local, from: self)
        guard returnButton.frame.contains(inPanel) else { return nil }
        return returnButton.hitTest(inPanel)
    }

    func invalidateAction() {
        onReturnControl = nil
        returnButton.isEnabled = false
    }

    @objc
    private func returnControl() {
        guard window != nil, !isHiddenOrHasHiddenAncestor,
            let presentation, presentation.canReturnControl, returnButton.isEnabled
        else { return }
        onReturnControl?(presentation.taskID)
    }
}

@MainActor
private final class TerminalAutomationReturnButton: NSButton {
    // WHY: Clicking the action must not transfer terminal focus or select a different pane.
    override var acceptsFirstResponder: Bool { false }
}
