import AppKit

@MainActor
final class NormalWindowController: NSWindowController, PresentationWindowContainer {
    private var isRetiredForTermination = false

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

    // WHY: Freeze leaves native ownership untouched; only explicit coordinator teardown hides.
    func retireForApplicationTermination() {
        isRetiredForTermination = true
    }

    func setPresentationFrame(_ frame: NSRect) {
        guard !isRetiredForTermination else { return }
        window?.setFrame(frame, display: false)
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        guard !isRetiredForTermination else { return }
        guard let window else { throw PresentationContainerError.windowUnavailable }
        if let contentViewController {
            let view = contentViewController.view
            guard !isRetiredForTermination else { return }
            view.removeFromSuperview()
            guard !isRetiredForTermination else { return }
            contentViewController.removeFromParent()
            guard !isRetiredForTermination else { return }
        }
        let frame = window.frame
        window.contentViewController = contentViewController
        // WHY: AppKit can change the frame and call the persistence delegate during assignment.
        guard !isRetiredForTermination else { return }
        window.setFrame(frame, display: false)
    }

    func showPresentationWindow() throws {
        guard !isRetiredForTermination else { return }
        guard let window else { throw PresentationContainerError.windowUnavailable }
        showWindow(nil)
        guard !isRetiredForTermination else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func hidePresentationWindow() {
        guard !isRetiredForTermination else { return }
        window?.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
