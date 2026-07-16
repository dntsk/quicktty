import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    var onActivateWorkspace: ((WorkspaceID) -> Void)?
    var onActivateTab: ((TabID) -> Void)?
    var onCloseTab: ((TabID) -> Void)?
    var onMoveToNewWorkspace: (([TabID]) -> Void)?
    var onMoveToWorkspace: (([TabID], WorkspaceID) -> Void)?
    var onReorderTabs: (([TabID]) -> Void)?

    let workspaceSelector = WorkspaceSelector()
    let tabBarViewController = TabBarViewController()
    private let terminalContentView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No tabs in this workspace")
    private weak var displayedTerminalView: NSView?

    override func loadView() {
        let rootView = NSView()

        let chrome = NSVisualEffectView()
        chrome.material = .headerView
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.translatesAutoresizingMaskIntoConstraints = false

        workspaceSelector.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(workspaceSelector)

        addChild(tabBarViewController)
        let tabBarView = tabBarViewController.view
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(tabBarView)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        terminalContentView.identifier = NSUserInterfaceItemIdentifier("terminal-content")
        terminalContentView.wantsLayer = true
        terminalContentView.layer?.backgroundColor = NSColor.black.cgColor
        terminalContentView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalContentView.addSubview(emptyLabel)

        rootView.addSubview(chrome)
        rootView.addSubview(separator)
        rootView.addSubview(terminalContentView)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: rootView.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 38),
            workspaceSelector.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 10),
            workspaceSelector.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            workspaceSelector.widthAnchor.constraint(equalToConstant: 148),
            tabBarView.leadingAnchor.constraint(
                equalTo: workspaceSelector.trailingAnchor, constant: 8),
            tabBarView.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            tabBarView.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 2),
            tabBarView.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -2),
            separator.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            terminalContentView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            terminalContentView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            terminalContentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            terminalContentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: terminalContentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalContentView.centerYAnchor),
        ])
        view = rootView

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
