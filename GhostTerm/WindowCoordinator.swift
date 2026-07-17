import AppKit

struct WorkspaceDeletionConfirmation: Equatable {
    let workspaceID: WorkspaceID
    let workspaceName: String
    let tabCount: Int
    let paneCount: Int
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    typealias ModePersistence = @MainActor (PresentationMode) -> Void
    typealias QuakeHeightPersistence = @MainActor (Double) -> Void
    typealias NormalWindowFramePersistence = @MainActor (NormalWindowFrame) -> Void
    typealias WorkspacePersistence = @MainActor (WorkspaceStore) -> Void
    typealias WorkspaceDeletionConfirmationPresenter =
        @MainActor (
            WorkspaceDeletionConfirmation,
            @escaping @MainActor (Bool) -> Void
        ) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void

    private let ghosttyBridge: GhosttyBridge
    private let normalWindowController: NormalWindowController
    private let quakeWindowController: QuakeWindowController
    private let presentationController: PresentationController
    private let hotKeyController: any HotKeyControlling
    private let surfaceConfiguration: GhosttySurfaceConfiguration
    private let confirmationPresenter: GhosttyConfirmationQueue.Presenter?
    private let workspaceDeletionConfirmationPresenter: WorkspaceDeletionConfirmationPresenter?
    private let persistNormalWindowFrame: NormalWindowFramePersistence
    private let persistWorkspaceStore: WorkspacePersistence
    private let onError: ErrorHandler
    private let workspaceViewController = WorkspaceViewController()
    private let splitCoordinator = SplitCoordinator()
    private var workspaceStore: WorkspaceStore
    private var createWorkspaceController: CreateWorkspaceController?
    private var pendingWorkspaceDeletionID: WorkspaceID?
    private var surfaces: [PaneID: GhosttySurfaceView] = [:]
    private var isCreatingReplacementShell = false
    private var activeHotKey = HotKeyDescriptor(key: .f12)
    private var configEditor = "nano"

    #if DEBUG
        private var failsNextSplitMutationForTesting = false
    #endif

    private lazy var confirmationQueue = GhosttyConfirmationQueue {
        [weak self] presentation, completion in
        guard let self else {
            completion(.deny)
            return nil
        }
        if let confirmationPresenter {
            return confirmationPresenter(presentation, completion)
        }
        return presentConfirmation(presentation, completion: completion)
    }

    var presentationMode: PresentationMode { presentationController.mode }

    var workspaceStoreForPersistence: WorkspaceStore {
        var candidate = workspaceStore
        for (paneID, workingDirectory) in ghosttyBridge.latestWorkingDirectoriesForPersistence
        where !workingDirectory.isEmpty && (workingDirectory as NSString).isAbsolutePath {
            try? candidate.updateWorkingDirectory(workingDirectory, for: paneID)
        }
        return candidate
    }

    var isBroadcastingActiveTab: Bool {
        activeTab?.isBroadcasting ?? false
    }

    var canToggleBroadcast: Bool {
        activeTab != nil
    }

    init(
        ghosttyBridge: GhosttyBridge,
        presentationMode: PresentationMode = .normal,
        normalWindowFrame: NormalWindowFrame? = nil,
        quakeConfiguration: QuakeWindowConfiguration = QuakeWindowConfiguration(),
        surfaceConfiguration: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration(),
        initialWorkspaceStore: WorkspaceStore = WorkspaceStore(),
        persistWorkspaceStore: @escaping WorkspacePersistence = { _ in },
        confirmationPresenter: GhosttyConfirmationQueue.Presenter? = nil,
        workspaceDeletionConfirmationPresenter: WorkspaceDeletionConfirmationPresenter? = nil,
        persistPresentationMode: @escaping ModePersistence = { _ in },
        persistQuakeHeight: @escaping QuakeHeightPersistence = { _ in },
        persistNormalWindowFrame: @escaping NormalWindowFramePersistence = { _ in },
        onError: @escaping ErrorHandler = { _ in },
        hotKeyController: (any HotKeyControlling)? = nil,
        visibleScreenFrames: @escaping @MainActor () -> [NSRect] = {
            NSScreen.screens.map(\.visibleFrame)
        }
    ) {
        let normalWindowController = NormalWindowController()
        let quakeWindowController = QuakeWindowController(
            configuration: quakeConfiguration,
            persistQuakeHeight: persistQuakeHeight
        )
        let hotKeyRelay = HotKeyActionRelay()
        let resolvedHotKeyController =
            hotKeyController
            ?? GlobalHotKeyController {
                hotKeyRelay.perform()
            }
        let restoredNormalFrame = normalWindowFrame.flatMap {
            Self.restoredWindowFrame(from: $0, visibleScreenFrames: visibleScreenFrames())
        }

        self.ghosttyBridge = ghosttyBridge
        self.normalWindowController = normalWindowController
        self.quakeWindowController = quakeWindowController
        self.hotKeyController = resolvedHotKeyController
        self.surfaceConfiguration = surfaceConfiguration
        workspaceStore = initialWorkspaceStore
        self.confirmationPresenter = confirmationPresenter
        self.workspaceDeletionConfirmationPresenter = workspaceDeletionConfirmationPresenter
        self.persistNormalWindowFrame = persistNormalWindowFrame
        self.persistWorkspaceStore = persistWorkspaceStore
        self.onError = onError
        presentationController = try! PresentationController(
            contentViewController: workspaceViewController,
            normalWindowController: normalWindowController,
            quakeWindowController: quakeWindowController,
            initialMode: presentationMode,
            savedNormalFrame: restoredNormalFrame,
            persistSuccessfulMode: persistPresentationMode,
            onError: onError
        )
        super.init()

        workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
        normalWindowController.window?.delegate = self
        hotKeyRelay.action = { [weak self] in
            self?.presentationController.toggleQuakeVisibility()
        }
        ghosttyBridge.surfaceFocusHandler = { [weak self] paneID in
            self?.surfaceDidBecomeFirstResponder(id: paneID)
        }
        ghosttyBridge.surfaceWorkingDirectoryHandler = { [weak self] paneID, workingDirectory in
            self?.surfaceWorkingDirectoryDidChange(id: paneID, workingDirectory: workingDirectory)
        }
        ghosttyBridge.inputTargetProvider = { [weak self] sourcePaneID in
            guard let self else { return [sourcePaneID] }
            return TerminalInputRouter.targetPaneIDs(
                in: workspaceStore,
                sourcePaneID: sourcePaneID
            ).filter { surfaces[$0] != nil }
        }
        ghosttyBridge.clipboardConfirmationHandler = { [weak self] event in
            switch event {
            case .request(let request, let response):
                guard let self else {
                    response(.deny)
                    return
                }
                confirmationQueue.enqueueClipboard(request, completion: response)
            case .invalidate(let paneID):
                self?.confirmationQueue.invalidateClipboard(for: paneID)
            }
        }
        configurePresentationCallbacks()
    }

    isolated deinit {
        prepareForApplicationTermination()
        try? hotKeyController.unregister()
        ghosttyBridge.surfaceFocusHandler = nil
        ghosttyBridge.surfaceWorkingDirectoryHandler = nil
        ghosttyBridge.inputTargetProvider = { [$0] }
        ghosttyBridge.clipboardConfirmationHandler = nil
        if normalWindowController.window?.delegate === self {
            normalWindowController.window?.delegate = nil
        }
    }

    var normalWindowFrame: NormalWindowFrame? {
        Self.normalWindowFrame(from: presentationController.normalFrameForPersistence)
    }

    private var activeWindow: NSWindow? {
        switch presentationMode {
        case .normal:
            normalWindowController.window
        case .quake:
            quakeWindowController.appKitWindow
        }
    }

    static func windowFrame(from frame: NormalWindowFrame) -> NSRect {
        NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    static func normalWindowFrame(from frame: NSRect) -> NormalWindowFrame? {
        NormalWindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    static func restoredWindowFrame(
        from savedFrame: NormalWindowFrame,
        visibleScreenFrames: [NSRect]
    ) -> NSRect? {
        let savedRect = windowFrame(from: savedFrame)
        var selectedScreen: NSRect?
        var largestIntersectionArea: CGFloat = 0

        for screen in visibleScreenFrames where isValidVisibleScreenFrame(screen) {
            let intersection = savedRect.intersection(screen)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > largestIntersectionArea {
                largestIntersectionArea = area
                selectedScreen = screen
            }
        }

        guard let selectedScreen else { return nil }
        let minimumFrameSize = NormalWindowController.minimumFrameSize
        let width = min(max(savedRect.width, minimumFrameSize.width), selectedScreen.width)
        let height = min(max(savedRect.height, minimumFrameSize.height), selectedScreen.height)
        let x = min(
            max(savedRect.minX, selectedScreen.minX),
            selectedScreen.maxX - width
        )
        let y = min(
            max(savedRect.minY, selectedScreen.minY),
            selectedScreen.maxY - height
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func isValidVisibleScreenFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    func start() throws {
        guard surfaces.isEmpty else { return }

        workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
        if workspaceStore.workspaces.allSatisfy({ $0.tabs.isEmpty }) {
            try createShellTab(refreshPresentation: false, surfaceContext: .window)
        } else {
            try restoreWorkspaceSurfaces()
        }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    @discardableResult
    private func commitWorkspaceStore(_ candidate: WorkspaceStore) -> Bool {
        guard candidate != workspaceStore else { return false }
        workspaceStore = candidate
        persistWorkspaceStore(workspaceStore)
        return true
    }

    private func surfaceWorkingDirectoryDidChange(
        id paneID: PaneID,
        workingDirectory: String
    ) {
        guard !workingDirectory.isEmpty, (workingDirectory as NSString).isAbsolutePath,
            surfaces[paneID] != nil
        else {
            return
        }

        var candidate = workspaceStore
        do {
            try candidate.updateWorkingDirectory(workingDirectory, for: paneID)
        } catch {
            return
        }
        _ = commitWorkspaceStore(candidate)
    }

    func createNewTab() {
        do {
            try createShellTab()
        } catch {
            onError(error)
        }
    }

    func splitActivePane(axis: SplitAxis) throws {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            let descriptor = tab.paneDescriptor(for: tab.activePaneID),
            let activeSurface = surfaces[tab.activePaneID]
        else {
            return
        }

        let workingDirectory =
            activeSurface.currentWorkingDirectory.flatMap {
                $0.isEmpty ? nil : $0
            } ?? descriptor.cwd
        let paneID = PaneID()
        var splitConfiguration = surfaceConfiguration
        splitConfiguration.workingDirectory = workingDirectory
        splitConfiguration.command = nil
        splitConfiguration.initialInput = nil
        splitConfiguration.context = .split
        let surface = try ghosttyBridge.makeSurface(
            id: paneID,
            configuration: splitConfiguration
        ) { [weak self] paneID, processAlive in
            self?.surfaceDidRequestClose(id: paneID, processAlive: processAlive)
        }
        let newPane = TerminalPaneDescriptor(
            id: paneID,
            cwd: workingDirectory,
            startupCommand: .shell
        )
        var candidate = workspaceStore

        do {
            #if DEBUG
                if failsNextSplitMutationForTesting {
                    failsNextSplitMutationForTesting = false
                    throw SplitCoordinatorError.paneNotFound(tab.activePaneID)
                }
            #endif

            _ = try splitCoordinator.apply(
                .split(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    paneID: tab.activePaneID,
                    axis: axis,
                    newPane: newPane,
                    ratio: 0.5
                ),
                to: &candidate
            )
        } catch {
            ghosttyBridge.closeSurface(id: paneID)
            throw error
        }

        surfaces[paneID] = surface
        _ = commitWorkspaceStore(candidate)
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func activateTab(at index: Int) {
        guard index > 0,
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID),
            workspace.tabs.indices.contains(index - 1)
        else { return }

        var candidate = workspaceStore
        do {
            try candidate.activateTab(
                workspace.tabs[index - 1].id,
                in: candidate.activeWorkspaceID
            )
        } catch {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func activateWorkspace(at oneBasedIndex: Int) {
        guard
            (1...9).contains(oneBasedIndex),
            workspaceStore.workspaces.indices.contains(oneBasedIndex - 1)
        else {
            return
        }
        activateWorkspace(id: workspaceStore.workspaces[oneBasedIndex - 1].id)
    }

    private func activateWorkspace(id workspaceID: WorkspaceID) {
        var candidate = workspaceStore
        do {
            try candidate.activateWorkspace(workspaceID)
        } catch {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func toggleBroadcast() {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID)
        else {
            return
        }

        var candidate = workspaceStore
        do {
            try candidate.setBroadcasting(
                !tab.isBroadcasting,
                for: tabID,
                in: workspaceID
            )
            guard commitWorkspaceStore(candidate) else { return }
            workspaceViewController.apply(workspaceStore)
            if let surface = activePaneID.flatMap({ surfaces[$0] }), let paneID = activePaneID {
                focus(surface, paneID: paneID)
            }
        } catch {
            onError(error)
        }
    }

    func focusPreviousPane() {
        focusActivePane(using: .previous)
    }

    func focusNextPane() {
        focusActivePane(using: .next)
    }

    func focusPane(direction: SplitFocusDirection) {
        focusActivePane(using: .direction(direction))
    }

    func createShellTab(in workspaceID: WorkspaceID? = nil) throws {
        try createShellTab(in: workspaceID, refreshPresentation: true)
    }

    func openConfiguration(at configURL: URL) throws {
        try createConfigurationTab(
            at: configURL,
            in: workspaceStore.activeWorkspaceID
        )
    }

    private func createShellTab(
        in workspaceID: WorkspaceID? = nil,
        refreshPresentation: Bool,
        surfaceContext: GhosttySurfaceConfiguration.Context = .newTab
    ) throws {
        var candidate = workspaceStore
        let prepared = try prepareShellTab(
            in: workspaceID ?? candidate.activeWorkspaceID,
            candidate: &candidate,
            surfaceContext: surfaceContext
        )
        surfaces[prepared.paneID] = prepared.surface
        _ = commitWorkspaceStore(candidate)
        if refreshPresentation {
            refreshWorkspacePresentation(focusTerminal: true)
        }
    }

    private func prepareShellTab(
        in workspaceID: WorkspaceID,
        candidate: inout WorkspaceStore,
        surfaceContext: GhosttySurfaceConfiguration.Context
    ) throws -> (paneID: PaneID, surface: GhosttySurfaceView) {
        let paneID = PaneID()
        var tabConfiguration = surfaceConfiguration
        tabConfiguration.context = surfaceContext
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: surfaceConfiguration.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            startupCommand: surfaceConfiguration.command.map(StartupCommand.custom) ?? .shell
        )
        let surface = try prepareTab(
            title: "Shell",
            paneID: paneID,
            descriptor: descriptor,
            configuration: tabConfiguration,
            in: workspaceID,
            candidate: &candidate
        )
        return (paneID, surface)
    }

    private func createConfigurationTab(
        at configURL: URL,
        in workspaceID: WorkspaceID
    ) throws {
        let absoluteConfigURL = configURL.standardizedFileURL
        let workingDirectory = absoluteConfigURL.deletingLastPathComponent().path
        let command = "\(configEditor) \(Self.posixShellQuoted(absoluteConfigURL.path))"
        let paneID = PaneID()
        var tabConfiguration = surfaceConfiguration
        tabConfiguration.workingDirectory = workingDirectory
        tabConfiguration.command = command
        tabConfiguration.initialInput = nil
        tabConfiguration.context = .newTab
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: workingDirectory,
            startupCommand: .custom(command)
        )
        try createTab(
            title: "Config",
            paneID: paneID,
            descriptor: descriptor,
            configuration: tabConfiguration,
            in: workspaceID,
            refreshPresentation: true
        )
    }

    private func createTab(
        title: String,
        paneID: PaneID,
        descriptor: TerminalPaneDescriptor,
        configuration: GhosttySurfaceConfiguration,
        in workspaceID: WorkspaceID,
        refreshPresentation: Bool
    ) throws {
        var candidate = workspaceStore
        let surface = try prepareTab(
            title: title,
            paneID: paneID,
            descriptor: descriptor,
            configuration: configuration,
            in: workspaceID,
            candidate: &candidate
        )
        surfaces[paneID] = surface
        _ = commitWorkspaceStore(candidate)
        if refreshPresentation {
            refreshWorkspacePresentation(focusTerminal: true)
        }
    }

    private func prepareTab(
        title: String,
        paneID: PaneID,
        descriptor: TerminalPaneDescriptor,
        configuration: GhosttySurfaceConfiguration,
        in workspaceID: WorkspaceID,
        candidate: inout WorkspaceStore
    ) throws -> GhosttySurfaceView {
        let surface = try ghosttyBridge.makeSurface(
            id: paneID,
            configuration: configuration
        ) { [weak self] paneID, processAlive in
            self?.surfaceDidRequestClose(id: paneID, processAlive: processAlive)
        }
        let tab = TerminalTab(title: title, pane: descriptor)

        do {
            try candidate.addTab(tab, to: workspaceID)
            try candidate.activateTab(tab.id, in: workspaceID)
        } catch {
            ghosttyBridge.closeSurface(id: paneID)
            throw error
        }

        return surface
    }

    private static func posixShellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func restoreWorkspaceSurfaces() throws {
        var restoredSurfaces: [PaneID: GhosttySurfaceView] = [:]
        var restoredPaneIDs: [PaneID] = []

        do {
            for workspace in workspaceStore.workspaces {
                for tab in workspace.tabs {
                    for (leafIndex, paneID) in tab.root.leaves.enumerated() {
                        guard let descriptor = tab.paneDescriptor(for: paneID) else {
                            preconditionFailure("WorkspaceStore contains an invalid tab")
                        }
                        var restoredConfiguration = surfaceConfiguration
                        restoredConfiguration.workingDirectory = descriptor.cwd
                        restoredConfiguration.command = nil
                        restoredConfiguration.initialInput = nil
                        restoredConfiguration.context = leafIndex == 0 ? .newTab : .split
                        let surface = try ghosttyBridge.makeSurface(
                            id: paneID,
                            configuration: restoredConfiguration
                        ) { [weak self] paneID, processAlive in
                            self?.surfaceDidRequestClose(id: paneID, processAlive: processAlive)
                        }
                        restoredSurfaces[paneID] = surface
                        restoredPaneIDs.append(paneID)
                    }
                }
            }
        } catch {
            for paneID in restoredPaneIDs {
                ghosttyBridge.closeSurface(id: paneID)
            }
            throw error
        }

        surfaces = restoredSurfaces
    }

    func applyConfiguration(_ config: GhostTermConfig) {
        workspaceViewController.applyChromePalette(ghosttyBridge.chromePalette)
        activeHotKey = config.globalToggle
        configEditor = config.configEditor
        let geometry =
            QuakeWindowGeometry(
                heightFraction: config.quakeHeight,
                padding: config.quakePadding
            ) ?? QuakeWindowConfiguration().geometry
        quakeWindowController.updateConfiguration(
            QuakeWindowConfiguration(
                geometry: geometry,
                animationDuration: config.quakeAnimationDuration,
                hideOnFocusLoss: config.hideOnFocusLoss
            )
        )

        do {
            try presentationController.transition(to: config.presentationMode, persist: false)
            if presentationMode == .quake {
                try hotKeyController.register(config.globalToggle)
            } else {
                try hotKeyController.unregister()
            }
        } catch {
            onError(error)
        }
    }

    func togglePresentationMode() {
        let target: PresentationMode = presentationMode == .normal ? .quake : .normal
        do {
            try presentationController.transition(to: target)
            if target == .quake {
                try hotKeyController.register(activeHotKey)
            } else {
                try hotKeyController.unregister()
            }
        } catch {
            onError(error)
        }
    }

    private func configurePresentationCallbacks() {
        workspaceViewController.onActivateWorkspace = { [weak self] workspaceID in
            self?.activateWorkspace(id: workspaceID)
        }
        workspaceViewController.onCreateWorkspace = { [weak self] in
            self?.presentCreateWorkspace()
        }
        workspaceViewController.onRenameWorkspace = { [weak self] in
            self?.presentRenameWorkspace()
        }
        workspaceViewController.onDeleteWorkspace = { [weak self] in
            self?.requestDeleteActiveWorkspace()
        }
        workspaceViewController.onActivateTab = { [weak self] tabID in
            guard let self else { return }
            var candidate = workspaceStore
            do {
                try candidate.activateTab(tabID, in: candidate.activeWorkspaceID)
            } catch {
                return
            }
            guard commitWorkspaceStore(candidate) else { return }
            refreshWorkspacePresentation(focusTerminal: true)
        }
        workspaceViewController.onCloseTab = { [weak self] tabID in
            self?.requestCloseTab(tabID)
        }
        workspaceViewController.onToggleBroadcast = { [weak self] in
            self?.toggleBroadcast()
        }
        workspaceViewController.onMoveToNewWorkspace = { [weak self] tabIDs in
            self?.presentMoveToNewWorkspace(tabIDs)
        }
        workspaceViewController.onMoveToWorkspace = { [weak self] tabIDs, workspaceID in
            self?.moveTabs(tabIDs, to: workspaceID)
        }
        workspaceViewController.onReorderTabs = { [weak self] tabIDs, activeTabID in
            guard let self else { return false }
            return reorderTabs(tabIDs, activeTabID: activeTabID)
        }
        workspaceViewController.onFinishReorderTabs = { [weak self] in
            self?.finishTabReorder()
        }
    }

    private enum PaneFocusCommand {
        case previous
        case next
        case direction(SplitFocusDirection)
    }

    private func focusActivePane(using command: PaneFocusCommand) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            tab.root.leaves.count > 1
        else { return }

        var candidate = workspaceStore
        let splitCommand: SplitCommand =
            switch command {
            case .previous:
                .focusPrevious(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID
                )
            case .next:
                .focusNext(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID
                )
            case .direction(let direction):
                .focus(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    from: tab.activePaneID,
                    direction: direction
                )
            }
        let delta: SplitDelta
        do {
            delta = try splitCoordinator.apply(splitCommand, to: &candidate)
        } catch {
            return
        }

        guard case .focusChanged(_, _, let sourcePaneID, let destinationPaneID) = delta,
            sourcePaneID != destinationPaneID,
            surfaces[destinationPaneID] != nil
        else { return }

        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    private var activeTab: TerminalTab? {
        workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)?
            .activeTabID
            .flatMap { workspaceStore.tab(id: $0) }
    }

    private var activePaneID: PaneID? {
        activeTab?.activePaneID
    }

    private func refreshWorkspacePresentation(focusTerminal: Bool) {
        workspaceViewController.apply(workspaceStore)
        let activeTabSurfaces = Dictionary(
            uniqueKeysWithValues: (activeTab?.root.leaves ?? []).compactMap { paneID in
                surfaces[paneID].map { (paneID, $0) }
            }
        )
        let surface = activePaneID.flatMap { activeTabSurfaces[$0] }
        workspaceViewController.displayTerminal(
            root: activeTab?.root,
            surfaces: activeTabSurfaces,
            palette: ghosttyBridge.chromePalette,
            onResize: { [weak self] splitID, ratio in
                self?.updateActiveSplitRatio(id: splitID, ratio: ratio)
            },
            onEqualize: { [weak self] splitID in
                self?.equalizeActiveSplits(triggeredBy: splitID)
            }
        )
        if focusTerminal, let surface, let paneID = activePaneID {
            focus(surface, paneID: paneID)
        }
    }

    private func focus(
        _ surface: GhosttySurfaceView,
        paneID: PaneID,
        retryingAfterPresentation: Bool = false
    ) {
        guard let window = activeWindow else { return }
        guard surface.window === window else {
            guard !retryingAfterPresentation else { return }
            DispatchQueue.main.async { [weak self, weak surface] in
                guard let self, let surface, self.activePaneID == paneID else { return }
                self.focus(surface, paneID: paneID, retryingAfterPresentation: true)
            }
            return
        }
        window.makeFirstResponder(surface)
    }

    private func surfaceDidBecomeFirstResponder(id paneID: PaneID) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspace = workspaceStore.workspace(id: workspaceID),
            let tabID = workspace.activeTabID,
            let tab = workspaceStore.tab(id: tabID),
            tab.root.contains(paneID),
            tab.activePaneID != paneID,
            surfaces[paneID] != nil
        else {
            return
        }

        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .activatePane(workspaceID: workspaceID, tabID: tabID, paneID: paneID),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func updateActiveSplitRatio(id splitID: UUID, ratio: Double) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID else { return }
        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .updateRatio(
                    workspaceID: workspaceID,
                    tabID: tabID,
                    splitID: splitID,
                    ratio: ratio
                ),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func equalizeActiveSplits(triggeredBy splitID: UUID) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID,
            workspaceStore.tab(id: tabID)?.root.contains(splitID: splitID) == true
        else {
            return
        }
        var candidate = workspaceStore
        guard
            (try? splitCoordinator.apply(
                .equalize(workspaceID: workspaceID, tabID: tabID),
                to: &candidate
            )) != nil
        else {
            return
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: false)
    }

    private func presentCreateWorkspace() {
        guard createWorkspaceController == nil, let window = activeWindow else { return }

        let controller = CreateWorkspaceController(
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.map(\.name) ?? []
            },
            submit: { [weak self] name in
                guard let self else {
                    return .failure(.workspaceNotFound(WorkspaceID()))
                }
                var candidate = workspaceStore
                do {
                    let workspaceID = try candidate.createWorkspace(named: name)
                    try candidate.activateWorkspace(workspaceID)
                    let prepared = try prepareShellTab(
                        in: workspaceID,
                        candidate: &candidate,
                        surfaceContext: .newTab
                    )
                    surfaces[prepared.paneID] = prepared.surface
                    guard commitWorkspaceStore(candidate) else {
                        ghosttyBridge.closeSurface(id: prepared.paneID)
                        surfaces.removeValue(forKey: prepared.paneID)
                        return .failure(.workspaceNotFound(workspaceID))
                    }
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    onError(error)
                    return .failure(.workspaceNotFound(candidate.activeWorkspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func presentRenameWorkspace() {
        guard
            createWorkspaceController == nil,
            let window = activeWindow,
            let workspace = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)
        else {
            return
        }
        let workspaceID = workspace.id
        let controller = CreateWorkspaceController(
            title: "Rename Workspace",
            initialName: workspace.name,
            buttonTitle: "Rename",
            errorMessage: "The workspace could not be renamed.",
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.compactMap { workspace in
                    workspace.id == workspaceID ? nil : workspace.name
                } ?? []
            },
            submit: { [weak self] name in
                guard let self, workspaceStore.activeWorkspaceID == workspaceID else {
                    return .failure(.workspaceNotFound(workspaceID))
                }
                var candidate = workspaceStore
                do {
                    try candidate.renameWorkspace(workspaceID, to: name)
                    guard commitWorkspaceStore(candidate) else { return .success(()) }
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    return .failure(.workspaceNotFound(workspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func presentWorkspaceEditor(
        _ controller: CreateWorkspaceController,
        for window: NSWindow
    ) {
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.createWorkspaceController === controller else { return }
            self?.createWorkspaceController = nil
        }
        createWorkspaceController = controller
        controller.presentSheet(for: window)
    }

    private func requestDeleteActiveWorkspace() {
        requestDeleteWorkspace(workspaceStore.activeWorkspaceID)
    }

    private func requestDeleteWorkspace(_ workspaceID: WorkspaceID) {
        guard
            pendingWorkspaceDeletionID == nil,
            workspaceID == workspaceStore.activeWorkspaceID,
            workspaceStore.workspaces.count > 1,
            let workspace = workspaceStore.workspace(id: workspaceID)
        else {
            return
        }

        let paneCount = workspace.tabs.reduce(into: 0) { count, tab in
            count += tab.root.leaves.count
        }
        guard paneCount > 0 else {
            deleteWorkspace(workspaceID)
            return
        }

        let confirmation = WorkspaceDeletionConfirmation(
            workspaceID: workspaceID,
            workspaceName: workspace.name,
            tabCount: workspace.tabs.count,
            paneCount: paneCount
        )
        pendingWorkspaceDeletionID = workspaceID
        let completion: @MainActor (Bool) -> Void = { [weak self] allowed in
            self?.resolveWorkspaceDeletion(workspaceID, allowed: allowed)
        }
        if let workspaceDeletionConfirmationPresenter {
            workspaceDeletionConfirmationPresenter(confirmation, completion)
        } else {
            presentWorkspaceDeletionConfirmation(confirmation, completion: completion)
        }
    }

    private func resolveWorkspaceDeletion(_ workspaceID: WorkspaceID, allowed: Bool) {
        guard pendingWorkspaceDeletionID == workspaceID else { return }
        pendingWorkspaceDeletionID = nil
        guard allowed else { return }
        deleteWorkspace(workspaceID)
    }

    private func deleteWorkspace(_ workspaceID: WorkspaceID) {
        guard
            workspaceID == workspaceStore.activeWorkspaceID,
            workspaceStore.workspaces.count > 1
        else {
            return
        }
        var candidate = workspaceStore
        let removedWorkspace: Workspace
        do {
            removedWorkspace = try candidate.deleteWorkspace(workspaceID)
        } catch {
            return
        }

        detachActiveWorkspacePresentation()
        for paneID in removedWorkspace.tabs.flatMap(\.root.leaves) {
            _ = removeSurface(id: paneID, closeBridgeSurface: true)
        }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }

    private func detachActiveWorkspacePresentation() {
        _ = activeWindow?.makeFirstResponder(nil)
        workspaceViewController.displayTerminal(
            root: nil,
            surfaces: [:],
            palette: ghosttyBridge.chromePalette,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
    }

    private func presentWorkspaceDeletionConfirmation(
        _ confirmation: WorkspaceDeletionConfirmation,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let window = activeWindow else {
            completion(false)
            return
        }
        let alert = Self.makeWorkspaceDeletionAlert(confirmation)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    static func makeWorkspaceDeletionAlert(_ confirmation: WorkspaceDeletionConfirmation) -> NSAlert
    {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Workspace?"
        alert.informativeText =
            "\(confirmation.workspaceName) contains \(confirmation.tabCount) \(pluralized(confirmation.tabCount, singular: "tab", plural: "tabs")) and \(confirmation.paneCount) \(pluralized(confirmation.paneCount, singular: "pane", plural: "panes")). All of its terminals will be closed."
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1B}"
        return alert
    }

    private static func pluralized(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? singular : plural
    }

    private func presentMoveToNewWorkspace(_ tabIDs: [TabID]) {
        guard !tabIDs.isEmpty, createWorkspaceController == nil, let window = activeWindow else {
            return
        }
        let sourceWorkspaceID = workspaceStore.activeWorkspaceID
        let controller = CreateWorkspaceController(
            existingNames: { [weak self] in
                self?.workspaceStore.workspaces.map(\.name) ?? []
            },
            submit: { [weak self] name in
                guard let self else {
                    return .failure(.workspaceNotFound(sourceWorkspaceID))
                }
                var updatedStore = workspaceStore
                do {
                    let destinationID = try updatedStore.createWorkspace(named: name)
                    try updatedStore.moveTabs(
                        tabIDs,
                        from: sourceWorkspaceID,
                        to: destinationID
                    )
                    guard commitWorkspaceStore(updatedStore) else {
                        return .success(())
                    }
                    workspaceViewController.tabBarViewController.clearSelectionAfterMove()
                    refreshWorkspacePresentation(focusTerminal: true)
                    return .success(())
                } catch let error as WorkspaceError {
                    return .failure(error)
                } catch {
                    return .failure(.workspaceNotFound(sourceWorkspaceID))
                }
            }
        )
        presentWorkspaceEditor(controller, for: window)
    }

    private func moveTabs(_ tabIDs: [TabID], to destinationWorkspaceID: WorkspaceID) {
        let sourceWorkspaceID = workspaceStore.activeWorkspaceID
        var candidate = workspaceStore
        do {
            try candidate.moveTabs(
                tabIDs,
                from: sourceWorkspaceID,
                to: destinationWorkspaceID
            )
            guard commitWorkspaceStore(candidate) else { return }
            workspaceViewController.tabBarViewController.clearSelectionAfterMove()
            refreshWorkspacePresentation(focusTerminal: true)
        } catch {
            NSSound.beep()
        }
    }

    private func reorderTabs(_ orderedTabIDs: [TabID], activeTabID: TabID) -> Bool {
        let workspaceID = workspaceStore.activeWorkspaceID
        var candidate = workspaceStore
        do {
            try candidate.reorderTabs(orderedTabIDs, in: workspaceID)
            try candidate.activateTab(activeTabID, in: workspaceID)
        } catch {
            return false
        }
        guard candidate != workspaceStore, commitWorkspaceStore(candidate) else { return false }
        return true
    }

    private func finishTabReorder() {
        refreshWorkspacePresentation(focusTerminal: true)
    }

    private func requestCloseTab(_ tabID: TabID) {
        guard let tab = workspaceStore.tab(id: tabID) else { return }
        let paneIDs = tab.root.leaves
        if let confirmationPaneID = paneIDs.first(where: {
            ghosttyBridge.surfaceNeedsConfirmQuit(id: $0)
        }) {
            confirmationQueue.enqueueClose(paneID: confirmationPaneID) { [weak self] response in
                guard response == .allow else { return }
                self?.closeTab(tabID, paneIDs: paneIDs)
            }
            return
        }
        closeTab(tabID, paneIDs: paneIDs)
    }

    private func closeTab(_ tabID: TabID, paneIDs: [PaneID]) {
        for paneID in paneIDs {
            _ = removeSurface(id: paneID, closeBridgeSurface: true)
        }
        closeOwningTab(tabID)
        refreshWorkspacePresentation(focusTerminal: true)
        if ghosttyBridge.activeSurfaceCount == 0, presentationMode == .normal {
            normalWindowController.close()
        }
    }

    @discardableResult
    private func removeSurface(id: PaneID, closeBridgeSurface: Bool) -> Bool {
        guard surfaces.removeValue(forKey: id) != nil else { return false }
        confirmationQueue.invalidatePane(id)
        if closeBridgeSurface {
            ghosttyBridge.closeSurface(id: id)
        }
        return true
    }

    @discardableResult
    private func closeOwningTab(_ tabID: TabID) -> Bool {
        guard
            let owner = workspaceStore.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tabID })
            })
        else { return false }
        var candidate = workspaceStore
        do {
            try candidate.closeTab(tabID, in: owner.id)
        } catch {
            return false
        }
        return commitWorkspaceStore(candidate)
    }

    @discardableResult
    private func closeOwningTab(containing paneID: PaneID) -> Bool {
        guard
            let tabID = workspaceStore.workspaces.lazy
                .flatMap(\.tabs)
                .first(where: { $0.root.contains(paneID) })?.id
        else { return false }
        return closeOwningTab(tabID)
    }

    func prepareForApplicationTermination() {
        tearDownSurfaces()
    }

    #if DEBUG
        var windowForTesting: NSWindow? {
            normalWindowController.window
        }

        var activeWindowForTesting: NSWindow? {
            activeWindow
        }

        var workspaceViewControllerForTesting: WorkspaceViewController {
            workspaceViewController
        }

        var defaultSurfaceForTesting: GhosttySurfaceView? {
            activeSurfaceForTesting
        }

        var activeSurfaceForTesting: GhosttySurfaceView? {
            activePaneID.flatMap { surfaces[$0] }
        }

        var surfaceIDsForTesting: [PaneID] {
            surfaces.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }

        func surfaceForTesting(id paneID: PaneID) -> GhosttySurfaceView? {
            surfaces[paneID]
        }

        func activateTabForTesting(_ tabID: TabID) {
            var candidate = workspaceStore
            guard
                (try? candidate.activateTab(tabID, in: candidate.activeWorkspaceID)) != nil,
                commitWorkspaceStore(candidate)
            else { return }
            refreshWorkspacePresentation(focusTerminal: true)
        }

        func openConfigurationForTesting(
            at configURL: URL,
            in workspaceID: WorkspaceID
        ) throws {
            try createConfigurationTab(at: configURL, in: workspaceID)
        }

        func splitActivePaneForTesting(axis: SplitAxis) throws {
            try splitActivePane(axis: axis)
        }

        func failNextSplitMutationForTesting() {
            failsNextSplitMutationForTesting = true
        }

        func requestCloseTabForTesting(_ tabID: TabID) {
            requestCloseTab(tabID)
        }

        func closeTabImmediatelyForTesting(_ tabID: TabID) {
            guard let tab = workspaceStore.tab(id: tabID) else { return }
            closeTab(tabID, paneIDs: tab.root.leaves)
        }

        func presentMoveToNewWorkspaceForTesting(_ tabIDs: [TabID]) {
            presentMoveToNewWorkspace(tabIDs)
        }

        var createWorkspaceControllerForTesting: CreateWorkspaceController? {
            createWorkspaceController
        }

        func surfaceDidRequestCloseForTesting(id: PaneID, processAlive: Bool) {
            surfaceDidRequestClose(id: id, processAlive: processAlive)
        }

        func setActiveTabBroadcastingForTesting(_ isBroadcasting: Bool) throws {
            let workspaceID = workspaceStore.activeWorkspaceID
            guard let tabID = workspaceStore.workspace(id: workspaceID)?.activeTabID else { return }
            var candidate = workspaceStore
            try candidate.setBroadcasting(isBroadcasting, for: tabID, in: workspaceID)
            _ = commitWorkspaceStore(candidate)
        }

        func prepareForBridgeShutdownForTesting() {
            prepareForApplicationTermination()
        }

        var activeConfirmationForTesting: GhosttyConfirmationPresentation? {
            confirmationQueue.activePresentation
        }

        var workspaceStoreForTesting: WorkspaceStore {
            workspaceStore
        }
    #endif

    func windowDidEndLiveResize(_ notification: Notification) {
        persistNormalWindowFrameIfNeeded(from: notification)
    }

    func windowDidMove(_ notification: Notification) {
        persistNormalWindowFrameIfNeeded(from: notification)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === normalWindowController.window else { return true }
        let activeSurfaceIDs = ghosttyBridge.activeSurfaceIDs
        guard !activeSurfaceIDs.isEmpty else { return true }
        guard
            let confirmationPaneID = activeSurfaceIDs.first(where: {
                ghosttyBridge.surfaceNeedsConfirmQuit(id: $0)
            })
        else {
            closeActiveSurfaces()
            return true
        }

        let window = sender
        confirmationQueue.enqueueClose(paneID: confirmationPaneID) {
            [weak self, weak window] response in
            guard response == .allow,
                let self,
                let window,
                normalWindowController.window === window
            else { return }

            closeActiveSurfaces()
            window.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window === normalWindowController.window
        else { return }

        confirmationQueue.invalidateAll()
        closeActiveSurfaces()
    }

    private func persistNormalWindowFrameIfNeeded(from notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window === normalWindowController.window,
            let frame = Self.normalWindowFrame(from: window.frame)
        else { return }

        persistNormalWindowFrame(frame)
    }

    private func tearDownSurfaces() {
        _ = activeWindow?.makeFirstResponder(nil)
        workspaceViewController.displayTerminal(
            root: nil,
            surfaces: [:],
            palette: ghosttyBridge.chromePalette,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        activeWindow?.orderOut(nil)
        closeActiveSurfaces()
    }

    private func closeActiveSurfaces() {
        for paneID in Array(surfaces.keys) {
            _ = removeSurface(id: paneID, closeBridgeSurface: true)
        }
    }

    private func surfaceDidRequestClose(id: PaneID, processAlive: Bool) {
        guard !processAlive else {
            guard surfaces[id] != nil else { return }
            confirmationQueue.enqueueClose(paneID: id) { [weak self] response in
                guard response == .allow, let self else { return }
                finishSurfaceClosure(
                    id: id,
                    closeBridgeSurface: true,
                    createsReplacement: false
                )
            }
            return
        }

        finishSurfaceClosure(
            id: id,
            closeBridgeSurface: true,
            createsReplacement: true
        )
    }

    private func presentConfirmation(
        _ presentation: GhosttyConfirmationPresentation,
        completion: @escaping GhosttyConfirmationQueue.Completion
    ) -> GhosttyConfirmationQueue.Dismiss? {
        guard let window = activeWindow else {
            completion(.deny)
            return nil
        }

        let alert = Self.makeConfirmationAlert(presentation)

        alert.beginSheetModal(for: window) { response in
            let allowed: Bool
            switch presentation {
            case .close:
                allowed = response == .alertFirstButtonReturn
            case .clipboard:
                allowed = response == .alertSecondButtonReturn
            }
            completion(allowed ? .allow : .deny)
        }

        return { [weak alert, weak window] in
            guard let alert, let window, alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    }

    static func makeConfirmationAlert(
        _ presentation: GhosttyConfirmationPresentation
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch presentation {
        case .close:
            alert.messageText = "Close Terminal?"
            alert.informativeText =
                "The terminal still has a running process. If you close the terminal the process will be killed."
            let closeButton = alert.addButton(withTitle: "Close")
            closeButton.hasDestructiveAction = true
            closeButton.keyEquivalent = "\r"
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1B}"
        case .clipboard(let request):
            configureClipboardAlert(alert, request: request)
        }

        return alert
    }

    private static func configureClipboardAlert(
        _ alert: NSAlert,
        request: GhosttyClipboardConfirmationRequest
    ) {
        let cancelButton: NSButton
        let affirmativeButton: NSButton

        switch request.kind {
        case .paste:
            alert.messageText = "Warning: Potentially Unsafe Paste"
            alert.informativeText =
                "Pasting this text to the terminal may be dangerous as it looks like some commands may be executed."
            cancelButton = alert.addButton(withTitle: "Cancel")
            affirmativeButton = alert.addButton(withTitle: "Paste")
        case .osc52Read:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to read from the clipboard. The current clipboard contents are shown below."
            cancelButton = alert.addButton(withTitle: "Deny")
            affirmativeButton = alert.addButton(withTitle: "Allow")
        case .osc52Write:
            alert.messageText = "Authorize Clipboard Access"
            alert.informativeText =
                "An application is attempting to write to the clipboard. The content to write is shown below."
            cancelButton = alert.addButton(withTitle: "Deny")
            affirmativeButton = alert.addButton(withTitle: "Allow")
        }

        cancelButton.keyEquivalent = "\u{1B}"
        affirmativeButton.keyEquivalent = "\r"
        alert.accessoryView = clipboardContentsView(request.contents)
    }

    private static func clipboardContentsView(_ contents: [GhosttyClipboardContent]) -> NSView {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 220)
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = displayContents(contents)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        scrollView.documentView = textView
        return scrollView
    }

    private static func displayContents(_ contents: [GhosttyClipboardContent]) -> String {
        guard contents.count != 1 else { return contents[0].data }
        return contents.map { "[\($0.mime)]\n\($0.data)" }.joined(separator: "\n\n")
    }

    private func finishSurfaceClosure(
        id: PaneID,
        closeBridgeSurface: Bool,
        createsReplacement: Bool
    ) {
        guard surfaces[id] != nil else { return }
        let location = workspaceStore.workspaces.lazy
            .flatMap(\.tabs)
            .first { $0.root.contains(id) }
        guard let tab = location,
            let workspace = workspaceStore.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tab.id })
            })
        else {
            _ = removeSurface(id: id, closeBridgeSurface: closeBridgeSurface)
            return
        }

        var candidate = workspaceStore
        if workspace.id == candidate.activeWorkspaceID,
            workspace.activeTabID == tab.id,
            tab.isBroadcasting
        {
            try? candidate.setBroadcasting(false, for: tab.id, in: workspace.id)
        }
        guard
            (try? splitCoordinator.apply(
                .closePane(
                    workspaceID: workspace.id,
                    tabID: tab.id,
                    paneID: id
                ),
                to: &candidate
            )) != nil
        else {
            return
        }

        let shouldCreateReplacement =
            createsReplacement
            && surfaces.count == 1
            && candidate.workspaces.allSatisfy({ $0.tabs.isEmpty })
            && !isCreatingReplacementShell
        if shouldCreateReplacement {
            isCreatingReplacementShell = true
            defer { isCreatingReplacementShell = false }
            do {
                let replacement = try prepareShellTab(
                    in: candidate.activeWorkspaceID,
                    candidate: &candidate,
                    surfaceContext: .newTab
                )
                guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else {
                    ghosttyBridge.closeSurface(id: replacement.paneID)
                    return
                }
                surfaces[replacement.paneID] = replacement.surface
                _ = commitWorkspaceStore(candidate)
                refreshWorkspacePresentation(focusTerminal: true)
            } catch {
                guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else {
                    return
                }
                _ = commitWorkspaceStore(candidate)
                refreshWorkspacePresentation(focusTerminal: true)
                onError(error)
            }
            return
        }

        guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else { return }
        guard commitWorkspaceStore(candidate) else { return }
        refreshWorkspacePresentation(focusTerminal: true)
    }
}

@MainActor
private final class HotKeyActionRelay {
    var action: (@MainActor () -> Void)?

    func perform() {
        action?()
    }
}
