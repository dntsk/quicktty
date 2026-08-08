import AppKit

@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var toggleCallback: (@MainActor () -> Void)?

    var isMenuBarActive: Bool { statusItem != nil }

    init() {}

    func setToggleCallback(_ callback: @escaping @MainActor () -> Void) {
        toggleCallback = callback
    }

    func activateMenuBar() {
        guard statusItem == nil else { return }

        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        statusItem = item
    }

    func deactivateMenuBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        NSApp.setActivationPolicy(.regular)
    }

    func applyMode(_ mode: PresentationMode) {
        switch mode {
        case .normal:
            deactivateMenuBar()
        case .quake:
            activateMenuBar()
        }
    }

    @objc private func statusItemClicked() {
        toggleCallback?()
    }
}
