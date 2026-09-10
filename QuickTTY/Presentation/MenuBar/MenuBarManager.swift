import AppKit

@MainActor
final class MenuBarManager {
    private let systemPresentationEnabled: Bool
    private var statusItem: NSStatusItem?
    private var toggleCallback: (@MainActor () -> Void)?

    var isMenuBarActive: Bool { statusItem != nil }

    init(systemPresentationEnabled: Bool = true) {
        self.systemPresentationEnabled = systemPresentationEnabled
    }

    isolated deinit {
        // WHY: Remove only our item; cleanup must not change another owner's Dock policy.
        removeStatusItem()
    }

    func setToggleCallback(_ callback: @escaping @MainActor () -> Void) {
        toggleCallback = callback
    }

    func activateMenuBar() {
        guard systemPresentationEnabled, statusItem == nil else { return }

        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            configure(button: button)
        }
        statusItem = item
    }

    func configure(button: NSStatusBarButton) {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusItemClicked)
        button.setAccessibilityLabel("QuickTTY")
    }

    func deactivateMenuBar() {
        guard systemPresentationEnabled else { return }

        removeStatusItem()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
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
