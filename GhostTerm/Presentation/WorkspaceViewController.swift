import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    static let chromeHeight: CGFloat = 28

    var onActivateWorkspace: ((WorkspaceID) -> Void)?
    var onActivateTab: ((TabID) -> Void)?
    var onCloseTab: ((TabID) -> Void)?
    var onMoveToNewWorkspace: (([TabID]) -> Void)?
    var onMoveToWorkspace: (([TabID], WorkspaceID) -> Void)?
    var onReorderTabs: (([TabID]) -> Void)?

    let workspaceSelector = WorkspaceSelector()
    let tabBarViewController = TabBarViewController()
    private let chromeView = NSView()
    private let terminalContentView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No tabs in this workspace")
    private var chromePalette = GhosttyChromePalette.fallback
    private weak var displayedTerminalView: NSView?

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true

        chromeView.wantsLayer = true
        chromeView.translatesAutoresizingMaskIntoConstraints = false

        workspaceSelector.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(workspaceSelector)

        addChild(tabBarViewController)
        let tabBarView = tabBarViewController.view
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(tabBarView)

        terminalContentView.identifier = NSUserInterfaceItemIdentifier("terminal-content")
        terminalContentView.wantsLayer = true
        terminalContentView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalContentView.addSubview(emptyLabel)

        rootView.addSubview(chromeView)
        rootView.addSubview(terminalContentView)
        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: rootView.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            chromeView.heightAnchor.constraint(equalToConstant: Self.chromeHeight),
            tabBarView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 6),
            tabBarView.trailingAnchor.constraint(
                equalTo: workspaceSelector.leadingAnchor, constant: -8),
            workspaceSelector.trailingAnchor.constraint(
                equalTo: chromeView.trailingAnchor, constant: -10),
            workspaceSelector.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            workspaceSelector.widthAnchor.constraint(equalToConstant: 148),
            tabBarView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            tabBarView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            terminalContentView.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            terminalContentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            terminalContentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            terminalContentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: terminalContentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalContentView.centerYAnchor),
        ])
        view = rootView
        applyChromePalette(chromePalette)

        workspaceSelector.onSelection = { [weak self] workspaceID in
            self?.onActivateWorkspace?(workspaceID)
        }
        tabBarViewController.onActivateTab = { [weak self] tabID in
            self?.onActivateTab?(tabID)
        }
        tabBarViewController.onCloseTab = { [weak self] tabID in
            self?.onCloseTab?(tabID)
        }
        tabBarViewController.onMoveToNewWorkspace = { [weak self] tabIDs in
            self?.onMoveToNewWorkspace?(tabIDs)
        }
        tabBarViewController.onMoveToWorkspace = { [weak self] tabIDs, workspaceID in
            self?.onMoveToWorkspace?(tabIDs, workspaceID)
        }
        tabBarViewController.onReorderTabs = { [weak self] orderedIDs in
            self?.onReorderTabs?(orderedIDs)
        }
    }

    func applyChromePalette(_ palette: GhosttyChromePalette) {
        chromePalette = palette
        loadViewIfNeeded()

        let backgroundColor = NSColor(ghosttyRGB: palette.background)
        chromeView.layer?.backgroundColor = backgroundColor.cgColor
        terminalContentView.layer?.backgroundColor = backgroundColor.cgColor

        let appearanceName: NSAppearance.Name = palette.usesDarkAppearance ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName)
        view.appearance = appearance
        chromeView.appearance = appearance
        tabBarViewController.applyChromePalette(palette)
    }

    func apply(_ store: WorkspaceStore) {
        loadViewIfNeeded()
        workspaceSelector.apply(
            workspaces: store.workspaces,
            activeWorkspaceID: store.activeWorkspaceID
        )
        let activeWorkspace = store.workspace(id: store.activeWorkspaceID)
        let destinations = store.workspaces.compactMap { workspace in
            workspace.id == store.activeWorkspaceID
                ? nil
                : TabBarViewController.WorkspaceDestination(
                    id: workspace.id,
                    name: workspace.name
                )
        }
        tabBarViewController.apply(
            tabs: activeWorkspace?.tabs ?? [],
            activeTabID: activeWorkspace?.activeTabID,
            destinations: destinations
        )
    }

    #if DEBUG
        var chromePaletteForTesting: GhosttyChromePalette {
            chromePalette
        }

        var chromeAppearanceNameForTesting: NSAppearance.Name? {
            chromeView.effectiveAppearance.name
        }

        var chromeBackgroundColorForTesting: NSColor? {
            guard let color = chromeView.layer?.backgroundColor else { return nil }
            return NSColor(cgColor: color)
        }

        var terminalFallbackColorForTesting: NSColor? {
            guard let color = terminalContentView.layer?.backgroundColor else { return nil }
            return NSColor(cgColor: color)
        }
    #endif

    func displayTerminal(_ terminalView: NSView?) {
        loadViewIfNeeded()
        guard displayedTerminalView !== terminalView else { return }

        displayedTerminalView?.removeFromSuperview()
        displayedTerminalView = terminalView
        guard let terminalView else {
            emptyLabel.isHidden = false
            return
        }

        emptyLabel.isHidden = true
        terminalView.removeFromSuperview()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalContentView.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalContentView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContentView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContentView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContentView.bottomAnchor),
        ])
    }
}

extension NSColor {
    convenience init(ghosttyRGB color: GhosttyRGB) {
        self.init(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
