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
    private let closeButton = NSButton(title: "Close Pane", target: nil, action: nil)
    private lazy var buttonStack = NSStackView(views: [retryButton, closeButton])
    private lazy var contentStack = NSStackView(views: [titleLabel, messageLabel, buttonStack])
    private var contentWidthConstraint: NSLayoutConstraint?
    private var contentHeightConstraint: NSLayoutConstraint?
    private var onRetry: (@MainActor () -> Void)?
    private var onClosePane: (@MainActor () -> Void)?

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
        closeButton.bezelStyle = .rounded
        closeButton.setAccessibilityLabel("Close Pane")
        closeButton.target = self
        closeButton.action = #selector(closePane)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        NSLayoutConstraint.activate([
            buttonStack.widthAnchor.constraint(equalToConstant: buttonStack.fittingSize.width),
            buttonStack.heightAnchor.constraint(
                equalToConstant: max(retryButton.fittingSize.height, closeButton.fittingSize.height)
            ),
        ])

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
        messageLabel.stringValue = presentation.message
        needsLayout = true
        self.onRetry = onRetry
        self.onClosePane = onClosePane

        let foreground = NSColor(ghosttyRGB: palette.foreground)
        titleLabel.textColor = foreground
        messageLabel.textColor = foreground
        retryButton.contentTintColor = foreground
        closeButton.contentTintColor = foreground
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
    private func closePane() {
        onClosePane?()
    }
}
