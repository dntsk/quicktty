import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import QuickTTY

extension GhosttyBridgeTests {
    @Test
    func managedFactoryUsesExactHelperPathAndIsolatesLegacyConfigOverrides() async throws {
        let fixture = try SurfaceTestConfig(
            contents: """
                command = /bin/cat
                initial-command = /bin/sh -c 'printf LEGACY-INITIAL'
                shell-integration = bash
                abnormal-command-exit-runtime = 0
                """)
        defer { fixture.remove() }
        let helper = ApplicationEnvironment.bundledAgentHelperURL(in: Bundle.main)
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let copy = fixture.directoryURL.resolvingSymlinksInPath().appending(path: "helper's copy 猫")
        try FileManager.default.copyItem(at: helper, to: copy)
        let launch = try TerminalControlLaunch(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                /bin/stty -icanon -echo min 0 time 1
                value=$(/bin/dd bs=1 count=1 2>/dev/null)
                [ -z "$value" ] || exit 88
                printf 'MANAGED-EXACT-ARGV'
                exit 7
                """,
            ],
            cwd: fixture.directoryURL.resolvingSymlinksInPath().path)
        let configuration = try TerminalTaskLaunchConfiguration(
            launch: launch, bundledHelperPath: copy.path)
        // WHY: Both launch modes must avoid inherited shell hooks in this owned fixture.
        let environment = configuration.environment.merging([
            "ENV": "/dev/null", "BASH_ENV": "/dev/null", "INPUTRC": "/dev/null",
            "HISTFILE": "/dev/null", "PROMPT_COMMAND": "",
        ]) { _, value in value }
        let bridge = try GhosttyBridge(configURL: fixture.url)
        defer { bridge.shutdown() }
        #expect(bridge.diagnostics.isEmpty)
        var exits: [GhosttyProcessExited] = []
        bridge.surfaceProcessExitedHandler = { _, event in exits.append(event) }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                command: "exec /usr/bin/false", managedHelperPath: configuration.helperPath,
                environment: environment, initialInput: "unexpected\n",
                waitAfterCommand: false))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while exits.isEmpty || bridge.outputState(id: surface.paneID) == .pending {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SurfaceTestError.timeout }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
        }
        #expect(exits.count == 1 && exits.first?.exitCode == 7)
        #expect(surface.isReady)
        #expect(bridge.outputState(id: surface.paneID) == .complete)
        let rendered = try bridge.readRenderedText(id: surface.paneID, maximumUTF8Bytes: 1024)
        #expect(rendered.text.contains("MANAGED-EXACT-ARGV"))
        #expect(!rendered.text.contains("LEGACY-INITIAL"))
        #expect(!rendered.text.contains("unexpected"))
        bridge.shutdown()

        // WHY: The same config and payload environment must retain legacy first-command behavior.
        let legacy = try GhosttyBridge(configURL: fixture.url)
        defer { legacy.shutdown() }
        let normal = try legacy.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                environment: environment, waitAfterCommand: true))
        let legacyDeadline = clock.now.advanced(by: .seconds(5))
        while !normal.processExitedForTesting {
            try Task.checkCancellation()
            guard clock.now < legacyDeadline else { throw SurfaceTestError.timeout }
            try await clock.sleep(
                until: min(legacyDeadline, clock.now.advanced(by: .milliseconds(10))))
        }
        #expect(legacy.surfaceConfigurationForTesting(id: normal.paneID)?.managedHelperPath == nil)
        #expect(legacy.outputState(id: normal.paneID) == .failed)
        #expect(normal.isReady)
    }

    @Test
    func createsSurfaceWithExplicitCommandInHiddenWindow() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        embed(surface, in: window)

        #expect(surface.paneID == paneID)
        #expect(surface.isReady)
        #expect(surface.isActive)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(bridge.activeSurfaceCount == 1)
    }

    @Test
    func pwdChangesAreDeliveredToTheirOwningSurfaces() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial-first",
                command: "exec /bin/cat"
            )
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial-second",
                command: "exec /bin/cat"
            )
        )

        #expect(first.currentWorkingDirectory == "/tmp/initial-first")
        #expect(second.currentWorkingDirectory == "/tmp/initial-second")
        #expect(first.scheduleWorkingDirectoryChangeForTesting("/tmp/live-first"))
        #expect(second.scheduleWorkingDirectoryChangeForTesting("/tmp/live-second"))

        await Task.yield()

        #expect(first.currentWorkingDirectory == "/tmp/live-first")
        #expect(second.currentWorkingDirectory == "/tmp/live-second")
    }

    @Test
    func coalescedPwdChangesKeepTheFinalWorkingDirectory() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial",
                command: "exec /bin/cat"
            )
        )

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/first"))
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/second"))
        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/final"))
        #expect(surface.latestWorkingDirectoryForPersistence == "/tmp/final")
        #expect(
            bridge.latestWorkingDirectoriesForPersistence == [surface.paneID: "/tmp/final"]
        )
        await Task.yield()

        #expect(surface.currentWorkingDirectory == "/tmp/final")
    }

    @Test
    func queuedPwdChangeIsIgnoredAfterSurfaceClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial",
                command: "exec /bin/cat"
            )
        )

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        bridge.closeSurface(id: paneID)
        await Task.yield()

        #expect(surface.currentWorkingDirectory == "/tmp/initial")
    }

    @Test
    func titleCallbacksCopyStrictUTF8AndInvokeTypedHandlersOnce() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [(PaneID, String)] = []
        var tabTitles: [(PaneID, String)] = []
        var promptPaneIDs: [PaneID] = []
        var titleAtObservation: String?
        bridge.surfaceTitleHandler = { paneID, title in
            surfaceTitles.append((paneID, title))
            titleAtObservation = surface.currentTitle
        }
        bridge.surfaceTabTitleHandler = { paneID, title in
            tabTitles.append((paneID, title))
        }
        bridge.surfaceTabTitlePromptHandler = { paneID in
            promptPaneIDs.append(paneID)
        }

        #expect(surface.currentTitle == nil)
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("build 🚀".utf8),
                overwritePayloadAfterCallback: true
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("manual 🧭".utf8),
                overwritePayloadAfterCallback: true
            )
        )
        #expect(surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: []))
        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "build 🚀")
        #expect(titleAtObservation == "build 🚀")
        #expect(surfaceTitles.count == 1)
        #expect(surfaceTitles.first?.0 == surface.paneID)
        #expect(surfaceTitles.first?.1 == "build 🚀")
        #expect(tabTitles.count == 2)
        #expect(tabTitles.map(\.0) == [surface.paneID, surface.paneID])
        #expect(tabTitles.map(\.1) == ["manual 🧭", ""])
        #expect(promptPaneIDs == [surface.paneID])
    }

    @Test
    func titleCallbacksRejectNullInvalidUTF8AndUnsupportedTargets() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(!surface.scheduleTitleCallbackForTesting(.surfaceTitle, bytes: nil))
        #expect(!surface.scheduleTitleCallbackForTesting(.surfaceTitle, bytes: [0xFF]))
        #expect(!surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: nil))
        #expect(!surface.scheduleTitleCallbackForTesting(.tabTitle, bytes: [0xFF]))
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("ignored".utf8),
                target: .app
            )
        )
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: [],
                target: .unknown
            )
        )
        #expect(!surface.schedulePromptTitleCallbackForTesting(.surface))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.tab, target: .app))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.tab, target: .unknown))
        #expect(!surface.schedulePromptTitleCallbackForTesting(.unknown))
        #expect(surface.currentTitle == nil)
    }

    @Test
    func automaticTitleCallbacksCoalesceToLatestValue() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var deliveredTitles: [String] = []
        bridge.surfaceTitleHandler = { _, title in
            deliveredTitles.append(title)
        }

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("first".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("second".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("final 🟢".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == "final 🟢")
        #expect(deliveredTitles == ["final 🟢"])
    }

    @Test
    func queuedOldTitleEventsDoNotReachSamePaneIDReplacement() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let oldSurface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [(PaneID, String)] = []
        var tabTitles: [(PaneID, String)] = []
        var promptPaneIDs: [PaneID] = []
        bridge.surfaceTitleHandler = { surfaceTitles.append(($0, $1)) }
        bridge.surfaceTabTitleHandler = { tabTitles.append(($0, $1)) }
        bridge.surfaceTabTitlePromptHandler = { promptPaneIDs.append($0) }

        #expect(
            oldSurface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("stale automatic".utf8)
            )
        )
        #expect(
            oldSurface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("stale override".utf8)
            )
        )
        #expect(oldSurface.schedulePromptTitleCallbackForTesting(.tab))
        bridge.closeSurface(id: paneID)
        let replacement = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        await Task.yield()
        await Task.yield()

        #expect(replacement.currentTitle == nil)
        #expect(surfaceTitles.isEmpty)
        #expect(tabTitles.isEmpty)
        #expect(promptPaneIDs.isEmpty)

        #expect(
            replacement.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("replacement title".utf8)
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(replacement.currentTitle == "replacement title")
        #expect(surfaceTitles.count == 1)
        #expect(surfaceTitles.first?.0 == paneID)
        #expect(surfaceTitles.first?.1 == "replacement title")
        #expect(tabTitles.isEmpty)
        #expect(promptPaneIDs.isEmpty)
    }

    @Test
    func inactiveSurfaceCallbackContextRejectsTitleEvents() {
        let context = SurfaceCallbackContext(paneID: PaneID()) { _, _ in }

        context.deactivateAndDrain()

        #expect(!context.scheduleTitleChange("ignored"))
        #expect(!context.scheduleTabTitleChange(""))
        #expect(!context.scheduleTabTitlePrompt())
    }

    @Test
    func queuedTitleEventsAreDroppedAfterSurfaceTeardown() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var surfaceTitles: [String] = []
        var tabTitles: [String] = []
        var promptCount = 0
        bridge.surfaceTitleHandler = { _, title in
            surfaceTitles.append(title)
        }
        bridge.surfaceTabTitleHandler = { _, title in
            tabTitles.append(title)
        }
        bridge.surfaceTabTitlePromptHandler = { _ in
            promptCount += 1
        }

        #expect(
            surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("stale".utf8)
            )
        )
        #expect(
            surface.scheduleTitleCallbackForTesting(
                .tabTitle,
                bytes: Array("stale override".utf8)
            )
        )
        #expect(surface.schedulePromptTitleCallbackForTesting(.tab))
        bridge.closeSurface(id: surface.paneID)
        await Task.yield()
        await Task.yield()

        #expect(surface.currentTitle == nil)
        #expect(surfaceTitles.isEmpty)
        #expect(tabTitles.isEmpty)
        #expect(promptCount == 0)
        #expect(
            !surface.scheduleTitleCallbackForTesting(
                .surfaceTitle,
                bytes: Array("inactive".utf8)
            )
        )
    }

    @Test
    func scrollbarCallbacksCopyAndCoalesceLatestState() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 10, len: 20))
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 20))
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 30, len: 20))

        #expect(surface.scrollbarDeliveryCountForTesting == 0)
        await Task.yield()
        await Task.yield()

        #expect(
            surface.scrollbarStateForTesting
                == GhosttyScrollbarState(total: 100, offset: 30, len: 20)
        )
        #expect(surface.scrollbarDeliveryCountForTesting == 1)
    }

    @Test
    func scrollbarCallbackRejectsNonSurfaceTargets() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(
            !surface.scheduleScrollbarCallbackForTesting(
                total: 100,
                offset: 10,
                len: 20,
                target: .app
            )
        )
        #expect(
            !surface.scheduleScrollbarCallbackForTesting(
                total: 100,
                offset: 10,
                len: 20,
                target: .unknown
            )
        )
    }

    @Test
    func queuedScrollbarCallbackDoesNotReachSamePaneIDReplacement() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let oldSurface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(oldSurface.scheduleScrollbarCallbackForTesting(total: 100, offset: 10, len: 20))
        bridge.closeSurface(id: paneID)
        let replacement = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        await Task.yield()
        await Task.yield()

        #expect(oldSurface.scrollbarStateForTesting == nil)
        #expect(replacement.scrollbarStateForTesting == nil)
    }

    @Test
    func nonBottomScrollbarOffsetSurvivesRehostAndClampsToCurrentMaximum() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)

        embed(surface, in: window)
        #expect(surface.bindingActionObservationsForTesting.first == "scroll_to_row:20")
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 35, offset: 0, len: 30))
        await Task.yield()
        await Task.yield()

        #expect(surface.bindingActionObservationsForTesting.last == "scroll_to_row:5")
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 35, offset: 5, len: 30))
        await Task.yield()
        await Task.yield()
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)
    }

    @Test
    func bottomScrollbarStateDoesNotScheduleViewportRestore() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 90, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        embed(surface, in: window)

        #expect(surface.bindingActionObservationsForTesting.isEmpty)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)
    }

    @Test
    func manualViewportActionClearsPendingRestore() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)

        surface.paste(nil)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)

        embed(surface, in: window)
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)
        surface.pasteSelection(nil)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)

        embed(surface, in: window)
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)
        _ = surface.performTerminalShortcutAction(.clearScreen)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)

        embed(surface, in: window)
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)
        _ = surface.performTerminalShortcutAction(.previousPrompt)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)

        embed(surface, in: window)
        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        await Task.yield()
        await Task.yield()
        surface.removeFromSuperview()
        #expect(surface.pendingViewportRestoreOffsetForTesting == 20)
        _ = surface.performTerminalShortcutAction(.nextPrompt)
        #expect(surface.pendingViewportRestoreOffsetForTesting == nil)

        embed(surface, in: window)
        #expect(surface.bindingActionObservationsForTesting.isEmpty)
    }

    @Test
    func queuedScrollbarCallbackIsDroppedAfterSurfaceClose() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 20, len: 10))
        bridge.closeSurface(id: surface.paneID)
        await Task.yield()
        await Task.yield()

        #expect(surface.scrollbarStateForTesting == nil)
        #expect(!surface.scheduleScrollbarCallbackForTesting(total: 100, offset: 30, len: 10))
    }

    @Test(arguments: [false, true])
    func processExitCallbackCopiesPayloadWithoutClaimingLegacyUIHandling(hasHandler: Bool)
        async throws
    {
        var actions: [GhosttyRuntimeAction] = []
        let handler: GhosttyBridge.RuntimeActionHandler?
        if hasHandler {
            handler = { actions.append($0) }
        } else {
            handler = nil
        }
        let bridge = try GhosttyBridge(runtimeActionHandler: handler)
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat"))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat"))
        var panes: [PaneID] = []
        var exits: [GhosttyProcessExited] = []
        var commands: [GhosttyCommandFinished] = []
        bridge.surfaceProcessExitedHandler = { pane, process in
            #expect(Thread.isMainThread)
            panes.append(pane)
            exits.append(process)
        }
        bridge.surfaceCommandFinishedHandler = { _, command in commands.append(command) }
        let cases: [(UInt32, UInt8?)] = [
            (0, 0), (7, 7), (128 + 15, 143), (255, 255), (256, nil), (.max, nil),
        ]
        // WHY: Inject C actions to test Swift routing, not to claim a native process actually exited.
        for (code, _) in cases {
            #expect(
                first.scheduleProcessExitedCallbackForTesting(
                    exitCode: code, runtimeMilliseconds: .max) == hasHandler)
        }
        #expect(
            second.scheduleCommandFinishedCallbackForTesting(
                exitCode: 7, durationNanoseconds: 42))
        #expect(exits.isEmpty && commands.isEmpty)
        await Task.yield()
        await Task.yield()
        #expect(
            exits
                == cases.map {
                    GhosttyProcessExited(exitCode: $0.1, runtimeMilliseconds: .max)
                })
        #expect(panes == Array(repeating: first.paneID, count: cases.count))
        #expect(commands == [GhosttyCommandFinished(exitCode: 7, durationNanoseconds: 42)])
        #expect(actions.filter { $0 == .showChildExited }.count == (hasHandler ? cases.count : 0))
        #expect(first.isReady && second.isReady)

        for target in [GhosttyActivityCallbackTargetForTesting.app, .unknown] {
            #expect(
                first.scheduleProcessExitedCallbackForTesting(
                    exitCode: 0, runtimeMilliseconds: 1, target: target) == hasHandler)
        }
        await Task.yield()
        await Task.yield()
        #expect(exits.count == cases.count)
        #expect(
            actions.filter { $0 == .showChildExited }.count
                == (hasHandler ? cases.count + 2 : 0))
    }

    @Test
    func processExitContextDeliversOnMainActorAndDropsRemainingBatchAfterInvalidation() async throws
    {
        let paneID = PaneID()
        let process = GhosttyProcessExited(exitCode: 7, runtimeMilliseconds: 123)
        do {
            let (deliveries, continuation) = AsyncStream.makeStream(of: GhosttyProcessExited.self)
            defer { continuation.finish() }
            let workerContext = SurfaceCallbackContext(paneID: paneID) { pane, event in
                guard case .processExited(let process) = event else { return }
                #expect(Thread.isMainThread)
                #expect(pane == paneID)
                continuation.yield(process)
            }
            defer { workerContext.deactivateAndDrain() }
            // WHY: Await actual sink delivery, not just completion of worker scheduling.
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                #expect(workerContext.scheduleProcessExited(process))
            }
            let delivered = try await firstValues(
                from: deliveries, count: 1, timeout: .seconds(2))
            #expect(delivered == [process])
            workerContext.deactivateAndDrain()
            #expect(!workerContext.scheduleProcessExited(process))
        }

        var events: [GhosttyProcessExited] = []
        var context: SurfaceCallbackContext?
        let (deliveries, continuation) = AsyncStream.makeStream(of: GhosttyProcessExited.self)
        defer { continuation.finish() }
        context = SurfaceCallbackContext(paneID: paneID) { pane, event in
            guard case .processExited(let process) = event else { return }
            #expect(Thread.isMainThread)
            #expect(pane == paneID)
            events.append(process)
            context?.deactivateAndDrain()
            continuation.yield(process)
        }
        let active = try #require(context)
        defer {
            active.deactivateAndDrain()
            context = nil
        }
        // WHY: No suspension on the main actor until both events are in the fresh context's batch.
        #expect(active.scheduleProcessExited(process))
        #expect(active.scheduleProcessExited(process))
        #expect(events.isEmpty)
        let delivered = try await firstValues(
            from: deliveries, count: 1, timeout: .seconds(2))
        #expect(delivered == [process])
        #expect(events == [process])
        #expect(!active.scheduleProcessExited(process))
        context = nil
    }

    @Test
    func queuedProcessExitCannotReachReplacementOrSurviveBridgeShutdown() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let pane = PaneID()
        let old = try bridge.makeSurface(
            id: pane, configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat"))
        var events: [GhosttyProcessExited] = []
        bridge.surfaceProcessExitedHandler = { _, process in events.append(process) }
        #expect(!old.scheduleProcessExitedCallbackForTesting(exitCode: 0, runtimeMilliseconds: 1))
        bridge.closeSurface(id: pane)
        let replacement = try bridge.makeSurface(
            id: pane, configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat"))
        await Task.yield()
        await Task.yield()
        #expect(events.isEmpty)
        #expect(!old.scheduleProcessExitedCallbackForTesting(exitCode: 0, runtimeMilliseconds: 2))
        #expect(
            !replacement.scheduleProcessExitedCallbackForTesting(
                exitCode: 7, runtimeMilliseconds: 3))
        await Task.yield()
        await Task.yield()
        #expect(events == [GhosttyProcessExited(exitCode: 7, runtimeMilliseconds: 3)])
        #expect(
            !replacement.scheduleProcessExitedCallbackForTesting(
                exitCode: 0, runtimeMilliseconds: 4))
        bridge.shutdown()
        await Task.yield()
        await Task.yield()
        #expect(events == [GhosttyProcessExited(exitCode: 7, runtimeMilliseconds: 3)])
        #expect(
            !replacement.scheduleProcessExitedCallbackForTesting(
                exitCode: 0, runtimeMilliseconds: 5))
    }

    @Test
    func progressAndCommandCallbacksConvertExactPinnedPayloads() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var progressReports: [GhosttyProgressReport] = []
        var commandFinishedEvents: [GhosttyCommandFinished] = []
        bridge.surfaceProgressHandler = { _, report in
            progressReports.append(report)
        }
        bridge.surfaceCommandFinishedHandler = { _, command in
            commandFinishedEvents.append(command)
        }

        let progressCases: [(UInt32, Int8, GhosttyProgressReport)] = [
            (0, -1, GhosttyProgressReport(state: .remove, progress: nil)),
            (1, 42, GhosttyProgressReport(state: .set, progress: 42)),
            (2, 100, GhosttyProgressReport(state: .error, progress: 100)),
            (3, -1, GhosttyProgressReport(state: .indeterminate, progress: nil)),
            (4, 0, GhosttyProgressReport(state: .pause, progress: 0)),
        ]
        for (stateRawValue, progress, _) in progressCases {
            #expect(
                surface.scheduleProgressCallbackForTesting(
                    stateRawValue: stateRawValue,
                    progress: progress
                )
            )
        }
        #expect(
            surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: -1,
                durationNanoseconds: 123
            )
        )
        #expect(
            surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 255,
                durationNanoseconds: UInt64.max
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(progressReports == progressCases.map(\.2))
        #expect(
            commandFinishedEvents == [
                GhosttyCommandFinished(exitCode: nil, durationNanoseconds: 123),
                GhosttyCommandFinished(exitCode: 255, durationNanoseconds: UInt64.max),
            ]
        )
    }

    @Test
    func progressAndCommandCallbacksRejectInvalidPayloadsAndTargets() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(!surface.scheduleProgressCallbackForTesting(stateRawValue: 99, progress: 50))
        #expect(!surface.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: -2))
        #expect(!surface.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 101))
        #expect(
            !surface.scheduleProgressCallbackForTesting(
                stateRawValue: 1,
                progress: 50,
                target: .app
            )
        )
        #expect(
            !surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: -2,
                durationNanoseconds: 1
            )
        )
        #expect(
            !surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 256,
                durationNanoseconds: 1
            )
        )
        #expect(
            !surface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 0,
                durationNanoseconds: 1,
                target: .unknown
            )
        )
    }

    @Test
    func activityCallbacksRouteByPaneAndPreserveArrivalOrder() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var events: [ActivityCallbackObservation] = []
        bridge.surfaceProgressHandler = { paneID, report in
            events.append(.progress(paneID, report))
        }
        bridge.surfaceCommandFinishedHandler = { paneID, command in
            events.append(.commandFinished(paneID, command))
        }

        #expect(first.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 10))
        #expect(first.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 20))
        #expect(first.scheduleProgressCallbackForTesting(stateRawValue: 0, progress: -1))
        #expect(
            first.scheduleCommandFinishedCallbackForTesting(
                exitCode: 0,
                durationNanoseconds: 10
            )
        )
        #expect(
            first.scheduleCommandFinishedCallbackForTesting(
                exitCode: 1,
                durationNanoseconds: 20
            )
        )
        #expect(second.scheduleProgressCallbackForTesting(stateRawValue: 4, progress: 30))
        await Task.yield()
        await Task.yield()

        #expect(
            events == [
                .progress(first.paneID, GhosttyProgressReport(state: .set, progress: 10)),
                .progress(first.paneID, GhosttyProgressReport(state: .set, progress: 20)),
                .progress(first.paneID, GhosttyProgressReport(state: .remove, progress: nil)),
                .commandFinished(
                    first.paneID,
                    GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 10)
                ),
                .commandFinished(
                    first.paneID,
                    GhosttyCommandFinished(exitCode: 1, durationNanoseconds: 20)
                ),
                .progress(second.paneID, GhosttyProgressReport(state: .pause, progress: 30)),
            ]
        )
    }

    @Test
    func queuedActivityCallbacksAreDroppedAfterCloseAndSamePaneReplacement() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let oldSurface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        var events: [ActivityCallbackObservation] = []
        bridge.surfaceProgressHandler = { events.append(.progress($0, $1)) }
        bridge.surfaceCommandFinishedHandler = { events.append(.commandFinished($0, $1)) }

        #expect(oldSurface.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 1))
        #expect(
            oldSurface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 0,
                durationNanoseconds: 1
            )
        )
        bridge.closeSurface(id: paneID)
        let replacement = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        await Task.yield()
        await Task.yield()

        #expect(events.isEmpty)
        #expect(!oldSurface.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 2))
        #expect(
            !oldSurface.scheduleCommandFinishedCallbackForTesting(
                exitCode: 0,
                durationNanoseconds: 2
            )
        )
        #expect(replacement.scheduleProgressCallbackForTesting(stateRawValue: 1, progress: 3))
        await Task.yield()
        await Task.yield()

        #expect(
            events == [
                .progress(paneID, GhosttyProgressReport(state: .set, progress: 3))
            ]
        )
    }

    @Test
    func inactiveSurfaceCallbackContextRejectsActivityEvents() {
        let context = SurfaceCallbackContext(paneID: PaneID()) { _, _ in }
        context.deactivateAndDrain()

        #expect(
            !context.scheduleProgressReport(
                GhosttyProgressReport(state: .set, progress: 50)
            )
        )
        #expect(
            !context.scheduleCommandFinished(
                GhosttyCommandFinished(exitCode: 0, durationNanoseconds: 1)
            )
        )
    }

    @Test
    func resizeUpdatesRealCoreSurfaceMetricsInBackingPixels() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        surface.setFrameSize(NSSize(width: 360, height: 240))
        let first = try #require(surface.sizeSnapshotForTesting)
        let firstExpected = surface.convertToBacking(surface.bounds.size)

        #expect(first.widthPixels == UInt32(firstExpected.width.rounded(.down)))
        #expect(first.heightPixels == UInt32(firstExpected.height.rounded(.down)))
        #expect(first.columns > 0)
        #expect(first.rows > 0)
        #expect(first.cellWidthPixels > 0)
        #expect(first.cellHeightPixels > 0)

        let secondRequestedBackingSize = NSSize(width: 640, height: 420)
        surface.setFrameSize(surface.convertFromBacking(secondRequestedBackingSize))
        let second = try #require(surface.sizeSnapshotForTesting)

        #expect(second.widthPixels == UInt32(secondRequestedBackingSize.width))
        #expect(second.heightPixels == UInt32(secondRequestedBackingSize.height))
        #expect(second.widthPixels != first.widthPixels)
        #expect(second.heightPixels != first.heightPixels)
        #expect(second.columns != first.columns)
        #expect(second.rows != first.rows)
    }

    @Test
    func conservativeMinimumSurfaceSizeFallsBackForInvalidOrUnrepresentableMetrics() {
        let fallback = (widthPixels: UInt32(40), heightPixels: UInt32(32))

        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(cellWidth: 0, cellHeight: 0)
            ) == fallback
        )
        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(
                    columns: .max,
                    rows: .max,
                    widthPixels: .max,
                    heightPixels: .max,
                    cellWidth: .max,
                    cellHeight: .max
                )
            ) == fallback
        )
        #expect(
            conservativeMinimumSurfaceSize(
                for: syntheticSurfaceSize(
                    columns: 1,
                    rows: 1,
                    widthPixels: 0,
                    heightPixels: 0,
                    cellWidth: 1,
                    cellHeight: 1
                )
            ) == fallback
        )
    }

    @Test
    func transientTinySizesPreserveTheLastValidCoreSize() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        defer { window.orderOut(nil) }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        surface.setFrameSize(NSSize(width: 800, height: 600))
        let stableSize = try #require(surface.sizeSnapshotForTesting)
        let validRequestCount = surface.sizeRequestObservationsForTesting.count
        let minimumSize = conservativeMinimumSurfaceSize(
            for: syntheticSurfaceSize(
                columns: stableSize.columns,
                rows: stableSize.rows,
                widthPixels: stableSize.widthPixels,
                heightPixels: stableSize.heightPixels,
                cellWidth: stableSize.cellWidthPixels,
                cellHeight: stableSize.cellHeightPixels
            )
        )

        surface.setFrameSize(.zero)
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(surface.convertFromBacking(NSSize(width: 1, height: 1)))
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(
            surface.convertFromBacking(
                NSSize(
                    width: CGFloat(minimumSize.widthPixels - 1),
                    height: CGFloat(minimumSize.heightPixels)
                )
            )
        )
        #expect(surface.sizeSnapshotForTesting == stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount)

        surface.setFrameSize(
            surface.convertFromBacking(
                NSSize(
                    width: CGFloat(minimumSize.widthPixels),
                    height: CGFloat(minimumSize.heightPixels)
                )
            )
        )
        let thresholdSize = try #require(surface.sizeSnapshotForTesting)
        let thresholdRequest = try #require(surface.sizeRequestObservationsForTesting.last)
        #expect(thresholdRequest.requestedWidthPixels == minimumSize.widthPixels)
        #expect(thresholdRequest.requestedHeightPixels == minimumSize.heightPixels)
        #expect(thresholdSize.columns >= 5)
        #expect(thresholdSize.rows >= 2)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount + 1)

        surface.setFrameSize(NSSize(width: 640, height: 420))
        let restoredSize = try #require(surface.sizeSnapshotForTesting)
        #expect(restoredSize != stableSize)
        #expect(surface.sizeRequestObservationsForTesting.count == validRequestCount + 2)
        #expect(
            surface.sizeRequestObservationsForTesting.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
    }

    @Test
    func sizeRequestObservationsKeepOnlyTheLatest256AcceptedResizes() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        defer { window.orderOut(nil) }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        let initialSurfaceIDs = bridge.activeSurfaceIDs
        let requestedBackingSizes = (0..<300).map {
            NSSize(width: CGFloat(800 + $0), height: CGFloat(600 + $0))
        }
        for requestedBackingSize in requestedBackingSizes {
            surface.setFrameSize(surface.convertFromBacking(requestedBackingSize))
        }

        let observations = surface.sizeRequestObservationsForTesting
        #expect(bridge.activeSurfaceCount == 1)
        #expect(bridge.activeSurfaceIDs == initialSurfaceIDs)
        #expect(observations.count == 256)
        let expectedRequests = requestedBackingSizes.suffix(256).map {
            (width: UInt32($0.width), height: UInt32($0.height))
        }
        #expect(
            zip(observations, expectedRequests).allSatisfy {
                $0.requestedWidthPixels == $1.width && $0.requestedHeightPixels == $1.height
            }
        )
        #expect(
            observations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
    }

    @Test
    func realPTYDeliversOrderedIndeterminateAndRemoveProgressActions() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let window = makeHiddenWindow()
        defer { window.orderOut(nil) }
        let (reports, continuation) = AsyncStream.makeStream(of: GhosttyProgressReport.self)
        defer { continuation.finish() }
        bridge.surfaceProgressHandler = { reportedPaneID, report in
            guard reportedPaneID == paneID else { return }
            continuation.yield(report)
        }

        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                initialInput: "printf '\\033]9;4;3\\007\\033]9;4;0\\007'; exit\n"
            )
        )
        embed(surface, in: window)

        let delivered = try await firstValues(
            from: reports,
            count: 2,
            timeout: .seconds(10)
        )

        #expect(
            delivered == [
                GhosttyProgressReport(state: .indeterminate, progress: nil),
                GhosttyProgressReport(state: .remove, progress: nil),
            ]
        )
    }

    @Test
    func runtimeActionFromPTYAndProcessExitCloseSurface() async throws {
        let fixture = try SurfaceTestConfig()
        defer { fixture.remove() }
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge(configURL: fixture.url)
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let window = makeHiddenWindow()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }

        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                initialInput:
                    "printf '\\033]2;quicktty-io-action\\007'; exec /bin/sh -lc 'printf quicktty-ready'\n"
            )
        ) { paneID, processAlive in
            continuation.yield(SurfaceCloseEvent(paneID: paneID, processAlive: processAlive))
        }
        embed(surface, in: window)

        let event = try await firstEvent(from: events, timeout: .seconds(10))

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(!surface.isActive)
        #expect(!surface.isReady)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
    }

    @Test
    func liveProcessCloseRequestKeepsSurfaceUntilExplicitConfirmation() async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            let event = SurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            recorder.events.append(event)
            continuation.yield(event)
        }

        surface.scheduleRuntimeCloseForTesting(processAlive: true)
        let event = try await firstEvent(from: events, timeout: .seconds(2))

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: true))
        #expect(recorder.events == [event])
        #expect(surface.isReady)
        #expect(surface.isActive)
        #expect(bridge.activeSurfaceIDs == [paneID])
        #expect(bridge.activeSurfaceCount == 1)
        #expect(
            GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount + 1
        )

        bridge.closeSurface(id: paneID)

        #expect(!surface.isReady)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)

        surface.scheduleRuntimeCloseForTesting(processAlive: false)
        #expect(recorder.events == [event])
    }

    @Test
    func processExitOverridesQueuedLiveProcessCloseRequest() async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let (events, continuation) = AsyncStream.makeStream(of: SurfaceCloseEvent.self)
        defer { continuation.finish() }
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            let event = SurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            recorder.events.append(event)
            continuation.yield(event)
        }

        surface.scheduleRuntimeCloseForTesting(processAlive: true)
        surface.scheduleRuntimeCloseForTesting(processAlive: false)

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()

        #expect(event == SurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(recorder.events == event.map { [$0] })
        #expect(!surface.isReady)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
    }

    @Test
    func explicitCloseIsIdempotentAndDoesNotInvokeRuntimeHandler() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let recorder = SurfaceCloseRecorder()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        ) { paneID, processAlive in
            recorder.events.append(SurfaceCloseEvent(paneID: paneID, processAlive: processAlive))
        }

        bridge.closeSurface(id: paneID)
        bridge.closeSurface(id: paneID)

        #expect(recorder.events.isEmpty)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceCount == 0)
    }

    @Test
    func pwdChangeUpdatesSurfaceBeforeBridgeObserver() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(
                workingDirectory: "/tmp/initial",
                command: "exec /bin/cat"
            )
        )
        var observedPaneID: PaneID?
        var observedWorkingDirectory: String?
        var currentWorkingDirectoryAtObservation: String?
        var observationCount = 0
        bridge.surfaceWorkingDirectoryHandler = { id, workingDirectory in
            observedPaneID = id
            observedWorkingDirectory = workingDirectory
            currentWorkingDirectoryAtObservation = surface.currentWorkingDirectory
            observationCount += 1
        }

        #expect(surface.scheduleWorkingDirectoryChangeForTesting("/tmp/live"))
        #expect(surface.latestWorkingDirectoryForPersistence == "/tmp/live")
        #expect(bridge.latestWorkingDirectoriesForPersistence == [paneID: "/tmp/live"])
        #expect(observationCount == 0)
        await Task.yield()

        #expect(observedPaneID == paneID)
        #expect(observedWorkingDirectory == "/tmp/live")
        #expect(currentWorkingDirectoryAtObservation == "/tmp/live")
        #expect(surface.currentWorkingDirectory == "/tmp/live")
        #expect(observationCount == 1)
    }

    @Test
    func shutdownClosesSurfacesBeforeRuntimeAndRemainsIdempotent() throws {
        let initialAppContextCount = GhosttyBridge.callbackContextCountForTesting
        let initialSurfaceContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let bridge = try GhosttyBridge()
        let first = try bridge.makeSurface(
            id: PaneID(),
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            id: PaneID(),
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        bridge.shutdown()
        bridge.shutdown()

        #expect(!first.isActive)
        #expect(!second.isActive)
        #expect(bridge.activeSurfaceCount == 0)
        #expect(!bridge.isReady)
        #expect(GhosttyBridge.callbackContextCountForTesting == initialAppContextCount)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialSurfaceContextCount)
    }

    // MARK: - Search

    @Test
    func searchStartsAndEndsOnlyFromRuntimeCallbacks() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        #expect(surface.searchState == nil)
        #expect(surface.scheduleSearchCallbackForTesting(.started(nil)))
        await Task.yield()
        await Task.yield()

        #expect(surface.searchState?.needle == "")
        #expect(surface.searchOverlayInstalledForTesting)
        #expect(!surface.bindingActionObservationsForTesting.contains("start_search"))

        #expect(surface.scheduleSearchCallbackForTesting(.ended))
        await Task.yield()
        await Task.yield()

        #expect(surface.searchState == nil)
        #expect(!surface.searchOverlayInstalledForTesting)
        #expect(!surface.bindingActionObservationsForTesting.contains("end_search"))
    }

    @Test
    func repeatedStartPreservesStateUpdatesOnlyNonemptyNeedleAndRequestsFocus() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(
            surface.scheduleSearchCallbackForTesting(
                .started(Array("first".utf8)),
                overwritePayloadAfterCallback: true
            )
        )
        await Task.yield()
        await Task.yield()
        let state = try #require(surface.searchState)
        #expect(state.needle == "first")

        #expect(surface.scheduleSearchCallbackForTesting(.started([])))
        await Task.yield()
        await Task.yield()
        #expect(surface.searchState === state)
        #expect(state.needle == "first")

        #expect(surface.scheduleSearchCallbackForTesting(.started(Array("second".utf8))))
        await Task.yield()
        await Task.yield()
        #expect(surface.searchState === state)
        #expect(state.needle == "second")
        #expect(surface.searchFocusRequestsForTesting == 2)
    }

    @Test
    func searchCallbackRejectsInvalidUTF8AndNonSurfaceTargets() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(!surface.scheduleSearchCallbackForTesting(.started([0xFF])))
        #expect(
            !surface.scheduleSearchCallbackForTesting(
                .started(nil),
                target: .app
            )
        )
        #expect(surface.searchState == nil)
    }

    @Test
    func searchCountsUseOptionalZeroBasedCallbackValues() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        #expect(surface.scheduleSearchCallbackForTesting(.started(nil)))
        #expect(surface.scheduleSearchCallbackForTesting(.total(17)))
        #expect(surface.scheduleSearchCallbackForTesting(.selected(0)))
        await Task.yield()
        await Task.yield()

        #expect(surface.searchState?.total == 17)
        #expect(surface.searchState?.selected == 0)

        #expect(surface.scheduleSearchCallbackForTesting(.total(-1)))
        #expect(surface.scheduleSearchCallbackForTesting(.selected(-1)))
        await Task.yield()
        await Task.yield()

        #expect(surface.searchState?.total == nil)
        #expect(surface.searchState?.selected == nil)
    }

    @Test
    func nativeFindActionsAreSentWithoutPrecreatingOverlay() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        _ = surface.performTerminalShortcutAction(.find)
        _ = surface.performTerminalShortcutAction(.findNext)
        _ = surface.performTerminalShortcutAction(.findPrevious)

        #expect(surface.searchState == nil)
        #expect(
            surface.terminalActionObservationsForTesting.map(\.action)
                == [.find, .findNext, .findPrevious]
        )
    }

    @Test
    func endSearchWaitsForRuntimeCallbackBeforeRemovingLocalState() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)

        surface.endSearch()

        #expect(surface.searchState != nil)
        #expect(surface.bindingActionObservationsForTesting.last == "end_search")
        surface.processCallbackEvent(.searchEnded, confirmationHandler: nil)
        #expect(surface.searchState == nil)
    }

    @Test
    func acceptedUICloseFocusesTerminalAndWaitsForEndCallback() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        let otherResponder = NSTextField()
        window.contentView?.addSubview(otherResponder)
        #expect(window.makeFirstResponder(otherResponder))

        surface.closeSearchFromUIForTesting()

        #expect(window.firstResponder === surface)
        #expect(surface.searchState != nil)
        #expect(surface.bindingActionObservationsForTesting.last == "end_search")
    }

    @Test
    func initialDeferredSearchFocusIsCancelledAfterSearchEndsBeforeDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeHiddenWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embed(surface, in: window)

        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        surface.processCallbackEvent(.searchEnded, confirmationHandler: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(surface.searchState == nil)
        #expect(!surface.searchOverlayInstalledForTesting)
        #expect(!surface.isSearchFieldFocusedForTesting)
    }

    @Test
    func searchNeedleUsesPinnedImmediateAndDebouncedPipeline() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        let state = try #require(surface.searchState)
        #expect(surface.bindingActionObservationsForTesting.last == "search:")

        state.needle = "a"
        #expect(surface.bindingActionObservationsForTesting.last == "search:")
        state.needle = "abc"
        #expect(surface.bindingActionObservationsForTesting.last == "search:abc")

        state.needle = "xy"
        try await Task.sleep(for: .milliseconds(350))
        #expect(surface.bindingActionObservationsForTesting.last == "search:xy")
    }

    @Test
    func searchEndCancelsPendingShortNeedleDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        let state = try #require(surface.searchState)
        #expect(surface.bindingActionObservationsForTesting == ["search:"])

        state.needle = "xy"
        surface.processCallbackEvent(.searchEnded, confirmationHandler: nil)
        try await Task.sleep(for: .milliseconds(350))

        #expect(surface.bindingActionObservationsForTesting == ["search:"])
        #expect(surface.searchState == nil)
    }

    @Test
    func closeAndSamePaneReplacementCancelPendingOldNeedleDelivery() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let oldSurface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        oldSurface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        let oldState = try #require(oldSurface.searchState)
        oldState.needle = "x"

        bridge.closeSurface(id: paneID)
        let replacement = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        replacement.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        try await Task.sleep(for: .milliseconds(350))

        #expect(oldSurface.bindingActionObservationsForTesting == ["search:"])
        #expect(oldSurface.searchState == nil)
        #expect(replacement.bindingActionObservationsForTesting == ["search:"])
        #expect(replacement.searchState != nil)
    }

    @Test
    func closeRemovesSearchBeforeQueuedCallbacksCanDeliver() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        surface.processCallbackEvent(.searchStarted(nil), confirmationHandler: nil)
        #expect(surface.scheduleSearchCallbackForTesting(.total(8)))

        surface.close()
        await Task.yield()
        await Task.yield()

        #expect(surface.searchState == nil)
        #expect(!surface.searchOverlayInstalledForTesting)
        #expect(!surface.isActive)
    }

    @Test
    func automationTextAndKeysBypassManualRoutingAndBroadcast() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        bridge.inputTargetProvider = { _ in [other.paneID, source.paneID, other.paneID] }
        var manualPaneIDs: [PaneID] = []
        bridge.manualInputHandler = { paneID in
            manualPaneIDs.append(paneID)
        }
        let text = "A\0🙂"
        let keyCases:
            [(
                key: GhosttyAutomationKey, keyCode: UInt32, scalar: UInt32,
                modifiers: GhosttyInputModifiers
            )] = [
                (.enter, 36, 0x0D, []),
                (.tab, 48, 0x09, []),
                (.escape, 53, 0x1B, []),
                (.arrowUp, 126, UInt32(NSUpArrowFunctionKey), []),
                (.arrowDown, 125, UInt32(NSDownArrowFunctionKey), []),
                (.arrowLeft, 123, UInt32(NSLeftArrowFunctionKey), []),
                (.arrowRight, 124, UInt32(NSRightArrowFunctionKey), []),
                (.backspace, 51, 0x08, []),
                (.delete, 117, UInt32(NSDeleteFunctionKey), []),
                (.controlC, 8, "c".unicodeScalars.first!.value, [.control]),
                (.controlD, 2, "d".unicodeScalars.first!.value, [.control]),
            ]

        try bridge.sendAutomationText(id: source.paneID, text: text)
        for keyCase in keyCases {
            try bridge.sendAutomationKey(id: source.paneID, key: keyCase.key)
        }

        #expect(source.automationTextObservationsForTesting.map(\.bytes) == [Data(text.utf8)])
        #expect(
            source.automationKeyObservationsForTesting.map(\.key)
                == keyCases.map { $0.key }
        )
        for (observation, keyCase) in zip(source.automationKeyObservationsForTesting, keyCases) {
            #expect(observation.event.action == .press)
            #expect(observation.event.modifiers == keyCase.modifiers)
            #expect(observation.event.consumedModifiers.isEmpty)
            #expect(observation.event.keyCode == keyCase.keyCode)
            #expect(observation.event.unshiftedScalar == keyCase.scalar)
            #expect(observation.event.text == nil)
            #expect(!observation.event.composing)
        }
        #expect(source.terminalActionObservationsForTesting.isEmpty)
        #expect(source.clipboardObservationsForTesting.isEmpty)
        #expect(other.automationTextObservationsForTesting.isEmpty)
        #expect(other.automationKeyObservationsForTesting.isEmpty)
        #expect(other.terminalActionObservationsForTesting.isEmpty)
        #expect(other.clipboardObservationsForTesting.isEmpty)
        #expect(bridge.inputObservationsForTesting.isEmpty)
        #expect(manualPaneIDs.isEmpty)
    }

    @Test
    func automationTextValidationAndPasteCallbacksStayDistinct() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeHiddenWindow()
        embed(source, in: window)
        second.frame = source.frame
        third.frame = source.frame
        window.contentView?.addSubview(second)
        window.contentView?.addSubview(third)
        #expect(window.makeFirstResponder(source))
        bridge.inputTargetProvider = { _ in
            [third.paneID, source.paneID, second.paneID, third.paneID]
        }
        var callbackOrder: [PaneID] = []
        var callbackActionCounts: [Int] = []
        bridge.manualInputHandler = { paneID in
            callbackOrder.append(paneID)
            let count: Int
            switch paneID {
            case source.paneID:
                count = source.terminalActionObservationsForTesting.count
            case second.paneID:
                count = second.terminalActionObservationsForTesting.count
            case third.paneID:
                count = third.terminalActionObservationsForTesting.count
            default:
                count = -1
            }
            callbackActionCounts.append(count)
        }

        do {
            try bridge.sendAutomationText(id: source.paneID, text: "")
            Issue.record("Empty automation text was accepted")
        } catch let error as GhosttyBridgeError {
            #expect(error == .invalidAutomationText)
        } catch {
            Issue.record("Unexpected automation text error: \(error)")
        }

        do {
            try bridge.sendAutomationText(
                id: source.paneID,
                text: String(repeating: "a", count: TerminalControlProtocol.maximumTextSize + 1)
            )
            Issue.record("Oversized automation text was accepted")
        } catch let error as GhosttyBridgeError {
            #expect(error == .invalidAutomationText)
        } catch {
            Issue.record("Unexpected automation text error: \(error)")
        }

        source.paste(nil)

        #expect(callbackOrder == [third.paneID, source.paneID, second.paneID])
        #expect(callbackActionCounts == [0, 0, 0])
        #expect(source.terminalActionObservationsForTesting.map(\.action) == [.paste])
        #expect(second.terminalActionObservationsForTesting.map(\.action) == [.paste])
        #expect(third.terminalActionObservationsForTesting.map(\.action) == [.paste])
    }
}

private func syntheticSurfaceSize(
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    widthPixels: UInt32 = 800,
    heightPixels: UInt32 = 384,
    cellWidth: UInt32 = 10,
    cellHeight: UInt32 = 16
) -> ghostty_surface_size_s {
    ghostty_surface_size_s(
        columns: columns,
        rows: rows,
        width_px: widthPixels,
        height_px: heightPixels,
        cell_width_px: cellWidth,
        cell_height_px: cellHeight
    )
}

private enum ActivityCallbackObservation: Equatable {
    case progress(PaneID, GhosttyProgressReport)
    case commandFinished(PaneID, GhosttyCommandFinished)
}

private struct SurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

@MainActor
private final class SurfaceCloseRecorder {
    var events: [SurfaceCloseEvent] = []
}

private enum SurfaceTestError: Error {
    case eventStreamEnded
    case timeout
}

private func firstValues<Value: Sendable>(
    from stream: AsyncStream<Value>,
    count: Int,
    timeout: Duration
) async throws -> [Value] {
    try await withThrowingTaskGroup(of: [Value].self) { group in
        group.addTask {
            var values: [Value] = []
            for await value in stream {
                values.append(value)
                if values.count == count {
                    return values
                }
            }
            throw SurfaceTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SurfaceTestError.timeout
        }

        guard let values = try await group.next() else {
            throw SurfaceTestError.eventStreamEnded
        }
        group.cancelAll()
        return values
    }
}

private func firstEvent(
    from stream: AsyncStream<SurfaceCloseEvent>,
    timeout: Duration
) async throws -> SurfaceCloseEvent {
    try await withThrowingTaskGroup(of: SurfaceCloseEvent.self) { group in
        group.addTask {
            for await event in stream {
                return event
            }
            throw SurfaceTestError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SurfaceTestError.timeout
        }

        guard let event = try await group.next() else {
            throw SurfaceTestError.eventStreamEnded
        }
        group.cancelAll()
        return event
    }
}

@MainActor
private func makeHiddenWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private func embed(_ surface: GhosttySurfaceView, in window: NSWindow) {
    guard let contentView = window.contentView else {
        Issue.record("Hidden test window has no content view")
        return
    }

    surface.frame = contentView.bounds
    surface.autoresizingMask = [.width, .height]
    contentView.addSubview(surface)
}

private struct SurfaceTestConfig {
    let directoryURL: URL
    let url: URL

    init(contents: String = "abnormal-command-exit-runtime = 0\n") throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        url = directoryURL.appending(path: "config")
        try Data(contents.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
