import AppKit

@MainActor
final class AgentIntegrationsSheetController: NSObject, NSWindowDelegate {
    let viewController: AgentIntegrationsViewController
    let sheetWindow: NSWindow

    private weak var parentWindow: NSWindow?
    private let restoreTerminalFocus: @MainActor () -> Void
    private var isDetachingForTransition = false
    private(set) var isPresented = false

    init(
        viewController: AgentIntegrationsViewController,
        restoreTerminalFocus: @escaping @MainActor () -> Void
    ) {
        self.viewController = viewController
        self.restoreTerminalFocus = restoreTerminalFocus
        sheetWindow = NSWindow(contentViewController: viewController)
        super.init()
        sheetWindow.title = "Agent Integrations"
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.contentMinSize = NSSize(width: 620, height: 460)
        sheetWindow.setAccessibilityLabel("Agent Integrations")
        sheetWindow.delegate = self
        viewController.onRequestClose = { [weak self] in
            self?.close()
        }
    }

    isolated deinit {
        viewController.cancelDismissibleTasks()
        if sheetWindow.delegate === self {
            sheetWindow.delegate = nil
        }
    }

    func present(on window: NSWindow) {
        if isPresented {
            if parentWindow !== window {
                reattach(to: window)
            }
            sheetWindow.makeKeyAndOrderFront(nil)
            return
        }
        parentWindow = window
        isPresented = true
        viewController.reload()
        window.beginSheet(sheetWindow)
    }

    @discardableResult
    func detachForWindowTransition() -> Bool {
        guard isPresented, let parentWindow else { return false }
        isDetachingForTransition = true
        parentWindow.endSheet(sheetWindow)
        sheetWindow.orderOut(nil)
        self.parentWindow = nil
        isDetachingForTransition = false
        return true
    }

    func reattachAfterWindowTransition(to window: NSWindow, wasPresented: Bool) {
        guard wasPresented else { return }
        parentWindow = window
        isPresented = true
        window.beginSheet(sheetWindow)
    }

    func reattach(to window: NSWindow) {
        guard isPresented, parentWindow !== window else { return }
        let wasPresented = detachForWindowTransition()
        reattachAfterWindowTransition(to: window, wasPresented: wasPresented)
    }

    func close() {
        guard isPresented, viewController.canDismiss else { return }
        viewController.cancelDismissibleTasks()
        let parent = parentWindow
        isPresented = false
        parentWindow = nil
        if let parent {
            parent.endSheet(sheetWindow)
        }
        sheetWindow.orderOut(nil)
        restoreTerminalFocus()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard viewController.canDismiss else { return false }
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isDetachingForTransition else { return }
        viewController.cancelDismissibleTasks()
    }

    #if DEBUG
        var parentWindowForTesting: NSWindow? { parentWindow }
    #endif
}
