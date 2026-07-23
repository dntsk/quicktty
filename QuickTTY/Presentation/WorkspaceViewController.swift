import AppKit
import SwiftUI

@MainActor
final class WorkspaceViewController: NSViewController {
    static let chromeHeight: CGFloat = 28

    var onActivateWorkspace: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: (() -> Void)?
    var onDeleteWorkspace: (() -> Void)?
    var onWorkspaceMenuTrackingChanged: ((Bool) -> Void)?
    var onActivateTab: ((TabID) -> Void)?
    var onCloseTab: ((TabID) -> Void)?
    var onToggleBroadcast: (() -> Void)?
    var onMoveToNewWorkspace: (([TabID]) -> Void)?
    var onMoveToWorkspace: (([TabID], WorkspaceID) -> Void)?
    var onReorderTabs: (([TabID], TabID) -> Bool)?
    var onFinishReorderTabs: (() -> Void)?
    var onRenameTab: ((TabID, String) -> Void)?
    var onRenameEditingChanged: ((Bool) -> Void)?

    let workspaceSelector = WorkspaceSelector()
    let tabBarViewController = TabBarViewController()
    private let chromeView = NSView()
    private let terminalContentView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No tabs in this workspace")
    private let configurationDiagnosticView = ConfigDiagnosticView(frame: .zero)
    private var chromePalette = GhosttyChromePalette.fallback
    private var splitHostingController: NSHostingController<GhosttySplitTreeView>?
    private var splitHostingConstraints: [NSLayoutConstraint] = []
    private var splitResizeHandler: ((UUID, Double) -> Void)?
    private var splitEqualizeHandler: ((UUID) -> Void)?

    #if DEBUG
        private var hostedSurfacesForTesting: [PaneID: GhosttySurfaceView] = [:]
    #endif

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

        configurationDiagnosticView.translatesAutoresizingMaskIntoConstraints = false
        terminalContentView.addSubview(configurationDiagnosticView)

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
            configurationDiagnosticView.topAnchor.constraint(
                equalTo: terminalContentView.topAnchor,
                constant: 8
            ),
            configurationDiagnosticView.leadingAnchor.constraint(
                equalTo: terminalContentView.leadingAnchor,
                constant: 8
            ),
            configurationDiagnosticView.trailingAnchor.constraint(
                equalTo: terminalContentView.trailingAnchor,
                constant: -8
            ),
        ])
        view = rootView
        applyChromePalette(chromePalette)

        workspaceSelector.onSelection = { [weak self] workspaceID in
            self?.onActivateWorkspace?(workspaceID)
        }
        workspaceSelector.onCreateWorkspace = { [weak self] in
            self?.onCreateWorkspace?()
        }
        workspaceSelector.onRenameWorkspace = { [weak self] in
            self?.onRenameWorkspace?()
        }
        workspaceSelector.onDeleteWorkspace = { [weak self] in
            self?.onDeleteWorkspace?()
        }
        workspaceSelector.onMenuTrackingChanged = { [weak self] isTracking in
            self?.onWorkspaceMenuTrackingChanged?(isTracking)
        }
        tabBarViewController.onActivateTab = { [weak self] tabID in
            self?.onActivateTab?(tabID)
        }
        tabBarViewController.onCloseTab = { [weak self] tabID in
            self?.onCloseTab?(tabID)
        }
        tabBarViewController.onToggleBroadcast = { [weak self] in
            self?.onToggleBroadcast?()
        }
        tabBarViewController.onMoveToNewWorkspace = { [weak self] tabIDs in
            self?.onMoveToNewWorkspace?(tabIDs)
        }
        tabBarViewController.onMoveToWorkspace = { [weak self] tabIDs, workspaceID in
            self?.onMoveToWorkspace?(tabIDs, workspaceID)
        }
        tabBarViewController.onReorderTabs = { [weak self] orderedIDs, activeTabID in
            self?.onReorderTabs?(orderedIDs, activeTabID) ?? false
        }
        tabBarViewController.onFinishReorderTabs = { [weak self] in
            self?.onFinishReorderTabs?()
        }
        tabBarViewController.onRenameTab = { [weak self] tabID, title in
            self?.onRenameTab?(tabID, title)
        }
        tabBarViewController.onRenameEditingChanged = { [weak self] isEditing in
            self?.onRenameEditingChanged?(isEditing)
        }
    }

    func applyChromePalette(_ palette: GhosttyChromePalette) {
        chromePalette = palette
        loadViewIfNeeded()

        let backgroundColor = NSColor(ghosttyRGB: palette.background)
        chromeView.layer?.backgroundColor = backgroundColor.cgColor
        terminalContentView.layer?.backgroundColor = backgroundColor.cgColor
        configurationDiagnosticView.applyChromePalette(palette)

        let appearanceName: NSAppearance.Name = palette.usesDarkAppearance ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName)
        view.appearance = appearance
        chromeView.appearance = appearance
        tabBarViewController.applyChromePalette(palette)
    }

    func applyConfigurationDiagnostics(_ presentation: ConfigDiagnosticPresentation?) {
        loadViewIfNeeded()
        configurationDiagnosticView.apply(presentation)
    }

    func apply(
        _ store: WorkspaceStore,
        liveTitles: [PaneID: String] = [:]
    ) {
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
        let tabs = activeWorkspace?.tabs ?? []
        tabBarViewController.apply(
            tabs: tabs,
            activeTabID: activeWorkspace?.activeTabID,
            destinations: destinations,
            displayedTitles: Self.displayedTitles(for: tabs, liveTitles: liveTitles)
        )
    }

    func refreshTabTitles(
        in store: WorkspaceStore,
        liveTitles: [PaneID: String]
    ) {
        let tabs = store.workspace(id: store.activeWorkspaceID)?.tabs ?? []
        tabBarViewController.refreshDisplayedTitles(
            Self.displayedTitles(for: tabs, liveTitles: liveTitles)
        )
    }

    func presentTabTitlePrompt(for tabID: TabID) {
        tabBarViewController.beginRename(tabID)
    }

    func cancelTabRename() {
        tabBarViewController.cancelRename()
    }

    private static func displayedTitles(
        for tabs: [TerminalTab],
        liveTitles: [PaneID: String]
    ) -> [TabID: String] {
        Dictionary(
            uniqueKeysWithValues: tabs.map { tab in
                (
                    tab.id,
                    tab.titleOverride ?? liveTitles[tab.activePaneID] ?? tab.title
                )
            }
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

        var splitHostingControllerIdentifierForTesting: ObjectIdentifier? {
            splitHostingController.map(ObjectIdentifier.init)
        }

        var splitHostingViewForTesting: NSView? {
            splitHostingController?.view
        }

        var splitHostingConstraintIdentifiersForTesting: [ObjectIdentifier] {
            splitHostingConstraints.map(ObjectIdentifier.init)
        }

        var splitHostingConstraintsAreActiveForTesting: Bool {
            splitHostingConstraints.allSatisfy(\.isActive)
        }

        var terminalContentSubviewIdentifiersForTesting: [ObjectIdentifier] {
            terminalContentView.subviews.map(ObjectIdentifier.init)
        }

        var configurationDiagnosticViewForTesting: NSView {
            configurationDiagnosticView
        }

        var configurationDiagnosticIsVisibleForTesting: Bool {
            !configurationDiagnosticView.isHidden
        }

        var configurationDiagnosticTextForTesting: String {
            configurationDiagnosticView.textForTesting
        }

        var configurationDiagnosticAppearanceNameForTesting: NSAppearance.Name? {
            configurationDiagnosticView.appearanceNameForTesting
        }

        var configurationDiagnosticForegroundRGBAForTesting: [CGFloat]? {
            configurationDiagnosticView.foregroundRGBAForTesting
        }

        var configurationDiagnosticBackgroundRGBAForTesting: [CGFloat]? {
            configurationDiagnosticView.backgroundRGBAForTesting
        }

        var emptyWorkspaceLabelIsVisibleForTesting: Bool {
            !emptyLabel.isHidden
        }

        var hostedSurfaceIdentifiersForTesting: [PaneID: ObjectIdentifier] {
            Dictionary(
                uniqueKeysWithValues: hostedSurfacesForTesting.map {
                    ($0.key, ObjectIdentifier($0.value))
                })
        }

        var renderedSurfaceIdentifiersForTesting: [ObjectIdentifier] {
            guard let splitHostingController else { return [] }
            return surfaceViews(in: splitHostingController.view).map(ObjectIdentifier.init)
        }

        func invokeResizeForTesting(splitID: UUID, ratio: Double) {
            splitResizeHandler?(splitID, ratio)
        }

        func invokeEqualizeForTesting(splitID: UUID) {
            splitEqualizeHandler?(splitID)
        }
    #endif

    func displayTerminal(
        root: SplitNode?,
        surfaces: [PaneID: GhosttySurfaceView],
        failures: [PaneID: SurfaceFailurePresentation],
        palette: GhosttyChromePalette,
        onResize: @escaping (UUID, Double) -> Void,
        onEqualize: @escaping (UUID) -> Void,
        onRetryUnavailablePane: @escaping (PaneID) -> Void,
        onCloseUnavailablePane: @escaping (PaneID) -> Void
    ) {
        loadViewIfNeeded()
        guard let root else {
            splitResizeHandler = nil
            splitEqualizeHandler = nil

            #if DEBUG
                hostedSurfacesForTesting = [:]
            #endif

            removeSplitHost()
            emptyLabel.isHidden = false
            return
        }

        splitResizeHandler = onResize
        splitEqualizeHandler = onEqualize

        #if DEBUG
            hostedSurfacesForTesting = surfaces
        #endif

        emptyLabel.isHidden = true
        let splitTreeView = GhosttySplitTreeView(
            root: root,
            surfaces: surfaces,
            failures: failures,
            palette: palette,
            onResize: onResize,
            onEqualize: onEqualize,
            onRetryUnavailablePane: onRetryUnavailablePane,
            onCloseUnavailablePane: onCloseUnavailablePane
        )
        if let splitHostingController {
            splitHostingController.rootView = splitTreeView
            splitHostingController.view.layoutSubtreeIfNeeded()
            return
        }

        let splitHostingController = NSHostingController(rootView: splitTreeView)
        addChild(splitHostingController)
        let splitHostingView = splitHostingController.view
        splitHostingView.translatesAutoresizingMaskIntoConstraints = false
        terminalContentView.addSubview(
            splitHostingView,
            positioned: .below,
            relativeTo: configurationDiagnosticView
        )
        splitHostingConstraints = [
            splitHostingView.topAnchor.constraint(equalTo: terminalContentView.topAnchor),
            splitHostingView.leadingAnchor.constraint(equalTo: terminalContentView.leadingAnchor),
            splitHostingView.trailingAnchor.constraint(equalTo: terminalContentView.trailingAnchor),
            splitHostingView.bottomAnchor.constraint(equalTo: terminalContentView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(splitHostingConstraints)
        self.splitHostingController = splitHostingController
        splitHostingView.layoutSubtreeIfNeeded()
    }

    #if DEBUG
        private func surfaceViews(in view: NSView) -> [GhosttySurfaceView] {
            let directSurface = (view as? GhosttySurfaceView).map { [$0] } ?? []
            return directSurface + view.subviews.flatMap(surfaceViews)
        }
    #endif

    private func removeSplitHost() {
        guard let splitHostingController else { return }
        NSLayoutConstraint.deactivate(splitHostingConstraints)
        splitHostingConstraints = []
        splitHostingController.view.removeFromSuperview()
        splitHostingController.removeFromParent()
        self.splitHostingController = nil
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
