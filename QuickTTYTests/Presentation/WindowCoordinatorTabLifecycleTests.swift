import AppKit
import Foundation
import Synchronization
import Testing

@testable import QuickTTY

@Suite(.serialized, .ghosttyRuntime)
@MainActor
struct WindowCoordinatorTabLifecycleTests {
    @Test(arguments: [false, true])
    func agentIdentityEnvironmentIsInjectedForStartupNewTabAndSplitAndRevokedOnClose(
        controlEnabled: Bool
    ) throws {
        let instanceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let tokens = CoordinatorAgentTokenSequence([
            Array(repeating: 0x11, count: 32),
            Array(repeating: 0x22, count: 32),
            Array(repeating: 0x33, count: 32),
        ])
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-test/agent.sock",
            helperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty",
            controlSocketPath: controlEnabled ? "/tmp/quicktty-test/control.sock" : nil,
            instanceID: instanceID,
            tokenGenerator: tokens.next,
            onAction: { _ in false }
        )
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Control-Environment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        // WHY: Splits clear command overrides, so their default must also be an inert process.
        try Data("command = /bin/cat\n".utf8).write(to: configURL)
        let bridge = try GhosttyBridge(configURL: configURL)
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                command: "exec /bin/cat",
                managedHelperPath: "/must-not-launch-from-normal-configuration",
                environment: [
                    "BASE_VALUE": "preserved",
                    "QUICKTTY_PANE_ID": "collision",
                    "QUICKTTY_AGENT_SOCKET": "collision",
                    "QUICKTTY_INSTANCE_ID": "collision",
                    "QUICKTTY_PANE_TOKEN": "collision",
                    "QUICKTTY_AGENT_HELPER": "collision",
                    "QUICKTTY_CONTROL_SOCKET": "caller-owned",
                ]
            ),
            agentSessionController: controller
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()
        let startupSurface = try #require(coordinator.activeSurfaceForTesting)
        let startupEnvironment = try #require(
            bridge.surfaceConfigurationForTesting(id: startupSurface.paneID)?.environment
        )
        expectAgentEnvironment(
            startupEnvironment,
            paneID: startupSurface.paneID,
            instanceID: instanceID,
            token: String(repeating: "11", count: 32)
        )
        #expect(startupEnvironment["BASE_VALUE"] == "preserved")
        let expectedControlPath: String? = controlEnabled ? "/tmp/quicktty-test/control.sock" : nil
        #expect(startupEnvironment["QUICKTTY_CONTROL_SOCKET"] == expectedControlPath)

        coordinator.createNewTab()
        let newTabSurface = try #require(coordinator.activeSurfaceForTesting)
        let newTabEnvironment = try #require(
            bridge.surfaceConfigurationForTesting(id: newTabSurface.paneID)?.environment
        )
        expectAgentEnvironment(
            newTabEnvironment,
            paneID: newTabSurface.paneID,
            instanceID: instanceID,
            token: String(repeating: "22", count: 32)
        )

        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let splitSurface = try #require(coordinator.activeSurfaceForTesting)
        let splitEnvironment = try #require(
            bridge.surfaceConfigurationForTesting(id: splitSurface.paneID)?.environment
        )
        expectAgentEnvironment(
            splitEnvironment,
            paneID: splitSurface.paneID,
            instanceID: instanceID,
            token: String(repeating: "33", count: 32)
        )
        #expect(
            Set(
                [
                    startupEnvironment["QUICKTTY_PANE_TOKEN"],
                    newTabEnvironment["QUICKTTY_PANE_TOKEN"],
                    splitEnvironment["QUICKTTY_PANE_TOKEN"],
                ].compactMap { $0 }
            ).count == 3
        )

        #expect(newTabEnvironment["QUICKTTY_CONTROL_SOCKET"] == expectedControlPath)
        #expect(splitEnvironment["QUICKTTY_CONTROL_SOCKET"] == expectedControlPath)
        for surface in [startupSurface, newTabSurface, splitSurface] {
            #expect(
                bridge.surfaceConfigurationForTesting(id: surface.paneID)?.managedHelperPath == nil)
        }
        coordinator.surfaceDidRequestCloseForTesting(id: splitSurface.paneID, processAlive: false)

        #expect(controller.environment(for: splitSurface.paneID) == nil)
        #expect(controller.environment(for: startupSurface.paneID) != nil)
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func controlFreezeRevokesGrantedManagedPanesWithoutDetachingBeforePersistence(
        mode: PresentationMode
    ) async throws {
        let helperPath = ApplicationEnvironment.bundledAgentHelperURL(in: Bundle.main).path
        try #require(FileManager.default.isExecutableFile(atPath: helperPath))
        let cwd = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        let tokenCount = Mutex(0)
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-test/agent.sock", helperPath: helperPath,
            controlSocketPath: "/tmp/quicktty-test/control.sock",
            tokenGenerator: {
                tokenCount.withLock { count in
                    count += 1
                    return Array(repeating: UInt8(count), count: 32)
                }
            },
            onAction: { _ in false })
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        // WHY: A login banner can arrive between baseline and wait registration. Keep real
        // task/grant/wait lifecycles, but control rendered reads from before task creation.
        bridge.setTerminalAutomationClientForTesting(
            GhosttyTerminalAutomationClient(
                readText: { _, _ in
                    .success(GhosttyTerminalAutomationReadBuffer(bytes: Data(), release: {}))
                },
                freeText: { $0.release() }))
        defer { bridge.setTerminalAutomationClientForTesting(.live) }
        var promptCount = 0
        var snapshots: [WorkspaceStore] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: cwd, command: "exec /bin/cat",
                environment: ["BASE": "preserved", "QUICKTTY_CONTROL_SOCKET": "collision"]),
            agentSessionController: controller,
            terminalAutomationPermissionPresenter: { _ in
                promptCount += 1
                return .allowed
            },
            persistWorkspaceStore: { snapshots.append($0) })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let origin = try #require(coordinator.activeSurfaceForTesting?.paneID)
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude"), sessionID: "origin-session",
            workingDirectory: cwd, registeredAt: Date(), launchMetadata: [:], restoreState: .active)
        #expect(
            coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: origin, binding: binding)))
        let resolved = try #require(
            coordinator.resolveTerminalAutomationSession(
                instanceID: controller.instanceID, originPaneID: origin))
        let launch = try TerminalControlLaunch(executable: "/bin/cat", arguments: [], cwd: cwd)
        let operations: [TerminalControlRequest.Operation] = [
            .createTab(launch: launch, policy: .closeOnSuccess, focus: false),
            .split(
                anchorPaneID: origin.rawValue, direction: .right, ratio: 0.5,
                launch: launch, policy: .keep, focus: false),
        ]
        var tasks: [TerminalControlTask] = []
        for operation in operations {
            let response = await coordinator.handleTerminalAutomationRequest(
                TerminalControlSocketRequest(
                    instanceID: controller.instanceID, paneID: origin.rawValue,
                    request: try TerminalControlRequest(operation: operation, requestID: UUID())),
                context: TerminalControlRequestContext())
            guard case .task(let task) = response.result else {
                Issue.record("Expected a managed task")
                return
            }
            tasks.append(task)
            let pane = PaneID(rawValue: task.paneID)
            let environment = try #require(
                bridge.surfaceConfigurationForTesting(id: pane)?.environment)
            #expect(environment["BASE"] == "preserved")
            for key in [
                "QUICKTTY_PANE_ID", "QUICKTTY_AGENT_SOCKET", "QUICKTTY_INSTANCE_ID",
                "QUICKTTY_PANE_TOKEN", "QUICKTTY_AGENT_HELPER", "QUICKTTY_CONTROL_SOCKET",
            ] {
                #expect(environment[key] == nil)
            }
            #expect(controller.environment(for: pane) == nil)
            #expect(controller.rotate(paneID: pane) == nil)
            #expect(
                controller.credential(
                    for: try AgentIPCPreflight(
                        instanceID: controller.instanceID, paneID: task.paneID,
                        nonce: Data(repeating: 1, count: AgentIPCProtocol.nonceSize))) == nil)
            #expect(
                controller.credential(
                    for: try TerminalControlPreflight(
                        instanceID: controller.instanceID, paneID: task.paneID,
                        nonce: Data(repeating: 1, count: TerminalControlProtocol.nonceSize))) == nil
            )
        }
        #expect(tokenCount.withLock { $0 } == 1)
        #expect(promptCount == 1)
        let waitingTask = try #require(tasks.last)
        let baseline = coordinator.readManagedTask(
            taskID: waitingTask.taskID, expectedSession: resolved.identity)
        guard case .snapshot(let snapshot) = baseline else {
            Issue.record("Expected wait baseline")
            return
        }
        let waitRequest = TerminalControlSocketRequest(
            instanceID: controller.instanceID, paneID: origin.rawValue,
            request: try TerminalControlRequest(
                operation: .wait(
                    taskID: waitingTask.taskID, revision: snapshot.task.revision,
                    timeoutMilliseconds: 5_000)))
        let waiter = Task { @MainActor in
            await coordinator.handleTerminalAutomationRequest(
                waitRequest, context: TerminalControlRequestContext())
        }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !coordinator.hasPendingTerminalControlWaitForTesting(
            taskID: waitingTask.taskID, session: resolved.identity), ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            coordinator.hasPendingTerminalControlWaitForTesting(
                taskID: waitingTask.taskID, session: resolved.identity))
        let before = coordinator.workspaceStoreForPersistence
        let modelBefore = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let liveSurfaces = try surfaceIDs.map { paneID in
            try #require(coordinator.surfaceForTesting(id: paneID))
        }
        let selectedTab = activeTab(of: coordinator)
        try #require(selectedTab.root.leaves.count == 2)
        let inactivePaneID = try #require(
            selectedTab.root.leaves.first { $0 != selectedTab.activePaneID })
        let staleFocusHandler = try #require(bridge.surfaceFocusHandler)
        let staleProcessHandler = try #require(bridge.surfaceProcessExitedHandler)
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        snapshots.removeAll()
        coordinator.freezeTerminalControlForApplicationTermination()
        coordinator.freezeTerminalControlForApplicationTermination()
        #expect(bridge.surfaceFocusHandler == nil)
        staleFocusHandler(inactivePaneID)
        #expect(coordinator.workspaceStoreForTesting == modelBefore)
        #expect(coordinator.workspaceStoreForPersistence == before)
        #expect(activeTab(of: coordinator).activePaneID == selectedTab.activePaneID)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        for surface in liveSurfaces {
            #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        }
        #expect(bridge.activeSurfaceCount == 3)
        #expect(snapshots.isEmpty)
        // WHY: Freezing control must retire an already-allowed grant, not only its permission sheet.
        for task in tasks {
            // WHY: Freeze must not turn exact compensation into authority to close accepted panes.
            #expect(
                !coordinator.discardManagedTask(
                    TerminalAutomationCreatedTaskResponse(
                        task: task,
                        splitID: coordinator.managedSplitIDForTesting(taskID: task.taskID)),
                    expectedSession: resolved.identity))
            #expect(coordinator.managedTaskForTesting(taskID: task.taskID)?.owner == .user)
            #expect(
                coordinator.inspectManagedTask(
                    taskID: task.taskID,
                    expectedSession: resolved.identity) == .notOwned)
            let rejected = await coordinator.handleTerminalAutomationRequest(
                TerminalControlSocketRequest(
                    instanceID: controller.instanceID, paneID: origin.rawValue,
                    request: try TerminalControlRequest(operation: .read(taskID: task.taskID))),
                context: TerminalControlRequestContext())
            guard case .failure(let failure) = rejected.result else {
                Issue.record("Frozen control unexpectedly succeeded")
                return
            }
            #expect(failure.code == .cancelled)
        }
        let waitResponse = await waiter.value
        guard case .failure(let waitFailure) = waitResponse.result else {
            Issue.record("Revoked wait unexpectedly succeeded")
            return
        }
        #expect(waitFailure.code == .staleSession)
        #expect(
            !coordinator.hasPendingTerminalControlWaitForTesting(
                taskID: waitingTask.taskID, session: resolved.identity))
        #expect(promptCount == 1)
        #expect(controller.environment(for: origin) != nil)
        #expect(bridge.surfaceProcessExitedHandler == nil)
        for task in tasks {
            let revoked = coordinator.managedTaskForTesting(taskID: task.taskID)
            staleProcessHandler(
                PaneID(rawValue: task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 1))
            #expect(coordinator.managedTaskForTesting(taskID: task.taskID) == revoked)
            #expect(coordinator.managedCompletionTaskForTesting(taskID: task.taskID) == nil)
        }
        #expect(coordinator.workspaceStoreForTesting == modelBefore)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        controller.freeze()
        coordinator.prepareForApplicationTermination()
        coordinator.prepareForApplicationTermination()
        let closed = bridge.successfulSurfaceCloseObservationsForTesting
        for task in tasks {
            staleProcessHandler(
                PaneID(rawValue: task.paneID),
                GhosttyProcessExited(exitCode: 0, runtimeMilliseconds: 2))
            #expect(coordinator.managedTaskForTesting(taskID: task.taskID) == nil)
        }
        #expect(bridge.surfaceProcessExitedHandler == nil)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closed)
        #expect(coordinator.workspaceStoreForTesting == modelBefore)
        #expect(bridge.activeSurfaceCount == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func nativeQuakeKeyCallbackCannotActivateApplicationAfterPersistenceFreezes(
        freezeOnFocus: Bool, synchronousAnimation: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Quake-Native-Focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        try Data("command = /bin/cat\n".utf8).write(to: configURL)
        let bridge = try GhosttyBridge(configURL: configURL)
        defer { bridge.shutdown() }
        let driver = TerminationQuakeDriver()
        // WHY: Count and forward the exact production activation boundary, even if the
        // application is already active. Observing application focus cannot prove absence.
        let window = QuakeWindow(activateApplication: {
            driver.activate()
            NSApp.activate(ignoringOtherApps: true)
        })
        let screen = try #require(NSScreen.main?.visibleFrame)
        let quake = QuakeWindowController(
            window: window, configuration: QuakeWindowConfiguration(hideOnFocusLoss: false),
            visibleFrames: { [screen] },
            cursorLocation: { NSPoint(x: screen.midX, y: screen.midY) },
            animator: driver, animationDeferrer: driver, scheduler: driver,
            isFocusLossSuppressed: { false }, priorApplicationProvider: { nil })
        let state = NativeCallbackFreezeState()
        let keyObserver = NativeQuakeKeyObserver(window: window)
        var modes: [PresentationMode] = []
        var frameAtFreeze: NSRect?
        var visibilityAtFreeze: QuakeVisibility?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp", command: "exec /bin/cat"),
            persistWorkspaceStore: { store in
                if state.freezeOnCommit {
                    #expect(keyObserver.isInCallback)
                    frameAtFreeze = window.frame
                    visibilityAtFreeze = quake.requestedVisibility
                }
                state.record(store)
            }, persistPresentationMode: { modes.append($0) }, quakeWindowController: quake)
        state.coordinator = coordinator
        defer {
            keyObserver.stop()
            coordinator.prepareForApplicationTermination()
            window.orderOut(nil)
        }
        try coordinator.start()
        try #require(driver.deferred.count == 1)
        driver.deferred[0].action()
        try #require(driver.animations.count == 1)
        driver.animations[0].completion()
        try #require(driver.activationCount == 1)
        let sibling = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let selected = try #require(coordinator.activeSurfaceForTesting)
        let deadline = ContinuousClock.now + .seconds(2)
        while !selected.isReady || !sibling.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(selected.isReady && sibling.isReady)
        // Drain the existing startup focus retry before isolating the native callback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        try #require(selected !== sibling)
        try #require(activeTab(of: coordinator).activePaneID == selected.paneID)
        try #require(selected.window === window && sibling.window === window)
        try #require(window.delegate === quake)
        try coordinator.requestQuakeVisibilityForTesting(.hidden)
        try #require(driver.animations.count == 2)
        driver.animations[1].completion()
        try #require(!window.isVisible && !window.isKeyWindow)
        let content = coordinator.workspaceViewControllerForTesting
        let hosted = content.hostedSurfaceIdentifiersForTesting
        let bindings = [selected, sibling].map(\.bindingActionObservationsForTesting)
        let configurations = [selected, sibling].map {
            bridge.surfaceConfigurationForTesting(id: $0.paneID)
        }
        let refreshes = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let focusRoute = try #require(bridge.surfaceFocusHandler)
        var routedPanes: [PaneID] = []
        bridge.surfaceFocusHandler = { paneID in
            if keyObserver.isInCallback { routedPanes.append(paneID) }
            focusRoute(paneID)
        }
        // WHY: This is a real makeKeyAndOrderFront notification, not a fabricated notification
        // or fake Quake window algorithm. Its native responder change reaches Ghostty's real
        // becomeFirstResponder -> focusRoute -> selection persistence while makeKey is on stack.
        keyObserver.action = {
            #expect(state.isCompletingAnimation)
            #expect(driver.animations.count == 3)
            #expect(window.isKeyWindow)
            #expect(window.makeFirstResponder(sibling))
        }
        state.snapshots.removeAll()
        state.freezeOnCommit = freezeOnFocus
        driver.completesAnimationsSynchronously = synchronousAnimation
        let activations = driver.activationCount
        try coordinator.requestQuakeVisibilityForTesting(.shown)
        try #require(driver.deferred.count == 2)
        state.isCompletingAnimation = true
        driver.deferred[1].action()
        try #require(driver.animations.count == 3)
        if !synchronousAnimation { driver.animations[2].completion() }
        state.isCompletingAnimation = false

        try #require(keyObserver.callbackCount == 1)
        try #require(routedPanes == [sibling.paneID])
        try #require(state.snapshots.count == 1)
        #expect(activeTab(of: coordinator).activePaneID == sibling.paneID)
        #expect(state.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(driver.activationCount == activations + (freezeOnFocus ? 0 : 1))
        #expect(coordinator.presentationMode == .quake)
        #expect(modes.isEmpty)
        #expect(window.isVisible)
        #expect(window.contentViewController === content)
        #expect(content.hostedSurfaceIdentifiersForTesting == hosted)
        let postOperationBindings = [selected, sibling].map(\.bindingActionObservationsForTesting)
        // WHY: A live selection commit ends search only on the previously selected pane;
        // reentrant persistence freeze must stop that action without changing either history.
        if freezeOnFocus {
            #expect(postOperationBindings == bindings)
        } else {
            #expect(postOperationBindings == [bindings[0] + ["end_search"], bindings[1]])
        }
        #expect(bridge.activeSurfaceCount == 2)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        for (surface, configuration) in zip([selected, sibling], configurations) {
            #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
            #expect(
                bridge.surfaceConfigurationForTesting(id: surface.paneID)?.command
                    == configuration?.command)
            #expect(
                bridge.surfaceConfigurationForTesting(id: surface.paneID)?.environment
                    == configuration?.environment)
        }
        if freezeOnFocus {
            let frozen = try #require(state.presentationAtFreeze)
            let returned = NativeCallbackPresentationSnapshot(coordinator)
            #expect(!state.freezeChangedPresentation)
            #expect(window.frame == frameAtFreeze)
            #expect(quake.requestedVisibility == visibilityAtFreeze)
            #expect(returned.model == frozen.model)
            #expect(returned.persistenceModel == frozen.persistenceModel)
            #expect(returned.selectionGeneration == frozen.selectionGeneration)
            #expect(returned.displayedTabs == frozen.displayedTabs)
            #expect(returned.displayedTitles == frozen.displayedTitles)
            #expect(returned.activeTab == frozen.activeTab)
            #expect(returned.rendered == frozen.rendered)
            #expect(returned.splitHost == frozen.splitHost)
            #expect(returned.surfaces == frozen.surfaces)
            #expect(returned.statusRefreshCount == frozen.statusRefreshCount)
            #expect(returned.hosted == frozen.hosted)
            #expect(returned.surfaceHosts == frozen.surfaceHosts)
            #expect(returned.surfaceWindows == frozen.surfaceWindows)
            #expect(returned.reloadGeneration == frozen.reloadGeneration)
            #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshes)
            if synchronousAnimation {
                #expect(driver.animations[2].cancellation.isCancelled)
            }
        } else {
            #expect(state.presentationAtFreeze == nil)
            #expect(
                coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshes + 1)
        }
        // The native responder operation already on stack may finish after freeze. From its
        // return onward, compare the complete UI/model snapshot, including first responder.
        state.freezeOnCommit = false
        coordinator.freezeTerminalControlForApplicationTermination()
        keyObserver.stop()
        let frame = window.frame
        let activationCount = driver.activationCount
        let model = coordinator.workspaceStoreForTesting
        let snapshots = state.snapshots
        for afterTeardown in [false, true] {
            if afterTeardown { coordinator.prepareForApplicationTermination() }
            let before = NativeCallbackPresentationSnapshot(coordinator)
            for request in driver.deferred { request.action() }
            for request in driver.animations { request.completion() }
            for request in driver.scheduled { request.action() }
            window.focusForPresentation()
            window.orderFrontForPresentation()
            window.setPresentationFrame(frame.offsetBy(dx: 31, dy: 17))
            window.setPresentationLevel(.popUpMenu)
            try window.installContentViewController(nil)
            try quake.installContentViewController(nil)
            try quake.requestVisibility(.hidden)
            try quake.requestVisibility(.shown)
            quake.deactivateForModeTransition()
            focusRoute(selected.paneID)
            coordinator.createNewTab()
            coordinator.togglePresentationMode()
            #expect(NativeCallbackPresentationSnapshot(coordinator) == before)
            #expect(window.frame == frame)
            #expect(window.level == .floating)
            #expect(window.isVisible == !afterTeardown)
            #expect(driver.activationCount == activationCount)
            #expect(driver.animations.count == 3)
            #expect(driver.deferred.count == 2)
            #expect(coordinator.workspaceStoreForTesting == model)
            #expect(state.snapshots == snapshots)
            #expect(modes.isEmpty)
            // WHY: Replay must preserve the validated live/frozen result, including the
            // legitimate deactivation already performed by the unfrozen positive control.
            #expect(
                [selected, sibling].map(\.bindingActionObservationsForTesting)
                    == postOperationBindings)
            #expect(bridge.activeSurfaceCount == (afterTeardown ? 0 : 2))
            if afterTeardown {
                #expect(content.hostedSurfaceIdentifiersForTesting.isEmpty)
                #expect(
                    Set(bridge.successfulSurfaceCloseObservationsForTesting)
                        == [selected.paneID, sibling.paneID])
            } else {
                #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
            }
        }
    }

    @Test(arguments: [false, true])
    func nativeQuakeContentRemovalStopsBeforeParentRemovalAndAssignment(
        freezeOnRemoval: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let driver = TerminationQuakeDriver()
        let window = QuakeWindow()
        let quake = QuakeWindowController(
            window: window,
            visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
            cursorLocation: { NSPoint(x: 500, y: 500) },
            animator: driver, animationDeferrer: driver, scheduler: driver,
            isFocusLossSuppressed: { false }, priorApplicationProvider: { nil })
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            quakeWindowController: quake)
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let parent = NSViewController()
        let candidate = NSViewController()
        let view = RetirementRemovalView()
        candidate.view = view
        parent.addChild(candidate)
        let host = NSView()
        host.addSubview(view)
        defer {
            view.didRemove = nil
            window.contentViewController = nil
            view.removeFromSuperview()
            candidate.removeFromParent()
            window.orderOut(nil)
        }
        let frame = window.frame
        let before = NativeCallbackPresentationSnapshot(coordinator)
        var callbackCount = 0
        view.didRemove = {
            callbackCount += 1
            if freezeOnRemoval { coordinator.freezeTerminalControlForApplicationTermination() }
        }
        try quake.installContentViewController(candidate)
        #expect(callbackCount == 1)
        if freezeOnRemoval {
            #expect(view.superview == nil)
            #expect(candidate.parent === parent)
            #expect(window.contentViewController == nil)
            #expect(window.frame == frame)
            try window.installContentViewController(candidate)
            #expect(candidate.parent === parent)
            #expect(window.contentViewController == nil)
        } else {
            #expect(candidate.parent == nil)
            #expect(window.contentViewController === candidate)
        }
        #expect(NativeCallbackPresentationSnapshot(coordinator) == before)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
    }

    @Test
    func retainedNativeQuakePanelFailsClosedAfterControllerLifetimeEnds() throws {
        let driver = TerminationQuakeDriver()
        let window = QuakeWindow(activateApplication: {
            driver.activate()
            NSApp.activate(ignoringOtherApps: true)
        })
        defer { window.orderOut(nil) }
        weak var owner: QuakeWindowController?
        let liveFrame = NSRect(x: 100, y: 100, width: 600, height: 400)
        // WHY: Native frame callbacks can autorelease delegate references. End the controller's
        // closure-local lifetime and drain that pool before checking the externally retained panel.
        try autoreleasepool {
            let controller = QuakeWindowController(
                window: window,
                visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
                cursorLocation: { NSPoint(x: 500, y: 500) },
                animator: driver, animationDeferrer: driver, scheduler: driver,
                isFocusLossSuppressed: { false }, priorApplicationProvider: { nil })
            owner = controller
            try withExtendedLifetime(controller) {
                try #require(window.delegate === controller)
                try #require(window.canContinuePresentation())
                try #require(window.frame != liveFrame)
                controller.setPresentationFrame(liveFrame)
                try #require(window.frame == liveFrame)
                try #require(window.canContinuePresentation())
            }
        }
        try #require(owner == nil)
        #expect(window.delegate == nil)
        #expect(!window.canContinuePresentation())
        let frame = window.frame
        window.focusForPresentation()
        window.orderFrontForPresentation()
        window.setPresentationFrame(.zero)
        try window.installContentViewController(NSViewController())
        #expect(driver.activationCount == 0)
        #expect(window.frame == frame)
        #expect(!window.isVisible)
        #expect(window.contentViewController == nil)
        window.orderOutForPresentation()
    }

    @Test(arguments: ["live", "frame", "mode"])
    func nativeNormalFrameRestorationStopsTransitionAtReentrantFreeze(freezeAt: String) async throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeModeTransitionState()
        let driver = TerminationQuakeDriver()
        let quakeWindow = TerminationQuakeWindow()
        let screen = try #require(NSScreen.main?.visibleFrame)
        let quake = QuakeWindowController(
            window: quakeWindow,
            configuration: QuakeWindowConfiguration(hideOnFocusLoss: false),
            visibleFrames: { [screen] },
            cursorLocation: { NSPoint(x: screen.midX, y: screen.midY) },
            animator: driver, animationDeferrer: driver, scheduler: driver,
            isFocusLossSuppressed: { false }, priorApplicationProvider: { nil })
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp", command: "exec /bin/cat"),
            persistWorkspaceStore: { state.workspaces.append($0) },
            persistPresentationMode: { mode in
                state.modes.append(mode)
                if state.isReturning, freezeAt == "mode" { state.freeze() }
            },
            persistNormalWindowFrame: { frame in
                guard state.isReturning else { return }
                // WHY: Only the real normal-window delegate calls this persistence closure.
                // No synthetic notification or delegate replacement may stand in for setFrame.
                state.frames.append(frame)
                if let nativeFrame = state.coordinator?.windowForTesting?.frame {
                    state.nativeFrames.append(nativeFrame)
                }
                if freezeAt == "frame" { state.freeze() }
            },
            onError: { state.errors.append($0) }, quakeWindowController: quake)
        state.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let normalWindow = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let presentation = coordinator.presentationControllerForTesting
        let content = coordinator.workspaceViewControllerForTesting
        let normal = coordinator.normalWindowControllerForTesting
        let replayTransition = presentation.transition
        let replayShow = presentation.showCurrentPresentation
        let replayToggle = presentation.toggleQuakeVisibility
        let deadline = ContinuousClock.now + .seconds(2)
        while !surface.isReady || !normalWindow.isVisible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(surface.isReady)
        try #require(normalWindow.isVisible)
        try #require(normalWindow.delegate === coordinator)
        try #require(normalWindow.contentViewController === content)
        let savedFrame = normalWindow.frame
        let savedPersistenceFrame = try #require(
            WindowCoordinator.normalWindowFrame(from: savedFrame))
        let surfaceConfiguration = bridge.surfaceConfigurationForTesting(id: surface.paneID)
        let model = coordinator.workspaceStoreForTesting
        let host = try #require(surface.superview)

        coordinator.togglePresentationMode()
        try #require(coordinator.presentationMode == .quake)
        try #require(presentation.savedNormalFrame == savedFrame)
        try #require(driver.deferred.count == 1)
        driver.deferred[0].action()
        try #require(driver.animations.count == 1)
        driver.animations[0].completion()
        try #require(quakeWindow.isVisible)
        try #require(!normalWindow.isVisible)
        try #require(quakeWindow.contentViewController === content)
        try #require(surface.window === quakeWindow)
        let quakeFrame = quakeWindow.frame
        let quakeEvents = quakeWindow.events
        let hosted = content.hostedSurfaceIdentifiersForTesting
        let snapshot = NativeCallbackPresentationSnapshot(coordinator)
        // WHY: Change only the hidden native window before arming persistence. Restoration
        // must move it back exactly, so a missing synchronous native callback fails the test.
        let displacedFrame = savedFrame.offsetBy(dx: 37, dy: -23)
        normalWindow.setFrame(displacedFrame, display: false)
        try #require(normalWindow.frame == displacedFrame)
        try #require(coordinator.normalWindowFrame == savedPersistenceFrame)
        state.workspaces.removeAll()
        state.isReturning = true

        coordinator.togglePresentationMode()

        try #require(!state.frames.isEmpty)
        #expect(state.frames.first == savedPersistenceFrame)
        #expect(state.nativeFrames.count == state.frames.count)
        #expect(state.nativeFrames.first == savedFrame)
        #expect(normalWindow.frame == savedFrame)
        #expect(coordinator.normalWindowFrame == savedPersistenceFrame)
        #expect(presentation.savedNormalFrame == savedFrame)
        #expect(state.errors.isEmpty)
        #expect(state.workspaces.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        #expect(surface.superview === host)
        #expect(surface.isReady)
        #expect(bridge.activeSurfaceIDs == [surface.paneID])
        #expect(
            bridge.surfaceConfigurationForTesting(id: surface.paneID)?.command
                == surfaceConfiguration?.command)
        #expect(
            bridge.surfaceConfigurationForTesting(id: surface.paneID)?.environment
                == surfaceConfiguration?.environment)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(content.hostedSurfaceIdentifiersForTesting == hosted)
        if freezeAt == "frame" {
            #expect(state.frames == [savedPersistenceFrame])
            #expect(state.freezeCount == 1)
            #expect(!state.freezeChangedPresentation)
            #expect(state.modeAtFreeze == .quake)
            #expect(state.normalFrameAtFreeze == savedFrame)
            #expect(state.modes == [.quake])
            #expect(coordinator.presentationMode == .quake)
            #expect(coordinator.activeWindowForTesting === quakeWindow)
            #expect(normalWindow.contentViewController == nil)
            #expect(!normalWindow.isVisible)
            #expect(quakeWindow.contentViewController === content)
            #expect(quakeWindow.isVisible)
            #expect(quakeWindow.frame == quakeFrame)
            #expect(quakeWindow.events == quakeEvents)
            #expect(surface.window === quakeWindow)
            #expect(NativeCallbackPresentationSnapshot(coordinator) == snapshot)
        } else {
            #expect(state.modes == [.quake, .normal])
            #expect(coordinator.presentationMode == .normal)
            #expect(coordinator.activeWindowForTesting === normalWindow)
            #expect(normalWindow.contentViewController === content)
            #expect(normalWindow.isVisible)
            #expect(quakeWindow.contentViewController == nil)
            #expect(!quakeWindow.isVisible)
            #expect(surface.window === normalWindow)
            if freezeAt == "mode" {
                #expect(state.freezeCount == 1)
                #expect(state.modeAtFreeze == .normal)
                #expect(!state.freezeChangedPresentation)
            } else {
                #expect(state.freezeCount == 0)
            }
        }

        coordinator.freezeTerminalControlForApplicationTermination()
        let modes = state.modes
        let frames = state.frames
        for afterTeardown in [false, true] {
            if afterTeardown { coordinator.prepareForApplicationTermination() }
            let beforeReplay = NativeCallbackPresentationSnapshot(coordinator)
            let events = quakeWindow.events
            // WHY: Retain actual controller entry points to bypass the coordinator's outer guard.
            try replayTransition(.normal, true)
            try replayTransition(.quake, true)
            try replayShow()
            replayToggle()
            try coordinator.requestQuakeVisibilityForTesting(.shown)
            try coordinator.requestQuakeVisibilityForTesting(.hidden)
            coordinator.togglePresentationMode()
            normal.setPresentationFrame(displacedFrame)
            try normal.installContentViewController(nil)
            try normal.showPresentationWindow()
            normal.hidePresentationWindow()
            #expect(NativeCallbackPresentationSnapshot(coordinator) == beforeReplay)
            #expect(quakeWindow.events == events)
            #expect(normalWindow.frame == savedFrame)
            #expect(state.modes == modes)
            #expect(state.frames == frames)
            #expect(state.workspaces.isEmpty)
            #expect(bridge.activeSurfaceCount == (afterTeardown ? 0 : 1))
            if afterTeardown {
                #expect(!normalWindow.isVisible)
                #expect(!quakeWindow.isVisible)
                #expect(content.hostedSurfaceIdentifiersForTesting.isEmpty)
                #expect(bridge.successfulSurfaceCloseObservationsForTesting == [surface.paneID])
            }
        }
    }

    @Test(arguments: ["destination", "source", "rollback", "liveRollback"], [false, true])
    func partialModeTransitionRetirementSuppressesContinuationAndRollback(
        boundary: String, throwAfterFreeze: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeCallbackFreezeState()
        let driver = TerminationQuakeDriver()
        let window = TerminationQuakeWindow()
        let quake = QuakeWindowController(
            window: window,
            visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
            cursorLocation: { NSPoint(x: 500, y: 500) },
            animator: driver, animationDeferrer: driver, scheduler: driver,
            isFocusLossSuppressed: { true }, priorApplicationProvider: { nil })
        var modes: [PresentationMode] = []
        var errors: [Error] = []
        var eventsAtFreeze: [String]?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { state.record($0) },
            persistPresentationMode: { modes.append($0) }, onError: { errors.append($0) },
            quakeWindowController: quake)
        state.coordinator = coordinator
        defer {
            window.willInstallContent = nil
            window.didInstallContent = nil
            window.didOrderOut = nil
            coordinator.prepareForApplicationTermination()
        }
        try coordinator.start()
        let content = coordinator.workspaceViewControllerForTesting
        let normal = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let savedFrame = normal.frame
        if boundary == "source" {
            coordinator.togglePresentationMode()
            try #require(driver.deferred.count == 1)
            driver.deferred[0].action()
            try #require(driver.animations.count == 1)
            driver.animations[0].completion()
            try #require(window.isVisible)
        }
        let oldMode = coordinator.presentationMode
        let model = coordinator.workspaceStoreForTesting
        let oldModes = modes
        state.snapshots.removeAll()
        if boundary == "rollback" || boundary == "liveRollback" {
            window.willInstallContent = { controller in
                if controller != nil { throw PresentationContainerError.windowUnavailable }
            }
            if boundary == "rollback" {
                // WHY: The original error starts a live rollback. Retirement during its native
                // order-out must stop the remaining cleanup/reinstall/show steps as well.
                window.didOrderOut = {
                    state.freeze()
                    eventsAtFreeze = window.events
                }
            }
        } else {
            window.didInstallContent = { controller in
                #expect((controller == nil) == (boundary == "source"))
                state.freeze()
                eventsAtFreeze = window.events
                if throwAfterFreeze { throw PresentationContainerError.windowUnavailable }
            }
        }

        coordinator.togglePresentationMode()

        #expect(coordinator.presentationMode == oldMode)
        #expect(modes == oldModes)
        #expect(normal.frame == savedFrame)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(state.snapshots.isEmpty)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        #expect(surface.superview === host)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        if boundary == "liveRollback" {
            #expect(errors.count == 1)
            #expect(errors.first as? PresentationContainerError == .windowUnavailable)
            #expect(normal.contentViewController === content)
            #expect(window.contentViewController == nil)
            #expect(normal.isVisible)
            #expect(!window.isVisible)
        } else {
            try #require(state.presentationAtFreeze != nil)
            #expect(errors.isEmpty)
            #expect(!state.freezeChangedPresentation)
            #expect(NativeCallbackPresentationSnapshot(coordinator) == state.presentationAtFreeze)
            #expect(window.events == eventsAtFreeze)
            switch boundary {
            case "destination":
                #expect(normal.contentViewController == nil)
                #expect(window.contentViewController === content)
                #expect(surface.window === window)
                #expect(normal.isVisible)
                #expect(!window.isVisible)
            case "source":
                #expect(normal.contentViewController == nil)
                #expect(window.contentViewController == nil)
                // WHY: AppKit may retain the content view after clearing its controller;
                // the snapshot, not an assumed detach, defines the interrupted native state.
                #expect(window.isVisible)
                #expect(!normal.isVisible)
            default:
                #expect(normal.contentViewController === content)
                #expect(window.contentViewController == nil)
                #expect(normal.isVisible)
            }
        }
        window.willInstallContent = nil
        window.didInstallContent = nil
        window.didOrderOut = nil
        coordinator.freezeTerminalControlForApplicationTermination()
        let transition = coordinator.presentationControllerForTesting.transition
        for afterTeardown in [false, true] {
            if afterTeardown { coordinator.prepareForApplicationTermination() }
            let before = NativeCallbackPresentationSnapshot(coordinator)
            let events = window.events
            try transition(.normal, true)
            try transition(.quake, true)
            #expect(NativeCallbackPresentationSnapshot(coordinator) == before)
            #expect(window.events == events)
            #expect(modes == oldModes)
            #expect(state.snapshots.isEmpty)
            if afterTeardown {
                #expect(!normal.isVisible)
                #expect(!window.isVisible)
                #expect(content.hostedSurfaceIdentifiersForTesting.isEmpty)
                #expect(bridge.activeSurfaceCount == 0)
                #expect(bridge.successfulSurfaceCloseObservationsForTesting == [surface.paneID])
            }
        }
    }

    @Test
    func normalContainerStopsBetweenNativeViewRemovalAndParentRemovalWhenCoordinatorFreezes() throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"))
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let normal = coordinator.normalWindowControllerForTesting
        let window = try #require(normal.window)
        let installed = try #require(window.contentViewController)
        let parent = NSViewController()
        let candidate = NSViewController()
        let view = RetirementRemovalView()
        candidate.view = view
        parent.addChild(candidate)
        let host = NSView()
        host.addSubview(view)
        let before = NativeCallbackPresentationSnapshot(coordinator)
        let frame = window.frame
        var callbackCount = 0
        view.didRemove = {
            callbackCount += 1
            coordinator.freezeTerminalControlForApplicationTermination()
        }

        try normal.installContentViewController(candidate)

        #expect(callbackCount == 1)
        #expect(view.superview == nil)
        // WHY: The already-started native removal completes, but parent removal and window
        // assignment are new operations and must not run after that callback freezes.
        #expect(candidate.parent === parent)
        #expect(window.contentViewController === installed)
        #expect(window.frame == frame)
        #expect(NativeCallbackPresentationSnapshot(coordinator) == before)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        try normal.installContentViewController(candidate)
        #expect(callbackCount == 1)
        #expect(candidate.parent === parent)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func terminationFreezeSuppressesImmediateAndAlreadyQueuedCoordinatorFocus(
        mode: PresentationMode, freezeBeforeRetry: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Focus-Freeze-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        try Data("command = /bin/cat\n".utf8).write(to: configURL)
        let bridge = try GhosttyBridge(configURL: configURL)
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let sibling = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        // WHY: Drain startup/presentation focus before isolating the retry under test.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let host = try #require(surface.superview)
        try #require(surface !== sibling)
        try #require(surface.window === window)
        try #require(activeTab(of: coordinator).root.leaves.count == 2)
        let staleFocusHandler = try #require(bridge.surfaceFocusHandler)

        // WHY: Queue the real coordinator retry while the live surface is not yet presented.
        // Restore its host before freeze: freeze itself must never detach a surface.
        try #require(window.makeFirstResponder(nil))
        surface.removeFromSuperview()
        try #require(surface.window == nil)
        try #require(coordinator.activeSurfaceForTesting === surface)
        coordinator.focusActivePaneForTesting()
        host.addSubview(surface)
        try #require(surface.window === window)
        try #require(window.makeFirstResponder(nil))
        let firstResponder = window.firstResponder
        try #require(firstResponder !== surface)
        let modelBefore = coordinator.workspaceStoreForTesting
        let snapshotBefore = coordinator.workspaceStoreForPersistence
        let surfaceIDs = coordinator.surfaceIDsForTesting
        persistence.reset()
        if freezeBeforeRetry {
            coordinator.freezeTerminalControlForApplicationTermination()
            coordinator.freezeTerminalControlForApplicationTermination()
            #expect(bridge.surfaceFocusHandler == nil)
            staleFocusHandler(sibling.paneID)
            #expect(window.firstResponder === firstResponder)
            #expect(surface.superview === host)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        if freezeBeforeRetry {
            #expect(window.firstResponder === firstResponder)
        } else {
            // WHY: The unfrozen control proves the queued production path actually focuses.
            #expect(window.firstResponder === surface)
        }
        try #require(window.makeFirstResponder(nil))
        let responderBeforeImmediateFocus = window.firstResponder
        coordinator.focusActivePaneForTesting()
        if freezeBeforeRetry {
            #expect(window.firstResponder === responderBeforeImmediateFocus)
        } else {
            #expect(window.firstResponder === surface)
        }
        #expect(coordinator.workspaceStoreForTesting == modelBefore)
        #expect(coordinator.workspaceStoreForPersistence == snapshotBefore)
        #expect(activeTab(of: coordinator).activePaneID == surface.paneID)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(coordinator.surfaceForTesting(id: sibling.paneID) === sibling)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(surface.superview === host)
        #expect(sibling.window === window)
        #expect(persistence.snapshots.isEmpty)

        coordinator.prepareForApplicationTermination()
        coordinator.prepareForApplicationTermination()
        staleFocusHandler(sibling.paneID)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.workspaceStoreForTesting == modelBefore)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func lateIntegrationSheetCloseUsesTerminationProtectedProductionRestoration(
        mode: PresentationMode, freezeBeforeClose: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        coordinator.installAgentIntegrations(
            installer: AgentIntegrationInstallerClient(
                adapterIDs: AgentIntegrationInstaller.adapterIDs,
                status: { [] },
                prepare: { _ in AgentIntegrationPreparedSummary(planID: "plan", adapters: []) },
                apply: { _ in AgentIntegrationApplySummary(adapters: []) }),
            launcherInstaller: CommandLineLauncherInstallerClient(
                prepare: {
                    CommandLineLauncherSummary(
                        planID: "launcher", displayPath: "~/.local/bin/quicktty",
                        kind: "symlinkCreate", createsBackup: false, status: .available)
                },
                apply: { _ in .succeeded }))
        let sheet = try #require(coordinator.agentIntegrationsSheetControllerForTesting)
        let requestClose = try #require(sheet.viewController.onRequestClose)
        let window = try #require(coordinator.activeWindowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        coordinator.presentAgentIntegrations()
        try #require(sheet.sheetWindow.sheetParent === window)
        // WHY: Transition detachment leaves isPresented true, so close still restores focus.
        // Isolate that real callback from AppKit's own responder changes during endSheet.
        try #require(sheet.detachForWindowTransition())
        try #require(sheet.isPresented)
        try #require(sheet.parentWindowForTesting == nil)
        try #require(sheet.sheetWindow.sheetParent == nil)
        try #require(window.makeFirstResponder(nil))
        let responder = window.firstResponder
        try #require(responder !== surface)
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let hosted = coordinator.workspaceViewControllerForTesting
            .hostedSurfaceIdentifiersForTesting
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        if freezeBeforeClose {
            coordinator.freezeTerminalControlForApplicationTermination()
            coordinator.freezeTerminalControlForApplicationTermination()
            #expect(window.firstResponder === responder)
            #expect(surface.superview === host)
        }
        // WHY: Retain the installed UI closure, not a replica of coordinator restoration logic.
        requestClose()
        #expect(!sheet.isPresented)
        if freezeBeforeClose {
            #expect(window.firstResponder === responder)
        } else {
            #expect(window.firstResponder === surface)
        }
        sheet.close()
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.workspaceStoreForPersistence == snapshot)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hosted)
        #expect(persistence.snapshots.isEmpty)

        coordinator.prepareForApplicationTermination()
        requestClose()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func retainedWorkspaceEditorRequestsRespectTerminationPresentationBoundary(
        mode: PresentationMode
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) })
        defer {
            coordinator.createWorkspaceControllerForTesting?.cancelForTesting()
            coordinator.prepareForApplicationTermination()
        }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let create = try #require(presentation.onCreateWorkspace)
        let rename = try #require(presentation.onRenameWorkspace)
        let move = try #require(presentation.onMoveToNewWorkspace)
        let tabID = activeTab(of: coordinator).id
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let window = try #require(coordinator.activeWindowForTesting)
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let epoch = coordinator.selectionGenerationForTesting
        let hosted = presentation.hostedSurfaceIdentifiersForTesting
        let rendered = presentation.renderedSurfaceIdentifiersForTesting
        let splitHost = presentation.splitHostingControllerIdentifierForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let bindings = surface.bindingActionObservationsForTesting
        let responder = window.firstResponder
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        try #require(window.attachedSheet == nil)
        try #require(coordinator.createWorkspaceControllerForTesting == nil)
        persistence.reset()
        coordinator.freezeTerminalControlForApplicationTermination()

        // WHY: Rejected requests cannot change the baseline, so all retained UI callbacks
        // can share one frozen fixture while checking the complete baseline after each call.
        for action in ["create", "rename", "move"] {
            switch action {
            case "create": create()
            case "rename": rename()
            default: move([tabID])
            }
            #expect(coordinator.createWorkspaceControllerForTesting == nil)
            #expect(window.attachedSheet == nil)
            #expect(window.firstResponder === responder)
            #expect(Set(NSApp.windows.map(ObjectIdentifier.init)) == windows)
            #expect(coordinator.workspaceStoreForTesting == model)
            #expect(coordinator.workspaceStoreForPersistence == snapshot)
            #expect(coordinator.selectionGenerationForTesting == epoch)
            #expect(coordinator.activeSurfaceForTesting === surface)
            #expect(coordinator.surfaceIDsForTesting == [surface.paneID])
            #expect(surface.superview === host)
            #expect(surface.window === window)
            #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
            #expect(presentation.renderedSurfaceIdentifiersForTesting == rendered)
            #expect(presentation.splitHostingControllerIdentifierForTesting == splitHost)
            #expect(
                coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
            #expect(surface.bindingActionObservationsForTesting == bindings)
            #expect(bridge.activeSurfaceCount == 1)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
            #expect(persistence.snapshots.isEmpty)
        }
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["create", "rename", "move"])
    func alreadyPresentedWorkspaceEditorCannotCommitOrDismissOnFrozenSubmit(
        mode: PresentationMode, action: String
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeCallbackFreezeState()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { state.record($0) },
            onError: { errors.append($0) })
        state.coordinator = coordinator
        defer {
            coordinator.createWorkspaceControllerForTesting?.cancelForTesting()
            coordinator.prepareForApplicationTermination()
        }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let create = try #require(presentation.onCreateWorkspace)
        let rename = try #require(presentation.onRenameWorkspace)
        let move = try #require(presentation.onMoveToNewWorkspace)
        let original = coordinator.workspaceStoreForTesting
        let tab = activeTab(of: coordinator)
        let originalSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        state.snapshots.removeAll()
        if action == "create" {
            // WHY: Cancellation/reopening needs one positive control per mode, not per submit.
            create()
            let cancelledEditor = try #require(coordinator.createWorkspaceControllerForTesting)
            defer { cancelledEditor.window?.orderOut(nil) }
            cancelledEditor.cancelForTesting()
            try #require(coordinator.createWorkspaceControllerForTesting == nil)
            try #require(window.attachedSheet == nil)
            #expect(coordinator.workspaceStoreForTesting == original)
            #expect(state.snapshots.isEmpty)
        }
        switch action {
        case "create": create()
        case "rename": rename()
        default: move([tab.id])
        }
        let liveEditor = try #require(coordinator.createWorkspaceControllerForTesting)
        let liveSheet = try #require(liveEditor.window)
        defer { liveSheet.orderOut(nil) }
        try #require(liveSheet.sheetParent === window)
        try #require(window.attachedSheet === liveSheet)
        #expect(
            liveEditor.submitButtonTitleForTesting == (action == "rename" ? "Rename" : "Create"))
        let liveDismiss = try #require(liveEditor.onDismiss)
        liveEditor.onDismiss = {
            state.dismissCount += 1
            liveDismiss()
        }
        let name = "Accepted \(action) \(UUID().uuidString)"
        liveEditor.submitForTesting(name: name)
        let expected = try expectedWorkspaceEditorStore(
            original: original, tab: tab, action: action, name: name,
            committed: coordinator.workspaceStoreForTesting)
        try #require(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == [expected])
        #expect(liveEditor.errorMessageForTesting.isEmpty)
        #expect(state.presentationAtFreeze == nil)
        #expect(state.dismissCount == 1)
        try #require(coordinator.createWorkspaceControllerForTesting == nil)
        try #require(window.attachedSheet == nil)
        #expect(liveSheet.sheetParent == nil)
        let expectedSurfaceIDs = Set(
            expected.workspaces.flatMap { $0.tabs.flatMap { $0.root.leaves } })
        let expectedSurfaceCount = action == "create" ? 2 : 1
        #expect(expectedSurfaceIDs.count == expectedSurfaceCount)
        #expect(Set(coordinator.surfaceIDsForTesting) == expectedSurfaceIDs)
        #expect(Set(bridge.activeSurfaceIDs) == expectedSurfaceIDs)
        #expect(bridge.activeSurfaceCount == expectedSurfaceCount)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(coordinator.surfaceForTesting(id: originalSurface.paneID) === originalSurface)
        let currentTab = activeTab(of: coordinator)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        #expect(surface.paneID == currentTab.activePaneID)
        let configuration = try #require(bridge.surfaceConfigurationForTesting(id: surface.paneID))
        #expect(configuration.command == "exec /bin/cat")
        if action == "create" {
            #expect(surface !== originalSurface)
            #expect(configuration.context == .newTab)
            // WHY: The launch cwd override stays nil; only the descriptor falls back to home.
            #expect(configuration.workingDirectory == nil)
        } else {
            #expect(surface === originalSurface)
        }

        // WHY: A fresh editor on the validated live result isolates freeze-before-submit
        // without unfreezing or losing the accepted commit (including create's extra surface).
        switch action {
        case "create": create()
        case "rename": rename()
        default: move([currentTab.id])
        }
        let editor = try #require(coordinator.createWorkspaceControllerForTesting)
        try #require(editor !== liveEditor)
        let sheet = try #require(editor.window)
        defer { sheet.orderOut(nil) }
        let host = try #require(surface.superview)
        try #require(sheet.sheetParent === window)
        try #require(window.attachedSheet === sheet)
        #expect(editor.submitButtonTitleForTesting == (action == "rename" ? "Rename" : "Create"))
        var frozenDismissCount = 0
        let dismiss = try #require(editor.onDismiss)
        editor.onDismiss = {
            frozenDismissCount += 1
            dismiss()
        }
        let responder = window.firstResponder
        let sheetResponder = sheet.firstResponder
        let snapshot = coordinator.workspaceStoreForPersistence
        let epoch = coordinator.selectionGenerationForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let beforeFreeze = NativeCallbackPresentationSnapshot(coordinator, editor: editor)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == [expected])

        coordinator.freezeTerminalControlForApplicationTermination()
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == beforeFreeze)
        #expect(window.attachedSheet === sheet)
        #expect(sheet.sheetParent === window)
        let nameBeforeSubmit = editor.nameForTesting
        let errorBeforeSubmit = editor.errorMessageForTesting
        // WHY: A retired caller must reject submit before validation or its coordinator callback.
        editor.submitForTesting(name: "Late workspace")
        #expect(coordinator.createWorkspaceControllerForTesting === editor)
        #expect(window.attachedSheet === sheet)
        #expect(sheet.sheetParent === window)
        #expect(window.firstResponder === responder)
        #expect(sheet.firstResponder === sheetResponder)
        #expect(editor.nameForTesting == nameBeforeSubmit)
        #expect(editor.errorMessageForTesting == errorBeforeSubmit)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(coordinator.workspaceStoreForPersistence == snapshot)
        #expect(coordinator.selectionGenerationForTesting == epoch)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(coordinator.surfaceForTesting(id: originalSurface.paneID) === originalSurface)
        #expect(Set(coordinator.surfaceIDsForTesting) == expectedSurfaceIDs)
        #expect(Set(bridge.activeSurfaceIDs) == expectedSurfaceIDs)
        #expect(bridge.activeSurfaceCount == expectedSurfaceCount)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == beforeFreeze)
        #expect(frozenDismissCount == 0)
        #expect(state.dismissCount == 1)
        #expect(state.snapshots == [expected])
        #expect(errors.isEmpty)

        coordinator.prepareForApplicationTermination()
        #expect(coordinator.createWorkspaceControllerForTesting == nil)
        #expect(window.attachedSheet == nil)
        #expect(liveSheet.sheetParent == nil)
        #expect(sheet.sheetParent == nil)
        #expect(!sheet.isVisible)
        #expect(state.dismissCount == 1)
        #expect(frozenDismissCount == 1)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
        let liveTornDown = NativeCallbackPresentationSnapshot(coordinator, editor: liveEditor)
        let tornDown = NativeCallbackPresentationSnapshot(coordinator, editor: editor)
        liveEditor.submitForTesting(name: "After teardown")
        liveEditor.cancelForTesting()
        editor.submitForTesting(name: "After teardown")
        editor.cancelForTesting()
        coordinator.prepareForApplicationTermination()
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: liveEditor) == liveTornDown)
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == tornDown)
        #expect(state.dismissCount == 1)
        #expect(frozenDismissCount == 1)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == [expected])
        #expect(errors.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["create", "rename", "move"])
    func workspaceEditorAcceptedSubmitRetainsSheetWhenPersistenceFreezes(
        mode: PresentationMode, action: String
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeCallbackFreezeState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { state.record($0) })
        state.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let create = try #require(presentation.onCreateWorkspace)
        let rename = try #require(presentation.onRenameWorkspace)
        let move = try #require(presentation.onMoveToNewWorkspace)
        let original = coordinator.workspaceStoreForTesting
        let tab = activeTab(of: coordinator)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let window = try #require(coordinator.activeWindowForTesting)
        switch action {
        case "create": create()
        case "rename": rename()
        default: move([tab.id])
        }
        let editor = try #require(coordinator.createWorkspaceControllerForTesting)
        let sheet = try #require(editor.window)
        defer { sheet.orderOut(nil) }
        try #require(sheet.sheetParent === window)
        let dismiss = try #require(editor.onDismiss)
        editor.onDismiss = {
            state.dismissCount += 1
            dismiss()
        }
        state.snapshots.removeAll()
        state.freezeOnCommit = true
        let name = "Accepted \(action) \(UUID().uuidString)"

        // WHY: Use the actual caller whose success branch used to endSheet after freeze.
        editor.submitForTesting(name: name)

        let expected = try expectedWorkspaceEditorStore(
            original: original, tab: tab, action: action, name: name,
            committed: coordinator.workspaceStoreForTesting)
        #expect(state.snapshots == [expected])
        #expect(editor.errorMessageForTesting.isEmpty)
        #expect(bridge.activeSurfaceCount == (action == "create" ? 2 : 1))
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        let frozen = try #require(state.presentationAtFreeze)
        #expect(!state.freezeChangedPresentation)
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == frozen)
        #expect(state.dismissCount == 0)
        #expect(coordinator.createWorkspaceControllerForTesting === editor)
        #expect(window.attachedSheet === sheet)
        #expect(sheet.sheetParent === window)
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        editor.submitForTesting(name: "Replay \(UUID().uuidString)")
        editor.cancelForTesting()
        #expect(editor.nameForTesting == name)
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == frozen)
        #expect(state.dismissCount == 0)
        coordinator.prepareForApplicationTermination()
        #expect(coordinator.createWorkspaceControllerForTesting == nil)
        #expect(window.attachedSheet == nil)
        #expect(sheet.sheetParent == nil)
        #expect(!sheet.isVisible)
        #expect(state.dismissCount == 1)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
        let tornDown = NativeCallbackPresentationSnapshot(coordinator, editor: editor)
        editor.submitForTesting(name: "After teardown")
        editor.cancelForTesting()
        coordinator.prepareForApplicationTermination()
        #expect(NativeCallbackPresentationSnapshot(coordinator, editor: editor) == tornDown)
        #expect(state.dismissCount == 1)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == [expected])
    }

    private func expectedWorkspaceEditorStore(
        original: WorkspaceStore, tab: TerminalTab, action: String, name: String,
        committed: WorkspaceStore
    ) throws -> WorkspaceStore {
        let sourceID = original.activeWorkspaceID
        let destination = try #require(committed.workspaces.first { $0.name == name })
        var expected = original
        if action != "rename" {
            expected = try WorkspaceStore(
                workspaces: original.workspaces + [Workspace(id: destination.id, name: name)],
                activeWorkspaceID: sourceID)
        }
        switch action {
        case "rename":
            try expected.renameWorkspace(sourceID, to: name)
        case "move":
            try expected.moveTabs([tab.id], from: sourceID, to: destination.id)
        default:
            try #require(destination.tabs.count == 1)
            let createdTab = try #require(destination.tabs.first)
            try #require(createdTab.id != tab.id)
            try #require(createdTab.root.leaves.count == 1)
            #expect(createdTab.title == "Shell")
            #expect(createdTab.titleOverride == nil)
            #expect(!createdTab.isBroadcasting)
            let descriptor = try #require(
                createdTab.paneDescriptor(for: createdTab.activePaneID))
            #expect(descriptor.startupCommand == .custom("exec /bin/cat"))
            #expect(descriptor.cwd == FileManager.default.homeDirectoryForCurrentUser.path)
            #expect(descriptor.agentResumeBinding == nil)
            try expected.activateWorkspace(destination.id)
            try expected.addTab(createdTab, to: destination.id)
            try expected.activateTab(createdTab.id, in: destination.id)
        }
        #expect(committed == expected)
        return expected
    }

    @Test(
        arguments: [PresentationMode.normal, .quake], ["unfrozen", "pending", "commit", "reject"])
    func nativeDragCompletionRespectsCoordinatorRetirement(
        mode: PresentationMode, freezeAt: String
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeCallbackFreezeState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { state.record($0) })
        state.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let firstTab = activeTab(of: coordinator)
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let secondTab = activeTab(of: coordinator)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let tabBar = presentation.tabBarViewController
        let collectionView = tabBar.collectionViewForTesting
        let drag = CoordinatorTabDraggingInfo(
            source: collectionView, payload: firstTab.id.rawValue.uuidString)
        defer { drag.draggingPasteboard.releaseGlobally() }
        let session = NSDraggingSession()
        tabBar.collectionView(
            collectionView, draggingSession: session, willBeginAt: .zero,
            forItemsAt: [IndexPath(item: 0, section: 0)])
        let displayed = tabBar.displayedTabsForTesting
        let reloads = tabBar.dataReloadGenerationForTesting
        var expected = coordinator.workspaceStoreForTesting
        let order = [secondTab.id, firstTab.id]
        if freezeAt != "reject" {
            try expected.reorderTabs(order, in: expected.activeWorkspaceID)
            try expected.activateTab(firstTab.id, in: expected.activeWorkspaceID)
        }
        let expectedSnapshots: [WorkspaceStore] = freezeAt == "reject" ? [] : [expected]
        state.snapshots.removeAll()
        state.freezeOnCommit = freezeAt == "commit"
        if freezeAt == "reject" {
            let reorder = try #require(tabBar.onReorderTabs)
            tabBar.onReorderTabs = { ids, activeID in
                state.freeze()
                return reorder(ids, activeID)
            }
        }

        let accepted = tabBar.collectionView(
            collectionView, acceptDrop: drag, indexPath: IndexPath(item: 2, section: 0),
            dropOperation: .before)

        #expect(accepted == (freezeAt != "reject"))
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == expectedSnapshots)
        #expect(tabBar.displayedTabsForTesting == displayed)
        #expect(tabBar.dataReloadGenerationForTesting == reloads)
        #expect(
            tabBar.hasPendingReorderForTesting
                == (freezeAt == "unfrozen" || freezeAt == "pending"))
        if freezeAt == "commit" || freezeAt == "reject" {
            let frozen = try #require(state.presentationAtFreeze)
            #expect(!state.freezeChangedPresentation)
            #expect(NativeCallbackPresentationSnapshot(coordinator) == frozen)
        } else if freezeAt == "pending" {
            let beforeFreeze = NativeCallbackPresentationSnapshot(coordinator)
            coordinator.freezeTerminalControlForApplicationTermination()
            #expect(NativeCallbackPresentationSnapshot(coordinator) == beforeFreeze)
            #expect(!tabBar.hasPendingReorderForTesting)
        }
        let beforeCompletion = NativeCallbackPresentationSnapshot(coordinator)
        // WHY: Call the native delegate, not just the coordinator's guarded finish closure.
        tabBar.collectionView(
            collectionView, draggingSession: session, endedAt: .zero, dragOperation: .move)
        if freezeAt == "unfrozen" {
            #expect(tabBar.displayedTabsForTesting.map(\.id) == order)
            #expect(tabBar.orderedTabIDsForTesting == order)
            #expect(tabBar.selectedTabIDsInOrderForTesting == [firstTab.id])
            #expect(tabBar.activeTabIDForTesting == firstTab.id)
            #expect(tabBar.dataReloadGenerationForTesting > reloads)
            #expect(coordinator.activeWindowForTesting?.firstResponder === firstSurface)
        } else {
            #expect(NativeCallbackPresentationSnapshot(coordinator) == beforeCompletion)
        }
        #expect(!tabBar.hasPendingReorderForTesting)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        coordinator.freezeTerminalControlForApplicationTermination()
        for afterTeardown in [false, true] {
            if afterTeardown { coordinator.prepareForApplicationTermination() }
            let beforeReplay = NativeCallbackPresentationSnapshot(coordinator)
            let closes = bridge.successfulSurfaceCloseObservationsForTesting
            tabBar.collectionView(
                collectionView, draggingSession: session, endedAt: .zero, dragOperation: .move)
            let lateAccepted = tabBar.collectionView(
                collectionView, acceptDrop: drag, indexPath: IndexPath(item: 0, section: 0),
                dropOperation: .before)
            #expect(!lateAccepted)
            var proposedIndexPath = IndexPath(item: 0, section: 0) as NSIndexPath
            var dropOperation = NSCollectionView.DropOperation.on
            let validation = tabBar.collectionView(
                collectionView, validateDrop: drag, proposedIndexPath: &proposedIndexPath,
                dropOperation: &dropOperation)
            #expect(validation.isEmpty)
            #expect(dropOperation == .on)
            tabBar.collectionView(
                collectionView, draggingSession: session, willBeginAt: .zero, forItemsAt: [])
            tabBar.beginSelectionForTesting(secondTab.id, gesture: .click)
            tabBar.finishSelectionForTesting()
            tabBar.beginRenameForTesting(secondTab.id)
            #expect(tabBar.contextMenu(for: secondTab.id).items.isEmpty)
            #expect(!tabBar.hasPendingReorderForTesting)
            #expect(NativeCallbackPresentationSnapshot(coordinator) == beforeReplay)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting == closes)
            #expect(bridge.activeSurfaceCount == (afterTeardown ? 0 : 2))
            #expect(coordinator.workspaceStoreForTesting == expected)
            #expect(state.snapshots == expectedSnapshots)
        }
        #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["begin", "reload", "commit"])
    func nativeRenameAndSelectionStopAtReentrantCallbackRetirement(
        mode: PresentationMode, boundary: String
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let state = NativeCallbackFreezeState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { state.record($0) })
        state.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let tab = activeTab(of: coordinator)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController
        let item = tabBar.tabItemForTesting(at: 0)
        if boundary != "commit" {
            let editingChanged = try #require(tabBar.onRenameEditingChanged)
            tabBar.onRenameEditingChanged = { isEditing in
                editingChanged(isEditing)
                if isEditing == (boundary == "begin") { state.freeze() }
            }
        }
        var expected = coordinator.workspaceStoreForTesting
        state.snapshots.removeAll()
        tabBar.beginRenameForTesting(tab.id)
        if boundary == "begin" {
            #expect(!item.isRenamingForTesting)
            #expect(tabBar.editedTabIDForTesting == tab.id)
        } else {
            try #require(item.isRenamingForTesting)
            if boundary == "reload" {
                // WHY: reloadCollectionView ends native editing before it can safely reload.
                tabBar.finishSelectionForTesting()
            } else {
                let editor = try #require(item.renameEditorForTesting)
                editor.stringValue = "Accepted native rename"
                state.freezeOnCommit = true
                try expected.setTitleOverride(editor.stringValue, for: tab.id)
                item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))
            }
        }
        let frozen = try #require(state.presentationAtFreeze)
        #expect(!state.freezeChangedPresentation)
        #expect(NativeCallbackPresentationSnapshot(coordinator) == frozen)
        #expect(coordinator.workspaceStoreForTesting == expected)
        let expectedSnapshots: [WorkspaceStore] = boundary == "commit" ? [expected] : []
        #expect(state.snapshots == expectedSnapshots)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        tabBar.finishSelectionForTesting()
        tabBar.beginRenameForTesting(tab.id)
        item.endRenameEditingForTesting()
        #expect(NativeCallbackPresentationSnapshot(coordinator) == frozen)
        // WHY: A begin interrupted before item.beginRenaming still needs explicit cleanup.
        coordinator.prepareForApplicationTermination()
        #expect(tabBar.editedTabIDForTesting == nil)
        #expect(!item.isRenamingForTesting)
        #expect(!coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
        #expect(bridge.activeSurfaceCount == 0)
        let tornDown = NativeCallbackPresentationSnapshot(coordinator)
        item.endRenameEditingForTesting()
        tabBar.finishSelectionForTesting()
        #expect(NativeCallbackPresentationSnapshot(coordinator) == tornDown)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == expectedSnapshots)
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["return", "escape", "endEditing"])
    func fullyActiveNativeRenameDefersAutomaticCompletionUntilExplicitTeardown(
        mode: PresentationMode, completion: String
    ) throws {
        for freezeBeforeCompletion in [false, true] {
            let bridge = try GhosttyBridge()
            defer { bridge.shutdown() }
            let state = NativeCallbackFreezeState()
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge, presentationMode: mode,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
                persistWorkspaceStore: { state.record($0) })
            defer { coordinator.prepareForApplicationTermination() }
            try coordinator.start()
            if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
            let presentation = coordinator.workspaceViewControllerForTesting
            let tabBar = presentation.tabBarViewController
            let window = try #require(coordinator.activeWindowForTesting)
            window.contentView?.layoutSubtreeIfNeeded()
            let tab = activeTab(of: coordinator)
            let surface = try #require(coordinator.activeSurfaceForTesting)
            let bindings = surface.bindingActionObservationsForTesting
            let item = tabBar.tabItemForTesting(at: 0)
            try #require(item.view.window === window)
            let commit = try #require(tabBar.onRenameTab)
            let editingChanged = try #require(tabBar.onRenameEditingChanged)
            tabBar.onRenameTab = { id, title in
                state.renameCommits.append(title)
                commit(id, title)
            }
            tabBar.onRenameEditingChanged = { isEditing in
                state.renameEditingStates.append(isEditing)
                editingChanged(isEditing)
            }
            tabBar.beginRenameForTesting(tab.id)
            let editor = try #require(item.renameEditorForTesting)
            let fieldEditor = try #require(editor.currentEditor())
            try #require(window.firstResponder === fieldEditor)
            try #require(item.isRenamingForTesting)
            try #require(!editor.isHidden)
            try #require(item.visibleTitleForTesting == nil)
            try #require(tabBar.editedTabIDForTesting == tab.id)
            try #require(coordinator.isTabRenameEditingForTesting)
            let title = "Native active rename"
            editor.stringValue = title
            fieldEditor.string = title
            fieldEditor.selectedRange = NSRange(2..<6)
            let selectedRange = fieldEditor.selectedRange
            let displayedTitle = item.latestDisplayedTitleForTesting
            let transientInteractions = coordinator.quakeTransientInteractionCountForTesting
            let active = NativeCallbackPresentationSnapshot(coordinator)
            var expected = coordinator.workspaceStoreForTesting
            state.snapshots.removeAll()

            // WHY: Retain the real item/editor and deliver at the native caller, not its parent
            // callbacks. Each completion gets its own fully active session and unfrozen control.
            let deliverCompletion: @MainActor () -> Void = {
                switch completion {
                case "return":
                    item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))
                case "escape":
                    item.invokeRenameCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
                default:
                    item.endRenameEditingForTesting()
                }
            }
            @MainActor func expectActiveRenameUnchanged() {
                #expect(NativeCallbackPresentationSnapshot(coordinator) == active)
                #expect(item.isRenamingForTesting)
                #expect(!editor.isHidden)
                #expect(editor.stringValue == title)
                #expect(fieldEditor.string == title)
                #expect(fieldEditor.selectedRange == selectedRange)
                #expect(editor.currentEditor() === fieldEditor)
                #expect(window.firstResponder === fieldEditor)
                #expect(item.visibleTitleForTesting == nil)
                #expect(item.latestDisplayedTitleForTesting == displayedTitle)
                #expect(coordinator.isTabRenameEditingForTesting)
                #expect(
                    coordinator.quakeTransientInteractionCountForTesting == transientInteractions)
                #expect(state.renameCommits.isEmpty)
                #expect(state.renameEditingStates == [true])
                #expect(state.snapshots.isEmpty)
                #expect(surface.bindingActionObservationsForTesting == bindings)
                #expect(bridge.activeSurfaceCount == 1)
                #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
            }

            if freezeBeforeCompletion {
                coordinator.freezeTerminalControlForApplicationTermination()
                expectActiveRenameUnchanged()
                for _ in 0..<2 {
                    deliverCompletion()
                    expectActiveRenameUnchanged()
                }
            } else {
                if completion != "escape" {
                    try expected.setTitleOverride(title, for: tab.id)
                }
                deliverCompletion()
                #expect(!item.isRenamingForTesting)
                #expect(editor.isHidden)
                #expect(item.visibleTitleForTesting != nil)
                #expect(editor.currentEditor() == nil)
                #expect(window.firstResponder !== fieldEditor)
                #expect(tabBar.editedTabIDForTesting == nil)
                #expect(!coordinator.isTabRenameEditingForTesting)
                #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
                #expect(state.renameCommits == (completion == "escape" ? [] : [title]))
                #expect(state.renameEditingStates == [true, false])
                let finished = NativeCallbackPresentationSnapshot(coordinator)
                deliverCompletion()
                item.endRenameEditingForTesting()
                #expect(NativeCallbackPresentationSnapshot(coordinator) == finished)
                #expect(state.renameCommits == (completion == "escape" ? [] : [title]))
                #expect(state.renameEditingStates == [true, false])
                coordinator.freezeTerminalControlForApplicationTermination()
            }
            let expectedSnapshots: [WorkspaceStore] =
                !freezeBeforeCompletion && completion != "escape" ? [expected] : []
            #expect(coordinator.workspaceStoreForTesting == expected)
            #expect(state.snapshots == expectedSnapshots)
            #expect(bridge.activeSurfaceCount == 1)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)

            coordinator.prepareForApplicationTermination()
            #expect(!item.isRenamingForTesting)
            #expect(editor.isHidden)
            #expect(item.visibleTitleForTesting != nil)
            #expect(editor.currentEditor() == nil)
            #expect(window.firstResponder !== fieldEditor)
            #expect(tabBar.editedTabIDForTesting == nil)
            #expect(!coordinator.isTabRenameEditingForTesting)
            #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
            #expect(state.renameEditingStates == [true, false])
            #expect(bridge.activeSurfaceCount == 0)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting == [surface.paneID])
            #expect(coordinator.surfaceIDsForTesting.isEmpty)
            #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
            let tornDown = NativeCallbackPresentationSnapshot(coordinator)
            let editorText = editor.stringValue
            let visibleTitle = item.visibleTitleForTesting
            let commits = state.renameCommits
            // WHY: Replay every automatic route against the retained, explicitly ended session.
            item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))
            item.invokeRenameCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
            item.endRenameEditingForTesting()
            #expect(NativeCallbackPresentationSnapshot(coordinator) == tornDown)
            #expect(!item.isRenamingForTesting)
            #expect(editor.isHidden)
            #expect(editor.stringValue == editorText)
            #expect(item.visibleTitleForTesting == visibleTitle)
            #expect(editor.currentEditor() == nil)
            #expect(window.firstResponder !== fieldEditor)
            #expect(state.renameCommits == commits)
            #expect(state.renameEditingStates == [true, false])
            #expect(coordinator.workspaceStoreForTesting == expected)
            #expect(state.snapshots == expectedSnapshots)
            #expect(surface.bindingActionObservationsForTesting == bindings)
            #expect(bridge.activeSurfaceCount == 0)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting == [surface.paneID])
        }
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func workspaceDeletionStopsWhenNativeEndEditingPersistsRenameAndFreezes(
        mode: PresentationMode, freezeDuringRename: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Delete-Rename-Freeze-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        // WHY: The selected split and both workspaces use controlled, real runtimes.
        try Data("command = /bin/cat\n".utf8).write(to: configURL)
        let bridge = try GhosttyBridge(configURL: configURL)
        defer { bridge.shutdown() }
        let selected = Workspace(name: "Selected")
        let other = Workspace(name: "Other")
        let store = try WorkspaceStore(
            workspaces: [selected, other], activeWorkspaceID: selected.id)
        let state = NativeCallbackFreezeState()
        let deletion = NativeRenameDeletionState()
        let title = "Accepted rename during workspace deletion"
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp", command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshot in
                if deletion.isInRenameCallback {
                    #expect(deletion.isResolvingDeletion)
                    #expect(state.renameCommits == [title])
                    deletion.persistedRenameDuringDeletion = deletion.isResolvingDeletion
                }
                if state.freezeOnCommit { #expect(deletion.isInRenameCallback) }
                state.record(snapshot)
            },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                deletion.confirmations.append(confirmation)
                deletion.completions.append(completion)
            })
        state.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        try coordinator.createShellTab(in: other.id)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let tabBar = presentation.tabBarViewController
        let window = try #require(coordinator.activeWindowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let surfaces = try coordinator.surfaceIDsForTesting.map {
            try #require(coordinator.surfaceForTesting(id: $0))
        }
        try #require(surfaces.count == 3)
        let tab = activeTab(of: coordinator)
        try #require(tab.root.leaves.count == 2)
        let backgroundPane = try #require(
            coordinator.workspaceStoreForTesting.workspace(id: other.id)?.tabs.first?.activePaneID)
        let indexPath = IndexPath(item: 0, section: 0)
        let deadline = ContinuousClock.now + .seconds(2)
        // WHY: Require an actually installed collection item, not the testing fallback item.
        // Drain deferred startup/Quake focus before creating the native field editor.
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if window.isVisible, window.firstResponder === surface,
                tabBar.collectionViewForTesting.item(at: indexPath)?.view.window === window,
                surfaces.allSatisfy({ $0.isReady })
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        try #require(window.isVisible)
        try #require(window.firstResponder === surface)
        try #require(surfaces.allSatisfy { $0.isReady })
        let nativeItem = try #require(tabBar.collectionViewForTesting.item(at: indexPath))
        let item = tabBar.tabItemForTesting(at: 0)
        try #require(item === nativeItem)
        try #require(item.view.window === window)
        let rename = try #require(tabBar.onRenameTab)
        let editingChanged = try #require(tabBar.onRenameEditingChanged)
        tabBar.onRenameTab = { id, value in
            deletion.isInRenameCallback = true
            defer { deletion.isInRenameCallback = false }
            state.renameCommits.append(value)
            rename(id, value)
        }
        tabBar.onRenameEditingChanged = { isEditing in
            state.renameEditingStates.append(isEditing)
            editingChanged(isEditing)
        }
        tabBar.beginRenameForTesting(tab.id)
        let editor = try #require(item.renameEditorForTesting)
        let editorDeadline = ContinuousClock.now + .seconds(2)
        while editor.currentEditor() == nil, ContinuousClock.now < editorDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let fieldEditor = try #require(editor.currentEditor())
        try #require(window.firstResponder === fieldEditor)
        try #require(item.isRenamingForTesting)
        try #require(!editor.isHidden)
        try #require(tabBar.editedTabIDForTesting == tab.id)
        try #require(coordinator.isTabRenameEditingForTesting)
        editor.stringValue = title
        fieldEditor.string = title
        fieldEditor.selectedRange = NSRange(2..<6)
        let before = NativeCallbackPresentationSnapshot(coordinator)
        let bindingActions = surfaces.map(\.bindingActionObservationsForTesting)
        var renamed = coordinator.workspaceStoreForTesting
        try renamed.setTitleOverride(title, for: tab.id)
        state.snapshots.removeAll()
        let requestDeletion = try #require(presentation.onDeleteWorkspace)
        requestDeletion()
        try #require(
            deletion.confirmations == [
                WorkspaceDeletionConfirmation(
                    workspaceID: selected.id, workspaceName: selected.name, tabCount: 1,
                    paneCount: 2)
            ])
        try #require(deletion.completions.count == 1)
        let allowDeletion = try #require(deletion.completions.first)
        try #require(coordinator.pendingWorkspaceDeletionIDForTesting == selected.id)
        try #require(window.attachedSheet == nil)
        try #require(editor.currentEditor() === fieldEditor)
        try #require(window.firstResponder === fieldEditor)
        try #require(state.renameCommits.isEmpty)
        try #require(state.snapshots.isEmpty)
        try #require(state.presentationAtFreeze == nil)
        try #require(NativeCallbackPresentationSnapshot(coordinator) == before)

        // WHY: No manual end-edit or freeze here. The real deletion callback must reach
        // detach's makeFirstResponder(nil), native end-edit, rename commit, then persistence.
        state.freezeOnCommit = freezeDuringRename
        deletion.isResolvingDeletion = true
        allowDeletion(true)
        deletion.isResolvingDeletion = false

        try #require(deletion.persistedRenameDuringDeletion)
        try #require(state.renameCommits == [title])
        #expect(coordinator.pendingWorkspaceDeletionIDForTesting == nil)
        var expected = renamed
        if freezeDuringRename {
            let frozen = try #require(state.presentationAtFreeze)
            let returned = NativeCallbackPresentationSnapshot(coordinator)
            #expect(!state.freezeChangedPresentation)
            #expect(frozen.model == renamed)
            #expect(returned.model == frozen.model)
            #expect(returned.persistenceModel == frozen.persistenceModel)
            #expect(returned.selectionGeneration == before.selectionGeneration)
            #expect(returned.hosted == before.hosted)
            #expect(returned.rendered == before.rendered)
            #expect(returned.splitHost == before.splitHost)
            #expect(returned.surfaces == before.surfaces)
            #expect(returned.surfaceHosts == before.surfaceHosts)
            #expect(returned.surfaceWindows == before.surfaceWindows)
            #expect(returned.refreshCount == frozen.refreshCount)
            #expect(returned.statusRefreshCount == frozen.statusRefreshCount)
            #expect(returned.reloadGeneration == frozen.reloadGeneration)
            #expect(returned.displayedTabs == frozen.displayedTabs)
            #expect(returned.displayedTitles == frozen.displayedTitles)
            #expect(bridge.activeSurfaceCount == 3)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
            #expect(surfaces.map(\.bindingActionObservationsForTesting) == bindingActions)
            #expect(state.snapshots == [renamed])
            // WHY: The AppKit responder call began BEFORE freeze and may finish unwinding.
            // Compare responders only after that boundary returns, not to the in-call snapshot.
            allowDeletion(true)
            requestDeletion()
            item.endRenameEditingForTesting()
            coordinator.focusActivePaneForTesting()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(NativeCallbackPresentationSnapshot(coordinator) == returned)
            #expect(state.snapshots == [renamed])
            #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        } else {
            _ = try expected.deleteWorkspace(selected.id)
            #expect(state.presentationAtFreeze == nil)
            #expect(state.snapshots == [renamed, expected])
            #expect(coordinator.surfaceIDsForTesting == [backgroundPane])
            #expect(bridge.activeSurfaceCount == 1)
            #expect(
                Set(bridge.successfulSurfaceCloseObservationsForTesting) == Set(tab.root.leaves))
        }
        #expect(coordinator.workspaceStoreForTesting == expected)
        let snapshots = state.snapshots
        coordinator.prepareForApplicationTermination()
        coordinator.prepareForApplicationTermination()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
        #expect(
            Set(bridge.successfulSurfaceCloseObservationsForTesting) == Set(surfaces.map(\.paneID)))
        #expect(!item.isRenamingForTesting)
        #expect(editor.currentEditor() == nil)
        #expect(!coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
        #expect(state.renameCommits == [title])
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(state.snapshots == snapshots)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func retainedWorkspaceDeletionRequestCannotPresentOrBecomePendingAfterFreeze(
        mode: PresentationMode, freezeBeforeRequest: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let selected = Workspace(name: "Selected")
        let other = Workspace(name: "Other")
        let store = try WorkspaceStore(
            workspaces: [selected, other], activeWorkspaceID: selected.id)
        let persistence = WorkspacePersistenceRecorder()
        var confirmations: [WorkspaceDeletionConfirmation] = []
        var completions: [@MainActor (Bool) -> Void] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                confirmations.append(confirmation)
                completions.append(completion)
            })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let request = try #require(coordinator.workspaceViewControllerForTesting.onDeleteWorkspace)
        let window = try #require(coordinator.activeWindowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let responder = window.firstResponder
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let epoch = coordinator.selectionGenerationForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        persistence.reset()
        if freezeBeforeRequest { coordinator.freezeTerminalControlForApplicationTermination() }

        for attempt in 1...2 {
            request()
            if freezeBeforeRequest {
                #expect(confirmations.isEmpty)
                #expect(completions.isEmpty)
            } else {
                #expect(confirmations.count == attempt)
                #expect(confirmations.last?.workspaceID == selected.id)
                #expect(coordinator.pendingWorkspaceDeletionIDForTesting == selected.id)
                let completion = try #require(completions.last)
                completion(false)
            }
            #expect(coordinator.pendingWorkspaceDeletionIDForTesting == nil)
        }
        #expect(window.attachedSheet == nil)
        #expect(Set(NSApp.windows.map(ObjectIdentifier.init)) == windows)
        #expect(window.firstResponder === responder)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.workspaceStoreForPersistence == snapshot)
        #expect(coordinator.selectionGenerationForTesting == epoch)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(coordinator.surfaceIDsForTesting == [surface.paneID])
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func queuedAndLateConfirmationsFailClosedAtActualPresenterBoundary(
        mode: PresentationMode, freezeBeforeResolution: Bool
    ) throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var presentations: [GhosttyConfirmationPresentation] = []
        var completions: [GhosttyConfirmationQueue.Completion] = []
        var dismissCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            confirmationPresenter: { presentation, completion in
                presentations.append(presentation)
                completions.append(completion)
                return { dismissCount += 1 }
            })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let first = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let second = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let third = try #require(coordinator.activeSurfaceForTesting)
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let close = try #require(coordinator.workspaceViewControllerForTesting.onCloseTab)
        let clipboard = try #require(bridge.clipboardConfirmationHandler)
        let request = GhosttyClipboardConfirmationRequest(
            id: UUID(), paneID: third.paneID, kind: .paste, location: .standard,
            contents: [GhosttyClipboardContent(mime: "text/plain", data: "bounded\nfixture")])
        let closeResponses = Mutex<[GhosttyClipboardConfirmationResponse]>([])
        let clipboardResponses = Mutex<[GhosttyClipboardConfirmationResponse]>([])
        coordinator.enqueueCloseConfirmationForTesting(first.paneID)
        coordinator.enqueueCloseConfirmationForTesting(second.paneID) { response in
            closeResponses.withLock { $0.append(response) }
        }
        clipboard(
            .request(
                request,
                response: { response in
                    clipboardResponses.withLock { $0.append(response) }
                }))
        try #require(presentations == [.close(first.paneID)])
        try #require(coordinator.pendingConfirmationCountForTesting == 2)
        let resolveFirst = try #require(completions.first)
        let window = try #require(coordinator.activeWindowForTesting)
        let host = try #require(third.superview)
        let responder = window.firstResponder
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let epoch = coordinator.selectionGenerationForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let hosted = coordinator.workspaceViewControllerForTesting
            .hostedSurfaceIdentifiersForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        if freezeBeforeResolution {
            coordinator.freezeTerminalControlForApplicationTermination()
            #expect(dismissCount == 0)
            #expect(coordinator.activeConfirmationForTesting == .close(first.paneID))
            #expect(closeResponses.withLock { $0.isEmpty })
            #expect(clipboardResponses.withLock { $0.isEmpty })
            let lateResponses = Mutex<[GhosttyClipboardConfirmationResponse]>([])
            clipboard(
                .request(
                    request,
                    response: { response in
                        lateResponses.withLock { $0.append(response) }
                    }))
            // WHY: A late close must not cancel the queued clipboard or preempt an existing sheet;
            // a late clipboard must complete immediately, even while another request is active.
            close(activeTab(of: coordinator).id)
            coordinator.requestCloseActivePane()
            #expect(lateResponses.withLock { $0 } == [.deny])
            #expect(clipboardResponses.withLock { $0.isEmpty })
            #expect(coordinator.pendingConfirmationCountForTesting == 2)
            #expect(coordinator.activeConfirmationForTesting == .close(first.paneID))
            #expect(dismissCount == 0)
        }
        // WHY: Drain through the production queue callback, not a duplicate presenter guard.
        // Frozen pending requests must each receive exactly one synchronous denial.
        resolveFirst(.deny)
        if freezeBeforeResolution {
            #expect(presentations == [.close(first.paneID)])
        } else {
            try #require(presentations == [.close(first.paneID), .close(second.paneID)])
            let resolveSecond = try #require(completions.last)
            resolveSecond(.deny)
            try #require(presentations.last == .clipboard(request))
            let resolveClipboard = try #require(completions.last)
            resolveClipboard(.deny)
            #expect(presentations.count == 3)
        }
        #expect(closeResponses.withLock { $0 } == [.deny])
        #expect(clipboardResponses.withLock { $0 } == [.deny])
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(coordinator.pendingConfirmationCountForTesting == 0)
        if freezeBeforeResolution {
            let lateCloseResponses = Mutex<[GhosttyClipboardConfirmationResponse]>([])
            coordinator.enqueueCloseConfirmationForTesting(second.paneID) { response in
                lateCloseResponses.withLock { $0.append(response) }
            }
            #expect(lateCloseResponses.withLock { $0 } == [.deny])
            #expect(presentations.count == 1)
            #expect(coordinator.activeConfirmationForTesting == nil)
            #expect(coordinator.pendingConfirmationCountForTesting == 0)
        }
        resolveFirst(.allow)
        #expect(dismissCount == 0)
        #expect(window.attachedSheet == nil)
        #expect(Set(NSApp.windows.map(ObjectIdentifier.init)) == windows)
        #expect(window.firstResponder === responder)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.workspaceStoreForPersistence == snapshot)
        #expect(coordinator.selectionGenerationForTesting == epoch)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hosted)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.surfaceForTesting(id: first.paneID) === first)
        #expect(coordinator.surfaceForTesting(id: second.paneID) === second)
        #expect(coordinator.activeSurfaceForTesting === third)
        #expect(third.superview === host)
        #expect(third.window === window)
        #expect(bridge.activeSurfaceCount == 3)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func retainedRenameAndReorderCompletionsCannotRestoreFocusOrPersistAfterFreeze(
        mode: PresentationMode, freezeBeforeCompletion: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let presentation = coordinator.workspaceViewControllerForTesting
        let rename = try #require(presentation.onRenameTab)
        let editingChanged = try #require(presentation.onRenameEditingChanged)
        let finishReorder = try #require(presentation.onFinishReorderTabs)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let window = try #require(coordinator.activeWindowForTesting)
        let tabID = activeTab(of: coordinator).id
        // WHY: Exercise retained production completions without asserting native editor teardown focus.
        editingChanged(true)
        try #require(coordinator.isTabRenameEditingForTesting)
        try #require(window.makeFirstResponder(nil))
        let responder = window.firstResponder
        try #require(responder !== surface)
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        if freezeBeforeCompletion {
            coordinator.freezeTerminalControlForApplicationTermination()
        }
        rename(tabID, "Late rename")
        editingChanged(false)
        finishReorder()

        #expect(!coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
        if freezeBeforeCompletion {
            #expect(window.firstResponder === responder)
            #expect(coordinator.workspaceStoreForTesting == model)
            #expect(coordinator.workspaceStoreForPersistence == snapshot)
            #expect(persistence.snapshots.isEmpty)
            #expect(
                coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        } else {
            #expect(window.firstResponder === surface)
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == "Late rename")
            #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        }
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(coordinator.surfaceIDsForTesting == [surface.paneID])
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func retainedTabActivationAndReorderRespectSharedTerminationBoundaries(
        mode: PresentationMode, freezeBeforeCallback: Bool
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        try #require(firstSurface !== secondSurface)
        let presentation = coordinator.workspaceViewControllerForTesting
        let activate = try #require(presentation.onActivateTab)
        let reorder = try #require(presentation.onReorderTabs)
        let finishReorder = try #require(presentation.onFinishReorderTabs)
        let window = try #require(coordinator.activeWindowForTesting)
        if freezeBeforeCallback {
            coordinator.freezeTerminalControlForApplicationTermination()
        }

        for isReorder in [false, true] {
            let model = coordinator.workspaceStoreForTesting
            let snapshot = coordinator.workspaceStoreForPersistence
            let workspace = try #require(model.workspace(id: model.activeWorkspaceID))
            try #require(workspace.tabs.count == 2)
            let selected = activeTab(of: coordinator)
            let target = try #require(workspace.tabs.first { $0.id != selected.id })
            let order = Array(workspace.tabs.map(\.id).reversed())
            try #require(order != workspace.tabs.map(\.id))
            let surface = try #require(coordinator.activeSurfaceForTesting)
            let host = try #require(surface.superview)
            let firstHost = firstSurface.superview
            let secondHost = secondSurface.superview
            let responder = window.firstResponder
            let surfaceIDs = coordinator.surfaceIDsForTesting
            let epoch = coordinator.selectionGenerationForTesting
            let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
            let statusCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting
            let hosted = presentation.hostedSurfaceIdentifiersForTesting
            let rendered = presentation.renderedSurfaceIdentifiersForTesting
            let splitHost = presentation.splitHostingControllerIdentifierForTesting
            let displayedTabs = presentation.tabBarViewController.displayedTabsForTesting.map(\.id)
            let displayedActiveTab = presentation.tabBarViewController.activeTabIDForTesting
            let reloadGeneration = presentation.tabBarViewController.dataReloadGenerationForTesting
            let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
            let bindingActions = surface.bindingActionObservationsForTesting
            persistence.reset()

            // WHY: Retain and invoke the installed closures with real selection/order changes,
            // not a helper that duplicates their guards or a single-tab no-op.
            if isReorder {
                #expect(reorder(order, target.id) == !freezeBeforeCallback)
            } else {
                activate(target.id)
            }
            if freezeBeforeCallback {
                #expect(coordinator.workspaceStoreForTesting == model)
                #expect(coordinator.workspaceStoreForPersistence == snapshot)
                #expect(coordinator.selectionGenerationForTesting == epoch)
                #expect(activeTab(of: coordinator).id == selected.id)
                #expect(activeTab(of: coordinator).activePaneID == selected.activePaneID)
                #expect(coordinator.activeSurfaceForTesting === surface)
                #expect(window.firstResponder === responder)
                #expect(surface.superview === host)
                #expect(firstSurface.superview === firstHost)
                #expect(secondSurface.superview === secondHost)
                #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
                #expect(presentation.renderedSurfaceIdentifiersForTesting == rendered)
                #expect(presentation.splitHostingControllerIdentifierForTesting == splitHost)
                #expect(
                    presentation.tabBarViewController.displayedTabsForTesting.map(\.id)
                        == displayedTabs)
                #expect(
                    presentation.tabBarViewController.activeTabIDForTesting == displayedActiveTab)
                #expect(
                    presentation.tabBarViewController.dataReloadGenerationForTesting
                        == reloadGeneration)
                #expect(
                    coordinator.refreshWorkspacePresentationInvocationCountForTesting
                        == refreshCount)
                #expect(
                    coordinator.refreshWorkspaceStatusesInvocationCountForTesting == statusCount)
                #expect(surface.bindingActionObservationsForTesting == bindingActions)
                #expect(persistence.snapshots.isEmpty)
            } else {
                var expected = model
                if isReorder { try expected.reorderTabs(order, in: workspace.id) }
                try expected.activateTab(target.id, in: workspace.id)
                #expect(coordinator.workspaceStoreForTesting == expected)
                #expect(coordinator.selectionGenerationForTesting == epoch + 1)
                #expect(activeTab(of: coordinator).id == target.id)
                #expect(activeTab(of: coordinator).activePaneID == target.activePaneID)
                #expect(persistence.snapshots == [expected])
                #expect(
                    coordinator.refreshWorkspacePresentationInvocationCountForTesting
                        == refreshCount + (isReorder ? 0 : 1))
            }
            if isReorder { finishReorder() }
            if freezeBeforeCallback {
                #expect(
                    coordinator.refreshWorkspacePresentationInvocationCountForTesting
                        == refreshCount)
                #expect(window.firstResponder === responder)
                #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
            } else {
                #expect(
                    window.firstResponder === coordinator.surfaceForTesting(id: target.activePaneID)
                )
                #expect(
                    coordinator.refreshWorkspacePresentationInvocationCountForTesting
                        == refreshCount + 1)
            }
            #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
            #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
            #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)
            #expect(bridge.activeSurfaceCount == 2)
            #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        }

        let finalModel = coordinator.workspaceStoreForTesting
        persistence.reset()
        coordinator.prepareForApplicationTermination()
        coordinator.prepareForApplicationTermination()
        #expect(coordinator.workspaceStoreForTesting == finalModel)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(presentation.hostedSurfaceIdentifiersForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: ["show", "hide", "deferred"])
    func coordinatorFreezeRetiresActualQuakeCallbacksBeforeAndAfterTeardown(work: String) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let driver = TerminationQuakeDriver()
        let window = TerminationQuakeWindow()
        let persistence = WorkspacePersistenceRecorder()
        let quake = QuakeWindowController(
            window: window,
            visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
            cursorLocation: { NSPoint(x: 500, y: 500) },
            animator: driver, animationDeferrer: driver, scheduler: driver,
            isFocusLossSuppressed: { false }, priorApplicationProvider: { driver },
            persistQuakeHeight: { driver.persistedHeights.append($0) })
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            quakeWindowController: quake)
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        try #require(surface.window === window)
        // WHY: Positive controls use the same real controller completions, not replica logic.
        try #require(driver.deferred.count == 1)
        driver.deferred[0].action()
        try #require(driver.animations.count == 1)
        driver.animations[0].completion()
        #expect(window.focusCount == 1)
        try coordinator.requestQuakeVisibilityForTesting(.hidden)
        try #require(driver.animations.count == 2)
        driver.animations[1].completion()
        #expect(!window.isVisible)
        #expect(driver.activationCount == 1)

        try coordinator.requestQuakeVisibilityForTesting(.shown)
        try #require(driver.deferred.count == 2)
        if work != "deferred" {
            driver.deferred[1].action()
            try #require(driver.animations.count == 3)
        }
        quake.focusDidResignKey()
        try #require(driver.scheduled.count == 1)
        if work == "hide" {
            driver.animations[2].completion()
            try coordinator.requestQuakeVisibilityForTesting(.hidden)
            try #require(driver.animations.count == 4)
        }
        // WHY: A resize already in flight must not persist geometry after retirement either.
        quake.windowWillStartLiveResize(
            Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let visibility = quake.requestedVisibility
        let frame = window.frame
        let events = window.events
        let responder = window.firstResponder
        let hosted = coordinator.workspaceViewControllerForTesting
            .hostedSurfaceIdentifiersForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let activationCount = driver.activationCount
        let animationCount = driver.animations.count
        persistence.reset()
        try #require(window.isVisible)
        if work == "deferred" {
            try #require(driver.deferred.last?.cancellation.isCancelled == false)
        } else {
            try #require(driver.animations.last?.cancellation.isCancelled == false)
        }
        if work != "hide" {
            try #require(driver.scheduled.last?.cancellation.isCancelled == false)
        }

        coordinator.freezeTerminalControlForApplicationTermination()
        coordinator.freezeTerminalControlForApplicationTermination()
        #expect(window.events == events)
        #expect(window.frame == frame)
        #expect(window.isVisible)
        #expect(quake.requestedVisibility == visibility)
        #expect(driver.scheduled.last?.cancellation.isCancelled == true)
        if work == "deferred" {
            #expect(driver.deferred.last?.cancellation.isCancelled == true)
        } else {
            #expect(driver.animations.last?.cancellation.isCancelled == true)
        }

        // WHY: Deliberately deliver cancelled callbacks, then deliver the SAME callbacks again
        // after teardown. Cancellation alone must not be the authority to focus/order windows.
        for afterTeardown in [false, true] {
            if afterTeardown { coordinator.prepareForApplicationTermination() }
            let eventsBeforeDelivery = window.events
            let responderBeforeDelivery = window.firstResponder
            for request in driver.deferred { request.action() }
            for request in driver.animations { request.completion() }
            for request in driver.scheduled { request.action() }
            quake.focusDidResignKey()
            quake.windowDidResize(
                Notification(name: NSWindow.didResizeNotification, object: window))
            quake.windowDidEndLiveResize(
                Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            try coordinator.requestQuakeVisibilityForTesting(.hidden)
            try coordinator.requestQuakeVisibilityForTesting(.shown)
            quake.deactivateForModeTransition()
            #expect(window.events == eventsBeforeDelivery)
            #expect(window.firstResponder === responderBeforeDelivery)
            #expect(window.frame == frame)
            #expect(window.isVisible == !afterTeardown)
            #expect(quake.requestedVisibility == visibility)
            #expect(driver.animations.count == animationCount)
            #expect(driver.deferred.count == 2)
            #expect(driver.scheduled.count == 1)
            #expect(driver.activationCount == activationCount)
            #expect(driver.persistedHeights.isEmpty)
            #expect(coordinator.workspaceStoreForTesting == model)
            #expect(coordinator.workspaceStoreForPersistence == snapshot)
            #expect(
                coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
            #expect(persistence.snapshots.isEmpty)
            if afterTeardown {
                #expect(bridge.activeSurfaceCount == 0)
                #expect(coordinator.surfaceIDsForTesting.isEmpty)
                #expect(
                    coordinator.workspaceViewControllerForTesting
                        .hostedSurfaceIdentifiersForTesting.isEmpty)
            } else {
                #expect(window.firstResponder === responder)
                #expect(surface.superview === host)
                #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
                #expect(bridge.activeSurfaceCount == 1)
                #expect(
                    coordinator.workspaceViewControllerForTesting
                        .hostedSurfaceIdentifiersForTesting == hosted)
                #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
            }
        }
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["broadcast", "move", "reorder"])
    func acceptedUICommitCannotApplyOrClearSelectionWhenPersistenceFreezes(
        mode: PresentationMode, action: String
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = Workspace(name: "Source")
        let destination = Workspace(name: "Destination")
        let store = try WorkspaceStore(
            workspaces: [source, destination], activeWorkspaceID: source.id)
        let persistence = WorkspacePersistenceRecorder()
        let termination = ReentrantTerminationState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: {
                persistence.snapshots.append($0)
                if termination.freezeOnCommit {
                    termination.coordinator?.freezeTerminalControlForApplicationTermination()
                }
            })
        termination.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        let firstTab = activeTab(of: coordinator)
        coordinator.createNewTab()
        let secondTab = activeTab(of: coordinator)
        let presentation = coordinator.workspaceViewControllerForTesting
        let tabBar = presentation.tabBarViewController
        tabBar.beginSelectionForTesting(firstTab.id, gesture: .commandClick)
        tabBar.finishSelectionForTesting()
        let selection = tabBar.selectedTabIDsInOrderForTesting
        try #require(selection.count == 2)
        let selected = activeTab(of: coordinator)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let host = try #require(surface.superview)
        let window = try #require(coordinator.activeWindowForTesting)
        try #require(window.makeFirstResponder(nil))
        let responder = window.firstResponder
        let hosted = presentation.hostedSurfaceIdentifiersForTesting
        let rendered = presentation.renderedSurfaceIdentifiersForTesting
        let splitHost = presentation.splitHostingControllerIdentifierForTesting
        let displayed = tabBar.displayedTabsForTesting
        let displayedActiveTab = tabBar.activeTabIDForTesting
        let reloadCount = tabBar.dataReloadGenerationForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let statusCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting
        let surfaces = coordinator.surfaceIDsForTesting
        let bindings = surface.bindingActionObservationsForTesting
        let epoch = coordinator.selectionGenerationForTesting
        var expected = coordinator.workspaceStoreForTesting
        let broadcast = try #require(presentation.onToggleBroadcast)
        let move = try #require(presentation.onMoveToWorkspace)
        let reorder = try #require(presentation.onReorderTabs)
        let finishReorder = try #require(presentation.onFinishReorderTabs)
        persistence.reset()
        termination.freezeOnCommit = true
        switch action {
        case "broadcast":
            try expected.setBroadcasting(!selected.isBroadcasting, for: selected.id, in: source.id)
            broadcast()
        case "move":
            try expected.moveTabs([selected.id], from: source.id, to: destination.id)
            move([selected.id], destination.id)
        default:
            let order = [secondTab.id, firstTab.id]
            try expected.reorderTabs(order, in: source.id)
            try expected.activateTab(secondTab.id, in: source.id)
            // WHY: A commit already accepted before freeze must still report true.
            #expect(reorder(order, secondTab.id))
            finishReorder()
        }
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(persistence.snapshots == [expected])
        #expect(
            coordinator.selectionGenerationForTesting == epoch + (action == "broadcast" ? 0 : 1))
        #expect(tabBar.displayedTabsForTesting == displayed)
        #expect(tabBar.activeTabIDForTesting == displayedActiveTab)
        #expect(tabBar.selectedTabIDsInOrderForTesting == selection)
        #expect(tabBar.dataReloadGenerationForTesting == reloadCount)
        #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
        #expect(presentation.renderedSurfaceIdentifiersForTesting == rendered)
        #expect(presentation.splitHostingControllerIdentifierForTesting == splitHost)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(coordinator.refreshWorkspaceStatusesInvocationCountForTesting == statusCount)
        #expect(surface.bindingActionObservationsForTesting == bindings)
        #expect(window.firstResponder === responder)
        #expect(surface.superview === host)
        #expect(coordinator.surfaceIDsForTesting == surfaces)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        coordinator.prepareForApplicationTermination()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.workspaceStoreForTesting == expected)
        #expect(persistence.snapshots == [expected])
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func freezeDuringCommitPreventsFollowingPresentationAndLatePhysicalMutations(
        mode: PresentationMode
    ) throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let termination = ReentrantTerminationState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: {
                persistence.snapshots.append($0)
                if termination.freezeOnCommit {
                    termination.coordinator?.freezeTerminalControlForApplicationTermination()
                }
            })
        termination.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let firstTabID = activeTab(of: coordinator).id
        coordinator.createNewTab()
        let presentation = coordinator.workspaceViewControllerForTesting
        let activate = try #require(presentation.onActivateTab)
        let window = try #require(coordinator.activeWindowForTesting)
        let responder = window.firstResponder
        let hosted = presentation.hostedSurfaceIdentifiersForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        persistence.reset()
        termination.freezeOnCommit = true
        activate(firstTabID)
        // WHY: Commit succeeded before freeze; only the shared refresh boundary can stop
        // the production activation callback from rebuilding presentation on its return.
        #expect(activeTab(of: coordinator).id == firstTabID)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
        #expect(window.firstResponder === responder)
        let model = coordinator.workspaceStoreForTesting
        persistence.reset()

        #expect(throws: CancellationError.self) { try coordinator.createShellTab() }
        #expect(throws: CancellationError.self) {
            try coordinator.splitActivePane(axis: .horizontal)
        }
        #expect(throws: CancellationError.self) {
            try coordinator.openConfiguration(at: URL(fileURLWithPath: "/tmp/quicktty-config"))
        }
        let normalWindow = try #require(coordinator.windowForTesting)
        #expect(!coordinator.windowShouldClose(normalWindow))
        coordinator.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: normalWindow))
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
        #expect(window.firstResponder === responder)
        #expect(persistence.snapshots.isEmpty)

        coordinator.prepareForApplicationTermination()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake], [false, true])
    func pendingCreationCompensatesExactRuntimeWithoutEditingFrozenModel(
        mode: PresentationMode, createsSplit: Bool
    ) async throws {
        let helperPath = ApplicationEnvironment.bundledAgentHelperURL(in: Bundle.main).path
        try #require(FileManager.default.isExecutableFile(atPath: helperPath))
        let cwd = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-test/agent.sock", helperPath: helperPath,
            controlSocketPath: "/tmp/quicktty-test/control.sock",
            tokenGenerator: { Array(repeating: 0x11, count: 32) },
            onAction: { _ in false })
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let taskID = UUID()
        let persistence = WorkspacePersistenceRecorder()
        let termination = ReentrantTerminationState()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: cwd, command: "exec /bin/cat"),
            agentSessionController: controller,
            managedTaskIDProvider: { taskID },
            terminalAutomationPermissionPresenter: { _ in .allowed },
            persistWorkspaceStore: { snapshot in
                persistence.snapshots.append(snapshot)
                guard termination.freezeOnCommit, let reference = termination.coordinator,
                    let task = reference.managedTaskForTesting(taskID: taskID)
                else { return }
                termination.created = TerminalAutomationCreatedTaskResponse(
                    task: task, splitID: reference.managedSplitIDForTesting(taskID: taskID))
                reference.freezeTerminalControlForApplicationTermination()
            })
        termination.coordinator = coordinator
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let origin = try #require(coordinator.activeSurfaceForTesting)
        let binding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude"), sessionID: "pending-origin",
            workingDirectory: cwd, registeredAt: Date(), launchMetadata: [:], restoreState: .active)
        try #require(
            coordinator.handleAgentSessionLifecycleAction(
                .register(paneID: origin.paneID, binding: binding)))
        let resolved = try #require(
            coordinator.resolveTerminalAutomationSession(
                instanceID: controller.instanceID, originPaneID: origin.paneID))
        let presentation = coordinator.workspaceViewControllerForTesting
        let hosted = presentation.hostedSurfaceIdentifiersForTesting
        let responder = coordinator.activeWindowForTesting?.firstResponder
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let launch = try TerminalControlLaunch(executable: "/bin/cat", arguments: [], cwd: cwd)
        let operation: TerminalControlRequest.Operation =
            createsSplit
            ? .split(
                anchorPaneID: origin.paneID.rawValue, direction: .right, ratio: 0.5,
                launch: launch, policy: .keep, focus: false)
            : .createTab(launch: launch, policy: .keep, focus: false)
        persistence.reset()
        termination.freezeOnCommit = true
        // WHY: Freeze inside the real host commit, before domain acceptance. The domain's
        // post-await validation must compensate, not strand a surface behind a rejected commit.
        let response = await coordinator.handleTerminalAutomationRequest(
            TerminalControlSocketRequest(
                instanceID: controller.instanceID, paneID: origin.paneID.rawValue,
                request: try TerminalControlRequest(
                    operation: operation,
                    requestID: UUID(uuidString: "00000000-0000-0000-0000-000000001010")!)),
            context: TerminalControlRequestContext())
        guard case .failure = response.result else {
            Issue.record("Frozen pending creation unexpectedly succeeded")
            return
        }
        let exact = try #require(termination.created)
        let frozenModel = try #require(persistence.snapshots.first)
        #expect(persistence.snapshots == [frozenModel])
        #expect(coordinator.workspaceStoreForTesting == frozenModel)
        #expect(frozenModel.workspaces.flatMap(\.tabs).flatMap(\.root.leaves).count == 2)
        #expect(coordinator.surfaceIDsForTesting == [origin.paneID])
        #expect(coordinator.surfaceForTesting(id: origin.paneID) === origin)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(
            bridge.successfulSurfaceCloseObservationsForTesting == [
                PaneID(rawValue: exact.task.paneID)
            ])
        #expect(presentation.hostedSurfaceIdentifiersForTesting == hosted)
        #expect(coordinator.activeWindowForTesting?.firstResponder === responder)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(coordinator.managedTaskForTesting(taskID: taskID) == nil)
        let epoch = coordinator.selectionGenerationForTesting
        #expect(
            !coordinator.discardManagedTask(
                TerminalAutomationCreatedTaskResponse(task: exact.task, splitID: UUID()),
                expectedSession: resolved.identity))
        #expect(coordinator.discardManagedTask(exact, expectedSession: resolved.identity))
        #expect(coordinator.discardManagedTask(exact, expectedSession: resolved.identity))
        #expect(coordinator.selectionGenerationForTesting == epoch)
        #expect(coordinator.workspaceStoreForTesting == frozenModel)
        #expect(persistence.snapshots == [frozenModel])
        coordinator.prepareForApplicationTermination()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.count == 2)
        #expect(coordinator.workspaceStoreForTesting == frozenModel)
        #expect(persistence.snapshots == [frozenModel])
    }

    @Test(arguments: [PresentationMode.normal, .quake], ["pane", "tab", "workspace"])
    func retainedCloseConfirmationCannotDetachOrMutateDuringTerminationFreeze(
        mode: PresentationMode, target: String
    ) throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let selected = Workspace(name: "Selected")
        let other = Workspace(name: "Other")
        let store = try WorkspaceStore(
            workspaces: [selected, other], activeWorkspaceID: selected.id)
        let persistence = WorkspacePersistenceRecorder()
        var closeResponse: GhosttyConfirmationQueue.Completion?
        var deletionResponse: (@MainActor (Bool) -> Void)?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge, presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            confirmationPresenter: { _, completion in
                closeResponse = completion
                return nil
            },
            workspaceDeletionConfirmationPresenter: { _, completion in
                deletionResponse = completion
            })
        defer { coordinator.prepareForApplicationTermination() }
        try coordinator.start()
        if mode == .quake { try coordinator.requestQuakeVisibilityForTesting(.shown) }
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let host = try #require(surface.superview)
        switch target {
        case "pane": coordinator.requestCloseActivePane()
        case "tab": coordinator.requestCloseActiveTab()
        default: coordinator.deleteActiveWorkspace()
        }
        let model = coordinator.workspaceStoreForTesting
        let snapshot = coordinator.workspaceStoreForPersistence
        let responder = window.firstResponder
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        coordinator.freezeTerminalControlForApplicationTermination()
        // WHY: Deliver the actual retained confirmation, including an affirmative late result.
        if target == "workspace" {
            let response = try #require(deletionResponse)
            response(true)
            response(false)
        } else {
            let response = try #require(closeResponse)
            response(.allow)
            response(.deny)
        }
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(coordinator.workspaceStoreForPersistence == snapshot)
        #expect(window.firstResponder === responder)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(coordinator.surfaceIDsForTesting == [surface.paneID])
        #expect(surface.superview === host)
        #expect(surface.window === window)
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting.isEmpty)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
        #expect(persistence.snapshots.isEmpty)

        coordinator.prepareForApplicationTermination()
        #expect(bridge.activeSurfaceCount == 0)
        #expect(coordinator.workspaceStoreForTesting == model)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func activeSameSessionRegistrationIsAnExactNoOp() throws {
        let paneID = PaneID()
        let originalBinding = try AgentResumeBinding(
            adapterID: AgentAdapterID(rawValue: "claude-code"),
            sessionID: "session-1",
            workingDirectory: "/tmp/original",
            registeredAt: Date(timeIntervalSince1970: 2_000),
            launchMetadata: ["source": "original"],
            restoreState: .active
        )
        let tab = TerminalTab(
            title: "Agent",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp",
                agentResumeBinding: originalBinding
            )
        )
        let workspace = Workspace(name: "Agent", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let commitCount = persistence.snapshots.count
        let staleBinding = try AgentResumeBinding(
            adapterID: originalBinding.adapterID,
            sessionID: originalBinding.sessionID,
            workingDirectory: "/tmp/stale",
            registeredAt: Date(timeIntervalSince1970: 1_000),
            launchMetadata: ["source": "stale"],
            restoreState: .active
        )

        let accepted = coordinator.handleAgentSessionLifecycleAction(
            .register(paneID: paneID, binding: staleBinding)
        )

        #expect(accepted)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.agentResumeBinding == originalBinding
        )
        #expect(persistence.snapshots.count == commitCount)
    }

    @Test
    func restoredSurfaceRetryRetainsPaneIdentityRotatesTokenAndRevokesFailedAttempt() throws {
        let paneID = PaneID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let tab = TerminalTab(
            title: "Restored",
            pane: TerminalPaneDescriptor(
                id: paneID,
                cwd: "/tmp/restored",
                startupCommand: .custom("printf should-not-run")
            )
        )
        let workspace = Workspace(name: "Restored", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let tokens = CoordinatorAgentTokenSequence([
            Array(repeating: 0x44, count: 32),
            Array(repeating: 0x55, count: 32),
        ])
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-test/agent.sock",
            helperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty",
            controlSocketPath: "/tmp/quicktty-test/control.sock",
            tokenGenerator: tokens.next,
            onAction: { _ in false }
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: paneID)
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()

        #expect(controller.environment(for: paneID) == nil)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root.leaves == [paneID])

        coordinator.retryUnavailablePaneForTesting(paneID)

        let environment = try #require(
            bridge.surfaceConfigurationForTesting(id: paneID)?.environment
        )
        #expect(environment["QUICKTTY_PANE_ID"] == paneID.rawValue.uuidString)
        #expect(environment["QUICKTTY_PANE_TOKEN"] == String(repeating: "55", count: 32))
        #expect(environment["QUICKTTY_CONTROL_SOCKET"] == "/tmp/quicktty-test/control.sock")
        #expect(coordinator.surfaceForTesting(id: paneID)?.paneID == paneID)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: paneID)?.startupCommand
                == .custom("printf should-not-run")
        )
    }

    @Test
    func restoredMultiWorkspaceSurfacesReceiveDistinctAgentEnvironments() throws {
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()
        let firstTab = TerminalTab(
            title: "First",
            pane: TerminalPaneDescriptor(id: firstPaneID, cwd: "/tmp/first")
        )
        let secondTab = TerminalTab(
            title: "Second",
            pane: TerminalPaneDescriptor(id: secondPaneID, cwd: "/tmp/second")
        )
        let firstWorkspace = Workspace(
            name: "First",
            tabs: [firstTab],
            activeTabID: firstTab.id
        )
        let secondWorkspace = Workspace(
            name: "Second",
            tabs: [secondTab],
            activeTabID: secondTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: secondWorkspace.id
        )
        let instanceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let controller = try AgentSessionController(
            socketPath: "/tmp/quicktty-test/agent.sock",
            helperPath: "/Applications/QuickTTY.app/Contents/Helpers/quicktty",
            instanceID: instanceID,
            tokenGenerator: CoordinatorAgentTokenSequence([
                Array(repeating: 0x66, count: 32),
                Array(repeating: 0x77, count: 32),
            ]).next,
            onAction: { _ in false }
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            agentSessionController: controller,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()

        expectAgentEnvironment(
            try #require(
                bridge.surfaceConfigurationForTesting(id: firstPaneID)?.environment
            ),
            paneID: firstPaneID,
            instanceID: instanceID,
            token: String(repeating: "66", count: 32)
        )
        expectAgentEnvironment(
            try #require(
                bridge.surfaceConfigurationForTesting(id: secondPaneID)?.environment
            ),
            paneID: secondPaneID,
            instanceID: instanceID,
            token: String(repeating: "77", count: 32)
        )
        #expect(Set(coordinator.surfaceIDsForTesting) == [firstPaneID, secondPaneID])
    }

    @Test
    func existingCoordinatorWithoutAgentControllerPreservesSurfaceEnvironment() throws {
        let environment = ["CUSTOM": "value", "QUICKTTY_PANE_TOKEN": "caller-owned"]
        var callerEnvironment = environment
        callerEnvironment["QUICKTTY_CONTROL_SOCKET"] = "/tmp/caller.sock"
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                command: "exec /bin/cat",
                environment: callerEnvironment
            )
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()
        let paneID = try #require(coordinator.activeSurfaceForTesting?.paneID)

        #expect(bridge.surfaceConfigurationForTesting(id: paneID)?.environment == environment)
    }

    @Test
    func activePaneProgressRefreshesStatusInPlaceWithoutStructuralSideEffects() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        let fullRefreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let statusRefreshCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        persistence.reset()

        bridge.surfaceProgressHandler?(
            surface.paneID,
            GhosttyProgressReport(state: .set, progress: 42)
        )

        #expect(
            coordinator.terminalActivityStatusesForTesting[surface.paneID]?.phase
                == .working(progress: 42)
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[tab.id]
                == TerminalStatusPresentation(phase: .working, percent: 42)
        )
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == coordinator.workspaceStoreForPersistence)
        #expect(
            coordinator.refreshWorkspacePresentationInvocationCountForTesting == fullRefreshCount)
        #expect(
            coordinator.refreshWorkspaceStatusesInvocationCountForTesting
                == statusRefreshCount + 1
        )
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
    }

    @Test
    func inactiveSplitAndInactiveTabActivityUpdateTheirOwningAggregates() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let splitTab = activeTab(of: coordinator)
        let inactiveSplitPaneID = try #require(
            splitTab.root.leaves.first(where: { $0 != splitTab.activePaneID })
        )

        bridge.surfaceProgressHandler?(
            inactiveSplitPaneID,
            GhosttyProgressReport(state: .set, progress: 30)
        )

        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[splitTab.id]
                == TerminalStatusPresentation(phase: .working, percent: 30)
        )

        coordinator.createNewTab()
        let activeSecondTab = activeTab(of: coordinator)
        bridge.surfaceProgressHandler?(
            inactiveSplitPaneID,
            GhosttyProgressReport(state: .pause, progress: 35)
        )

        let statuses = coordinator.workspaceViewControllerForTesting.tabBarViewController
            .statusesForTesting
        #expect(
            statuses[splitTab.id]
                == TerminalStatusPresentation(phase: .waiting, percent: 35)
        )
        #expect(statuses[activeSecondTab.id] == nil)
    }

    @Test
    func inactiveWorkspaceActivityUpdatesMenuAndSurvivesWorkspaceSelection() throws {
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let activeTab = TerminalTab(
            title: "Active",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp/active")
        )
        let background = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let active = Workspace(name: "Active", tabs: [activeTab], activeTabID: activeTab.id)
        let store = try WorkspaceStore(
            workspaces: [background, active],
            activeWorkspaceID: active.id
        )
        let scheduler = CoordinatorActivityScheduler()
        let activityController = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            terminalActivityController: activityController,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.setActiveWindowIsKeyForTesting(true)
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))

        bridge.surfaceProgressHandler?(
            backgroundPaneID,
            GhosttyProgressReport(state: .indeterminate, progress: nil)
        )

        #expect(
            coordinator.workspaceViewControllerForTesting.workspaceSelector
                .statusesForTesting[background.id]
                == TerminalStatusPresentation(phase: .working, percent: nil)
        )
        bridge.surfaceCommandFinishedHandler?(
            backgroundPaneID,
            GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 1)
        )
        #expect(scheduler.activeRequests.isEmpty)
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(background.id)
        #expect(coordinator.activeSurfaceForTesting === backgroundSurface)
        #expect(scheduler.activeRequests.map(\.delay) == [3])
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[backgroundTab.id]
                == TerminalStatusPresentation(phase: .completed, percent: nil)
        )
    }

    @Test
    func surfaceRemovalAndStaleGenerationCallbacksCannotRestoreActivity() throws {
        let scheduler = CoordinatorActivityScheduler()
        let activityController = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            terminalActivityController: activityController
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        coordinator.setActiveWindowIsKeyForTesting(true)
        let tab = activeTab(of: coordinator)
        let removedPaneID = try #require(tab.root.leaves.first(where: { $0 != tab.activePaneID }))
        let staleProgressHandler = try #require(bridge.surfaceProgressHandler)
        staleProgressHandler(removedPaneID, GhosttyProgressReport(state: .set, progress: 15))
        staleProgressHandler(removedPaneID, GhosttyProgressReport(state: .remove, progress: nil))
        #expect(scheduler.activeRequests.map(\.delay) == [3])

        coordinator.surfaceDidRequestCloseForTesting(id: removedPaneID, processAlive: false)
        #expect(scheduler.activeRequests.isEmpty)
        staleProgressHandler(removedPaneID, GhosttyProgressReport(state: .set, progress: 90))
        scheduler.runActiveRequests()

        #expect(coordinator.terminalActivityStatusesForTesting[removedPaneID] == nil)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[tab.id] == nil
        )
    }

    @Test
    func staleHandlerIsRejectedAfterSameIDRetryReplacement() throws {
        let paneID = PaneID()
        let tab = TerminalTab(
            title: "Retry",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: paneID)
        let coordinator = WindowCoordinator(ghosttyBridge: bridge, initialWorkspaceStore: store)
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let staleProgressHandler = try #require(bridge.surfaceProgressHandler)

        coordinator.retryUnavailablePaneForTesting(paneID)
        staleProgressHandler(paneID, GhosttyProgressReport(state: .set, progress: 60))

        #expect(coordinator.surfaceForTesting(id: paneID) != nil)
        #expect(coordinator.terminalActivityStatusesForTesting[paneID] == nil)
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 70)
        )
        #expect(
            coordinator.terminalActivityStatusesForTesting[paneID]?.phase
                == .working(progress: 70)
        )
    }

    @Test
    func retryWithSamePaneIDClearsOldActivityAndNotificationLifecycle() throws {
        let paneID = PaneID()
        let tab = TerminalTab(
            title: "Retry lifecycle",
            pane: TerminalPaneDescriptor(id: paneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Retry lifecycle", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let activityController = TerminalActivityController(now: { 0 })
        _ = activityController.handleProgress(
            GhosttyProgressReport(state: .set, progress: 40),
            for: paneID
        )
        let waiting = try #require(
            activityController.handleProgress(
                GhosttyProgressReport(state: .pause, progress: 40),
                for: paneID
            ).first
        )
        let destination = TerminalDestination(
            workspaceID: workspace.id,
            tabID: tab.id,
            paneID: paneID
        )
        let notificationClient = CoordinatorNotificationClient(status: .authorized)
        var activations: [TerminalDestination] = []
        let notificationController = TerminalNotificationController(
            client: notificationClient,
            desktopNotificationsEnabled: { true },
            destinationProvider: { $0 == paneID ? destination : nil },
            isCurrentEffect: { effectMatchesStatus($0, in: activityController) },
            isSuppressed: { _ in false },
            activateDestination: { activations.append($0) }
        )
        notificationController.handle(waiting)
        let oldRequest = try #require(notificationClient.addedRequests.first)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: paneID)
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            terminalActivityController: activityController,
            terminalNotificationController: notificationController,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        #expect(notificationController.destinationMappingCountForTesting == 1)

        coordinator.retryUnavailablePaneForTesting(paneID)
        notificationController.handleDefaultResponse(
            identifier: oldRequest.identifier,
            userInfo: oldRequest.userInfo
        )

        #expect(coordinator.surfaceForTesting(id: paneID) != nil)
        #expect(coordinator.terminalActivityStatusesForTesting[paneID] == nil)
        #expect(notificationController.trackedNotificationCountForTesting == 0)
        #expect(activations.isEmpty)
    }

    @Test
    func modelOnlySplitCollapseClearsOldActivityAndNotificationLifecycle() throws {
        let livePaneID = PaneID()
        let unavailablePaneID = PaneID()
        let tab = try TerminalTab(
            title: "Collapse lifecycle",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(livePaneID),
                second: .pane(unavailablePaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: livePaneID, cwd: "/tmp"),
                TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp"),
            ],
            activePaneID: unavailablePaneID
        )
        let workspace = Workspace(name: "Collapse lifecycle", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(workspaces: [workspace], activeWorkspaceID: workspace.id)
        let activityController = TerminalActivityController(now: { 0 })
        _ = activityController.handleProgress(
            GhosttyProgressReport(state: .set, progress: 70),
            for: unavailablePaneID
        )
        let waiting = try #require(
            activityController.handleProgress(
                GhosttyProgressReport(state: .pause, progress: 70),
                for: unavailablePaneID
            ).first
        )
        let destination = TerminalDestination(
            workspaceID: workspace.id,
            tabID: tab.id,
            paneID: unavailablePaneID
        )
        let notificationClient = CoordinatorNotificationClient(status: .authorized)
        let notificationController = TerminalNotificationController(
            client: notificationClient,
            desktopNotificationsEnabled: { true },
            destinationProvider: { $0 == unavailablePaneID ? destination : nil },
            isCurrentEffect: { effectMatchesStatus($0, in: activityController) },
            isSuppressed: { _ in false },
            activateDestination: { _ in }
        )
        notificationController.handle(waiting)
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            terminalActivityController: activityController,
            terminalNotificationController: notificationController,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let refreshCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == .pane(livePaneID))
        #expect(coordinator.terminalActivityStatusesForTesting[unavailablePaneID] == nil)
        #expect(notificationController.trackedNotificationCountForTesting == 0)
        #expect(
            coordinator.refreshWorkspaceStatusesInvocationCountForTesting > refreshCount
        )
    }

    @Test
    func activityConfigurationReloadIsTransactionalAndNotificationsDoNotHideBadges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-Activity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let enabledURL = directory.appending(path: "enabled")
        let disabledURL = directory.appending(path: "disabled")
        let reenabledURL = directory.appending(path: "reenabled")
        let invalidURL = directory.appending(path: "invalid")
        try Data("progress-style = true\ndesktop-notifications = true\n".utf8).write(
            to: enabledURL)
        try Data("progress-style = false\ndesktop-notifications = true\n".utf8).write(
            to: disabledURL)
        try Data("progress-style = true\ndesktop-notifications = false\n".utf8).write(
            to: reenabledURL)
        try Data("progress-style = false\nnot-a-ghostty-option = true\n".utf8).write(
            to: invalidURL)
        let bridge = try GhosttyBridge(configURL: enabledURL)
        defer { bridge.shutdown() }
        let notificationClient = CoordinatorNotificationClient(status: nil)
        weak var coordinatorReference: WindowCoordinator?
        let notificationController = TerminalNotificationController(
            client: notificationClient,
            desktopNotificationsEnabled: {
                coordinatorReference?.terminalActivityConfiguration
                    .desktopNotificationsEnabled == true
            },
            destinationProvider: { coordinatorReference?.terminalDestination(for: $0) },
            isCurrentEffect: {
                coordinatorReference?.isCurrentTerminalActivityEffect($0) == true
            },
            isSuppressed: { _ in false },
            activateDestination: { _ in }
        )
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            terminalNotificationController: notificationController
        )
        coordinatorReference = coordinator
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        var effects: [TerminalActivityEffect] = []
        coordinator.terminalActivityEffectHandler = { effects.append($0) }
        try coordinator.start()
        coordinator.setActiveWindowIsKeyForTesting(false)
        let paneID = try #require(coordinator.activeSurfaceForTesting?.paneID)
        let tab = activeTab(of: coordinator)
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 20)
        )
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .pause, progress: 20)
        )
        #expect(notificationController.trackedNotificationCountForTesting == 1)
        coordinator.setActiveWindowIsKeyForTesting(true)
        #expect(notificationController.trackedNotificationCountForTesting == 0)
        coordinator.setActiveWindowIsKeyForTesting(false)
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 20)
        )
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .pause, progress: 20)
        )
        #expect(notificationController.trackedNotificationCountForTesting == 1)

        try bridge.reloadConfig(at: disabledURL)
        coordinator.applyConfiguration(QuickTTYConfig())
        #expect(coordinator.terminalActivityStatusesForTesting.isEmpty)
        #expect(notificationController.trackedNotificationCountForTesting == 0)
        notificationClient.resolveAuthorizationStatus(.authorized)
        #expect(notificationClient.addedRequests.isEmpty)
        effects.removeAll()
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 40)
        )
        #expect(coordinator.terminalActivityStatusesForTesting.isEmpty)

        try bridge.reloadConfig(at: reenabledURL)
        coordinator.applyConfiguration(QuickTTYConfig())
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 55)
        )
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .pause, progress: 55)
        )
        #expect(
            coordinator.terminalActivityConfigurationForTesting
                == GhosttyActivityConfiguration(
                    progressStyleEnabled: true,
                    desktopNotificationsEnabled: false
                )
        )
        #expect(effects == [.waiting(paneID: paneID)])
        #expect(notificationClient.addedRequests.isEmpty)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[tab.id]
                == TerminalStatusPresentation(phase: .waiting, percent: 55)
        )

        #expect(throws: GhosttyBridgeError.self) {
            try bridge.reloadConfig(at: invalidURL)
        }
        #expect(
            coordinator.terminalActivityStatusesForTesting[paneID]?.phase == .waiting(progress: 55))
        #expect(coordinator.terminalActivityConfigurationForTesting == bridge.activityConfiguration)
    }

    @Test
    func terminalAcknowledgementUsesSelectedTabAndModeAwareKeyWindow() throws {
        let scheduler = CoordinatorActivityScheduler()
        let activityController = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            terminalActivityController: activityController
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let tab = activeTab(of: coordinator)
        let inactivePaneID = try #require(tab.root.leaves.first(where: { $0 != tab.activePaneID }))
        coordinator.setActiveWindowIsKeyForTesting(false)
        bridge.surfaceProgressHandler?(
            inactivePaneID,
            GhosttyProgressReport(state: .set, progress: 100)
        )
        bridge.surfaceProgressHandler?(
            inactivePaneID,
            GhosttyProgressReport(state: .remove, progress: nil)
        )
        #expect(scheduler.activeRequests.isEmpty)

        coordinator.setActiveWindowIsKeyForTesting(true)
        #expect(scheduler.activeRequests.map(\.delay) == [3])
        let statusRefreshCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting
        scheduler.runActiveRequests()

        #expect(coordinator.terminalActivityStatusesForTesting[inactivePaneID] == nil)
        #expect(
            coordinator.refreshWorkspaceStatusesInvocationCountForTesting
                == statusRefreshCount + 1
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .statusesForTesting[tab.id] == nil
        )

        bridge.surfaceProgressHandler?(
            tab.activePaneID,
            GhosttyProgressReport(state: .set, progress: 100)
        )
        bridge.surfaceProgressHandler?(
            tab.activePaneID,
            GhosttyProgressReport(state: .remove, progress: nil)
        )
        #expect(scheduler.activeRequests.map(\.delay) == [3])
    }

    @Test
    func activityShutdownClearsStateAndDisconnectsBridgeCallbacks() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(ghosttyBridge: bridge)
        try coordinator.start()
        let paneID = try #require(coordinator.activeSurfaceForTesting?.paneID)
        bridge.surfaceProgressHandler?(
            paneID,
            GhosttyProgressReport(state: .set, progress: 25)
        )
        #expect(!coordinator.terminalActivityStatusesForTesting.isEmpty)

        coordinator.prepareForBridgeShutdownForTesting()

        #expect(coordinator.terminalActivityStatusesForTesting.isEmpty)
        #expect(bridge.surfaceProgressHandler == nil)
        #expect(bridge.surfaceCommandFinishedHandler == nil)
        #expect(bridge.surfaceProcessExitedHandler == nil)
    }

    @Test
    func selectingBackgroundTabAcknowledgesItsTerminalStatus() throws {
        let scheduler = CoordinatorActivityScheduler()
        let activityController = TerminalActivityController(
            now: { 0 },
            scheduleCleanup: scheduler.schedule
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            terminalActivityController: activityController
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundTab = activeTab(of: coordinator)
        let backgroundPaneID = backgroundTab.activePaneID
        coordinator.createNewTab()
        let foregroundTab = activeTab(of: coordinator)
        coordinator.setActiveWindowIsKeyForTesting(true)
        bridge.surfaceProgressHandler?(
            backgroundPaneID,
            GhosttyProgressReport(state: .set, progress: 100)
        )
        bridge.surfaceCommandFinishedHandler?(
            backgroundPaneID,
            GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 1)
        )
        #expect(scheduler.activeRequests.isEmpty)

        coordinator.activateTabForTesting(backgroundTab.id)
        #expect(scheduler.activeRequests.map(\.delay) == [3])

        coordinator.activateTabForTesting(foregroundTab.id)
        #expect(scheduler.activeRequests.isEmpty)
        scheduler.runActiveRequests()
        #expect(coordinator.terminalActivityStatusesForTesting[backgroundPaneID] != nil)

        coordinator.activateTabForTesting(backgroundTab.id)
        #expect(scheduler.activeRequests.map(\.delay) == [3])
    }

    @Test
    func openConfigurationCreatesFocusedEditorTabWithQuotedPathAndLatestEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY Config's \(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config file")
        let editor = "/bin/sh -c 'exec /bin/cat'"
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let existingSurface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDsBeforeOpening = coordinator.surfaceIDsForTesting
        var initialConfig = QuickTTYConfig()
        initialConfig.configEditor = "nano"
        coordinator.applyConfiguration(initialConfig)
        var latestConfig = initialConfig
        latestConfig.configEditor = editor
        coordinator.applyConfiguration(latestConfig)

        try coordinator.openConfiguration(at: configURL)

        let configSurface = try #require(coordinator.activeSurfaceForTesting)
        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let configTab = try #require(workspace.tabs.last)
        let expectedCommand =
            "\(editor) '\(configURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"

        #expect(configSurface !== existingSurface)
        #expect(bridge.activeSurfaceCount == 2)
        #expect(coordinator.surfaceIDsForTesting.count == surfaceIDsBeforeOpening.count + 1)
        #expect(coordinator.surfaceForTesting(id: existingSurface.paneID) === existingSurface)
        #expect(configTab.title == "Config")
        #expect(configTab.activePaneID == configSurface.paneID)
        #expect(
            configTab.paneDescriptor(for: configSurface.paneID)
                == TerminalPaneDescriptor(
                    id: configSurface.paneID,
                    cwd: directory.path,
                    startupCommand: .custom(expectedCommand)
                )
        )
        #expect(bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.context == .newTab)
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.workingDirectory
                == directory.path
        )
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.command
                == expectedCommand
        )
        #expect(!expectedCommand.hasPrefix("exec "))
        #expect(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.initialInput == nil)
        #expect(coordinator.activeWindowForTesting?.firstResponder === configSurface)
    }

    @Test
    func openConfigurationUsesDefaultNanoWithoutExecPrefix() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "config")
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        try coordinator.openConfiguration(at: configURL)

        let configSurface = try #require(coordinator.activeSurfaceForTesting)
        let command = try #require(
            bridge.surfaceConfigurationForTesting(id: configSurface.paneID)?.command
        )
        #expect(command == "nano '\(configURL.path)'")
        #expect(!command.hasPrefix("exec "))
        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        #expect(
            workspace.tabs.last?.paneDescriptor(for: configSurface.paneID)?.startupCommand
                == .custom(command)
        )
    }

    @Test
    func workspacePersistenceReportsTabActivationCloseAndReorderExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()

        let tabs = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )?.tabs
        )
        let firstTabID = tabs[0].id
        let secondTabID = tabs[1].id

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onActivateTab?(firstTabID)
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                [secondTabID, firstTabID],
                secondTabID
            ) == true
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.closeTabImmediatelyForTesting(secondTabID)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func persistedTabReorderKeepsExistingSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let expectedOrder = workspace.tabs.map(\.id).reversed()
        let activeTabID = try #require(workspace.activeTabID)

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                Array(expectedOrder),
                activeTabID
            ) == true
        )

        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: workspace.id)?.tabs.map(\.id)
                == Array(expectedOrder)
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)
        #expect(bridge.activeSurfaceIDs == coordinator.surfaceIDsForTesting)
    }

    @Test
    func tabReorderCommitsOrderAndActivationOnceThenFinishesPresentation() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()

        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let firstTabID = workspace.tabs[0].id
        let secondTabID = workspace.tabs[1].id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        persistence.reset()
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                [secondTabID, firstTabID],
                firstTabID
            ) == true
        )

        let snapshot = try #require(persistence.snapshots.first)
        #expect(persistence.snapshots.count == 1)
        #expect(
            snapshot.workspace(id: workspace.id)?.tabs.map(\.id) == [secondTabID, firstTabID]
        )
        #expect(snapshot.workspace(id: workspace.id)?.activeTabID == firstTabID)
        #expect(tabBar.displayedTabsForTesting.map(\.id) == workspace.tabs.map(\.id))
        #expect(tabBar.activeTabIDForTesting == secondTabID)

        coordinator.workspaceViewControllerForTesting.onFinishReorderTabs?()

        #expect(tabBar.displayedTabsForTesting.map(\.id) == [secondTabID, firstTabID])
        #expect(tabBar.activeTabIDForTesting == firstTabID)
        #expect(persistence.snapshots == [snapshot])
    }

    @Test
    func workspacePersistenceReportsPaneFocusAndProcessExitExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let exitingPaneID = try #require(coordinator.activeSurfaceForTesting?.paneID)

        persistence.reset()
        coordinator.focusNextPane()
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.surfaceDidRequestCloseForTesting(id: exitingPaneID, processAlive: false)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsSplitResizeAndEqualizeExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        guard case .split(let splitID, _, _, _, _) = activeTab(of: coordinator).root else {
            Issue.record("Expected a split")
            return
        }

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: splitID,
            ratio: 0.8
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeEqualizeForTesting(splitID: splitID)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsWorkspaceActivationExactlyOnce() throws {
        let firstWorkspace = Workspace(name: "First")
        let secondWorkspace = Workspace(name: "Second")
        let store = try WorkspaceStore(
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: firstWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(secondWorkspace.id)
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspaceSelectorActualMenuItemSwitchesLiveWorkspaceWithoutReplacingSurfaces() throws {
        let defaultPaneID = PaneID()
        let testPaneID = PaneID()
        let defaultTab = TerminalTab(
            title: "Default tab",
            pane: TerminalPaneDescriptor(id: defaultPaneID, cwd: "/tmp/default")
        )
        let testTab = TerminalTab(
            title: "Test tab",
            pane: TerminalPaneDescriptor(id: testPaneID, cwd: "/tmp/test")
        )
        let defaultWorkspace = Workspace(
            name: "Default",
            tabs: [defaultTab],
            activeTabID: defaultTab.id
        )
        let testWorkspace = Workspace(
            name: "Test",
            tabs: [testTab],
            activeTabID: testTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [defaultWorkspace, testWorkspace],
            activeWorkspaceID: testWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let defaultSurface = try #require(coordinator.surfaceForTesting(id: defaultPaneID))
        let testSurface = try #require(coordinator.surfaceForTesting(id: testPaneID))
        let registeredSurfaceIdentities = [
            defaultPaneID: ObjectIdentifier(defaultSurface),
            testPaneID: ObjectIdentifier(testSurface),
        ]

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(defaultWorkspace.id)

        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == defaultWorkspace.id)
        #expect(coordinator.activeSurfaceForTesting === defaultSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === defaultSurface)
        #expect(Set(coordinator.surfaceIDsForTesting) == [defaultPaneID, testPaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [defaultPaneID, testPaneID])
        #expect(
            coordinator.surfaceForTesting(id: defaultPaneID).map(ObjectIdentifier.init)
                == registeredSurfaceIdentities[defaultPaneID])
        #expect(
            coordinator.surfaceForTesting(id: testPaneID).map(ObjectIdentifier.init)
                == registeredSurfaceIdentities[testPaneID])
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [defaultPaneID: ObjectIdentifier(defaultSurface)])
        #expect(
            coordinator.workspaceViewControllerForTesting.workspaceSelector.buttonTitleForTesting
                == "Default")
        #expect(
            coordinator.workspaceViewControllerForTesting.workspaceSelector.selectedWorkspaceID
                == defaultWorkspace.id)
    }

    @Test
    func quakeWorkspaceMenuTrackingDoesNotRecreateSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let selector = coordinator.workspaceViewControllerForTesting.workspaceSelector

        selector.onMenuTrackingChanged?(true)

        #expect(coordinator.isWorkspaceMenuTrackingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)

        selector.onMenuTrackingChanged?(false)

        #expect(!coordinator.isWorkspaceMenuTrackingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)

        selector.onMenuTrackingChanged?(true)
        coordinator.prepareForBridgeShutdownForTesting()
        #expect(!coordinator.isWorkspaceMenuTrackingForTesting)
    }

    @Test
    func activateWorkspaceUsesOneBasedIndicesAndIgnoresSameAndOutOfRangeValues() throws {
        let defaultPaneID = PaneID()
        let testPaneID = PaneID()
        let defaultTab = TerminalTab(
            title: "Default tab",
            pane: TerminalPaneDescriptor(id: defaultPaneID, cwd: "/tmp/default")
        )
        let testTab = TerminalTab(
            title: "Test tab",
            pane: TerminalPaneDescriptor(id: testPaneID, cwd: "/tmp/test")
        )
        let defaultWorkspace = Workspace(
            name: "Default",
            tabs: [defaultTab],
            activeTabID: defaultTab.id
        )
        let testWorkspace = Workspace(
            name: "Test",
            tabs: [testTab],
            activeTabID: testTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [defaultWorkspace, testWorkspace],
            activeWorkspaceID: testWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let defaultSurface = try #require(coordinator.surfaceForTesting(id: defaultPaneID))
        let testSurface = try #require(coordinator.surfaceForTesting(id: testPaneID))
        let surfaceIDs = coordinator.surfaceIDsForTesting

        persistence.reset()
        coordinator.activateWorkspace(at: 1)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.activeSurfaceForTesting === defaultSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === defaultSurface)

        persistence.reset()
        coordinator.activateWorkspace(at: 2)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.activeSurfaceForTesting === testSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === testSurface)

        persistence.reset()
        coordinator.activateWorkspace(at: 2)
        coordinator.activateWorkspace(at: 9)
        coordinator.activateWorkspace(at: 0)
        coordinator.activateWorkspace(at: 10)
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.activeSurfaceForTesting === testSurface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(Set(bridge.activeSurfaceIDs) == Set(surfaceIDs))
    }

    @Test
    func notificationActivationSelectsExactInactiveWorkspaceTabAndPaneWithoutRecreatingSurfaces()
        throws
    {
        let visiblePaneID = PaneID()
        let inactiveTabPaneID = PaneID()
        let targetFirstPaneID = PaneID()
        let targetPaneID = PaneID()
        let targetTab = try TerminalTab(
            title: "Target",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(targetFirstPaneID),
                second: .pane(targetPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: targetFirstPaneID, cwd: "/tmp/target-first"),
                TerminalPaneDescriptor(id: targetPaneID, cwd: "/tmp/target"),
            ],
            activePaneID: targetFirstPaneID
        )
        let inactiveTab = TerminalTab(
            title: "Inactive selected",
            pane: TerminalPaneDescriptor(id: inactiveTabPaneID, cwd: "/tmp/inactive-tab")
        )
        let targetWorkspace = Workspace(
            name: "Target workspace",
            tabs: [targetTab, inactiveTab],
            activeTabID: inactiveTab.id
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp/visible")
        )
        let visibleWorkspace = Workspace(
            name: "Visible workspace",
            tabs: [visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [targetWorkspace, visibleWorkspace],
            activeWorkspaceID: visibleWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surfaces = Dictionary(
            uniqueKeysWithValues: coordinator.surfaceIDsForTesting.compactMap { paneID in
                coordinator.surfaceForTesting(id: paneID).map { (paneID, $0) }
            }
        )
        let surfaceIdentities = surfaces.mapValues(ObjectIdentifier.init)
        let processStates = surfaces.mapValues(\.processExitedForTesting)
        let activeSurfaceCount = bridge.activeSurfaceCount
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let callbackContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        persistence.reset()

        coordinator.activate(
            destination: TerminalDestination(
                workspaceID: targetWorkspace.id,
                tabID: targetTab.id,
                paneID: targetPaneID
            )
        )

        let resultingStore = coordinator.workspaceStoreForTesting
        #expect(resultingStore.activeWorkspaceID == targetWorkspace.id)
        #expect(resultingStore.workspace(id: targetWorkspace.id)?.activeTabID == targetTab.id)
        #expect(resultingStore.tab(id: targetTab.id)?.activePaneID == targetPaneID)
        #expect(coordinator.activeSurfaceForTesting === surfaces[targetPaneID])
        #expect(coordinator.activeWindowForTesting?.firstResponder === surfaces[targetPaneID])
        #expect(persistence.snapshots == [resultingStore])
        #expect(
            coordinator.surfaceIDsForTesting
                == surfaces.keys.sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                })
        #expect(
            Dictionary(
                uniqueKeysWithValues: coordinator.surfaceIDsForTesting.compactMap { paneID in
                    coordinator.surfaceForTesting(id: paneID).map {
                        (paneID, ObjectIdentifier($0))
                    }
                }
            ) == surfaceIdentities
        )
        #expect(surfaces.mapValues(\.processExitedForTesting) == processStates)
        #expect(bridge.activeSurfaceCount == activeSurfaceCount)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == callbackContextCount)

        persistence.reset()
        let storeAfterActivation = coordinator.workspaceStoreForTesting
        coordinator.activate(
            destination: TerminalDestination(
                workspaceID: targetWorkspace.id,
                tabID: targetTab.id,
                paneID: PaneID()
            )
        )
        #expect(coordinator.workspaceStoreForTesting == storeAfterActivation)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func hiddenQuakeNotificationActivationShowsCurrentModeAndFocusesExactPane() throws {
        let visiblePaneID = PaneID()
        let targetPaneID = PaneID()
        let targetTab = TerminalTab(
            title: "Target",
            pane: TerminalPaneDescriptor(id: targetPaneID, cwd: "/tmp/target")
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp/visible")
        )
        let targetWorkspace = Workspace(
            name: "Target",
            tabs: [targetTab],
            activeTabID: targetTab.id
        )
        let visibleWorkspace = Workspace(
            name: "Visible",
            tabs: [visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [targetWorkspace, visibleWorkspace],
            activeWorkspaceID: visibleWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let targetSurface = try #require(coordinator.surfaceForTesting(id: targetPaneID))
        let identities = coordinator.surfaceIDsForTesting.compactMap {
            coordinator.surfaceForTesting(id: $0).map(ObjectIdentifier.init)
        }
        try coordinator.requestQuakeVisibilityForTesting(.hidden)
        #expect(coordinator.quakeVisibilityForTesting == .hidden)

        coordinator.activate(
            destination: TerminalDestination(
                workspaceID: targetWorkspace.id,
                tabID: targetTab.id,
                paneID: targetPaneID
            )
        )

        #expect(coordinator.presentationMode == .quake)
        #expect(coordinator.quakeVisibilityForTesting == .shown)
        #expect(coordinator.activeSurfaceForTesting === targetSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === targetSurface)
        #expect(
            coordinator.surfaceIDsForTesting.compactMap {
                coordinator.surfaceForTesting(id: $0).map(ObjectIdentifier.init)
            } == identities
        )
    }

    @Test
    func notificationSuppressionUsesModeAwareKeyWindowAndExactSelectedWorkspaceAndTab() throws {
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()
        let inactiveTabPaneID = PaneID()
        let inactiveWorkspacePaneID = PaneID()
        let selectedTab = try TerminalTab(
            title: "Selected",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(firstPaneID),
                second: .pane(secondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: firstPaneID, cwd: "/tmp/first"),
                TerminalPaneDescriptor(id: secondPaneID, cwd: "/tmp/second"),
            ],
            activePaneID: firstPaneID
        )
        let inactiveTab = TerminalTab(
            title: "Inactive",
            pane: TerminalPaneDescriptor(id: inactiveTabPaneID, cwd: "/tmp/inactive")
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [selectedTab, inactiveTab],
            activeTabID: selectedTab.id
        )
        let inactiveWorkspaceTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: inactiveWorkspacePaneID, cwd: "/tmp/background")
        )
        let inactiveWorkspace = Workspace(
            name: "Background",
            tabs: [inactiveWorkspaceTab],
            activeTabID: inactiveWorkspaceTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [activeWorkspace, inactiveWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(ghosttyBridge: bridge, initialWorkspaceStore: store)
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.setActiveWindowIsKeyForTesting(true)
        let first = try #require(coordinator.terminalDestination(for: firstPaneID))
        let second = try #require(coordinator.terminalDestination(for: secondPaneID))
        let inactiveTabDestination = try #require(
            coordinator.terminalDestination(for: inactiveTabPaneID)
        )
        let inactiveWorkspaceDestination = try #require(
            coordinator.terminalDestination(for: inactiveWorkspacePaneID)
        )

        #expect(coordinator.shouldSuppressNotification(for: first))
        #expect(coordinator.shouldSuppressNotification(for: second))
        #expect(!coordinator.shouldSuppressNotification(for: inactiveTabDestination))
        #expect(!coordinator.shouldSuppressNotification(for: inactiveWorkspaceDestination))

        coordinator.setActiveWindowIsKeyForTesting(false)
        #expect(!coordinator.shouldSuppressNotification(for: first))
    }

    @Test
    func workspacePersistenceReportsMoveToNewWorkspaceThroughNameSheetExactlyOnce() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id

        persistence.reset()
        coordinator.presentMoveToNewWorkspaceForTesting([tabID])
        let sheet = try #require(coordinator.createWorkspaceControllerForTesting)
        sheet.submitForTesting(name: "Moved")
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceReportsMoveToExistingWorkspaceAndBroadcastExactlyOnce() throws {
        let sourceWorkspace = Workspace(name: "Source")
        let destinationWorkspace = Workspace(name: "Destination")
        let store = try WorkspaceStore(
            workspaces: [sourceWorkspace, destinationWorkspace],
            activeWorkspaceID: sourceWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onMoveToWorkspace?(
            [tabID],
            destinationWorkspace.id
        )
        persistence.expectSingleFinalSnapshot(from: coordinator)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onToggleBroadcast?()
        persistence.expectSingleFinalSnapshot(from: coordinator)
    }

    @Test
    func workspacePersistenceIgnoresNoOpTabWorkspaceAndReorderCallbacks() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()
        let workspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        let activeTabID = try #require(workspace.activeTabID)
        let orderedTabIDs = workspace.tabs.map(\.id)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onActivateTab?(activeTabID)
        coordinator.workspaceViewControllerForTesting.onActivateTab?(TabID())
        coordinator.workspaceViewControllerForTesting.onActivateWorkspace?(
            coordinator.workspaceStoreForTesting.activeWorkspaceID
        )
        coordinator.workspaceViewControllerForTesting.onActivateWorkspace?(WorkspaceID())
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?(
                orderedTabIDs,
                activeTabID
            ) == false
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.onReorderTabs?([activeTabID], activeTabID)
                == false
        )

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceIgnoresSinglePaneFocusAndEquivalentSplitRatio() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.focusNextPane()
        coordinator.focusPane(direction: .left)
        #expect(persistence.snapshots.isEmpty)

        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        guard case .split(let splitID, _, _, _, _) = activeTab(of: coordinator).root else {
            Issue.record("Expected a split")
            return
        }
        persistence.reset()
        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: splitID,
            ratio: 0.5
        )

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceIgnoresInvalidAndFailedTransactionalMutations() throws {
        let sourceWorkspace = Workspace(name: "Source")
        let destinationWorkspace = Workspace(name: "Destination")
        let store = try WorkspaceStore(
            workspaces: [sourceWorkspace, destinationWorkspace],
            activeWorkspaceID: sourceWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onCloseTab?(TabID())
        coordinator.workspaceViewControllerForTesting.onMoveToWorkspace?(
            [TabID()],
            destinationWorkspace.id
        )
        coordinator.failNextSplitMutationForTesting()
        #expect(throws: SplitCoordinatorError.self) {
            try coordinator.splitActivePaneForTesting(axis: .horizontal)
        }
        #expect(throws: WorkspaceError.self) {
            try coordinator.openConfigurationForTesting(
                at: URL(fileURLWithPath: "/tmp/quicktty-config"),
                in: WorkspaceID()
            )
        }

        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func openConfigurationRollsBackStoreAndRegistryForMissingDestinationWorkspace() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        let missingWorkspaceID = WorkspaceID()

        #expect(throws: WorkspaceError.workspaceNotFound(missingWorkspaceID)) {
            try coordinator.openConfigurationForTesting(
                at: URL(fileURLWithPath: "/tmp/quicktty-config"),
                in: missingWorkspaceID
            )
        }

        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(bridge.activeSurfaceIDs == surfaceIDsBeforeFailure)
    }

    @Test
    func openConfigurationRollsBackStoreAndRegistryWhenSurfaceCreationFails() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        bridge.failNextSurfaceCreationForTesting()

        #expect(throws: GhosttyBridgeError.self) {
            try coordinator.openConfiguration(at: URL(fileURLWithPath: "/tmp/quicktty-config"))
        }

        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(bridge.activeSurfaceIDs == surfaceIDsBeforeFailure)
    }

    @Test
    func createsDistinctLiveSurfacesAndSwitchesBetweenThem() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let firstSurface = try #require(coordinator.activeSurfaceForTesting)
            let firstTabID = try #require(
                coordinator.workspaceStoreForTesting.workspace(
                    id: coordinator.workspaceStoreForTesting.activeWorkspaceID
                )?.activeTabID
            )

            coordinator.createNewTab()
            await Task.yield()

            let secondSurface = try #require(coordinator.activeSurfaceForTesting)
            let store = coordinator.workspaceStoreForTesting
            let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
            let secondTabID = try #require(activeWorkspace.activeTabID)
            #expect(firstSurface.paneID != secondSurface.paneID)
            #expect(activeWorkspace.tabs.count == 2)
            #expect(activeWorkspace.tabs.last?.id == secondTabID)
            #expect(bridge.activeSurfaceCount == 2)
            #expect(
                Set(coordinator.surfaceIDsForTesting)
                    == Set([firstSurface.paneID, secondSurface.paneID])
            )
            #expect(secondSurface.isActive)
            #expect(coordinator.activeWindowForTesting?.firstResponder === secondSurface)

            coordinator.activateTabForTesting(firstTabID)
            #expect(coordinator.activeSurfaceForTesting === firstSurface)
            #expect(firstSurface.isActive)
            #expect(secondSurface.isActive)

            coordinator.activateTabForTesting(secondTabID)
            #expect(coordinator.activeSurfaceForTesting === secondSurface)
        }
    }

    @Test
    func commandNumberActivationUsesOneBasedIndexAndIgnoresOutOfRangeIndices() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        coordinator.createNewTab()
        await Task.yield()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.activateTab(at: 1)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstSurface)

        coordinator.activateTab(at: 0)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        coordinator.activateTab(at: 3)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)

        coordinator.activateTab(at: 2)
        #expect(coordinator.activeSurfaceForTesting === secondSurface)
    }

    @Test
    func createNewTabActivatesAndFocusesNewSurfaceInQuakeMode() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.createNewTab()
        await Task.yield()

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(secondSurface.paneID != firstSurface.paneID)
        #expect(secondSurface.isActive)
        #expect(coordinator.activeWindowForTesting?.firstResponder === secondSurface)
    }

    @Test
    func createShellTabRollsBackNewSurfaceWhenDestinationWorkspaceIsMissing() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let storeBeforeFailure = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeFailure = coordinator.surfaceIDsForTesting
        let missingWorkspaceID = WorkspaceID()

        #expect(throws: WorkspaceError.workspaceNotFound(missingWorkspaceID)) {
            try coordinator.createShellTab(in: missingWorkspaceID)
        }

        #expect(bridge.activeSurfaceIDs == [activeSurface.paneID])
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeFailure)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeFailure)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
    }

    @Test
    func processExitCleansOnlyExitedTabWhenAnotherSurfaceIsLive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let firstSurface = try #require(coordinator.activeSurfaceForTesting)
            coordinator.createNewTab()
            let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            let store = coordinator.workspaceStoreForTesting
            let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
            #expect(bridge.activeSurfaceIDs == [firstSurface.paneID])
            #expect(coordinator.surfaceIDsForTesting == [firstSurface.paneID])
            #expect(activeWorkspace.tabs.count == 1)
            #expect(activeWorkspace.tabs[0].activePaneID == firstSurface.paneID)
            #expect(coordinator.activeSurfaceForTesting === firstSurface)
        }
    }

    @Test
    func configurableClosePaneUsesLiveConfirmationAndFinalPaneReplacement() throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        var confirmationCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                confirmationCount += 1
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let closedSurface = try #require(coordinator.activeSurfaceForTesting)

        coordinator.requestCloseActivePane()

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let activeWorkspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )
        #expect(confirmationCount == 1)
        #expect(replacement.paneID != closedSurface.paneID)
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(activeWorkspace.tabs.count == 1)
        #expect(activeWorkspace.tabs[0].activePaneID == replacement.paneID)
    }

    @Test
    func configurableClosePaneClosesUnavailablePaneInModelOnly() throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Unavailable", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()

        coordinator.requestCloseActivePane()

        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
    }

    @Test
    func configurableCloseTabUsesActiveTabPaneChecksAndReplacement() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let closedPaneIDs = coordinator.surfaceIDsForTesting

        #expect(coordinator.canCloseActiveTab)
        coordinator.requestCloseActiveTab()

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        #expect(closedPaneIDs.allSatisfy { !bridge.activeSurfaceIDs.contains($0) })
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(coordinator.workspaceStoreForTesting.workspaces.flatMap(\.tabs).count == 1)
    }

    @Test
    func explicitConfirmedFinalTabCloseIsIdempotentAndCreatesOneReplacement() throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        var confirmationCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: { _, completion in
                confirmationCount += 1
                completion(.allow)
                return nil
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )?.activeTabID
        )

        coordinator.requestCloseTabForTesting(tabID)
        coordinator.requestCloseTabForTesting(tabID)
        coordinator.surfaceDidRequestCloseForTesting(id: surface.paneID, processAlive: true)

        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let activeWorkspace = try #require(
            coordinator.workspaceStoreForTesting.workspace(
                id: coordinator.workspaceStoreForTesting.activeWorkspaceID
            )
        )

        #expect(confirmationCount == 1)
        #expect(bridge.activeSurfaceIDs == [replacement.paneID])
        #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
        #expect(activeWorkspace.tabs.count == 1)
        #expect(activeWorkspace.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != surface.paneID)
        #expect(window.firstResponder === replacement)
        #expect(window.isVisible)
        #expect(coordinator.windowForTesting === window)
        #expect(window.delegate === coordinator)
    }

    @Test
    func closingLastTabCreatesReplacementInItsOwnerWorkspaceWithoutChangingOtherSurfaces() throws {
        let backgroundPaneID = PaneID()
        let ownerPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let ownerTab = TerminalTab(
            title: "Owner",
            pane: TerminalPaneDescriptor(id: ownerPaneID, cwd: "/tmp/owner")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let ownerWorkspace = Workspace(
            name: "Owner",
            tabs: [ownerTab],
            activeTabID: ownerTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [backgroundWorkspace, ownerWorkspace],
            activeWorkspaceID: ownerWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        let closedSurface = try #require(coordinator.surfaceForTesting(id: ownerPaneID))
        let window = try #require(coordinator.activeWindowForTesting)

        persistence.reset()
        coordinator.closeTabImmediatelyForTesting(ownerTab.id)

        let store = coordinator.workspaceStoreForTesting
        let owner = try #require(store.workspace(id: ownerWorkspace.id))
        let replacement = try #require(coordinator.activeSurfaceForTesting)
        #expect(persistence.snapshots == [store])
        #expect(owner.tabs.count == 1)
        #expect(owner.activeTabID == owner.tabs[0].id)
        #expect(owner.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != closedSurface.paneID)
        #expect(coordinator.surfaceForTesting(id: backgroundPaneID) === backgroundSurface)
        #expect(bridge.activeSurfaceIDs.contains(backgroundPaneID))
        #expect(window.firstResponder === replacement)

        let restartBridge = try GhosttyBridge()
        defer { restartBridge.shutdown() }
        let restarted = WindowCoordinator(
            ghosttyBridge: restartBridge,
            initialWorkspaceStore: try #require(persistence.snapshots.first)
        )
        defer { restarted.prepareForBridgeShutdownForTesting() }
        try restarted.start()
        #expect(
            restarted.workspaceStoreForTesting.workspace(id: ownerWorkspace.id)?.tabs.count == 1)
        #expect(restartBridge.activeSurfaceIDs.contains(replacement.paneID))
    }

    @Test
    func finalProcessExitCreatesOneReplacementAndIgnoresLateDuplicateClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let persistence = WorkspacePersistenceRecorder()
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
                persistWorkspaceStore: { persistence.snapshots.append($0) }
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }
            try coordinator.start()
            let window = try #require(coordinator.windowForTesting)
            let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

            persistence.reset()
            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            let replacement = try #require(coordinator.activeSurfaceForTesting)
            #expect(persistence.snapshots.count == 1)
            let snapshot = try #require(persistence.snapshots.first)
            #expect(replacement.paneID != exitedSurface.paneID)
            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
            #expect(!bridge.activeSurfaceIDs.contains(exitedSurface.paneID))
            #expect(
                snapshot.workspaces.flatMap(\.tabs).flatMap(\.root.leaves)
                    == [replacement.paneID]
            )
            #expect(!snapshot.workspaces.flatMap(\.tabs).isEmpty)
            #expect(
                coordinator.workspaceStoreForTesting.workspaces.flatMap(\.tabs).map(\.activePaneID)
                    == [replacement.paneID]
            )
            #expect(window.firstResponder === replacement)

            exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
            await Task.yield()

            #expect(persistence.snapshots == [snapshot])
            #expect(bridge.activeSurfaceIDs == [replacement.paneID])
            #expect(coordinator.surfaceIDsForTesting == [replacement.paneID])
        }
    }

    @Test
    func finalProcessExitReportsReplacementCreationFailureWithoutClosingCoordinator() async throws {
        let initialSurfaceContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

        persistence.reset()
        bridge.failNextSurfaceCreationForTesting()
        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        let snapshot = try #require(persistence.snapshots.first)
        #expect(!exitedSurface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(snapshot.workspaces.allSatisfy { $0.tabs.isEmpty })
        #expect(coordinator.workspaceStoreForTesting == snapshot)
        #expect(errors.count == 1)
        let error = try #require(errors.first as? GhosttyBridgeError)
        guard case .surfaceCreationFailed(let failedPaneID) = error else {
            Issue.record("Expected a surface creation failure, got \(error)")
            return
        }
        #expect(failedPaneID != exitedSurface.paneID)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount
        )

        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        #expect(errors.count == 1)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == snapshot)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount
        )
        #expect(window.isVisible)
        #expect(coordinator.windowForTesting === window)
        #expect(window.delegate === coordinator)
    }

    @Test
    func paneExitDisablesBroadcastingAndLeavesSiblingLive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let exitingSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let siblingSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.setActiveTabBroadcastingForTesting(true)

        exitingSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let activeWorkspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let activeTabID = try #require(activeWorkspace.activeTabID)
        let activeTab = try #require(store.tab(id: activeTabID))
        #expect(!activeTab.isBroadcasting)
        #expect(activeTab.root.leaves == [siblingSurface.paneID])
        #expect(bridge.activeSurfaceIDs == [siblingSurface.paneID])
    }

    @Test
    func splitActivePaneCreatesNestedLiveSurfacesWithInheritedShellContext() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp",
                command: "exec /bin/cat",
                initialInput: "echo should-not-run\n"
            )
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        try coordinator.splitActivePaneForTesting(axis: .horizontal)

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let firstSplit = try #require(split(in: activeTab(of: coordinator).root))
        #expect(firstSplit.axis == .horizontal)
        #expect(firstSplit.first == .pane(firstSurface.paneID))
        #expect(firstSplit.second == .pane(secondSurface.paneID))
        #expect(activeTab(of: coordinator).activePaneID == secondSurface.paneID)
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: secondSurface.paneID)
                == TerminalPaneDescriptor(
                    id: secondSurface.paneID,
                    cwd: "/tmp",
                    startupCommand: .shell
                ))
        #expect(bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.context == .split)
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.workingDirectory
                == "/tmp")
        #expect(bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.command == nil)
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.initialInput == nil)

        try coordinator.splitActivePaneForTesting(axis: .vertical)

        let thirdSurface = try #require(coordinator.activeSurfaceForTesting)
        let nestedRoot = activeTab(of: coordinator).root
        guard
            case .split(_, .horizontal, 0.5, .pane(let firstPaneID), let secondBranch) = nestedRoot,
            case .split(_, .vertical, 0.5, .pane(let secondPaneID), .pane(let thirdPaneID)) =
                secondBranch
        else {
            Issue.record("Expected a horizontal split with a nested vertical split")
            return
        }
        #expect(firstPaneID == firstSurface.paneID)
        #expect(secondPaneID == secondSurface.paneID)
        #expect(thirdPaneID == thirdSurface.paneID)
        #expect(activeTab(of: coordinator).activePaneID == thirdSurface.paneID)
        #expect(Set(coordinator.surfaceIDsForTesting) == Set(nestedRoot.leaves))
        #expect(bridge.activeSurfaceCount == 3)
    }

    @Test
    func applicationTerminationDetachesNestedLiveSurfacesBeforeRuntimeShutdown() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let thirdSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let storeBeforeTermination = coordinator.workspaceStoreForTesting
        let surfaceIDs = Set([firstSurface.paneID, secondSurface.paneID, thirdSurface.paneID])

        #expect(window.firstResponder === thirdSurface)
        #expect(
            Set(
                coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                    .keys
            ) == surfaceIDs
        )
        #expect(
            Set(coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting)
                == Set([
                    ObjectIdentifier(firstSurface), ObjectIdentifier(secondSurface),
                    ObjectIdentifier(thirdSurface),
                ])
        )

        coordinator.prepareForApplicationTermination()

        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        #expect(window.firstResponder === window)
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                == nil
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting.isEmpty
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                .isEmpty
        )
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeTermination)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(Set(closeObservations) == surfaceIDs)
        #expect(closeObservations.count == surfaceIDs.count)

        coordinator.prepareForApplicationTermination()

        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)

        bridge.shutdown()

        #expect(!bridge.isReady)
    }

    @Test
    func splitActivePaneUsesLiveWorkingDirectoryInsteadOfStartupDescriptor() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup",
                command: "exec /bin/cat"
            )
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)

        #expect(firstSurface.currentWorkingDirectory == "/tmp/startup")
        #expect(firstSurface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        await Task.yield()

        try coordinator.splitActivePaneForTesting(axis: .horizontal)

        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let descriptor = try #require(
            activeTab(of: coordinator).paneDescriptor(for: secondSurface.paneID)
        )
        #expect(descriptor.cwd == "/tmp/live")
        #expect(secondSurface.currentWorkingDirectory == "/tmp/live")
        #expect(
            bridge.surfaceConfigurationForTesting(id: secondSurface.paneID)?.workingDirectory
                == "/tmp/live"
        )
    }

    @Test
    func workspacePersistenceSnapshotOverlaysPendingWorkingDirectoryWithoutDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup",
                command: "exec /bin/cat"
            ),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)

        persistence.reset()
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/immediate"))

        let pendingSnapshot = coordinator.workspaceStoreForPersistence
        let pendingDescriptor = try #require(
            pendingSnapshot.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)
        )
        #expect(pendingDescriptor.cwd == "/tmp/immediate")
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: surface.paneID)?.cwd == "/tmp/startup"
        )
        #expect(persistence.snapshots.isEmpty)

        let finalState = AppDelegate.applicationState(
            ApplicationState(workspaceStore: coordinator.workspaceStoreForTesting),
            merging: pendingSnapshot,
            normalWindowFrame: nil
        )
        #expect(
            finalState.workspaceStore.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)?.cwd
                == "/tmp/immediate"
        )

        coordinator.prepareForApplicationTermination()
        await Task.yield()

        #expect(
            finalState.workspaceStore.tab(id: tab.id)?.paneDescriptor(for: surface.paneID)?.cwd
                == "/tmp/immediate"
        )
        #expect(
            activeTab(of: coordinator).paneDescriptor(for: surface.paneID)?.cwd == "/tmp/startup"
        )
        #expect(persistence.snapshots.isEmpty)
    }

    @Test
    func workspacePersistenceTracksLiveCWDForActiveBackgroundAndStalePanes() throws {
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(
                id: backgroundPaneID,
                cwd: "/tmp/background-start",
                startupCommand: .custom("printf background")
            )
        )
        let activeTab = TerminalTab(
            title: "Active",
            pane: TerminalPaneDescriptor(
                id: activePaneID,
                cwd: "/tmp/active-start",
                startupCommand: .custom("printf active")
            )
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }

        try coordinator.start()
        let workingDirectoryHandler = try #require(bridge.surfaceWorkingDirectoryHandler)
        bridge.surfaceWorkingDirectoryHandler = nil

        #expect(persistence.snapshots.isEmpty)
        _ = try #require(coordinator.surfaceForTesting(id: activePaneID))
        _ = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        workingDirectoryHandler(activePaneID, "/tmp/active-live")

        let activeDescriptor = try #require(
            coordinator.workspaceStoreForTesting.tab(id: activeTab.id)?
                .paneDescriptor(for: activePaneID)
        )
        #expect(
            activeDescriptor
                == TerminalPaneDescriptor(
                    id: activePaneID,
                    cwd: "/tmp/active-live",
                    startupCommand: .custom("printf active")
                )
        )
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == backgroundTab.paneDescriptor(for: backgroundPaneID)
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        persistence.reset()

        workingDirectoryHandler(backgroundPaneID, "/tmp/background-live")

        #expect(
            coordinator.workspaceStoreForTesting.tab(id: backgroundTab.id)?
                .paneDescriptor(for: backgroundPaneID)
                == TerminalPaneDescriptor(
                    id: backgroundPaneID,
                    cwd: "/tmp/background-live",
                    startupCommand: .custom("printf background")
                )
        )
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        persistence.reset()

        workingDirectoryHandler(activePaneID, "/tmp/active-live")
        workingDirectoryHandler(activePaneID, "relative")
        workingDirectoryHandler(activePaneID, "")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: activeTab.id)?
                .paneDescriptor(for: activePaneID)
                == activeDescriptor
        )

        coordinator.prepareForBridgeShutdownForTesting()
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        let storeBeforeStaleCallback = coordinator.workspaceStoreForTesting
        workingDirectoryHandler(activePaneID, "/tmp/stale")

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeBeforeStaleCallback)
    }

    @Test
    func automaticTitleRefreshIsEphemeralAndDoesNotRebuildOrRefocusTerminalPresentation()
        async throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)
        let window = try #require(coordinator.activeWindowForTesting)
        let store = coordinator.workspaceStoreForTesting
        let splitHostID = try #require(
            coordinator.workspaceViewControllerForTesting
                .splitHostingControllerIdentifierForTesting
        )
        let hostedSurfaces =
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
        let fullRefreshCount =
            coordinator.refreshWorkspacePresentationInvocationCountForTesting
        let tabReloadGeneration =
            coordinator.workspaceViewControllerForTesting.tabBarViewController
            .dataReloadGenerationForTesting
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("  command 🚀  ".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "  command 🚀  ")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tab.id] == "  command 🚀  "
        )
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == hostedSurfaces
        )
        #expect(
            coordinator.workspaceViewControllerForTesting
                .splitHostingControllerIdentifierForTesting == splitHostID
        )
        #expect(
            coordinator.refreshWorkspacePresentationInvocationCountForTesting
                == fullRefreshCount
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .dataReloadGenerationForTesting == tabReloadGeneration
        )
        #expect(window.firstResponder === surface)
    }

    @Test
    func inactiveSplitTitleStaysHiddenUntilItsPaneBecomesActive() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id

        #expect(
            secondSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("active second".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        #expect(
            firstSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest inactive 💤".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(firstSurface.currentTitle == "latest inactive 💤")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "active second"
        )

        coordinator.focusNextPane()

        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "latest inactive 💤"
        )
    }

    @Test
    func inactiveWorkspaceTitleAppearsFromItsLiveSurfaceAfterWorkspaceActivation() async throws {
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background fallback",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let activeTab = TerminalTab(
            title: "Active fallback",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp/active")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(
            coordinator.surfaceForTesting(id: backgroundPaneID)
        )
        persistence.reset()

        #expect(
            backgroundSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("background live 🌙".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(backgroundSurface.currentTitle == "background live 🌙")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[activeTab.id] == "Active fallback"
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[backgroundTab.id] == nil
        )

        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(backgroundWorkspace.id)

        #expect(coordinator.activeSurfaceForTesting === backgroundSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[backgroundTab.id] == "background live 🌙"
        )
    }

    @Test
    func inlineRenamePersistsExactTextClearsOverrideAndRestoresLiveSurfaceFocus() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let bridgeInputs = bridge.inputObservationsForTesting
        let surfaceInputs = surface.inputObservationsForTesting
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        persistence.reset()
        tabBar.beginRenameForTesting(tabID)
        var item = tabBar.tabItemForTesting(at: 0)
        #expect(
            coordinator.activeWindowForTesting?.firstResponder
                === item.renameEditorForTesting?.currentEditor())
        item.renameEditorForTesting?.stringValue = "  kept whitespace 🧷  "
        item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        #expect(persistence.snapshots.count == 1)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride
                == "  kept whitespace 🧷  "
        )
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.surfaceForTesting(id: surface.paneID) === surface)

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest automatic 🌙".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        persistence.reset()
        tabBar.beginRenameForTesting(tabID)
        item = tabBar.tabItemForTesting(at: 0)
        item.renameEditorForTesting?.stringValue = ""
        item.endRenameEditingForTesting()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == nil)
        #expect(tabBar.displayedTitlesForTesting[tabID] == "latest automatic 🌙")
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(bridge.inputObservationsForTesting == bridgeInputs)
        #expect(surface.inputObservationsForTesting == surfaceInputs)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
    }

    @Test
    func contextMenuRenamePersistsSelectedInactiveTabWithoutChangingActiveTabOrFocus() async throws
    {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        await Task.yield()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let activeTabID = activeTab(of: coordinator).id
        coordinator.createNewTab()
        await Task.yield()
        let inactiveSurface = try #require(coordinator.activeSurfaceForTesting)
        let inactiveTabID = activeTab(of: coordinator).id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        tabBar.beginSelectionForTesting(activeTabID, gesture: .commandClick)
        tabBar.finishSelectionForTesting()
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [activeTabID, inactiveTabID])

        persistence.reset()
        let menu = tabBar.contextMenu(for: inactiveTabID)
        let renameItem = try #require(menu.item(withTitle: "Rename Tab…"))
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)

        #expect(NSApp.sendAction(renameItem.action!, to: renameItem.target, from: renameItem))
        let item = tabBar.tabItemForTesting(at: 1)
        #expect(
            coordinator.activeWindowForTesting?.firstResponder
                === item.renameEditorForTesting?.currentEditor())
        item.renameEditorForTesting?.stringValue = "selected inactive 💤"
        item.invokeRenameCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        #expect(persistence.snapshots.count == 1)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: inactiveTabID)?.titleOverride
                == "selected inactive 💤"
        )
        #expect(activeTab(of: coordinator).id == activeTabID)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)
        #expect(tabBar.selectedTabIDsInOrderForTesting == [activeTabID, inactiveTabID])
        #expect(coordinator.surfaceForTesting(id: inactiveSurface.paneID) === inactiveSurface)
    }

    @Test
    func promptStartsInlineRenameOnlyForCurrentLiveTabAndDoesNotRecreateSurfaces() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        let firstTabID = activeTab(of: coordinator).id
        coordinator.createNewTab()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let secondTabID = activeTab(of: coordinator).id
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let promptHandler = try #require(bridge.surfaceTabTitlePromptHandler)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        promptHandler(firstSurface.paneID)
        #expect(tabBar.editedTabIDForTesting == nil)

        #expect(secondSurface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()

        #expect(tabBar.editedTabIDForTesting == secondTabID)
        #expect(tabBar.tabItemForTesting(at: 1).isRenamingForTesting)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(coordinator.surfaceForTesting(id: firstSurface.paneID) === firstSurface)
        #expect(coordinator.surfaceForTesting(id: secondSurface.paneID) === secondSurface)

        tabBar.cancelRenameForTesting()
        coordinator.activateTabForTesting(firstTabID)
        promptHandler(secondSurface.paneID)
        #expect(tabBar.editedTabIDForTesting == nil)
    }

    @Test
    func closingEditedTabCancelsWithoutApplyingStaleEditorValue() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        coordinator.createNewTab()
        let editedTab = activeTab(of: coordinator)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController
        tabBar.beginRenameForTesting(editedTab.id)
        let editedItem = tabBar.tabItemForTesting(at: 1)
        editedItem.renameEditorForTesting?.stringValue = "must not persist"
        persistence.reset()

        coordinator.closeTabImmediatelyForTesting(editedTab.id)
        editedItem.endRenameEditingForTesting()

        #expect(coordinator.workspaceStoreForTesting.tab(id: editedTab.id) == nil)
        #expect(tabBar.editedTabIDForTesting == nil)
        #expect(
            persistence.snapshots.allSatisfy {
                $0.workspaces.flatMap(\.tabs).allSatisfy { $0.titleOverride != "must not persist" }
            }
        )
    }

    @Test
    func quakeInlineRenameOwnsOneTransientInteractionAndTeardownEndsIt() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: .quake,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let tabID = activeTab(of: coordinator).id
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        tabBar.beginRenameForTesting(tabID)
        tabBar.beginRenameForTesting(tabID)

        #expect(coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 1)

        tabBar.cancelRenameForTesting()
        tabBar.cancelRenameForTesting()

        #expect(!coordinator.isTabRenameEditingForTesting)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)

        tabBar.beginRenameForTesting(tabID)
        #expect(coordinator.quakeTransientInteractionCountForTesting == 1)
        coordinator.prepareForBridgeShutdownForTesting()
        #expect(coordinator.quakeTransientInteractionCountForTesting == 0)
    }

    @Test
    func closedPaneTitleRequestsAndPromptsAreIgnored() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tab = activeTab(of: coordinator)
        let titleHandler = try #require(bridge.surfaceTitleHandler)
        let tabTitleHandler = try #require(bridge.surfaceTabTitleHandler)
        let promptHandler = try #require(bridge.surfaceTabTitlePromptHandler)
        let tabBar = coordinator.workspaceViewControllerForTesting.tabBarViewController

        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()
        #expect(tabBar.editedTabIDForTesting == tab.id)
        tabBar.cancelRenameForTesting()

        coordinator.closeTabImmediatelyForTesting(tab.id)
        let storeAfterClose = coordinator.workspaceStoreForTesting
        let displayedTitlesAfterClose =
            coordinator.workspaceViewControllerForTesting.tabBarViewController
            .displayedTitlesForTesting
        persistence.reset()

        titleHandler(surface.paneID, "stale automatic")
        tabTitleHandler(surface.paneID, "stale override")
        promptHandler(surface.paneID)
        titleHandler(PaneID(), "non-owned automatic")
        tabTitleHandler(PaneID(), "non-owned override")
        promptHandler(PaneID())

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == storeAfterClose)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting == displayedTitlesAfterClose
        )
        #expect(tabBar.editedTabIDForTesting == nil)
    }

    @Test
    func setTabTitlePersistsOverrideWhileAutomaticTitleContinuesUpdatingUnderIt() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let tabID = activeTab(of: coordinator).id

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("initial automatic".utf8)
            )
        )
        await Task.yield()
        await Task.yield()
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("Pinned 🧷".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == "Pinned 🧷")
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "Pinned 🧷"
        )
        persistence.reset()

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("latest automatic 🚦".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "latest automatic 🚦")
        #expect(persistence.snapshots.isEmpty)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "Pinned 🧷"
        )

        #expect(surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: []))
        await Task.yield()
        await Task.yield()

        #expect(persistence.snapshots.count == 1)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tabID)?.titleOverride == nil)
        #expect(
            coordinator.workspaceViewControllerForTesting.tabBarViewController
                .displayedTitlesForTesting[tabID] == "latest automatic 🚦"
        )
    }

    @Test
    func splitActivePaneRollsBackCreatedSurfaceAndStoreWhenCandidateMutationFails() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let store = coordinator.workspaceStoreForTesting

        coordinator.failNextSplitMutationForTesting()
        do {
            try coordinator.splitActivePaneForTesting(axis: .horizontal)
            Issue.record("Expected split mutation failure")
        } catch {}

        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
        #expect(coordinator.workspaceStoreForTesting == store)
    }

    @Test
    func activeTabRenderingUsesOnlyItsExactLiveSurfaceIdentities() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)

        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [
                    firstSurface.paneID: ObjectIdentifier(firstSurface),
                    secondSurface.paneID: ObjectIdentifier(secondSurface),
                ])

        coordinator.createNewTab()
        let tabSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [tabSurface.paneID: ObjectIdentifier(tabSurface)])

        let splitTabID = try #require(
            coordinator.workspaceStoreForTesting.workspaces.first?.tabs.first?.id)
        coordinator.activateTabForTesting(splitTabID)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [
                    firstSurface.paneID: ObjectIdentifier(firstSurface),
                    secondSurface.paneID: ObjectIdentifier(secondSurface),
                ])
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func surfaceFocusCallbackActivatesExistingPaneInEveryPresentationMode(
        mode: PresentationMode
    ) async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: mode,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let firstSurface = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        await Task.yield()
        let secondSurface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)

        #expect(window.firstResponder === secondSurface)
        _ = window.makeFirstResponder(firstSurface)

        #expect(activeTab(of: coordinator).activePaneID == firstSurface.paneID)
        #expect(coordinator.activeSurfaceForTesting === firstSurface)
        #expect(window.firstResponder === firstSurface)
    }

    @Test
    func splitPaneActivationEndsSearchOnlyOnceOnPreviouslyActiveSurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let oldSurface = try #require(coordinator.activeSurfaceForTesting)
        let targetPaneID = try #require(
            activeTab(of: coordinator).root.leaves.first { $0 != oldSurface.paneID }
        )
        let targetSurface = try #require(coordinator.surfaceForTesting(id: targetPaneID))
        let targetEndSearchCount = targetSurface.bindingActionObservationsForTesting.filter {
            $0 == "end_search"
        }.count
        oldSurface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        coordinator.focusNextPane()

        let newSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(newSurface === targetSurface)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
        #expect(
            newSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count
                == targetEndSearchCount
        )
    }

    @Test
    func queuedSearchStartIsEndedWhenActivePaneChangesBeforeDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let oldSurface = try #require(coordinator.activeSurfaceForTesting)

        #expect(oldSurface.scheduleSearchCallbackForTesting(.started(nil)))
        #expect(oldSurface.searchState == nil)
        coordinator.focusNextPane()

        #expect(coordinator.activeSurfaceForTesting !== oldSurface)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
        #expect(oldSurface.scheduleSearchCallbackForTesting(.ended))
        await Task.yield()
        await Task.yield()

        #expect(oldSurface.searchState == nil)
        #expect(!oldSurface.searchOverlayInstalledForTesting)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
    }

    @Test
    func newTabActivationEndsSearchOnlyOnceOnPreviouslyActiveSurface() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let oldSurface = try #require(coordinator.activeSurfaceForTesting)
        oldSurface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        coordinator.createNewTab()

        let newSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(newSurface !== oldSurface)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
        #expect(!newSurface.bindingActionObservationsForTesting.contains("end_search"))
    }

    @Test
    func workspaceActivationEndsSearchOnlyOnceOnPreviouslyActiveSurface() throws {
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()
        let firstTab = TerminalTab(
            title: "First",
            pane: TerminalPaneDescriptor(id: firstPaneID, cwd: "/tmp/first")
        )
        let secondTab = TerminalTab(
            title: "Second",
            pane: TerminalPaneDescriptor(id: secondPaneID, cwd: "/tmp/second")
        )
        let firstWorkspace = Workspace(
            name: "First",
            tabs: [firstTab],
            activeTabID: firstTab.id
        )
        let secondWorkspace = Workspace(
            name: "Second",
            tabs: [secondTab],
            activeTabID: secondTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [firstWorkspace, secondWorkspace],
            activeWorkspaceID: firstWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(ghosttyBridge: bridge, initialWorkspaceStore: store)
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let oldSurface = try #require(coordinator.surfaceForTesting(id: firstPaneID))
        let newSurface = try #require(coordinator.surfaceForTesting(id: secondPaneID))
        oldSurface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .performWorkspaceSelectionForTesting(secondWorkspace.id)

        #expect(coordinator.activeSurfaceForTesting === newSurface)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
        #expect(!newSurface.bindingActionObservationsForTesting.contains("end_search"))
    }

    @Test
    func destinationActivationEndsSearchOnlyOnceOnPreviouslyActiveSurface() throws {
        let sourcePaneID = PaneID()
        let destinationPaneID = PaneID()
        let sourceTab = TerminalTab(
            title: "Source",
            pane: TerminalPaneDescriptor(id: sourcePaneID, cwd: "/tmp/source")
        )
        let destinationTab = TerminalTab(
            title: "Destination",
            pane: TerminalPaneDescriptor(id: destinationPaneID, cwd: "/tmp/destination")
        )
        let sourceWorkspace = Workspace(
            name: "Source",
            tabs: [sourceTab],
            activeTabID: sourceTab.id
        )
        let destinationWorkspace = Workspace(
            name: "Destination",
            tabs: [destinationTab],
            activeTabID: destinationTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [sourceWorkspace, destinationWorkspace],
            activeWorkspaceID: sourceWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(ghosttyBridge: bridge, initialWorkspaceStore: store)
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let oldSurface = try #require(coordinator.surfaceForTesting(id: sourcePaneID))
        let newSurface = try #require(coordinator.surfaceForTesting(id: destinationPaneID))
        oldSurface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        coordinator.activate(
            destination: TerminalDestination(
                workspaceID: destinationWorkspace.id,
                tabID: destinationTab.id,
                paneID: destinationPaneID
            )
        )

        #expect(coordinator.activeSurfaceForTesting === newSurface)
        #expect(
            oldSurface.bindingActionObservationsForTesting.filter { $0 == "end_search" }.count == 1
        )
        #expect(!newSurface.bindingActionObservationsForTesting.contains("end_search"))
    }

    @Test
    func samePaneNoOpAndFailedMutationDoNotEndSearch() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        coordinator.toggleBroadcast()
        coordinator.activateTab(at: 1)
        coordinator.activateWorkspace(at: 1)
        coordinator.failNextSplitMutationForTesting()
        #expect(throws: (any Error).self) {
            try coordinator.splitActivePaneForTesting(axis: .horizontal)
        }

        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(surface.searchState != nil)
        #expect(!surface.bindingActionObservationsForTesting.contains("end_search"))
    }

    @Test
    func paneNavigationMovesThroughNestedLiveSurfacesWithoutRecreatingThem() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let first = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let second = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)

        _ = window.makeFirstResponder(first)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let third = try #require(coordinator.activeSurfaceForTesting)
        _ = window.makeFirstResponder(second)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let fourth = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDs = coordinator.surfaceIDsForTesting

        _ = window.makeFirstResponder(first)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === third)
        #expect(window.firstResponder === third)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === second)
        #expect(window.firstResponder === second)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)
        coordinator.focusNextPane()
        #expect(coordinator.activeSurfaceForTesting === first)
        #expect(window.firstResponder === first)
        coordinator.focusPreviousPane()
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)

        _ = window.makeFirstResponder(first)
        coordinator.focusPane(direction: .right)
        #expect(coordinator.activeSurfaceForTesting === second)
        #expect(window.firstResponder === second)
        coordinator.focusPane(direction: .down)
        #expect(coordinator.activeSurfaceForTesting === fourth)
        #expect(window.firstResponder === fourth)
        coordinator.focusPane(direction: .left)
        #expect(coordinator.activeSurfaceForTesting === third)
        #expect(window.firstResponder === third)
        coordinator.focusPane(direction: .up)
        #expect(coordinator.activeSurfaceForTesting === first)
        #expect(window.firstResponder === first)
        #expect(activeTab(of: coordinator).activePaneID == first.paneID)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
    }

    @Test
    func paneNavigationIsANoOpForASingleLivePane() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let window = try #require(coordinator.activeWindowForTesting)
        let store = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting

        coordinator.focusPreviousPane()
        coordinator.focusNextPane()
        coordinator.focusPane(direction: .left)
        coordinator.focusPane(direction: .right)
        coordinator.focusPane(direction: .up)
        coordinator.focusPane(direction: .down)

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(window.firstResponder === surface)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
    }

    @Test
    func nestedDividerCallbacksUpdateRatiosWithoutRecreatingSurfacesAndEqualizeAll() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        try coordinator.splitActivePaneForTesting(axis: .vertical)
        let surfaceIDs = coordinator.surfaceIDsForTesting

        guard
            case .split(let outerID, _, let outerRatio, _, let second) = activeTab(of: coordinator)
                .root,
            case .split(let nestedID, _, let nestedRatio, _, _) = second
        else {
            Issue.record("Expected nested split tree")
            return
        }
        #expect(outerRatio == 0.5)
        #expect(nestedRatio == 0.5)

        coordinator.workspaceViewControllerForTesting.invokeResizeForTesting(
            splitID: nestedID,
            ratio: 0.9
        )

        #expect(ratio(in: activeTab(of: coordinator).root, splitID: outerID) == 0.5)
        #expect(ratio(in: activeTab(of: coordinator).root, splitID: nestedID) == 0.9)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)

        coordinator.workspaceViewControllerForTesting.invokeEqualizeForTesting(splitID: outerID)

        #expect(ratio(in: activeTab(of: coordinator).root, splitID: outerID) == 0.5)
        #expect(ratio(in: activeTab(of: coordinator).root, splitID: nestedID) == 0.5)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
    }

    @Test
    func processExitClosesOnlyOnePaneAndCollapsesToItsLiveSibling() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let sibling = try #require(coordinator.activeSurfaceForTesting)
        try coordinator.splitActivePaneForTesting(axis: .horizontal)
        let exited = try #require(coordinator.activeSurfaceForTesting)

        exited.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let tab = activeTab(of: coordinator)
        #expect(tab.root == .pane(sibling.paneID))
        #expect(tab.activePaneID == sibling.paneID)
        #expect(coordinator.activeSurfaceForTesting === sibling)
        #expect(coordinator.surfaceIDsForTesting == [sibling.paneID])
        #expect(bridge.activeSurfaceIDs == [sibling.paneID])
    }

    @Test
    func processExitReplacesLastPaneInOwnerWorkspaceWhenAnotherWorkspaceIsActive() async throws {
        let activePaneID = PaneID()
        let ownerPaneID = PaneID()
        let activeTab = TerminalTab(
            title: "Active",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp/active")
        )
        let ownerTab = TerminalTab(
            title: "Owner",
            pane: TerminalPaneDescriptor(id: ownerPaneID, cwd: "/tmp/owner")
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let ownerWorkspace = Workspace(
            name: "Owner",
            tabs: [ownerTab],
            activeTabID: ownerTab.id
        )
        let initialStore = try WorkspaceStore(
            workspaces: [activeWorkspace, ownerWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let activeSurface = try #require(coordinator.activeSurfaceForTesting)
        let ownerSurface = try #require(coordinator.surfaceForTesting(id: ownerPaneID))
        let window = try #require(coordinator.activeWindowForTesting)

        persistence.reset()
        ownerSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let owner = try #require(store.workspace(id: ownerWorkspace.id))
        let replacementPaneID = try #require(owner.tabs.first?.activePaneID)
        let replacement = try #require(coordinator.surfaceForTesting(id: replacementPaneID))
        #expect(persistence.snapshots == [store])
        #expect(owner.tabs.count == 1)
        #expect(replacement.paneID != ownerSurface.paneID)
        #expect(coordinator.surfaceForTesting(id: activePaneID) === activeSurface)
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(window.firstResponder === activeSurface)
    }

    @Test
    func finalProcessExitReplacesTabInTheActiveWorkspace() async throws {
        let firstWorkspace = Workspace(name: "First")
        let activeWorkspace = Workspace(name: "Active")
        let initialStore = try WorkspaceStore(
            workspaces: [firstWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: initialStore
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let exitedSurface = try #require(coordinator.activeSurfaceForTesting)

        exitedSurface.scheduleRuntimeCloseForTesting(processAlive: false)
        await Task.yield()

        let store = coordinator.workspaceStoreForTesting
        let replacement = try #require(coordinator.activeSurfaceForTesting)
        let replacementWorkspace = try #require(store.workspace(id: activeWorkspace.id))
        #expect(store.activeWorkspaceID == activeWorkspace.id)
        #expect(store.workspace(id: firstWorkspace.id)?.tabs.isEmpty == true)
        #expect(replacementWorkspace.tabs.count == 1)
        #expect(replacementWorkspace.tabs[0].activePaneID == replacement.paneID)
        #expect(replacement.paneID != exitedSurface.paneID)
    }

    @Test
    func startRestoresEverySavedPaneWithoutReplayingCommands() async throws {
        let authoredStore = try restoredWorkspaceStore(isBroadcasting: true)
        let savedStore = try JSONDecoder().decode(
            WorkspaceStore.self,
            from: JSONEncoder().encode(authoredStore)
        )
        let savedActiveWorkspace = try #require(
            savedStore.workspace(id: savedStore.activeWorkspaceID)
        )
        let savedActiveTabID = try #require(savedActiveWorkspace.activeTabID)
        let savedActiveTab = try #require(savedStore.tab(id: savedActiveTabID))
        let customPaneID = savedActiveTab.root.leaves[1]

        #expect(!savedActiveTab.isBroadcasting)
        #expect(
            savedActiveTab.paneDescriptor(for: customPaneID)?.startupCommand
                == .custom("printf should-not-run")
        )

        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }

        do {
            let coordinator = WindowCoordinator(
                ghosttyBridge: bridge,
                surfaceConfiguration: GhosttySurfaceConfiguration(
                    workingDirectory: "/tmp/ignored",
                    command: "exec /bin/cat",
                    initialInput: "echo should-not-run\\n"
                ),
                initialWorkspaceStore: savedStore
            )
            defer { coordinator.prepareForBridgeShutdownForTesting() }

            try coordinator.start()
            await Task.yield()

            let expectedPaneIDs = Set(
                savedStore.workspaces.flatMap(\.tabs).flatMap { $0.root.leaves }
            )
            #expect(Set(coordinator.surfaceIDsForTesting) == expectedPaneIDs)
            #expect(Set(bridge.activeSurfaceIDs) == expectedPaneIDs)
            #expect(bridge.activeSurfaceCount == expectedPaneIDs.count)
            #expect(coordinator.workspaceStoreForTesting == savedStore)
            #expect(
                coordinator.workspaceStoreForTesting.activeWorkspaceID
                    == savedStore.activeWorkspaceID)
            #expect(
                coordinator.workspaceStoreForTesting.workspace(id: savedStore.activeWorkspaceID)?
                    .activeTabID == savedActiveTabID
            )
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: savedActiveTabID)?.activePaneID
                    == savedActiveTab.activePaneID
            )
            #expect(!coordinator.isBroadcastingActiveTab)
            #expect(
                coordinator.workspaceStoreForTesting.tab(id: savedActiveTabID)?
                    .paneDescriptor(for: customPaneID)?.startupCommand
                    == .custom("printf should-not-run")
            )

            var expectedActiveSurfaceIdentities: [PaneID: ObjectIdentifier] = [:]
            for paneID in savedActiveTab.root.leaves {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                expectedActiveSurfaceIdentities[paneID] = ObjectIdentifier(surface)
            }
            #expect(
                coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                    == expectedActiveSurfaceIdentities
            )
            let activeSurface = try #require(coordinator.activeSurfaceForTesting)
            #expect(activeSurface.paneID == savedActiveTab.activePaneID)
            #expect(coordinator.activeWindowForTesting?.firstResponder === activeSurface)

            for workspace in savedStore.workspaces {
                for tab in workspace.tabs {
                    for (leafIndex, paneID) in tab.root.leaves.enumerated() {
                        let descriptor = try #require(tab.paneDescriptor(for: paneID))
                        let configuration = try #require(
                            bridge.surfaceConfigurationForTesting(id: paneID)
                        )
                        #expect(configuration.workingDirectory == descriptor.cwd)
                        #expect(configuration.command == nil)
                        #expect(configuration.initialInput == nil)
                        #expect(
                            configuration.context
                                == (leafIndex == 0 ? .newTab : .split)
                        )
                    }
                }
            }

            var originalSurfaceIdentities: [PaneID: ObjectIdentifier] = [:]
            for paneID in expectedPaneIDs {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                originalSurfaceIdentities[paneID] = ObjectIdentifier(surface)
            }

            try coordinator.start()

            #expect(Set(coordinator.surfaceIDsForTesting) == expectedPaneIDs)
            #expect(bridge.activeSurfaceCount == expectedPaneIDs.count)
            for (paneID, identity) in originalSurfaceIdentities {
                let surface = try #require(coordinator.surfaceForTesting(id: paneID))
                #expect(ObjectIdentifier(surface) == identity)
            }
        }
    }

    @Test
    func startCreatesDefaultShellOnlyWhenEveryWorkspaceIsEmpty() async throws {
        let emptyBridge = try GhosttyBridge()
        defer { emptyBridge.shutdown() }

        do {
            let emptyCoordinator = WindowCoordinator(ghosttyBridge: emptyBridge)
            defer { emptyCoordinator.prepareForBridgeShutdownForTesting() }

            try emptyCoordinator.start()
            await Task.yield()

            let defaultStore = emptyCoordinator.workspaceStoreForTesting
            let defaultWorkspace = try #require(
                defaultStore.workspace(id: defaultStore.activeWorkspaceID)
            )
            let defaultTabID = try #require(defaultWorkspace.activeTabID)
            let defaultTab = try #require(defaultStore.tab(id: defaultTabID))
            let defaultSurface = try #require(emptyCoordinator.activeSurfaceForTesting)
            #expect(defaultWorkspace.tabs.count == 1)
            #expect(defaultTab.root.leaves == [defaultSurface.paneID])
            #expect(defaultTab.paneDescriptor(for: defaultSurface.paneID)?.startupCommand == .shell)
            #expect(emptyBridge.activeSurfaceIDs == [defaultSurface.paneID])
            #expect(
                emptyBridge.surfaceConfigurationForTesting(id: defaultSurface.paneID)?.context
                    == .window
            )
            #expect(emptyCoordinator.activeWindowForTesting?.firstResponder === defaultSurface)

            emptyCoordinator.createNewTab()

            let newTabSurface = try #require(emptyCoordinator.activeSurfaceForTesting)
            #expect(
                emptyBridge.surfaceConfigurationForTesting(id: newTabSurface.paneID)?.context
                    == .newTab
            )
        }

        let backgroundPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let emptyActiveWorkspace = Workspace(name: "Active Empty")
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let mixedStore = try WorkspaceStore(
            workspaces: [emptyActiveWorkspace, backgroundWorkspace],
            activeWorkspaceID: emptyActiveWorkspace.id
        )
        let mixedBridge = try GhosttyBridge()
        defer { mixedBridge.shutdown() }

        do {
            let mixedCoordinator = WindowCoordinator(
                ghosttyBridge: mixedBridge,
                initialWorkspaceStore: mixedStore
            )
            defer { mixedCoordinator.prepareForBridgeShutdownForTesting() }

            try mixedCoordinator.start()
            await Task.yield()

            #expect(mixedCoordinator.workspaceStoreForTesting == mixedStore)
            #expect(
                mixedCoordinator.workspaceStoreForTesting.activeWorkspaceID
                    == emptyActiveWorkspace.id)
            #expect(mixedCoordinator.activeSurfaceForTesting == nil)
            #expect(mixedCoordinator.surfaceIDsForTesting == [backgroundPaneID])
            #expect(mixedBridge.activeSurfaceIDs == [backgroundPaneID])
            #expect(
                mixedCoordinator.workspaceViewControllerForTesting
                    .hostedSurfaceIdentifiersForTesting
                    .isEmpty
            )
            #expect(
                mixedCoordinator.workspaceViewControllerForTesting
                    .emptyWorkspaceLabelIsVisibleForTesting)
        }
    }

    @Test
    func startupModelMutationFailureCanRetryOnceThenRemainsIdempotent() throws {
        let initialStore = WorkspaceStore()
        let expectedError = WorkspaceError.workspaceNotFound(initialStore.activeWorkspaceID)
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: initialStore,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        coordinator.failNextStartupModelMutationForTesting()

        #expect(throws: expectedError) {
            try coordinator.start()
        }

        #expect(coordinator.workspaceStoreForTesting == initialStore)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )

        try coordinator.start()

        let startedStore = coordinator.workspaceStoreForTesting
        let workspace = try #require(startedStore.workspace(id: startedStore.activeWorkspaceID))
        let tab = try #require(workspace.tabs.first)
        let surface = try #require(coordinator.activeSurfaceForTesting)
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let surfaceIdentity = ObjectIdentifier(surface)
        #expect(workspace.tabs.count == 1)
        #expect(tab.activePaneID == surface.paneID)
        #expect(surfaceIDs == [surface.paneID])
        #expect(bridge.activeSurfaceIDs == [surface.paneID])
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots == [startedStore])
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        try coordinator.start()

        #expect(coordinator.workspaceStoreForTesting == startedStore)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == surfaceIDs)
        #expect(coordinator.activeSurfaceForTesting.map(ObjectIdentifier.init) == surfaceIdentity)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots == [startedStore])
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.prepareForBridgeShutdownForTesting()
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func emptyStoreStartupKeepsCreatedModelAndPresentationWhenSurfaceCreationFails() throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/startup-failure",
                command: "exec /bin/cat",
                initialInput: "printf startup"
            ),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failNextSurfaceCreationForTesting()

        do {
            try coordinator.start()
        } catch {
            Issue.record("Expected a nonfatal startup surface failure, got \(error)")
        }

        let store = coordinator.workspaceStoreForTesting
        let workspace = try #require(store.workspace(id: store.activeWorkspaceID))
        let tab = try #require(workspace.tabs.first)
        let paneID = try #require(tab.root.leaves.first)
        #expect(workspace.tabs.count == 1)
        #expect(tab.title == "Shell")
        #expect(tab.root == .pane(paneID))
        #expect(
            tab.paneDescriptor(for: paneID)
                == TerminalPaneDescriptor(
                    id: paneID,
                    cwd: "/tmp/startup-failure",
                    startupCommand: .custom("exec /bin/cat")
                )
        )
        #expect(persistence.snapshots == [store])
        #expect(persistence.snapshots.first?.tab(id: tab.id)?.activePaneID == paneID)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting == [paneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[paneID]
                == GhosttyBridgeError.surfaceCreationFailed(paneID).localizedDescription
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                != nil
        )
        #expect(
            !coordinator.workspaceViewControllerForTesting.emptyWorkspaceLabelIsVisibleForTesting
        )
        let window = try #require(coordinator.windowForTesting)
        #expect(window.isVisible)
        #expect(window.delegate === coordinator)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )

        let failureMessages = coordinator.surfaceFailureMessagesForTesting
        let persistedSnapshots = persistence.snapshots

        try coordinator.start()

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.activePaneID == paneID)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting == [paneID])
        #expect(coordinator.surfaceFailureMessagesForTesting == failureMessages)
        #expect(persistence.snapshots == persistedSnapshots)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func unavailablePaneActionRoutesRetryWithSameIdentity() throws {
        let paneID = PaneID()
        let descriptor = TerminalPaneDescriptor(
            id: paneID,
            cwd: "/tmp",
            startupCommand: .custom("printf should-not-run")
        )
        let tab = TerminalTab(title: "Unavailable", pane: descriptor)
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/ignored",
                command: "printf base-should-not-run",
                initialInput: "printf input-should-not-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: paneID)
        try coordinator.start()
        persistence.reset()

        coordinator.invokeRetryUnavailablePanePresentationCallbackForTesting(paneID)

        let surface = try #require(coordinator.surfaceForTesting(id: paneID))
        let configuration = try #require(bridge.surfaceConfigurationForTesting(id: paneID))
        #expect(surface.paneID == paneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == tab.root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?.paneDescriptor(for: paneID)
                == descriptor
        )
        #expect(coordinator.surfaceIDsForTesting == [paneID])
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(configuration.workingDirectory == descriptor.cwd)
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .newTab)
        #expect(coordinator.activeSurfaceForTesting === surface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === surface)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )
    }

    @Test
    func closeUnavailablePaneCollapsesSplitWithoutTouchingLiveSurfaceAndIsIdempotent() throws {
        let livePaneID = PaneID()
        let unavailablePaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.35,
            first: .pane(livePaneID),
            second: .pane(unavailablePaneID)
        )
        let tab = try TerminalTab(
            title: "Unavailable split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: livePaneID, cwd: "/tmp/live"),
                TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp/unavailable"),
            ],
            activePaneID: unavailablePaneID,
            isBroadcasting: true
        )
        let workspace = Workspace(name: "Split", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var snapshots: [WorkspaceStore] = []
        var closeDidBeginCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let liveSurface = try #require(coordinator.surfaceForTesting(id: livePaneID))
        let liveIdentity = ObjectIdentifier(liveSurface)
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.isBroadcasting == false)
        #expect(coordinator.surfaceForTesting(id: unavailablePaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting == [unavailablePaneID])
        snapshots = []
        coordinator.setCloseUnavailablePaneDidBeginHookForTesting { [weak coordinator] paneID in
            closeDidBeginCount += 1
            coordinator?.invokeCloseUnavailablePanePresentationCallbackForTesting(paneID)
        }

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingTab = try #require(resultingStore.tab(id: tab.id))
        #expect(closeDidBeginCount == 1)
        #expect(snapshots == [resultingStore])
        #expect(resultingTab.root == .pane(livePaneID))
        #expect(resultingTab.activePaneID == livePaneID)
        #expect(resultingTab.paneDescriptor(for: unavailablePaneID) == nil)
        #expect(!resultingTab.isBroadcasting)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [livePaneID])
        #expect(bridge.activeSurfaceIDs == [livePaneID])
        #expect(
            coordinator.surfaceForTesting(id: livePaneID).map(ObjectIdentifier.init)
                == liveIdentity
        )
        #expect(coordinator.activeSurfaceForTesting === liveSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === liveSurface)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)

        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        snapshots = []
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(livePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)
        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(PaneID())

        #expect(coordinator.workspaceStoreForTesting == resultingStore)
        #expect(snapshots.isEmpty)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
    }

    @Test
    func closeUnavailablePaneInvalidatesConfirmationBeforeCommitAndClearsFailureAfterCommit() throws
    {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Confirmations", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var dismissCount = 0
        var snapshots: [WorkspaceStore] = []
        var confirmationWasClearedDuringPersistence = false
        var failureWasPresentDuringPersistence = false
        weak var coordinatorReference: WindowCoordinator?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshot in
                snapshots.append(snapshot)
                confirmationWasClearedDuringPersistence =
                    coordinatorReference?.activeConfirmationForTesting == nil
                    && coordinatorReference?.pendingConfirmationCountForTesting == 0
                    && dismissCount == 1
                failureWasPresentDuringPersistence =
                    coordinatorReference?.surfaceFailureIDsForTesting == [unavailablePaneID]
            },
            confirmationPresenter: { _, _ in
                { dismissCount += 1 }
            }
        )
        coordinatorReference = coordinator
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        snapshots = []
        coordinator.enqueueCloseConfirmationForTesting(unavailablePaneID)
        #expect(coordinator.activeConfirmationForTesting == .close(unavailablePaneID))
        #expect(coordinator.pendingConfirmationCountForTesting == 0)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        #expect(dismissCount == 1)
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(coordinator.pendingConfirmationCountForTesting == 0)
        #expect(confirmationWasClearedDuringPersistence)
        #expect(failureWasPresentDuringPersistence)
        #expect(snapshots == [resultingStore])
        #expect(resultingStore.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
    }

    @Test
    func closeUnavailablePaneRebasesAfterConfirmationDismissalMutatesWorkspace() throws {
        let unavailablePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(
            name: "Reentrant confirmation",
            tabs: [unavailableTab],
            activeTabID: unavailableTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        var snapshots: [WorkspaceStore] = []
        var dismissalDidCreateTab = false
        weak var coordinatorReference: WindowCoordinator?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { snapshots.append($0) },
            confirmationPresenter: { _, _ in
                {
                    dismissalDidCreateTab = true
                    coordinatorReference?.createNewTab()
                }
            }
        )
        coordinatorReference = coordinator
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        snapshots = []
        coordinator.enqueueCloseConfirmationForTesting(unavailablePaneID)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        let createdTab = try #require(resultingWorkspace.tabs.first)
        let createdPaneID = createdTab.activePaneID
        let createdSurface = try #require(coordinator.surfaceForTesting(id: createdPaneID))
        #expect(dismissalDidCreateTab)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.workspace(id: workspace.id)?.tabs.count == 2)
        #expect(snapshots.first?.tab(id: unavailableTab.id) != nil)
        #expect(snapshots.last == resultingStore)
        #expect(resultingWorkspace.tabs.map(\.id) == [createdTab.id])
        #expect(resultingWorkspace.activeTabID == createdTab.id)
        #expect(resultingStore.tab(id: unavailableTab.id) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [createdPaneID])
        #expect(bridge.activeSurfaceIDs == [createdPaneID])
        #expect(coordinator.activeSurfaceForTesting === createdSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === createdSurface)
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(coordinator.pendingConfirmationCountForTesting == 0)
    }

    @Test
    func genericUnavailablePaneCloseCallbackClosesModelPaneWithoutFailureEntry() throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Generic unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Generic", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        coordinator.clearSurfaceFailureForTesting(unavailablePaneID)
        persistence.reset()
        #expect(coordinator.surfaceForTesting(id: unavailablePaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        #expect(resultingStore.workspace(id: workspace.id)?.tabs.isEmpty == true)
        #expect(persistence.snapshots == [resultingStore])
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
    }

    @Test(arguments: [PresentationMode.normal, .quake])
    func closeLastUnavailablePaneLeavesWorkspaceEmptyAndPhysicalWindowOpen(
        mode: PresentationMode
    ) throws {
        let unavailablePaneID = PaneID()
        let tab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(name: "Empty after close", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            presentationMode: mode,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let window = try #require(coordinator.activeWindowForTesting)
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.workspaces.map(\.id) == [workspace.id])
        #expect(resultingStore.activeWorkspaceID == workspace.id)
        #expect(resultingWorkspace.tabs.isEmpty)
        #expect(resultingWorkspace.activeTabID == nil)
        #expect(coordinator.surfaceIDsForTesting.isEmpty)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
        #expect(coordinator.activeSurfaceForTesting == nil)
        #expect(coordinator.activeWindowForTesting === window)
        #expect(window.isVisible)
        #expect(errors.isEmpty)
    }

    @Test
    func closeUnavailablePaneInBackgroundKeepsVisibleWorkspaceTabAndFocus() throws {
        let unavailablePaneID = PaneID()
        let backgroundLivePaneID = PaneID()
        let visiblePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp/unavailable")
        )
        let backgroundLiveTab = TerminalTab(
            title: "Background live",
            pane: TerminalPaneDescriptor(id: backgroundLivePaneID, cwd: "/tmp/background")
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp/visible")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [unavailableTab, backgroundLiveTab],
            activeTabID: unavailableTab.id
        )
        let visibleWorkspace = Workspace(
            name: "Visible",
            tabs: [visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, visibleWorkspace],
            activeWorkspaceID: visibleWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let backgroundLiveSurface = try #require(
            coordinator.surfaceForTesting(id: backgroundLivePaneID)
        )
        let visibleSurface = try #require(coordinator.surfaceForTesting(id: visiblePaneID))
        let visibleFirstResponder = coordinator.activeWindowForTesting?.firstResponder
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingBackground = try #require(
            resultingStore.workspace(id: backgroundWorkspace.id)
        )
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.activeWorkspaceID == visibleWorkspace.id)
        #expect(resultingBackground.tabs.map(\.id) == [backgroundLiveTab.id])
        #expect(resultingBackground.activeTabID == backgroundLiveTab.id)
        #expect(
            resultingStore.workspace(id: visibleWorkspace.id)?.activeTabID == visibleTab.id
        )
        #expect(coordinator.activeSurfaceForTesting === visibleSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === visibleFirstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(
            Set(coordinator.surfaceIDsForTesting) == [backgroundLivePaneID, visiblePaneID]
        )
        #expect(Set(bridge.activeSurfaceIDs) == [backgroundLivePaneID, visiblePaneID])
        #expect(coordinator.surfaceForTesting(id: backgroundLivePaneID) === backgroundLiveSurface)
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [visiblePaneID: ObjectIdentifier(visibleSurface)]
        )
    }

    @Test
    func closeUnavailablePaneInInactiveTabKeepsVisibleSelectionAndFocus() throws {
        let unavailablePaneID = PaneID()
        let visiblePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let visibleTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: visiblePaneID, cwd: "/tmp")
        )
        let workspace = Workspace(
            name: "Active",
            tabs: [unavailableTab, visibleTab],
            activeTabID: visibleTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let visibleSurface = try #require(coordinator.surfaceForTesting(id: visiblePaneID))
        let window = try #require(coordinator.activeWindowForTesting)
        _ = window.makeFirstResponder(nil)
        let firstResponder = window.firstResponder
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        let contextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        coordinator.invokeCloseUnavailablePanePresentationCallbackForTesting(unavailablePaneID)

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingWorkspace = try #require(resultingStore.workspace(id: workspace.id))
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingWorkspace.tabs.map(\.id) == [visibleTab.id])
        #expect(resultingWorkspace.activeTabID == visibleTab.id)
        #expect(coordinator.activeSurfaceForTesting === visibleSurface)
        #expect(window.firstResponder === firstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.surfaceIDsForTesting == [visiblePaneID])
        #expect(bridge.activeSurfaceIDs == [visiblePaneID])
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == contextCount)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
    }

    @Test
    func retryFailurePreservesSplitRuntimeAndRetrySuccessUsesSavedShellConfiguration() throws {
        let siblingPaneID = PaneID()
        let unavailablePaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.35,
            first: .pane(siblingPaneID),
            second: .pane(unavailablePaneID)
        )
        let unavailableDescriptor = TerminalPaneDescriptor(
            id: unavailablePaneID,
            cwd: "/tmp",
            startupCommand: .custom("printf never-run")
        )
        let tab = try TerminalTab(
            title: "Retry split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: siblingPaneID, cwd: "/"),
                unavailableDescriptor,
            ],
            activePaneID: unavailablePaneID
        )
        let workspace = Workspace(name: "Retry", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var errors: [Error] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/var/empty",
                command: "printf base-never-run",
                initialInput: "printf input-never-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            onError: { errors.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let siblingSurface = try #require(coordinator.surfaceForTesting(id: siblingPaneID))
        let siblingIdentity = ObjectIdentifier(siblingSurface)
        let failureMessage = try #require(
            coordinator.surfaceFailureMessagesForTesting[unavailablePaneID]
        )
        persistence.reset()

        bridge.failNextSurfaceCreationForTesting()
        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: unavailablePaneID) == unavailableDescriptor
        )
        #expect(coordinator.surfaceIDsForTesting == [siblingPaneID])
        #expect(bridge.activeSurfaceIDs == [siblingPaneID])
        #expect(
            coordinator.surfaceForTesting(id: siblingPaneID).map(ObjectIdentifier.init)
                == siblingIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting == [unavailablePaneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[unavailablePaneID]
                == GhosttyBridgeError.surfaceCreationFailed(unavailablePaneID)
                .localizedDescription
        )
        #expect(coordinator.surfaceFailureMessagesForTesting[unavailablePaneID] == failureMessage)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        let retriedSurface = try #require(
            coordinator.surfaceForTesting(id: unavailablePaneID)
        )
        let configuration = try #require(
            bridge.surfaceConfigurationForTesting(id: unavailablePaneID)
        )
        #expect(retriedSurface.paneID == unavailablePaneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.tab(id: tab.id)?.root == root)
        #expect(
            coordinator.workspaceStoreForTesting.tab(id: tab.id)?
                .paneDescriptor(for: unavailablePaneID) == unavailableDescriptor
        )
        #expect(Set(coordinator.surfaceIDsForTesting) == [siblingPaneID, unavailablePaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [siblingPaneID, unavailablePaneID])
        #expect(
            coordinator.surfaceForTesting(id: siblingPaneID).map(ObjectIdentifier.init)
                == siblingIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(configuration.workingDirectory == unavailableDescriptor.cwd)
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .split)
        #expect(coordinator.activeSurfaceForTesting === retriedSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === retriedSurface)
        #expect(persistence.snapshots.isEmpty)
        #expect(errors.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 2
        )
    }

    @Test
    func retryInInactiveTabAndWorkspaceDoesNotChangeSelectionOrFocus() throws {
        let unavailablePaneID = PaneID()
        let backgroundPaneID = PaneID()
        let activePaneID = PaneID()
        let unavailableTab = TerminalTab(
            title: "Unavailable",
            pane: TerminalPaneDescriptor(id: unavailablePaneID, cwd: "/tmp")
        )
        let backgroundTab = TerminalTab(
            title: "Background active",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let activeTab = TerminalTab(
            title: "Visible",
            pane: TerminalPaneDescriptor(id: activePaneID, cwd: "/tmp")
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [unavailableTab, backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Visible",
            tabs: [activeTab],
            activeTabID: activeTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: unavailablePaneID)
        try coordinator.start()
        let activeSurface = try #require(coordinator.surfaceForTesting(id: activePaneID))
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        let refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        persistence.reset()

        coordinator.retryUnavailablePaneForTesting(unavailablePaneID)

        let retriedSurface = try #require(
            coordinator.surfaceForTesting(id: unavailablePaneID)
        )
        #expect(retriedSurface.paneID == unavailablePaneID)
        #expect(coordinator.workspaceStoreForTesting == store)
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == activeWorkspace.id)
        #expect(
            coordinator.workspaceStoreForTesting.workspace(id: backgroundWorkspace.id)?
                .activeTabID == backgroundTab.id
        )
        #expect(coordinator.activeSurfaceForTesting === activeSurface)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.refreshWorkspacePresentationInvocationCountForTesting == refreshCount)
    }

    @Test
    func retryAlreadyLiveDeletedAndUnknownPanesIsNoOp() throws {
        let deletedPaneID = PaneID()
        let livePaneID = PaneID()
        let deletedTab = TerminalTab(
            title: "Delete",
            pane: TerminalPaneDescriptor(id: deletedPaneID, cwd: "/tmp")
        )
        let liveTab = TerminalTab(
            title: "Live",
            pane: TerminalPaneDescriptor(id: livePaneID, cwd: "/tmp")
        )
        let deletedWorkspace = Workspace(
            name: "Delete",
            tabs: [deletedTab],
            activeTabID: deletedTab.id
        )
        let liveWorkspace = Workspace(
            name: "Live",
            tabs: [liveTab],
            activeTabID: liveTab.id
        )
        let store = try WorkspaceStore(
            workspaces: [deletedWorkspace, liveWorkspace],
            activeWorkspaceID: deletedWorkspace.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var deletionResponse: (@MainActor (Bool) -> Void)?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { _, completion in
                deletionResponse = completion
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: deletedPaneID)
        try coordinator.start()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let respondToDeletion = try #require(deletionResponse)
        respondToDeletion(true)
        let liveSurface = try #require(coordinator.surfaceForTesting(id: livePaneID))
        let resultingStore = coordinator.workspaceStoreForTesting
        let surfaceIDs = coordinator.surfaceIDsForTesting
        let bridgeSurfaceIDs = bridge.activeSurfaceIDs
        let liveIdentity = ObjectIdentifier(liveSurface)
        let firstResponder = coordinator.activeWindowForTesting?.firstResponder
        persistence.reset()

        coordinator.retryUnavailablePaneForTesting(livePaneID)
        coordinator.retryUnavailablePaneForTesting(deletedPaneID)
        coordinator.retryUnavailablePaneForTesting(PaneID())

        #expect(coordinator.workspaceStoreForTesting == resultingStore)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDs)
        #expect(bridge.activeSurfaceIDs == bridgeSurfaceIDs)
        #expect(
            coordinator.surfaceForTesting(id: livePaneID).map(ObjectIdentifier.init)
                == liveIdentity
        )
        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(coordinator.activeWindowForTesting?.firstResponder === firstResponder)
        #expect(persistence.snapshots.isEmpty)
    }

    @Test(arguments: [false, true])
    func startKeepsSuccessfulSplitSurfaceAndFailedPaneDuringPartialRestore(
        isBroadcasting: Bool
    ) throws {
        let successfulPaneID = PaneID()
        let failingPaneID = PaneID()
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(successfulPaneID),
            second: .pane(failingPaneID)
        )
        let tab = try TerminalTab(
            title: "Restored split",
            root: root,
            paneDescriptors: [
                TerminalPaneDescriptor(id: successfulPaneID, cwd: "/tmp/success"),
                TerminalPaneDescriptor(id: failingPaneID, cwd: "/tmp/failure"),
            ],
            activePaneID: failingPaneID,
            isBroadcasting: isBroadcasting
        )
        let workspace = Workspace(name: "Restored", tabs: [tab], activeTabID: tab.id)
        let store = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/ignored",
                command: "printf should-not-run",
                initialInput: "printf should-not-run"
            ),
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        bridge.failSurfaceCreationForTesting(id: failingPaneID)

        do {
            try coordinator.start()
        } catch {
            Issue.record("Expected a nonfatal restore surface failure, got \(error)")
        }

        let resultingStore = coordinator.workspaceStoreForTesting
        let resultingTab = try #require(resultingStore.tab(id: tab.id))
        let successfulSurface = try #require(
            coordinator.surfaceForTesting(id: successfulPaneID)
        )
        #expect(resultingTab.root == root)
        #expect(resultingTab.root.leaves == [successfulPaneID, failingPaneID])
        #expect(resultingTab.paneDescriptors == tab.paneDescriptors)
        #expect(!resultingTab.isBroadcasting)
        #expect(coordinator.surfaceIDsForTesting == [successfulPaneID])
        #expect(bridge.activeSurfaceIDs == [successfulPaneID])
        #expect(coordinator.surfaceForTesting(id: successfulPaneID) === successfulSurface)
        #expect(coordinator.surfaceForTesting(id: failingPaneID) == nil)
        #expect(coordinator.surfaceFailureIDsForTesting == [failingPaneID])
        #expect(
            coordinator.surfaceFailureMessagesForTesting[failingPaneID]
                == GhosttyBridgeError.surfaceCreationFailed(failingPaneID).localizedDescription
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.hostedSurfaceIdentifiersForTesting
                == [successfulPaneID: ObjectIdentifier(successfulSurface)]
        )
        #expect(
            coordinator.workspaceViewControllerForTesting.splitHostingControllerIdentifierForTesting
                != nil
        )
        let configuration = try #require(
            bridge.surfaceConfigurationForTesting(id: successfulPaneID)
        )
        #expect(configuration.workingDirectory == "/tmp/success")
        #expect(configuration.command == nil)
        #expect(configuration.initialInput == nil)
        #expect(configuration.context == .newTab)
        #expect(
            persistence.snapshots == (isBroadcasting ? [resultingStore] : [])
        )
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        coordinator.prepareForBridgeShutdownForTesting()

        #expect(coordinator.surfaceFailureIDsForTesting.isEmpty)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount
        )
    }

    @Test
    func workspaceCreateAndRenameCommitOnceWithoutRecreatingLiveSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.new)
        let createSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        createSheet.submitForTesting(name: "Backend")

        let createdStore = coordinator.workspaceStoreForTesting
        let backend = try #require(createdStore.workspaces.last)
        let backendTab = try #require(backend.tabs.first)
        let backendSurface = try #require(coordinator.activeSurfaceForTesting)
        #expect(persistence.snapshots == [createdStore])
        #expect(createdStore.activeWorkspaceID == backend.id)
        #expect(backend.name == "Backend")
        #expect(backendTab.activePaneID == backendSurface.paneID)
        #expect(
            bridge.surfaceConfigurationForTesting(id: backendSurface.paneID)?.context == .newTab)
        #expect(coordinator.activeWindowForTesting?.firstResponder === backendSurface)

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.rename)
        let renameSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        renameSheet.submitForTesting(name: "Services")

        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.workspace(id: backend.id)?.name == "Services")
        #expect(coordinator.activeSurfaceForTesting === backendSurface)
        #expect(coordinator.surfaceIDsForTesting.contains(backendSurface.paneID))

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onRenameWorkspace?()
        let noOpSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        noOpSheet.submitForTesting(name: "Services")
        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.activeSurfaceForTesting === backendSurface)

        coordinator.workspaceViewControllerForTesting.onRenameWorkspace?()
        let invalidRenameSheet = try #require(coordinator.createWorkspaceControllerForTesting)
        invalidRenameSheet.submitForTesting(name: "default")
        #expect(
            invalidRenameSheet.errorMessageForTesting
                == "A workspace with this name already exists.")
        invalidRenameSheet.submitForTesting(name: " \n")
        #expect(invalidRenameSheet.errorMessageForTesting == "Workspace name is required.")
        #expect(persistence.snapshots.isEmpty)
        invalidRenameSheet.cancelForTesting()
    }

    @Test
    func workspaceCreateRollsBackOnSurfaceFailureWithoutPersisting() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let beforeStore = coordinator.workspaceStoreForTesting
        let beforeSurfaceIDs = coordinator.surfaceIDsForTesting

        persistence.reset()
        bridge.failNextSurfaceCreationForTesting()
        coordinator.workspaceViewControllerForTesting.onCreateWorkspace?()
        let sheet = try #require(coordinator.createWorkspaceControllerForTesting)
        sheet.submitForTesting(name: "Broken")

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting == beforeStore)
        #expect(coordinator.surfaceIDsForTesting == beforeSurfaceIDs)
        #expect(bridge.activeSurfaceIDs == beforeSurfaceIDs)
        #expect(!sheet.errorMessageForTesting.isEmpty)
    }

    @Test
    func workspaceDeletionAlertUsesExactCopyPluralizationAndButtons() {
        let singular = WindowCoordinator.makeWorkspaceDeletionAlert(
            WorkspaceDeletionConfirmation(
                workspaceID: WorkspaceID(),
                workspaceName: "Backend",
                tabCount: 1,
                paneCount: 1
            )
        )
        let plural = WindowCoordinator.makeWorkspaceDeletionAlert(
            WorkspaceDeletionConfirmation(
                workspaceID: WorkspaceID(),
                workspaceName: "Services",
                tabCount: 2,
                paneCount: 3
            )
        )

        #expect(singular.alertStyle == .warning)
        #expect(singular.messageText == "Delete Workspace?")
        #expect(
            singular.informativeText
                == "Backend contains 1 tab and 1 pane. All of its terminals will be closed.")
        #expect(
            plural.informativeText
                == "Services contains 2 tabs and 3 panes. All of its terminals will be closed.")
        #expect(singular.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(singular.buttons[0].hasDestructiveAction)
        #expect(singular.buttons[0].keyEquivalent == "\r")
        #expect(!singular.buttons[1].hasDestructiveAction)
        #expect(singular.buttons[1].keyEquivalent == "\u{1B}")
    }

    @Test
    func deletingMiddleActiveWorkspaceClosesOnlyItsSurfacesAndSelectsSuccessor() throws {
        let beforePaneID = PaneID()
        let deletedFirstPaneID = PaneID()
        let deletedSecondPaneID = PaneID()
        let afterPaneID = PaneID()
        let beforeTab = TerminalTab(
            title: "Before",
            pane: TerminalPaneDescriptor(id: beforePaneID, cwd: "/tmp/before")
        )
        let deletedTab = try TerminalTab(
            title: "Deleted",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(deletedFirstPaneID),
                second: .pane(deletedSecondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: deletedFirstPaneID, cwd: "/tmp/one"),
                TerminalPaneDescriptor(id: deletedSecondPaneID, cwd: "/tmp/two"),
            ],
            activePaneID: deletedSecondPaneID
        )
        let afterTab = TerminalTab(
            title: "After",
            pane: TerminalPaneDescriptor(id: afterPaneID, cwd: "/tmp/after")
        )
        let before = Workspace(name: "Before", tabs: [beforeTab], activeTabID: beforeTab.id)
        let deleted = Workspace(name: "Deleted", tabs: [deletedTab], activeTabID: deletedTab.id)
        let after = Workspace(name: "After", tabs: [afterTab], activeTabID: afterTab.id)
        let store = try WorkspaceStore(
            workspaces: [before, deleted, after],
            activeWorkspaceID: deleted.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        bridge.failSurfaceCreationForTesting(id: deletedSecondPaneID)
        let persistence = WorkspacePersistenceRecorder()
        var closePresentations: [GhosttyConfirmationPresentation] = []
        var closeDismissalCount = 0
        var deletionConfirmations: [WorkspaceDeletionConfirmation] = []
        var respondToDeletion: ((Bool) -> Void)?
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            confirmationPresenter: { presentation, _ in
                closePresentations.append(presentation)
                return { closeDismissalCount += 1 }
            },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                deletionConfirmations.append(confirmation)
                respondToDeletion = completion
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let beforeSurface = try #require(coordinator.surfaceForTesting(id: beforePaneID))
        let afterSurface = try #require(coordinator.surfaceForTesting(id: afterPaneID))
        let deletedFailureMessage = try #require(
            coordinator.surfaceFailureMessagesForTesting[deletedSecondPaneID]
        )
        #expect(
            deletedFailureMessage
                == GhosttyBridgeError.surfaceCreationFailed(deletedSecondPaneID)
                .localizedDescription
        )

        persistence.reset()
        coordinator.surfaceDidRequestCloseForTesting(id: deletedFirstPaneID, processAlive: true)
        #expect(closePresentations == [.close(deletedFirstPaneID)])
        #expect(coordinator.activeConfirmationForTesting == .close(deletedFirstPaneID))

        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let deletionConfirmation = try #require(deletionConfirmations.first)
        #expect(deletionConfirmations.count == 1)
        #expect(deletionConfirmation.workspaceName == "Deleted")
        #expect(deletionConfirmation.tabCount == 1)
        #expect(deletionConfirmation.paneCount == 2)

        respondToDeletion?(true)

        let resultingStore = coordinator.workspaceStoreForTesting
        let closeObservations = bridge.successfulSurfaceCloseObservationsForTesting
        #expect(persistence.snapshots == [resultingStore])
        #expect(resultingStore.workspaces.map(\.id) == [before.id, after.id])
        #expect(resultingStore.activeWorkspaceID == after.id)
        #expect(Set(coordinator.surfaceIDsForTesting) == [beforePaneID, afterPaneID])
        #expect(Set(bridge.activeSurfaceIDs) == [beforePaneID, afterPaneID])
        #expect(coordinator.surfaceForTesting(id: beforePaneID) === beforeSurface)
        #expect(coordinator.surfaceForTesting(id: afterPaneID) === afterSurface)
        #expect(coordinator.surfaceForTesting(id: deletedFirstPaneID) == nil)
        #expect(coordinator.surfaceForTesting(id: deletedSecondPaneID) == nil)
        #expect(!coordinator.surfaceFailureIDsForTesting.contains(deletedSecondPaneID))
        #expect(coordinator.surfaceFailureMessagesForTesting[deletedSecondPaneID] == nil)
        #expect(coordinator.activeSurfaceForTesting === afterSurface)
        #expect(
            coordinator.workspaceViewControllerForTesting.renderedSurfaceIdentifiersForTesting
                == [ObjectIdentifier(afterSurface)]
        )
        #expect(coordinator.activeConfirmationForTesting == nil)
        #expect(closeDismissalCount == 1)
        #expect(closeObservations == [deletedFirstPaneID])
        #expect(closeObservations.filter { $0 == deletedSecondPaneID }.isEmpty)
        #expect(closeObservations.filter { $0 == beforePaneID }.isEmpty)
        #expect(closeObservations.filter { $0 == afterPaneID }.isEmpty)

        coordinator.surfaceDidRequestCloseForTesting(id: deletedFirstPaneID, processAlive: false)
        coordinator.surfaceDidRequestCloseForTesting(id: deletedSecondPaneID, processAlive: false)
        #expect(persistence.snapshots == [resultingStore])
        #expect(bridge.successfulSurfaceCloseObservationsForTesting == closeObservations)
        #expect(Set(coordinator.surfaceIDsForTesting) == [beforePaneID, afterPaneID])
    }

    @Test
    func cancellingNonemptyWorkspaceDeletionLeavesRuntimeStateUntouchedAndCanPresentAgain() throws {
        let backgroundPaneID = PaneID()
        let deletedPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp/background")
        )
        let deletedTab = TerminalTab(
            title: "Deleted",
            pane: TerminalPaneDescriptor(id: deletedPaneID, cwd: "/tmp/deleted")
        )
        let background = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let deleted = Workspace(name: "Deleted", tabs: [deletedTab], activeTabID: deletedTab.id)
        let store = try WorkspaceStore(
            workspaces: [background, deleted],
            activeWorkspaceID: deleted.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var deletionConfirmations: [WorkspaceDeletionConfirmation] = []
        var deletionResponses: [(@MainActor (Bool) -> Void)] = []
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { confirmation, completion in
                deletionConfirmations.append(confirmation)
                deletionResponses.append(completion)
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()
        let backgroundSurface = try #require(coordinator.surfaceForTesting(id: backgroundPaneID))
        let deletedSurface = try #require(coordinator.surfaceForTesting(id: deletedPaneID))
        let activeWindow = try #require(coordinator.activeWindowForTesting)
        let storeBeforeCancellation = coordinator.workspaceStoreForTesting
        let surfaceIDsBeforeCancellation = coordinator.surfaceIDsForTesting
        let bridgeSurfaceIDsBeforeCancellation = bridge.activeSurfaceIDs
        let closeObservationsBeforeCancellation = bridge
            .successfulSurfaceCloseObservationsForTesting

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        let firstResponse = try #require(deletionResponses.first)
        #expect(
            deletionConfirmations == [
                WorkspaceDeletionConfirmation(
                    workspaceID: deleted.id,
                    workspaceName: "Deleted",
                    tabCount: 1,
                    paneCount: 1
                )
            ])

        firstResponse(false)

        #expect(coordinator.workspaceStoreForTesting == storeBeforeCancellation)
        #expect(coordinator.surfaceIDsForTesting == surfaceIDsBeforeCancellation)
        #expect(bridge.activeSurfaceIDs == bridgeSurfaceIDsBeforeCancellation)
        #expect(coordinator.surfaceForTesting(id: backgroundPaneID) === backgroundSurface)
        #expect(coordinator.surfaceForTesting(id: deletedPaneID) === deletedSurface)
        #expect(coordinator.activeSurfaceForTesting === deletedSurface)
        #expect(activeWindow.firstResponder === deletedSurface)
        #expect(persistence.snapshots.isEmpty)
        #expect(
            bridge.successfulSurfaceCloseObservationsForTesting
                == closeObservationsBeforeCancellation)

        coordinator.workspaceViewControllerForTesting.onDeleteWorkspace?()
        #expect(deletionConfirmations.count == 2)
        let secondResponse = try #require(deletionResponses.last)
        secondResponse(false)
    }

    @Test
    func deletingTheOnlyWorkspaceIsDisabledAndDoesNotPersist() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            persistWorkspaceStore: { persistence.snapshots.append($0) }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.delete)

        #expect(persistence.snapshots.isEmpty)
        #expect(coordinator.workspaceStoreForTesting.workspaces.count == 1)
        #expect(
            !coordinator.workspaceViewControllerForTesting.workspaceSelector
                .isActionEnabledForTesting(.delete)
        )
    }

    @Test
    func deletingAnEmptyActiveWorkspaceCommitsOnceWithoutPresentingAnAlert() throws {
        let backgroundPaneID = PaneID()
        let backgroundTab = TerminalTab(
            title: "Background",
            pane: TerminalPaneDescriptor(id: backgroundPaneID, cwd: "/tmp")
        )
        let background = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let empty = Workspace(name: "Empty")
        let store = try WorkspaceStore(
            workspaces: [background, empty],
            activeWorkspaceID: empty.id
        )
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let persistence = WorkspacePersistenceRecorder()
        var alertCount = 0
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            initialWorkspaceStore: store,
            persistWorkspaceStore: { persistence.snapshots.append($0) },
            workspaceDeletionConfirmationPresenter: { _, _ in
                alertCount += 1
            }
        )
        defer { coordinator.prepareForBridgeShutdownForTesting() }
        try coordinator.start()

        persistence.reset()
        coordinator.workspaceViewControllerForTesting.workspaceSelector
            .triggerActionForTesting(.delete)

        #expect(alertCount == 0)
        #expect(persistence.snapshots == [coordinator.workspaceStoreForTesting])
        #expect(coordinator.workspaceStoreForTesting.workspaces.map(\.id) == [background.id])
        #expect(coordinator.workspaceStoreForTesting.activeWorkspaceID == background.id)
        #expect(coordinator.surfaceIDsForTesting == [backgroundPaneID])
        #expect(coordinator.activeSurfaceForTesting?.paneID == backgroundPaneID)
    }

    private func expectAgentEnvironment(
        _ environment: [String: String],
        paneID: PaneID,
        instanceID: UUID,
        token: String
    ) {
        let reservedKeys: Set<String> = [
            "QUICKTTY_PANE_ID",
            "QUICKTTY_AGENT_SOCKET",
            "QUICKTTY_INSTANCE_ID",
            "QUICKTTY_PANE_TOKEN",
            "QUICKTTY_AGENT_HELPER",
        ]
        #expect(Set(environment.keys.filter { reservedKeys.contains($0) }) == reservedKeys)
        #expect(environment["QUICKTTY_PANE_ID"] == paneID.rawValue.uuidString)
        #expect(environment["QUICKTTY_AGENT_SOCKET"] == "/tmp/quicktty-test/agent.sock")
        #expect(environment["QUICKTTY_INSTANCE_ID"] == instanceID.uuidString)
        #expect(environment["QUICKTTY_PANE_TOKEN"] == token)
        #expect(
            environment["QUICKTTY_AGENT_HELPER"]
                == "/Applications/QuickTTY.app/Contents/Helpers/quicktty"
        )
    }

    private func restoredWorkspaceStore(isBroadcasting: Bool = false) throws -> WorkspaceStore {
        let backgroundFirstPaneID = PaneID()
        let backgroundSecondPaneID = PaneID()
        let backgroundTab = try TerminalTab(
            title: "Background split",
            root: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.3,
                first: .pane(backgroundFirstPaneID),
                second: .pane(backgroundSecondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: backgroundFirstPaneID, cwd: "/"),
                TerminalPaneDescriptor(id: backgroundSecondPaneID, cwd: "/usr"),
            ],
            activePaneID: backgroundSecondPaneID
        )
        let hiddenPaneID = PaneID()
        let hiddenTab = TerminalTab(
            title: "Hidden tab",
            pane: TerminalPaneDescriptor(id: hiddenPaneID, cwd: "/bin")
        )
        let activeFirstPaneID = PaneID()
        let activeSecondPaneID = PaneID()
        let activeThirdPaneID = PaneID()
        let activeTab = try TerminalTab(
            title: "Active nested split",
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.6,
                first: .pane(activeFirstPaneID),
                second: .split(
                    id: UUID(),
                    axis: .vertical,
                    ratio: 0.4,
                    first: .pane(activeSecondPaneID),
                    second: .pane(activeThirdPaneID)
                )
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: activeFirstPaneID, cwd: "/System"),
                TerminalPaneDescriptor(
                    id: activeSecondPaneID,
                    cwd: "/private",
                    startupCommand: .custom("printf should-not-run")
                ),
                TerminalPaneDescriptor(id: activeThirdPaneID, cwd: "/tmp"),
            ],
            activePaneID: activeThirdPaneID,
            isBroadcasting: isBroadcasting
        )
        let backgroundWorkspace = Workspace(
            name: "Background",
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )
        let activeWorkspace = Workspace(
            name: "Active",
            tabs: [hiddenTab, activeTab],
            activeTabID: activeTab.id
        )
        return try WorkspaceStore(
            workspaces: [backgroundWorkspace, activeWorkspace],
            activeWorkspaceID: activeWorkspace.id
        )
    }

    private func activeTab(of coordinator: WindowCoordinator) -> TerminalTab {
        let store = coordinator.workspaceStoreForTesting
        let workspace = store.workspace(id: store.activeWorkspaceID)!
        return store.tab(id: workspace.activeTabID!)!
    }

    private func split(in root: SplitNode) -> (
        id: UUID,
        axis: SplitAxis,
        ratio: Double,
        first: SplitNode,
        second: SplitNode
    )? {
        guard case .split(let id, let axis, let ratio, let first, let second) = root else {
            return nil
        }
        return (id, axis, ratio, first, second)
    }

    private func ratio(in root: SplitNode, splitID: UUID) -> Double? {
        switch root {
        case .pane:
            return nil
        case .split(let id, _, let storedRatio, let first, let second):
            if id == splitID {
                return storedRatio
            }
            return ratio(in: first, splitID: splitID) ?? ratio(in: second, splitID: splitID)
        }
    }
}

@MainActor
private final class CoordinatorActivityScheduler {
    @MainActor
    final class Cancellation {
        var isCancelled = false
    }

    struct Request {
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
        let cancellation: Cancellation
    }

    private(set) var requests: [Request] = []

    var activeRequests: [Request] {
        requests.filter { !$0.cancellation.isCancelled }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let cancellation = Cancellation()
        requests.append(Request(delay: delay, action: action, cancellation: cancellation))
        return { cancellation.isCancelled = true }
    }

    func runActiveRequests() {
        let pending = requests
        requests.removeAll()
        for request in pending where !request.cancellation.isCancelled {
            request.action()
        }
    }
}

@MainActor
private final class CoordinatorNotificationClient: TerminalNotificationClient {
    private let immediateStatus: TerminalNotificationAuthorizationStatus?
    private var statusCompletions:
        [@MainActor @Sendable (TerminalNotificationAuthorizationStatus) -> Void] = []
    private(set) var addedRequests: [TerminalNotificationRequest] = []

    init(status: TerminalNotificationAuthorizationStatus?) {
        immediateStatus = status
    }

    func authorizationStatus(
        completion:
            @escaping @MainActor @Sendable (
                TerminalNotificationAuthorizationStatus
            ) -> Void
    ) {
        if let immediateStatus {
            completion(immediateStatus)
        } else {
            statusCompletions.append(completion)
        }
    }

    func requestAuthorization(
        completion:
            @escaping @MainActor @Sendable (
                Result<Bool, TerminalNotificationClientError>
            ) -> Void
    ) {
        completion(.success(true))
    }

    func add(
        _ request: TerminalNotificationRequest,
        completion:
            @escaping @MainActor @Sendable (
                Result<Void, TerminalNotificationClientError>
            ) -> Void
    ) {
        addedRequests.append(request)
        completion(.success(()))
    }

    func resolveAuthorizationStatus(_ status: TerminalNotificationAuthorizationStatus) {
        let completions = statusCompletions
        statusCompletions.removeAll()
        for completion in completions {
            completion(status)
        }
    }
}

@MainActor
private func effectMatchesStatus(
    _ effect: TerminalActivityEffect,
    in controller: TerminalActivityController
) -> Bool {
    guard let phase = controller.statuses[effect.paneID]?.phase else { return false }
    switch (effect, phase) {
    case (.waiting, .waiting), (.failed, .failed), (.completed, .completed):
        return true
    case (.waiting, _), (.failed, _), (.completed, _), (.cleared, _):
        return false
    }
}

@MainActor
private final class CoordinatorAgentTokenSequence {
    private var values: [[UInt8]]

    init(_ values: [[UInt8]]) {
        self.values = values
    }

    func next() -> [UInt8] {
        values.removeFirst()
    }
}

@MainActor
private final class ReentrantTerminationState {
    weak var coordinator: WindowCoordinator?
    var freezeOnCommit = false
    var created: TerminalAutomationCreatedTaskResponse?
}

@MainActor
private final class TerminationPresentationCancellation: PresentationCancellation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

// WHY: Same manual protocol-driver pattern as PresentationStateMachineTests. Retained
// callbacks are delivered even after cancel(), so tests exercise controller invalidation.
@MainActor
private final class TerminationQuakeDriver: QuakeFrameAnimating, PresentationDeferring,
    PresentationScheduling, PresentationApplicationActivation
{
    struct Animation {
        let completion: @MainActor () -> Void
        let cancellation: TerminationPresentationCancellation
    }
    struct Scheduled {
        let action: @MainActor @Sendable () -> Void
        let cancellation: TerminationPresentationCancellation
    }
    private(set) var animations: [Animation] = []
    private(set) var deferred: [Scheduled] = []
    private(set) var scheduled: [Scheduled] = []
    private(set) var activationCount = 0
    var persistedHeights: [Double] = []
    var completesAnimationsSynchronously = false

    func animate(
        window: any QuakeWindowRepresenting, to frame: NSRect,
        request: QuakeAnimationRequest, duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> any PresentationCancellation {
        let cancellation = TerminationPresentationCancellation()
        animations.append(Animation(completion: completion, cancellation: cancellation))
        if completesAnimationsSynchronously { completion() }
        return cancellation
    }

    func deferAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let cancellation = TerminationPresentationCancellation()
        deferred.append(Scheduled(action: action, cancellation: cancellation))
        return cancellation
    }

    func schedule(
        after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let cancellation = TerminationPresentationCancellation()
        scheduled.append(Scheduled(action: action, cancellation: cancellation))
        return cancellation
    }

    func activate() { activationCount += 1 }
}

// WHY: Keep a real AppKit content host for coordinator/surface wiring while observing
// every Quake protocol write, including focus that could otherwise re-show an empty window.
@MainActor
private final class TerminationQuakeWindow: NSPanel, QuakeWindowRepresenting {
    private(set) var events: [String] = []
    private(set) var focusCount = 0
    var willInstallContent: (@MainActor (NSViewController?) throws -> Void)?
    var didInstallContent: (@MainActor (NSViewController?) throws -> Void)?
    var didOrderOut: (@MainActor () -> Void)?

    init(contentRect: NSRect = .zero) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    var presentationFrame: NSRect { frame }
    var isPresentationVisible: Bool { isVisible }
    var installedContentViewController: NSViewController? { contentViewController }
    var hasAttachedSheet: Bool { attachedSheet != nil }

    func setPresentationFrame(_ frame: NSRect) {
        events.append("frame")
        setFrame(frame, display: false)
    }
    func setPresentationLevel(_ level: QuakePresentationLevel) {
        events.append("level")
        self.level = level == .floating ? .floating : .popUpMenu
    }
    func installContentViewController(_ controller: NSViewController?) throws {
        events.append("content")
        try willInstallContent?(controller)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        contentViewController = controller
        try didInstallContent?(controller)
    }
    func orderFrontForPresentation() {
        events.append("front")
        orderFrontRegardless()
    }
    func focusForPresentation() {
        events.append("focus")
        focusCount += 1
        makeKeyAndOrderFront(nil)
    }
    func orderOutForPresentation() {
        events.append("out")
        orderOut(nil)
        didOrderOut?()
    }
}

// WHY: Value-only snapshots keep Swift Testing captures independent of mutable AppKit objects.
private struct NativeCallbackPresentationSnapshot: Equatable {
    let model: WorkspaceStore
    let persistenceModel: WorkspaceStore
    let selectionGeneration: UInt64
    let displayedTabs: [TerminalTab]
    let displayedTitles: [TabID: String]
    let selectedTabs: [TabID]
    let orderedTabs: [TabID]
    let activeTab: TabID?
    let editedTab: TabID?
    let nativeSelection: Set<IndexPath>
    let reloadGeneration: Int
    let dragGeneration: Int
    let refreshCount: Int
    let statusRefreshCount: Int
    let hosted: [PaneID: ObjectIdentifier]
    let rendered: [ObjectIdentifier]
    let splitHost: ObjectIdentifier?
    let surfaces: [PaneID: ObjectIdentifier]
    let surfaceHosts: [PaneID: ObjectIdentifier]
    let surfaceWindows: [PaneID: ObjectIdentifier]
    let responder: ObjectIdentifier?
    let windowVisible: Bool
    let ownedEditor: ObjectIdentifier?
    let attachedSheet: ObjectIdentifier?
    let sheetParent: ObjectIdentifier?
    let sheetResponder: ObjectIdentifier?
    let sheetVisible: Bool

    @MainActor
    init(_ coordinator: WindowCoordinator, editor: CreateWorkspaceController? = nil) {
        let presentation = coordinator.workspaceViewControllerForTesting
        let tabBar = presentation.tabBarViewController
        let window = coordinator.activeWindowForTesting
        let sheet = (editor ?? coordinator.createWorkspaceControllerForTesting)?.window
        model = coordinator.workspaceStoreForTesting
        persistenceModel = coordinator.workspaceStoreForPersistence
        selectionGeneration = coordinator.selectionGenerationForTesting
        displayedTabs = tabBar.displayedTabsForTesting
        displayedTitles = tabBar.displayedTitlesForTesting
        selectedTabs = tabBar.selectedTabIDsInOrderForTesting
        orderedTabs = tabBar.orderedTabIDsForTesting
        activeTab = tabBar.activeTabIDForTesting
        editedTab = tabBar.editedTabIDForTesting
        nativeSelection = tabBar.collectionViewForTesting.selectionIndexPaths
        reloadGeneration = tabBar.dataReloadGenerationForTesting
        dragGeneration = tabBar.dragSessionGenerationForTesting
        refreshCount = coordinator.refreshWorkspacePresentationInvocationCountForTesting
        statusRefreshCount = coordinator.refreshWorkspaceStatusesInvocationCountForTesting
        hosted = presentation.hostedSurfaceIdentifiersForTesting
        rendered = presentation.renderedSurfaceIdentifiersForTesting
        splitHost = presentation.splitHostingControllerIdentifierForTesting
        let liveSurfaces = coordinator.surfaceIDsForTesting.compactMap {
            coordinator.surfaceForTesting(id: $0)
        }
        surfaces = Dictionary(
            uniqueKeysWithValues: liveSurfaces.map {
                ($0.paneID, ObjectIdentifier($0))
            })
        surfaceHosts = Dictionary(
            uniqueKeysWithValues: liveSurfaces.compactMap { surface in
                surface.superview.map { (surface.paneID, ObjectIdentifier($0)) }
            })
        surfaceWindows = Dictionary(
            uniqueKeysWithValues: liveSurfaces.compactMap { surface in
                surface.window.map { (surface.paneID, ObjectIdentifier($0)) }
            })
        responder = window?.firstResponder.map(ObjectIdentifier.init)
        windowVisible = window?.isVisible == true
        ownedEditor = coordinator.createWorkspaceControllerForTesting.map(ObjectIdentifier.init)
        attachedSheet = window?.attachedSheet.map(ObjectIdentifier.init)
        sheetParent = sheet?.sheetParent.map(ObjectIdentifier.init)
        sheetResponder = sheet?.firstResponder.map(ObjectIdentifier.init)
        sheetVisible = sheet?.isVisible == true
    }
}

// WHY: Selector observation keeps AppKit delivery on the main actor without capturing
// non-Sendable state in NotificationCenter's @Sendable block observer API.
@MainActor
private final class NativeQuakeKeyObserver: NSObject {
    var action: (@MainActor () -> Void)?
    private(set) var callbackCount = 0
    private(set) var isInCallback = false

    init(window: NSWindow) {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func didBecomeKey(_ notification: Notification) {
        guard let action else { return }
        self.action = nil
        callbackCount += 1
        isInCallback = true
        defer { isInCallback = false }
        action()
    }

    func stop() {
        action = nil
        NotificationCenter.default.removeObserver(self)
    }

    isolated deinit { stop() }
}

@MainActor
private final class RetirementRemovalView: NSView {
    var didRemove: (@MainActor () -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { didRemove?() }
    }
}

@MainActor
private final class NativeModeTransitionState {
    weak var coordinator: WindowCoordinator?
    var isReturning = false
    var frames: [NormalWindowFrame] = []
    var nativeFrames: [NSRect] = []
    var modes: [PresentationMode] = []
    var workspaces: [WorkspaceStore] = []
    var errors: [Error] = []
    var freezeCount = 0
    var freezeChangedPresentation = false
    var modeAtFreeze: PresentationMode?
    var normalFrameAtFreeze: NSRect?

    func freeze() {
        guard let coordinator else { return }
        freezeCount += 1
        let before = NativeCallbackPresentationSnapshot(coordinator)
        modeAtFreeze = coordinator.presentationMode
        normalFrameAtFreeze = coordinator.windowForTesting?.frame
        coordinator.freezeTerminalControlForApplicationTermination()
        freezeChangedPresentation = before != NativeCallbackPresentationSnapshot(coordinator)
    }
}

@MainActor
private final class NativeRenameDeletionState {
    var confirmations: [WorkspaceDeletionConfirmation] = []
    var completions: [@MainActor (Bool) -> Void] = []
    var isResolvingDeletion = false
    var isInRenameCallback = false
    var persistedRenameDuringDeletion = false
}

@MainActor
private final class NativeCallbackFreezeState {
    weak var coordinator: WindowCoordinator?
    var freezeOnCommit = false
    var isCompletingAnimation = false
    var snapshots: [WorkspaceStore] = []
    var presentationAtFreeze: NativeCallbackPresentationSnapshot?
    var freezeChangedPresentation = false
    var dismissCount = 0
    var renameCommits: [String] = []
    var renameEditingStates: [Bool] = []

    func record(_ store: WorkspaceStore) {
        snapshots.append(store)
        guard freezeOnCommit else { return }
        freeze()
    }

    func freeze() {
        guard let coordinator else { return }
        let before = NativeCallbackPresentationSnapshot(coordinator)
        coordinator.freezeTerminalControlForApplicationTermination()
        let after = NativeCallbackPresentationSnapshot(coordinator)
        freezeChangedPresentation = before != after
        presentationAtFreeze = after
    }
}

// WHY: Match WorkspacePresentationTests' private local-drag fixture; never use the general pasteboard.
private final class CoordinatorTabDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    @MainActor
    init(source: AnyObject?, payload: String?) {
        draggingSource = source
        draggingPasteboard = NSPasteboard(
            name: NSPasteboard.Name("QuickTTYTests.CoordinatorTabDraggingInfo.\(UUID().uuidString)")
        )
        super.init()
        draggingPasteboard.clearContents()
        if let payload {
            draggingPasteboard.setString(payload, forType: .quickTTYTab)
        }
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@MainActor
private final class WorkspacePersistenceRecorder {
    var snapshots: [WorkspaceStore] = []

    func reset() {
        snapshots = []
    }

    func expectSingleFinalSnapshot(from coordinator: WindowCoordinator) {
        #expect(snapshots == [coordinator.workspaceStoreForPersistence])
    }
}
