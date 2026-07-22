import AppKit

@MainActor
final class NormalWindowController: NSWindowController, PresentationWindowContainer {
    static let defaultContentSize = NSSize(width: 1_100, height: 700)
    static let minimumContentSize = NSSize(width: 720, height: 440)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    static var minimumFrameSize: NSSize {
        NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize),
            styleMask: styleMask
        ).size
    }

    init(
        contentRect: NSRect = NSRect(origin: .zero, size: defaultContentSize),
        title: String = "QuickTTY"
    ) {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: Self.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = Self.minimumContentSize
        window.minSize = Self.minimumFrameSize
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    var presentationFrame: NSRect {
        window?.frame ?? .zero
    }

    var isPresentationVisible: Bool {
        window?.isVisible ?? false
    }

    var installedContentViewController: NSViewController? {
        window?.contentViewController
    }

    func setPresentationFrame(_ frame: NSRect) {
        window?.setFrame(frame, display: false)
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        guard let window else { throw PresentationContainerError.windowUnavailable }
        if let contentViewController {
            contentViewController.view.removeFromSuperview()
            contentViewController.removeFromParent()
        }
        let frame = window.frame
        window.contentViewController = contentViewController
        window.setFrame(frame, display: false)
    }

    func showPresentationWindow() throws {
        guard let window else { throw PresentationContainerError.windowUnavailable }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func hidePresentationWindow() {
        window?.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
