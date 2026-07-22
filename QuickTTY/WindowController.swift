import AppKit

@MainActor
final class WindowController: NSWindowController {
    init() {
        let contentViewController = NSViewController()
        contentViewController.view = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "QuickTTY"
        window.contentViewController = contentViewController
        window.center()

        super.init(window: window)
    }

    func embed(_ viewController: NSViewController) {
        guard let contentViewController else { return }
        contentViewController.addChild(viewController)
        let view = viewController.view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentViewController.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentViewController.view.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentViewController.view.leadingAnchor),
            view.bottomAnchor.constraint(equalTo: contentViewController.view.bottomAnchor),
            view.trailingAnchor.constraint(equalTo: contentViewController.view.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
