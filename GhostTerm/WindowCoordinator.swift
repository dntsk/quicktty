import AppKit

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    typealias ModePersistence = @MainActor (PresentationMode) -> Void
    typealias QuakeHeightPersistence = @MainActor (Double) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void

    private let ghosttyBridge: GhosttyBridge
    private let normalWindowController: NormalWindowController
    private let quakeWindowController: QuakeWindowController
    private let presentationController: PresentationController
    private let hotKeyController: any HotKeyControlling
    private let surfaceConfiguration: GhosttySurfaceConfiguration
    private let confirmationPresenter: GhosttyConfirmationQueue.Presenter?
    private let onError: ErrorHandler
    private let workspaceViewController = WorkspaceViewController()
    private var workspaceStore: WorkspaceStore
    private var createWorkspaceController: CreateWorkspaceController?
    private var surfaces: [PaneID: GhosttySurfaceView] = [:]
    private var isCreatingReplacementShell = false
    private var activeHotKey = HotKeyDescriptor(key: .f12)
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

    init(
        ghosttyBridge: GhosttyBridge,
        presentationMode: PresentationMode = .normal,
        normalWindowFrame: NormalWindowFrame? = nil,
        quakeConfiguration: QuakeWindowConfiguration = QuakeWindowConfiguration(),
        surfaceConfiguration: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration(),
        initialWorkspaceStore: WorkspaceStore = WorkspaceStore(),
        confirmationPresenter: GhosttyConfirmationQueue.Presenter? = nil,
        persistPresentationMode: @escaping ModePersistence = { _ in },
        persistQuakeHeight: @escaping QuakeHeightPersistence = { _ in },
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

        normalWindowController.window?.delegate = self
        hotKeyRelay.action = { [weak self] in
            self?.presentationController.toggleQuakeVisibility()
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
        try? hotKeyController.unregister()
        ghosttyBridge.clipboardConfirmationHandler = nil
        if normalWindowController.window?.delegate === self {
            normalWindowController.window?.delegate = nil
        }
    }

    var normalWindowFrame: NormalWindowFrame? {
        normalWindowController.window.flatMap { Self.normalWindowFrame(from: $0.frame) }
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
        try createShellTab()
    }

    func createNewTab() {
        do {
            try createShellTab()
        } catch {
            onError(error)
        }
    }

    func createShellTab(in workspaceID: WorkspaceID? = nil) throws {
        let destinationWorkspaceID = workspaceID ?? workspaceStore.activeWorkspaceID
        let paneID = PaneID()
        let surface = try ghosttyBridge.makeSurface(
            id: paneID,
            configuration: surfaceConfiguration
        ) { [weak self] paneID, processAlive in
            self?.surfaceDidRequestClose(id: paneID, processAlive: processAlive)
        }
        let startupCommand = surfaceConfiguration.command.map(StartupCommand.custom) ?? .shell
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: surfaceConfiguration.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            startupCommand: startupCommand
        )
        let tab = TerminalTab(title: "Shell", pane: descriptor)
        var updatedStore = workspaceStore

        do {
            try updatedStore.addTab(tab, to: destinationWorkspaceID)
            try updatedStore.activateTab(tab.id, in: destinationWorkspaceID)
        } catch {
            ghosttyBridge.closeSurface(id: paneID)
            throw error
        }

        surfaces[paneID] = surface
        workspaceStore = updatedStore
        refreshWorkspacePresentation(focusTerminal: true)
    }

    func applyConfiguration(_ config: GhostTermConfig) {
        activeHotKey = config.globalToggle
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
            guard let self else { return }
            try? workspaceStore.activateWorkspace(workspaceID)
            refreshWorkspacePresentation(focusTerminal: true)
        }
        workspaceViewController.onActivateTab = { [weak self] tabID in
            guard let self else { return }
            try? workspaceStore.activateTab(tabID, in: workspaceStore.activeWorkspaceID)
            refreshWorkspacePresentation(focusTerminal: true)
        }
        workspaceViewController.onCloseTab = { [weak self] tabID in
            self?.requestCloseTab(tabID)
        }
        workspaceViewController.onNewTab = { [weak self] in
            self?.createNewTab()
        }
        workspaceViewController.onMoveToNewWorkspace = { [weak self] tabIDs in
            self?.presentMoveToNewWorkspace(tabIDs)
        }
        workspaceViewController.onMoveToWorkspace = { [weak self] tabIDs, workspaceID in
            self?.moveTabs(tabIDs, to: workspaceID)
        }
        workspaceViewController.onReorderTabs = { [weak self] tabIDs in
            self?.reorderTabs(tabIDs)
        }
    }

    private var activePaneID: PaneID? {
        workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)?
            .activeTabID
            .flatMap { workspaceStore.tab(id: $0)?.activePaneID }
    }

    private func refreshWorkspacePresentation(focusTerminal: Bool) {
        workspaceViewController.apply(workspaceStore)
        let surface = activePaneID.flatMap { surfaces[$0] }
        workspaceViewController.displayTerminal(surface)
        if focusTerminal, let surface {
            activeWindow?.makeFirstResponder(surface)
        }
    }

    private func presentMoveToNewWorkspace(_ tabIDs: [TabID]) {
        guard !tabIDs.isEmpty, let window = activeWindow else { return }
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
                    workspaceStore = updatedStore
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
        controller.onDismiss = { [weak self] in
            self?.createWorkspaceController = nil
        }
        createWorkspaceController = controller
        controller.presentSheet(for: window)
    }

    private func moveTabs(_ tabIDs: [TabID], to destinationWorkspaceID: WorkspaceID) {
        let sourceWorkspaceID = workspaceStore.activeWorkspaceID
        do {
            try workspaceStore.moveTabs(
                tabIDs,
                from: sourceWorkspaceID,
                to: destinationWorkspaceID
            )
            workspaceViewController.tabBarViewController.clearSelectionAfterMove()
            refreshWorkspacePresentation(focusTerminal: true)
        } catch {
            NSSound.beep()
        }
    }

    private func reorderTabs(_ orderedTabIDs: [TabID]) {
        let workspaceID = workspaceStore.activeWorkspaceID
        guard
            let workspaceIndex = workspaceStore.workspaces.firstIndex(where: {
                $0.id == workspaceID
            })
        else { return }
        let workspace = workspaceStore.workspaces[workspaceIndex]
        guard Set(orderedTabIDs) == Set(workspace.tabs.map(\.id)) else { return }
        let tabsByID = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })

        var workspaces = workspaceStore.workspaces
        workspaces[workspaceIndex].tabs = orderedTabIDs.compactMap { tabsByID[$0] }
        guard
            let reorderedStore = try? WorkspaceStore(
                workspaces: workspaces,
                activeWorkspaceID: workspaceStore.activeWorkspaceID
            )
        else { return }
        workspaceStore = reorderedStore
        refreshWorkspacePresentation(focusTerminal: false)
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

    private func closeOwningTab(_ tabID: TabID) {
        guard
            let owner = workspaceStore.workspaces.first(where: {
                $0.tabs.contains(where: { $0.id == tabID })
            })
        else { return }
        _ = try? workspaceStore.closeTab(tabID, in: owner.id)
    }

    private func closeOwningTab(containing paneID: PaneID) {
        guard
            let tabID = workspaceStore.workspaces.lazy
                .flatMap(\.tabs)
                .first(where: { $0.root.contains(paneID) })?.id
        else { return }
        closeOwningTab(tabID)
    }

    #if DEBUG
        var windowForTesting: NSWindow? {
            normalWindowController.window
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

        func activateTabForTesting(_ tabID: TabID) {
            try? workspaceStore.activateTab(tabID, in: workspaceStore.activeWorkspaceID)
            refreshWorkspacePresentation(focusTerminal: true)
        }

        func requestCloseTabForTesting(_ tabID: TabID) {
            requestCloseTab(tabID)
        }

        func surfaceDidRequestCloseForTesting(id: PaneID, processAlive: Bool) {
            surfaceDidRequestClose(id: id, processAlive: processAlive)
        }

        var activeConfirmationForTesting: GhosttyConfirmationPresentation? {
            confirmationQueue.activePresentation
        }

        var workspaceStoreForTesting: WorkspaceStore {
            workspaceStore
        }
    #endif

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
        guard removeSurface(id: id, closeBridgeSurface: closeBridgeSurface) else { return }
        closeOwningTab(containing: id)
        refreshWorkspacePresentation(focusTerminal: true)

        guard createsReplacement,
            surfaces.isEmpty,
            workspaceStore.workspaces.allSatisfy({ $0.tabs.isEmpty }),
            !isCreatingReplacementShell
        else { return }

        isCreatingReplacementShell = true
        defer { isCreatingReplacementShell = false }
        do {
            try createShellTab()
        } catch {
            onError(error)
        }
    }
}

@MainActor
private final class HotKeyActionRelay {
    var action: (@MainActor () -> Void)?

    func perform() {
        action?()
    }
}
