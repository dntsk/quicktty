import AppKit

@MainActor
final class QuakeWindow: NSPanel, QuakeWindowRepresenting {
    static let minimumContentHeight: CGFloat = 200

    // WHY: The controller installs a weak lifetime/retirement gate. Standalone panels
    // keep their existing behavior; a panel retained past its owner must fail closed.
    var canContinuePresentation: @MainActor () -> Bool = { true }
    private let activateApplication: @MainActor () -> Void

    init(
        contentRect: NSRect = .zero,
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "QuickTTY Quake Terminal"
        level = .floating
        contentMinSize = NSSize(width: 0, height: Self.minimumContentHeight)
        minSize = NSSize(width: 0, height: Self.minimumContentHeight)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setAccessibilityLabel("QuickTTY Quake Terminal")
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    var presentationFrame: NSRect { frame }

    var isPresentationVisible: Bool { isVisible }

    var installedContentViewController: NSViewController? { contentViewController }

    var hasAttachedSheet: Bool { attachedSheet != nil }

    func setPresentationFrame(_ frame: NSRect) {
        guard canContinuePresentation() else { return }
        setFrame(frame, display: true)
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        guard canContinuePresentation() else { return }
        if let contentViewController {
            let view = contentViewController.view
            guard canContinuePresentation() else { return }
            view.removeFromSuperview()
            guard canContinuePresentation() else { return }
            contentViewController.removeFromParent()
            guard canContinuePresentation() else { return }
        }
        self.contentViewController = contentViewController
    }

    func setPresentationLevel(_ level: QuakePresentationLevel) {
        guard canContinuePresentation() else { return }
        self.level =
            switch level {
            case .floating: .floating
            case .popUpMenu: .popUpMenu
            }
    }

    func orderFrontForPresentation() {
        guard canContinuePresentation() else { return }
        orderFrontRegardless()
    }

    func focusForPresentation() {
        guard canContinuePresentation() else { return }
        makeKeyAndOrderFront(nil)
        // WHY: Native responder restoration can persist selection and freeze the owner
        // synchronously. That call may finish, but activation is a separate operation.
        guard canContinuePresentation() else { return }
        activateApplication()
    }

    func orderOutForPresentation() {
        // WHY: Explicit teardown must still be able to hide a retired panel.
        orderOut(nil)
    }
}
