import AppKit
import SwiftUI

@MainActor
struct SurfaceErrorPlaceholder: NSViewRepresentable {
    let presentation: SurfaceFailurePresentation
    let palette: GhosttyChromePalette
    let onRetry: @MainActor () -> Void
    let onClosePane: @MainActor () -> Void

    func makeNSView(context _: Context) -> SurfaceErrorPlaceholderView {
        SurfaceErrorPlaceholderView()
    }

    func updateNSView(_ view: SurfaceErrorPlaceholderView, context _: Context) {
        view.apply(
            presentation: presentation,
            palette: palette,
            onRetry: onRetry,
            onClosePane: onClosePane
        )
    }
}

@MainActor
struct AgentResumeErrorPlaceholder: NSViewRepresentable {
    let presentation: AgentResumePresentation
    let palette: GhosttyChromePalette
    let onRetry: @MainActor () -> Void
    let onForget: @MainActor () -> Void

    func makeNSView(context _: Context) -> SurfaceErrorPlaceholderView {
        SurfaceErrorPlaceholderView()
    }

    func updateNSView(_ view: SurfaceErrorPlaceholderView, context _: Context) {
        view.apply(
            agentResumePresentation: presentation,
            palette: palette,
            onRetry: onRetry,
            onForget: onForget
        )
    }
}

@MainActor
final class SurfaceErrorPlaceholderView: NSView {
    private enum Metrics {
        static let contentPadding: CGFloat = 20
        static let contentSpacing: CGFloat = 12
        static let maximumContentWidth: CGFloat = 480
    }

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Terminal unavailable")
    private let messageLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "Close Pane", target: nil, action: nil)
    private lazy var buttonStack = NSStackView(views: [retryButton, secondaryButton])
    private lazy var contentStack = NSStackView(views: [titleLabel, messageLabel, buttonStack])
    private var buttonWidthConstraint: NSLayoutConstraint?
    private var buttonHeightConstraint: NSLayoutConstraint?
    private var contentWidthConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?
    private var onRetry: (@MainActor () -> Void)?
    private var onSecondaryAction: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.alignment = .center
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0

        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel("Retry")
        retryButton.target = self
        retryButton.action = #selector(retry)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.setAccessibilityLabel("Close Pane")
        secondaryButton.target = self
        secondaryButton.action = #selector(performSecondaryAction)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        let buttonWidthConstraint = buttonStack.widthAnchor.constraint(
            equalToConstant: naturalButtonSize.width
        )
        let buttonHeightConstraint = buttonStack.heightAnchor.constraint(
            equalToConstant: naturalButtonSize.height
        )
        self.buttonWidthConstraint = buttonWidthConstraint
        self.buttonHeightConstraint = buttonHeightConstraint
        NSLayoutConstraint.activate([buttonWidthConstraint, buttonHeightConstraint])

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = Metrics.contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let contentWidthConstraint = contentStack.widthAnchor.constraint(
            equalToConstant: ceil(max(titleLabel.fittingSize.width, buttonStack.fittingSize.width))
        )
        let contentHeightConstraint = contentStack.heightAnchor.constraint(
            equalToConstant: naturalContentHeight
        )
        self.contentWidthConstraint = contentWidthConstraint
        self.contentHeightConstraint = contentHeightConstraint
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: documentView.centerYAnchor),
            messageLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            contentWidthConstraint,
            contentHeightConstraint,
        ])

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.clipsToBounds = true
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    func apply(
        presentation: SurfaceFailurePresentation,
        palette: GhosttyChromePalette,
        onRetry: @escaping @MainActor () -> Void,
        onClosePane: @escaping @MainActor () -> Void
    ) {
        applyContent(
            title: "Terminal unavailable",
            message: presentation.message,
            retryTitle: "Retry",
            secondaryTitle: "Close Pane",
            accessibilityLabel: "Terminal unavailable",
            accessibilityValue: presentation.message,
            palette: palette,
            onRetry: onRetry,
            onSecondaryAction: onClosePane
        )
    }

    func apply(
        agentResumePresentation presentation: AgentResumePresentation,
        palette: GhosttyChromePalette,
        onRetry: @escaping @MainActor () -> Void,
        onForget: @escaping @MainActor () -> Void
    ) {
        applyContent(
            title: presentation.title,
            message: presentation.message,
            retryTitle: presentation.canRetry ? "Retry Resume" : nil,
            secondaryTitle: "Forget Agent Session",
            accessibilityLabel: presentation.accessibilityLabel,
            accessibilityValue: presentation.accessibilityValue,
            palette: palette,
            onRetry: onRetry,
            onSecondaryAction: onForget
        )
    }

    private func applyContent(
        title: String,
        message: String,
        retryTitle: String?,
        secondaryTitle: String,
        accessibilityLabel: String,
        accessibilityValue: String,
        palette: GhosttyChromePalette,
        onRetry: @escaping @MainActor () -> Void,
        onSecondaryAction: @escaping @MainActor () -> Void
    ) {
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        retryButton.title = retryTitle ?? ""
        retryButton.isHidden = retryTitle == nil
        secondaryButton.title = secondaryTitle
        let buttonSize = naturalButtonSize
        contentWidthConstraint?.constant = ceil(
            max(titleLabel.fittingSize.width, buttonSize.width)
        )
        buttonWidthConstraint?.constant = buttonSize.width
        buttonHeightConstraint?.constant = buttonSize.height
        contentHeightConstraint?.constant = naturalContentHeight
        retryButton.setAccessibilityLabel(retryTitle)
        secondaryButton.setAccessibilityLabel(secondaryTitle)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(accessibilityValue)
        needsLayout = true
        self.onRetry = onRetry
        self.onSecondaryAction = onSecondaryAction

        let foreground = NSColor(ghosttyRGB: palette.foreground)
        titleLabel.textColor = foreground
        messageLabel.textColor = foreground
        retryButton.contentTintColor = foreground
        secondaryButton.contentTintColor = foreground
        layer?.backgroundColor = NSColor(ghosttyRGB: palette.background).cgColor
    }

    private func layoutDocument() {
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width.isFinite, viewportSize.height.isFinite else {
            return
        }

        let minimumContentWidth = ceil(
            max(titleLabel.fittingSize.width, buttonStack.fittingSize.width)
        )
        let availableContentWidth = max(
            minimumContentWidth,
            viewportSize.width - (Metrics.contentPadding * 2)
        )
        let contentWidth = min(Metrics.maximumContentWidth, availableContentWidth)
        contentWidthConstraint?.constant = max(1, contentWidth)
        messageLabel.preferredMaxLayoutWidth = contentWidth
        contentHeightConstraint?.constant = naturalContentHeight

        documentView.frame.size.width = ceil(
            max(viewportSize.width, contentWidth + (Metrics.contentPadding * 2))
        )
        documentView.layoutSubtreeIfNeeded()
        documentView.frame.size.height = ceil(
            max(
                viewportSize.height,
                naturalContentHeight + (Metrics.contentPadding * 2)
            )
        )
        documentView.layoutSubtreeIfNeeded()

        let maximumOrigin = NSPoint(
            x: max(0, documentView.frame.width - viewportSize.width),
            y: max(0, documentView.frame.height - viewportSize.height)
        )
        let currentOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(
            to: NSPoint(
                x: min(max(0, currentOrigin.x), maximumOrigin.x),
                y: min(max(0, currentOrigin.y), maximumOrigin.y)
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var naturalButtonSize: NSSize {
        let retrySize = retryButton.isHidden ? .zero : retryButton.fittingSize
        let secondarySize = secondaryButton.fittingSize
        return NSSize(
            width: retrySize.width + secondarySize.width
                + (retryButton.isHidden ? 0 : buttonStack.spacing),
            height: max(retrySize.height, secondarySize.height)
        )
    }

    private var naturalContentHeight: CGFloat {
        ceil(
            titleLabel.fittingSize.height + messageLabel.fittingSize.height
                + buttonStack.fittingSize.height + (Metrics.contentSpacing * 2)
        )
    }

    @objc
    private func retry() {
        onRetry?()
    }

    @objc
    private func performSecondaryAction() {
        onSecondaryAction?()
    }
}
