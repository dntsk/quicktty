import AppKit

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let ghosttyBridge: GhosttyBridge
    private let windowController: WindowController
    private let surfaceConfiguration: GhosttySurfaceConfiguration
    private let confirmationPresenter: GhosttyConfirmationQueue.Presenter?
    private let workspaceViewController = WorkspaceViewController()
    private var workspaceStore = WorkspaceStore()
    private var createWorkspaceController: CreateWorkspaceController?
    private var defaultSurface: GhosttySurfaceView?
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
    private(set) var presentationMode: PresentationMode

    init(
        ghosttyBridge: GhosttyBridge,
        presentationMode: PresentationMode = .normal,
        normalWindowFrame: NormalWindowFrame? = nil,
        surfaceConfiguration: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration(),
        confirmationPresenter: GhosttyConfirmationQueue.Presenter? = nil,
        visibleScreenFrames: @escaping @MainActor () -> [NSRect] = {
            NSScreen.screens.map(\.visibleFrame)
        }
    ) {
        self.ghosttyBridge = ghosttyBridge
        self.presentationMode = presentationMode
        self.surfaceConfiguration = surfaceConfiguration
        self.confirmationPresenter = confirmationPresenter
        windowController = WindowController()
        super.init()

        windowController.window?.delegate = self
        if let normalWindowFrame,
            let restoredFrame = Self.restoredWindowFrame(
                from: normalWindowFrame,
                visibleScreenFrames: visibleScreenFrames()
            )
        {
            windowController.window?.setFrame(restoredFrame, display: false)
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
        ghosttyBridge.clipboardConfirmationHandler = nil
        if windowController.window?.delegate === self {
            windowController.window?.delegate = nil
        }
    }

    var normalWindowFrame: NormalWindowFrame? {
        windowController.window.flatMap { Self.normalWindowFrame(from: $0.frame) }
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
        let width = min(savedRect.width, selectedScreen.width)
        let height = min(savedRect.height, selectedScreen.height)
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
        do {
            try workspaceStore.addTab(tab, to: workspaceStore.activeWorkspaceID)
        } catch {
            ghosttyBridge.closeSurface(id: paneID)
            throw error
        }

        defaultSurface = surface
        workspaceViewController.apply(workspaceStore)
        workspaceViewController.displayTerminal(surface)
        windowController.embed(workspaceViewController)
        windowController.showWindow(nil)
        windowController.window?.makeFirstResponder(surface)
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

    private func refreshWorkspacePresentation(focusTerminal: Bool) {
        workspaceViewController.apply(workspaceStore)
        let activePaneID = workspaceStore.workspace(id: workspaceStore.activeWorkspaceID)?
            .activeTabID
            .flatMap { workspaceStore.tab(id: $0)?.activePaneID }
        let surface = activePaneID.flatMap { paneID in
            defaultSurface?.paneID == paneID ? defaultSurface : nil
        }
        workspaceViewController.displayTerminal(surface)
        if focusTerminal, let surface {
            windowController.window?.makeFirstResponder(surface)
        }
    }

    private func presentMoveToNewWorkspace(_ tabIDs: [TabID]) {
        guard !tabIDs.isEmpty, let window = windowController.window else { return }
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
            confirmationQueue.invalidatePane(paneID)
        }
        for paneID in paneIDs {
            ghosttyBridge.closeSurface(id: paneID)
            if defaultSurface?.paneID == paneID {
                defaultSurface = nil
            }
        }
        if let owner = workspaceStore.workspaces.first(where: {
            $0.tabs.contains(where: { $0.id == tabID })
        }) {
            _ = try? workspaceStore.closeTab(tabID, in: owner.id)
        }
        refreshWorkspacePresentation(focusTerminal: true)
        if ghosttyBridge.activeSurfaceCount == 0, presentationMode == .normal {
            windowController.close()
        }
    }

    #if DEBUG
        var windowForTesting: NSWindow? {
            windowController.window
        }

        var defaultSurfaceForTesting: GhosttySurfaceView? {
            defaultSurface
        }

        var activeConfirmationForTesting: GhosttyConfirmationPresentation? {
            confirmationQueue.activePresentation
        }

        var workspaceStoreForTesting: WorkspaceStore {
            workspaceStore
        }
    #endif

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === windowController.window else { return true }
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
                windowController.window === window
            else { return }

            closeActiveSurfaces()
            window.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window === windowController.window
        else { return }

        confirmationQueue.invalidateAll()
        closeActiveSurfaces()
    }

    private func closeActiveSurfaces() {
        let activeSurfaceIDs = ghosttyBridge.activeSurfaceIDs
        for paneID in activeSurfaceIDs {
            ghosttyBridge.closeSurface(id: paneID)
        }
        if let defaultSurface,
            !ghosttyBridge.activeSurfaceIDs.contains(defaultSurface.paneID)
        {
            self.defaultSurface = nil
        }
    }

    private func surfaceDidRequestClose(id: PaneID, processAlive: Bool) {
        guard processAlive else {
            confirmationQueue.invalidatePane(id)
            finishSurfaceClosure(id: id)
            return
        }

        confirmationQueue.enqueueClose(paneID: id) { [weak self] response in
            guard response == .allow,
                let self,
                ghosttyBridge.activeSurfaceIDs.contains(id)
            else { return }

            ghosttyBridge.closeSurface(id: id)
            finishSurfaceClosure(id: id)
        }
    }

    private func presentConfirmation(
        _ presentation: GhosttyConfirmationPresentation,
        completion: @escaping GhosttyConfirmationQueue.Completion
    ) -> GhosttyConfirmationQueue.Dismiss? {
        guard let window = windowController.window else {
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

    private func finishSurfaceClosure(id: PaneID) {
        if defaultSurface?.paneID == id {
            defaultSurface = nil
        }
        if let workspace = workspaceStore.workspaces.first(where: { workspace in
            workspace.tabs.contains(where: { $0.root.contains(id) })
        }), let tabID = workspace.tabs.first(where: { $0.root.contains(id) })?.id {
            _ = try? workspaceStore.closeTab(tabID, in: workspace.id)
        }
        refreshWorkspacePresentation(focusTerminal: false)

        guard ghosttyBridge.activeSurfaceCount == 0,
            presentationMode == .normal
        else { return }
        windowController.close()
    }
}
