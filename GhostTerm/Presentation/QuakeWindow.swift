import AppKit

@MainActor
final class QuakeWindow: NSPanel, QuakeWindowRepresenting {
    static let minimumContentHeight: CGFloat = 200

    init(contentRect: NSRect = .zero) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "GhostTerm Quake Terminal"
        level = .floating
        contentMinSize = NSSize(width: 0, height: Self.minimumContentHeight)
        minSize = NSSize(width: 0, height: Self.minimumContentHeight)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setAccessibilityLabel("GhostTerm Quake Terminal")
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    var presentationFrame: NSRect { frame }

    var isPresentationVisible: Bool { isVisible }

    var installedContentViewController: NSViewController? { contentViewController }

    var hasAttachedSheet: Bool { attachedSheet != nil }

    func setPresentationFrame(_ frame: NSRect) {
        setFrame(frame, display: true)
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        if let contentViewController {
            contentViewController.view.removeFromSuperview()
            contentViewController.removeFromParent()
        }
        self.contentViewController = contentViewController
    }

    func setPresentationLevel(_ level: QuakePresentationLevel) {
        self.level =
            switch level {
            case .floating: .floating
            case .popUpMenu: .popUpMenu
            }
    }

    func orderFrontForPresentation() {
        orderFrontRegardless()
    }

    func focusForPresentation() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func orderOutForPresentation() {
        orderOut(nil)
    }
}
