import AppKit

@MainActor
final class NormalWindowController: NSWindowController, PresentationWindowContainer {
    init(
        contentRect: NSRect = NSRect(x: 0, y: 0, width: 960, height: 640),
        title: String = "GhostTerm"
    ) {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
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
        window.contentViewController = contentViewController
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
