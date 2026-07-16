import AppKit
import Darwin
import Foundation
import Testing

@testable import GhostTerm

extension GhosttyBridgeTests {
    @Test
    func closeAlertUsesExplicitDefaultAndCancelKeyEquivalents() {
        let alert = WindowCoordinator.makeConfirmationAlert(.close(PaneID()))

        #expect(alert.messageText == "Close Terminal?")
        #expect(alert.buttons.map(\.title) == ["Close", "Cancel"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "\u{1B}"])
    }

    @Test
    func unsafePasteAlertUsesExplicitDefaultAndCancelKeyEquivalents() {
        let request = makeConfirmationRequest(paneID: PaneID(), text: "unsafe")
        let alert = WindowCoordinator.makeConfirmationAlert(.clipboard(request))

        #expect(alert.messageText == "Warning: Potentially Unsafe Paste")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Paste"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\u{1B}", "\r"])
    }

    @Test
    func oscReadAlertUsesExplicitDefaultAndCancelKeyEquivalents() {
        let request = makeConfirmationRequest(
            paneID: PaneID(),
            kind: .osc52Read,
            text: "read"
        )
        let alert = WindowCoordinator.makeConfirmationAlert(.clipboard(request))

        #expect(alert.messageText == "Authorize Clipboard Access")
        #expect(alert.buttons.map(\.title) == ["Deny", "Allow"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\u{1B}", "\r"])
    }

    @Test
    func oscWriteAlertUsesExplicitDefaultAndCancelKeyEquivalents() {
        let request = makeConfirmationRequest(
            paneID: PaneID(),
            kind: .osc52Write,
            text: "write"
        )
        let alert = WindowCoordinator.makeConfirmationAlert(.clipboard(request))

        #expect(alert.messageText == "Authorize Clipboard Access")
        #expect(alert.buttons.map(\.title) == ["Deny", "Allow"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\u{1B}", "\r"])
    }

    @Test
    func windowPerformClosePreemptsClipboardAndConfirmsRealActiveSurface() async throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "always")
        defer { config.remove() }
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: "unsafe\nclipboard")
        ]
        let recorder = CoordinatorConfirmationRecorder()
        defer { recorder.finish() }
        let bridge = try GhosttyBridge(configURL: config.url, clipboardClient: store.client)
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: recorder.presenter
        )
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.defaultSurfaceForTesting)
        #expect(window.delegate === coordinator)

        surface.paste(nil)
        let clipboardPresentation = try await firstClipboardValue(
            from: recorder.presentationStream,
            timeout: .seconds(10)
        )
        guard case .clipboard(let clipboardRequest) = clipboardPresentation else {
            Issue.record("Expected clipboard confirmation before close")
            return
        }
        #expect(clipboardRequest.paneID == surface.paneID)

        window.performClose(nil)

        #expect(recorder.dismissCount == 1)
        #expect(recorder.presentations.last == .close(surface.paneID))
        #expect(coordinator.activeConfirmationForTesting == .close(surface.paneID))
        #expect(surface.pendingClipboardReadCountForTesting == 0)

        window.performClose(nil)
        #expect(recorder.presentations.filter { $0 == .close(surface.paneID) }.count == 1)
        let deny = try #require(recorder.completions.last)
        deny(.deny)

        #expect(window.isVisible)
        #expect(surface.isActive)
        #expect(bridge.activeSurfaceIDs == [surface.paneID])
        #expect(coordinator.activeConfirmationForTesting == nil)

        window.performClose(nil)
        #expect(recorder.presentations.last == .close(surface.paneID))
        #expect(recorder.presentations.filter { $0 == .close(surface.paneID) }.count == 2)
        let allow = try #require(recorder.completions.last)
        allow(.allow)

        #expect(!window.isVisible)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
        #expect(coordinator.activeConfirmationForTesting == nil)
    }

    @Test
    func windowPerformCloseWithoutConfirmationDrainsSurfaceAndCloses() throws {
        let config = try WindowCloseConfig(confirmCloseSurface: "false")
        defer { config.remove() }
        let recorder = CoordinatorConfirmationRecorder()
        defer { recorder.finish() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let coordinator = WindowCoordinator(
            ghosttyBridge: bridge,
            surfaceConfiguration: GhosttySurfaceConfiguration(command: "exec /bin/cat"),
            confirmationPresenter: recorder.presenter
        )
        try coordinator.start()
        let window = try #require(coordinator.windowForTesting)
        let surface = try #require(coordinator.defaultSurfaceForTesting)

        window.performClose(nil)

        #expect(recorder.presentations.isEmpty)
        #expect(!window.isVisible)
        #expect(!surface.isActive)
        #expect(bridge.activeSurfaceIDs.isEmpty)
    }

    @Test
    func clipboardEnumsRuntimeSupportAndScopedContentMatchPinnedABI() {
        #expect(GhosttyBridge.clipboardABIMatchesPinnedHeader)
        #expect(GhosttyBridge.supportsSelectionClipboard)

        let original = [
            GhosttyClipboardContent(mime: "text/html", data: "<b>owned</b>")
        ]
        let copied = GhosttyBridge.copyScopedClipboardContentsForTesting(original)

        #expect(copied == original)
    }

    @Test
    func injectedClientKeepsStandardAndSelectionSlotsDistinctAndPreservesMIMEEntries() {
        let store = InMemoryClipboardStore()
        let client = store.client
        let standard = [
            GhosttyClipboardContent(mime: "text/plain", data: "plain"),
            GhosttyClipboardContent(mime: "text/html", data: "<b>plain</b>"),
        ]
        let selection = [GhosttyClipboardContent(mime: "text/plain", data: "selection")]

        client.write(.standard, standard)
        client.write(.selection, selection)

        #expect(store.contents[.standard] == standard)
        #expect(store.contents[.selection] == selection)
        #expect(client.read(.standard) == "plain")
        #expect(client.read(.selection) == "selection")
    }

    @Test
    func systemMappingIsPureAndUsesPinnedURLPrecedenceAndAppNamespace() {
        let fileURL = URL(filePath: "/tmp/a file's.txt")
        let webURL = URL(string: "https://example.com/a?q=1")!

        #expect(
            GhosttyClipboardClient.opinionatedString(
                urls: [fileURL, webURL],
                fallback: "fallback"
            ) == "/tmp/a\\ file\\\'s.txt https://example.com/a?q=1"
        )
        #expect(
            GhosttyClipboardClient.opinionatedString(urls: [], fallback: "fallback")
                == "fallback"
        )
        #expect(GhosttyClipboardClient.selectionPasteboardName == "com.dntsk.GhostTerm.selection")
        #expect(GhosttyClipboardClient.pasteboardType(for: "text/plain") == .string)
        #expect(GhosttyClipboardClient.pasteboardType(for: "text/html") == .html)
    }

    @Test
    func scopedMultiMIMEArrayIsOwnedBeforeCallbackReturns() {
        let original = [
            GhosttyClipboardContent(mime: "text/plain", data: "plain"),
            GhosttyClipboardContent(mime: "text/html", data: "<b>plain</b>"),
        ]
        let copied = GhosttyBridge.copyScopedClipboardContentsForTesting(original)

        #expect(copied == original)
    }

    @Test
    func safeStandardPasteUsesRealBindingCallbackAndExactPTYBytes() async throws {
        let payload = "safe-猫"
        let fixture = try ClipboardPTYFixture { readyFIFOURL, resultURL in
            "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
                + "dd bs=1 count=\(payload.utf8.count) "
                + "of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
        }
        defer { fixture.remove() }
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: payload)
        ]
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            },
            clipboardClient: store.client
        )
        defer { bridge.shutdown() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        )
        try await fixture.awaitReady(timeout: .seconds(10))

        surface.copy(nil)
        surface.paste(nil)

        _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
        #expect(try Data(contentsOf: fixture.resultURL) == Data(payload.utf8))
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .binding(action: "copy_to_clipboard", result: false)
            )
        )
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .binding(action: "paste_from_clipboard", result: true)
            )
        )
        #expect(surface.pendingClipboardReadCountForTesting == 0)
    }

    @Test
    func selectionPasteUsesDistinctSlotAndExactBinding() async throws {
        let payload = "selection-only"
        let fixture = try ClipboardPTYFixture { readyFIFOURL, resultURL in
            "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
                + "dd bs=1 count=\(payload.utf8.count) "
                + "of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
        }
        defer { fixture.remove() }
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: "wrong-slot")
        ]
        store.contents[.selection] = [
            GhosttyClipboardContent(mime: "text/plain", data: payload)
        ]
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            },
            clipboardClient: store.client
        )
        defer { bridge.shutdown() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        )
        try await fixture.awaitReady(timeout: .seconds(10))

        surface.pasteSelection(nil)

        _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
        #expect(try Data(contentsOf: fixture.resultURL) == Data(payload.utf8))
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .binding(action: "paste_from_selection", result: true)
            )
        )
    }

    @Test
    func realSelectAllThenCopyWritesParsedTerminalContents() async throws {
        let fixture = try ClipboardPTYFixture(
            configContents: "copy-on-select = false\n"
        ) { readyFIFOURL, resultURL in
            "stty raw -echo; printf '\\033[2J\\033[3J\\033[Hcopy-me\\033[?1000h\\033[?1000$p'; "
                + "response=\"$(dd bs=1 count=11 2>/dev/null)\"; "
                + "if [ \"$response\" = \"$(printf '\\033[?1000;1$y')\" ]; then "
                + "printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
                + "dd bs=1 count=1 of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null; "
                + "else printf '%s' \"$response\" > "
                + "\(shellQuoteClipboard(resultURL.path)); exit 97; fi"
        }
        defer { fixture.remove() }
        let store = InMemoryClipboardStore()
        let (writes, writeContinuation) = AsyncStream.makeStream(of: ClipboardWriteEvent.self)
        defer { writeContinuation.finish() }
        store.writeHandler = { event in
            writeContinuation.yield(event)
        }
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            },
            clipboardClient: store.client
        )
        defer { bridge.shutdown() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        )
        try await fixture.awaitReady(timeout: .seconds(10))

        surface.selectAll(nil)
        surface.copy(nil)

        let write = try await firstClipboardValue(from: writes, timeout: .seconds(10))
        #expect(write.location == .standard)
        #expect(write.contents.map(\.mime) == ["text/plain", "text/html"])
        #expect(write.contents.first { $0.mime == "text/plain" }?.data == "copy-me")
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .binding(action: "select_all", result: true)
            )
        )
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .binding(action: "copy_to_clipboard", result: true)
            )
        )

        surface.insertText("!", replacementRange: NSRange())
        _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
        #expect(try Data(contentsOf: fixture.resultURL) == Data("!".utf8))
    }

    @Test
    func unsafePasteConfirmationAllowsOwnedSanitizedBracketedBytes() async throws {
        let payload = "alpha\n\u{1B}[201~beta"
        let expected = Data("\u{1B}[200~alpha\n [201~beta\u{1B}[201~".utf8)
        let fixture = try ClipboardPTYFixture { readyFIFOURL, resultURL in
            "stty raw -echo; printf '\\033[?2004h\\033[?2004$p'; "
                + "response=\"$(dd bs=1 count=11 2>/dev/null)\"; "
                + "if [ \"$response\" = \"$(printf '\\033[?2004;1$y')\" ]; then "
                + "printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
                + "dd bs=1 count=\(expected.count) "
                + "of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null; "
                + "else exit 97; fi"
        }
        defer { fixture.remove() }
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [GhosttyClipboardContent(mime: "text/plain", data: payload)]
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            },
            clipboardClient: store.client
        )
        defer { bridge.shutdown() }
        let (confirmations, confirmationContinuation) = AsyncStream.makeStream(
            of: GhosttyClipboardConfirmationEvent.self
        )
        defer { confirmationContinuation.finish() }
        bridge.clipboardConfirmationHandler = { event in
            confirmationContinuation.yield(event)
        }
        let (closeEvents, closeContinuation) = AsyncStream.makeStream(
            of: ClipboardSurfaceCloseEvent.self
        )
        defer { closeContinuation.finish() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        ) { paneID, processAlive in
            closeContinuation.yield(
                ClipboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            )
        }
        try await fixture.awaitReady(timeout: .seconds(10))
        surface.paste(nil)

        let confirmation = try await firstClipboardRequest(
            from: confirmations,
            timeout: .seconds(10)
        )
        #expect(confirmation.request.paneID == surface.paneID)
        #expect(confirmation.request.kind == .paste)
        #expect(confirmation.request.location == .standard)
        #expect(
            confirmation.request.contents
                == [GhosttyClipboardContent(mime: "text/plain", data: payload)]
        )
        #expect(surface.pendingClipboardReadCountForTesting == 1)
        _ = closeEvents

        confirmation.response(.allow)

        _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
        #expect(try Data(contentsOf: fixture.resultURL) == expected)
        #expect(surface.pendingClipboardReadCountForTesting == 0)
        #expect(
            surface.clipboardObservationsForTesting.contains(
                .completion(data: payload, confirmed: true)
            )
        )
    }

    @Test
    func unsafePasteDenyAndDuplicateResponseProduceNoPastedBytes() async throws {
        let payload = "blocked\ncommand"
        let fixture = try ClipboardPTYFixture { readyFIFOURL, resultURL in
            "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
                + "dd bs=1 count=1 of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
        }
        defer { fixture.remove() }
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [GhosttyClipboardContent(mime: "text/plain", data: payload)]
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            },
            clipboardClient: store.client
        )
        defer { bridge.shutdown() }
        let (confirmations, confirmationContinuation) = AsyncStream.makeStream(
            of: GhosttyClipboardConfirmationEvent.self
        )
        defer { confirmationContinuation.finish() }
        bridge.clipboardConfirmationHandler = { event in
            confirmationContinuation.yield(event)
        }
        let (closeEvents, closeContinuation) = AsyncStream.makeStream(
            of: ClipboardSurfaceCloseEvent.self
        )
        defer { closeContinuation.finish() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        ) { paneID, processAlive in
            closeContinuation.yield(
                ClipboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            )
        }
        try await fixture.awaitReady(timeout: .seconds(10))
        surface.paste(nil)

        let confirmation = try await firstClipboardRequest(
            from: confirmations,
            timeout: .seconds(10)
        )
        _ = closeEvents
        confirmation.response(.deny)
        confirmation.response(.allow)
        surface.insertText("!", replacementRange: NSRange())

        _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
        #expect(try Data(contentsOf: fixture.resultURL) == Data("!".utf8))
        #expect(surface.pendingClipboardReadCountForTesting == 0)
        #expect(
            surface.clipboardObservationsForTesting.filter {
                $0 == .completion(data: "", confirmed: true)
            }.count == 1
        )
    }

    @Test
    func realOSC52ReadAskAllowsExactBase64AndDenyRepliesEmpty() async throws {
        try await runOSC52Read(response: .allow, clipboardText: "osc-猫")
        try await runOSC52Read(response: .deny, clipboardText: "must-not-leak")
    }

    @Test
    func realOSC52WriteAskCopiesPayloadAndOnlyAllowWrites() async throws {
        try await runOSC52Write(response: .allow, payload: "owned-write")
        try await runOSC52Write(response: .deny, payload: "denied-write")
    }

    @Test
    func realOSC52WriteAllowUsesNormalMainActorWritePath() async throws {
        try await runOSC52WriteWithoutConfirmation(payload: "normal-write")
    }

    @Test
    func emptyReadCompletesAsynchronouslyAndMissingHandlerDenies() async throws {
        let emptyStore = InMemoryClipboardStore()
        let emptyBridge = try GhosttyBridge(clipboardClient: emptyStore.client)
        let emptySurface = try emptyBridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let (emptyObservations, emptyContinuation) = AsyncStream.makeStream(
            of: GhosttySurfaceClipboardObservation.self
        )
        emptySurface.clipboardObservationHandlerForTesting = { observation in
            emptyContinuation.yield(observation)
        }

        emptySurface.paste(nil)
        let emptyCompletion = try await firstClipboardCompletion(
            from: emptyObservations,
            confirmed: false,
            timeout: .seconds(10)
        )

        #expect(emptyCompletion == .completion(data: "", confirmed: false))
        #expect(emptySurface.pendingClipboardReadCountForTesting == 0)
        emptyContinuation.finish()
        emptyBridge.shutdown()

        let deniedStore = InMemoryClipboardStore()
        deniedStore.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: "unsafe\ntext")
        ]
        let deniedBridge = try GhosttyBridge(clipboardClient: deniedStore.client)
        let deniedSurface = try deniedBridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let (deniedObservations, deniedContinuation) = AsyncStream.makeStream(
            of: GhosttySurfaceClipboardObservation.self
        )
        deniedSurface.clipboardObservationHandlerForTesting = { observation in
            deniedContinuation.yield(observation)
        }

        deniedSurface.paste(nil)
        let deniedCompletion = try await firstClipboardCompletion(
            from: deniedObservations,
            confirmed: true,
            timeout: .seconds(10)
        )

        #expect(deniedCompletion == .completion(data: "", confirmed: true))
        #expect(deniedSurface.pendingClipboardReadCountForTesting == 0)
        deniedContinuation.finish()
        deniedBridge.shutdown()
    }

    @Test(arguments: [QueuedClipboardTeardown.closeSurface, .shutdown])
    func queuedUnsafePasteDrainsBeforeSurfaceTeardown(
        _ teardown: QueuedClipboardTeardown
    ) async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: "queued\nunsafe")
        ]
        let recorder = ClipboardConfirmationRecorder()
        let bridge = try GhosttyBridge(clipboardClient: store.client)
        defer { bridge.shutdown() }
        bridge.clipboardConfirmationHandler = { event in
            recorder.record(event)
        }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        surface.paste(nil)
        let registeredReadCount = surface.pendingClipboardReadCountForTesting
        switch teardown {
        case .closeSurface:
            bridge.closeSurface(id: surface.paneID)
        case .shutdown:
            bridge.shutdown()
        }

        #expect(registeredReadCount == 1)
        #expect(surface.pendingClipboardReadCountForTesting == 0)
        #expect(
            surface.clipboardObservationsForTesting.filter {
                if case .completion = $0 { return true }
                return false
            } == [.completion(data: "", confirmed: true)]
        )
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
        #expect(store.readCount == 0)
        #expect(store.writeCount == 0)
        #expect(recorder.requestCount == 0)
        #expect(recorder.invalidatedPaneIDs == [surface.paneID])
        let observationsAfterTeardown = surface.clipboardObservationsForTesting

        try await awaitClipboardMainActorSentinel(timeout: .seconds(10))

        #expect(surface.clipboardObservationsForTesting == observationsAfterTeardown)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
        #expect(store.readCount == 0)
        #expect(store.writeCount == 0)
        #expect(recorder.requestCount == 0)
    }

    @Test
    func pendingReadsDrainBeforeCloseAndShutdownAcrossMultipleSurfaces() async throws {
        let initialContextCount = GhosttyBridge.surfaceCallbackContextCountForTesting
        let store = InMemoryClipboardStore()
        store.contents[.standard] = [
            GhosttyClipboardContent(mime: "text/plain", data: "pending\ntext")
        ]
        let bridge = try GhosttyBridge(clipboardClient: store.client)
        let (confirmations, confirmationContinuation) = AsyncStream.makeStream(
            of: GhosttyClipboardConfirmationEvent.self
        )
        defer { confirmationContinuation.finish() }
        bridge.clipboardConfirmationHandler = { event in
            confirmationContinuation.yield(event)
        }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        first.paste(nil)
        let firstConfirmation = try await firstClipboardRequest(
            from: confirmations,
            timeout: .seconds(10)
        )
        #expect(first.pendingClipboardReadCountForTesting == 1)

        bridge.closeSurface(id: first.paneID)

        #expect(first.pendingClipboardReadCountForTesting == 0)
        #expect(
            first.clipboardObservationsForTesting.filter {
                $0 == .completion(data: "", confirmed: true)
            }.count == 1
        )
        firstConfirmation.response(.allow)
        firstConfirmation.response(.deny)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)

        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let third = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        second.paste(nil)
        third.paste(nil)
        let secondConfirmation = try await firstClipboardRequest(
            from: confirmations,
            timeout: .seconds(10)
        )
        let thirdConfirmation = try await firstClipboardRequest(
            from: confirmations,
            timeout: .seconds(10)
        )
        #expect(second.pendingClipboardReadCountForTesting == 1)
        #expect(third.pendingClipboardReadCountForTesting == 1)

        bridge.shutdown()

        #expect(second.pendingClipboardReadCountForTesting == 0)
        #expect(third.pendingClipboardReadCountForTesting == 0)
        #expect(GhosttyBridge.surfaceCallbackContextCountForTesting == initialContextCount)
        secondConfirmation.response(.allow)
        thirdConfirmation.response(.allow)
        #expect(store.contents[.standard]?.first?.data == "pending\ntext")
    }

    @Test
    func confirmationQueueIsFIFOAndCloseHasCancelablePriority() throws {
        let recorder = ConfirmationQueueRecorder()
        let queue = GhosttyConfirmationQueue { presentation, completion in
            recorder.presentations.append(presentation)
            recorder.completions.append(completion)
            return { recorder.dismissCount += 1 }
        }
        let paneID = PaneID()
        let first = makeConfirmationRequest(paneID: paneID, text: "first")
        let second = makeConfirmationRequest(paneID: paneID, text: "second")

        queue.enqueueClipboard(first) { response in
            recorder.responses.append((first.id, response))
        }
        queue.enqueueClipboard(second) { response in
            recorder.responses.append((second.id, response))
        }

        #expect(recorder.presentations == [.clipboard(first)])
        #expect(queue.pendingCount == 1)
        let firstPresentationCompletion = try #require(recorder.completions.first)
        firstPresentationCompletion(.allow)
        firstPresentationCompletion(.deny)
        #expect(recorder.responses.count == 1)
        #expect(recorder.responses[0].0 == first.id)
        #expect(recorder.responses[0].1 == .allow)
        #expect(recorder.presentations == [.clipboard(first), .clipboard(second)])

        queue.enqueueClose(paneID: paneID) { response in
            recorder.closeResponses.append(response)
        }

        #expect(recorder.responses.count == 2)
        #expect(recorder.responses[1].0 == second.id)
        #expect(recorder.responses[1].1 == .deny)
        #expect(recorder.dismissCount == 1)
        #expect(recorder.presentations.last == .close(paneID))
        let lateClipboardCompletion = try #require(recorder.completions.dropFirst().first)
        lateClipboardCompletion(.allow)
        #expect(recorder.responses.count == 2)

        let closeCompletion = try #require(recorder.completions.last)
        queue.invalidatePane(paneID)
        #expect(recorder.dismissCount == 2)
        closeCompletion(.allow)
        closeCompletion(.deny)
        #expect(recorder.closeResponses.isEmpty)
        #expect(queue.activePresentation == nil)
    }

    @Test
    func duplicateActiveCloseCoalescesPresentationAndResolvesAllCompletions() throws {
        let recorder = ConfirmationQueueRecorder()
        let queue = GhosttyConfirmationQueue { presentation, completion in
            recorder.presentations.append(presentation)
            recorder.completions.append(completion)
            return nil
        }
        let paneID = PaneID()

        queue.enqueueClose(paneID: paneID) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: paneID) { response in
            recorder.closeResponses.append(response)
        }

        #expect(recorder.presentations == [.close(paneID)])
        #expect(queue.pendingCount == 0)
        let completion = try #require(recorder.completions.first)
        completion(.allow)
        completion(.deny)

        #expect(recorder.closeResponses == [.allow, .allow])
        #expect(queue.activePresentation == nil)
    }

    @Test
    func duplicatePendingCloseCoalescesPresentationAndResolvesAllCompletions() throws {
        let recorder = ConfirmationQueueRecorder()
        let queue = GhosttyConfirmationQueue { presentation, completion in
            recorder.presentations.append(presentation)
            recorder.completions.append(completion)
            return nil
        }
        let activePaneID = PaneID()
        let pendingPaneID = PaneID()

        queue.enqueueClose(paneID: activePaneID) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: pendingPaneID) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: pendingPaneID) { response in
            recorder.closeResponses.append(response)
        }

        #expect(recorder.presentations == [.close(activePaneID)])
        #expect(queue.pendingCount == 1)
        let activeCompletion = try #require(recorder.completions.first)
        activeCompletion(.deny)
        #expect(recorder.presentations == [.close(activePaneID), .close(pendingPaneID)])

        let pendingCompletion = try #require(recorder.completions.last)
        pendingCompletion(.deny)
        pendingCompletion(.allow)

        #expect(recorder.closeResponses == [.deny, .deny, .deny])
        #expect(queue.activePresentation == nil)
    }

    @Test
    func multipleCloseRequestsRemainFIFOAheadOfClipboardRequests() throws {
        let recorder = ConfirmationQueueRecorder()
        let queue = GhosttyConfirmationQueue { presentation, completion in
            recorder.presentations.append(presentation)
            recorder.completions.append(completion)
            return { recorder.dismissCount += 1 }
        }
        let closeA = PaneID()
        let closeB = PaneID()
        let closeC = PaneID()
        let firstClipboard = makeConfirmationRequest(paneID: PaneID(), text: "first")
        let secondClipboard = makeConfirmationRequest(paneID: PaneID(), text: "second")

        queue.enqueueClose(paneID: closeA) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: closeB) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: closeC) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClose(paneID: closeB) { response in
            recorder.closeResponses.append(response)
        }
        queue.enqueueClipboard(firstClipboard) { response in
            recorder.responses.append((firstClipboard.id, response))
        }
        queue.enqueueClipboard(secondClipboard) { response in
            recorder.responses.append((secondClipboard.id, response))
        }

        let expected: [GhosttyConfirmationPresentation] = [
            .close(closeA),
            .close(closeB),
            .close(closeC),
            .clipboard(firstClipboard),
            .clipboard(secondClipboard),
        ]
        #expect(recorder.presentations == Array(expected.prefix(1)))
        #expect(queue.pendingCount == 4)

        let closeACompletion = try #require(recorder.completions.last)
        closeACompletion(.deny)
        #expect(recorder.presentations == Array(expected.prefix(2)))
        let closeBCompletion = try #require(recorder.completions.last)
        closeBCompletion(.deny)
        #expect(recorder.presentations == Array(expected.prefix(3)))
        let closeCCompletion = try #require(recorder.completions.last)
        closeCCompletion(.deny)
        #expect(recorder.presentations == Array(expected.prefix(4)))
        let firstClipboardCompletion = try #require(recorder.completions.last)
        firstClipboardCompletion(.deny)
        #expect(recorder.presentations == expected)
        let secondClipboardCompletion = try #require(recorder.completions.last)
        secondClipboardCompletion(.deny)

        #expect(recorder.closeResponses == [.deny, .deny, .deny, .deny])
        #expect(recorder.responses.map(\.0) == [firstClipboard.id, secondClipboard.id])
        #expect(queue.activePresentation == nil)
        #expect(queue.pendingCount == 0)
    }

    @Test
    func closePriorityRequeuesOtherPaneWithFreshPresentationIdentity() throws {
        let recorder = ConfirmationQueueRecorder()
        let queue = GhosttyConfirmationQueue { presentation, completion in
            recorder.presentations.append(presentation)
            recorder.completions.append(completion)
            return { recorder.dismissCount += 1 }
        }
        let clipboardPaneID = PaneID()
        let closePaneID = PaneID()
        let request = makeConfirmationRequest(paneID: clipboardPaneID, text: "requeued")

        queue.enqueueClipboard(request) { response in
            recorder.responses.append((request.id, response))
        }
        let staleCompletion = try #require(recorder.completions.first)

        queue.enqueueClose(paneID: closePaneID) { response in
            recorder.closeResponses.append(response)
        }
        #expect(recorder.dismissCount == 1)
        #expect(recorder.presentations.last == .close(closePaneID))

        let closeCompletion = try #require(recorder.completions.last)
        closeCompletion(.deny)
        #expect(recorder.closeResponses == [.deny])
        #expect(recorder.presentations.last == .clipboard(request))

        staleCompletion(.allow)
        #expect(recorder.responses.isEmpty)

        let currentCompletion = try #require(recorder.completions.last)
        currentCompletion(.allow)
        currentCompletion(.deny)
        #expect(recorder.responses.count == 1)
        #expect(recorder.responses[0].0 == request.id)
        #expect(recorder.responses[0].1 == .allow)
        #expect(queue.activePresentation == nil)
    }
}

@MainActor
private final class InMemoryClipboardStore {
    var contents: [GhosttyClipboardLocation: [GhosttyClipboardContent]] = [:]
    var readCount = 0
    var writeCount = 0
    var writeHandler: (@MainActor @Sendable (ClipboardWriteEvent) -> Void)?

    lazy var client = GhosttyClipboardClient(
        read: { [weak self] location in
            guard let self else { return nil }
            readCount += 1
            return contents[location]?.first(where: { $0.mime == "text/plain" })?.data
        },
        write: { [weak self] location, contents in
            self?.contents[location] = contents
            self?.writeCount += 1
            self?.writeHandler?(ClipboardWriteEvent(location: location, contents: contents))
        }
    )
}

private struct ClipboardSurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

private struct ClipboardWriteEvent: Equatable, Sendable {
    let location: GhosttyClipboardLocation
    let contents: [GhosttyClipboardContent]
}

private struct CapturedClipboardRequest: Sendable {
    let request: GhosttyClipboardConfirmationRequest
    let response: @MainActor @Sendable (GhosttyClipboardConfirmationResponse) -> Void
}

enum QueuedClipboardTeardown: Sendable {
    case closeSurface
    case shutdown
}

private enum ClipboardTestError: Error {
    case fifoCreationFailed(Int32)
    case processFailed(Int32)
    case streamEnded
    case timeout
}

struct WindowCloseConfig {
    let directoryURL: URL
    let url: URL

    init(confirmCloseSurface: String) throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        url = directoryURL.appending(path: "config")
        try Data(
            "abnormal-command-exit-runtime = 0\nconfirm-close-surface = \(confirmCloseSurface)\n"
                .utf8
        ).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private final class CoordinatorConfirmationRecorder {
    private(set) var presentations: [GhosttyConfirmationPresentation] = []
    private(set) var completions: [GhosttyConfirmationQueue.Completion] = []
    private(set) var dismissCount = 0
    let presentationStream: AsyncStream<GhosttyConfirmationPresentation>

    private let presentationContinuation: AsyncStream<GhosttyConfirmationPresentation>.Continuation

    init() {
        (presentationStream, presentationContinuation) = AsyncStream.makeStream(
            of: GhosttyConfirmationPresentation.self
        )
    }

    lazy var presenter: GhosttyConfirmationQueue.Presenter = {
        [weak self] presentation, completion in
        guard let self else {
            completion(.deny)
            return nil
        }
        presentations.append(presentation)
        completions.append(completion)
        presentationContinuation.yield(presentation)
        return { [weak self] in
            self?.dismissCount += 1
        }
    }

    func finish() {
        presentationContinuation.finish()
    }
}

@MainActor
private final class ClipboardConfirmationRecorder {
    private(set) var requestCount = 0
    private(set) var invalidatedPaneIDs: [PaneID] = []

    func record(_ event: GhosttyClipboardConfirmationEvent) {
        switch event {
        case .request:
            requestCount += 1
        case .invalidate(let paneID):
            invalidatedPaneIDs.append(paneID)
        }
    }
}

@MainActor
private final class ClipboardPTYFixture {
    let directoryURL: URL
    let configURL: URL
    let resultURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init(
        configContents: String = "",
        script: (URL, URL) -> String
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        configURL = directoryURL.appending(path: "config")
        resultURL = directoryURL.appending(path: "result")
        readyFIFOURL = directoryURL.appending(path: "ready.fifo")
        try Data(
            ("abnormal-command-exit-runtime = 0\n" + configContents).utf8
        ).write(to: configURL)

        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw ClipboardTestError.fifoCreationFailed(errno)
        }

        command = "/bin/sh -c \(shellQuoteClipboard(script(readyFIFOURL, resultURL)))"
        (readyExits, readyExitContinuation) = AsyncStream.makeStream(of: Int32.self)
        readyReader.executableURL = URL(filePath: "/bin/cat")
        readyReader.arguments = [readyFIFOURL.path]
        readyReader.standardOutput = readyOutput
        readyReader.standardError = FileHandle.nullDevice
        let continuation = readyExitContinuation
        readyReader.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
    }

    func startReadyReader() throws {
        try readyReader.run()
    }

    func awaitReady(timeout: Duration) async throws {
        let status = try await firstClipboardValue(from: readyExits, timeout: timeout)
        guard status == 0 else {
            throw ClipboardTestError.processFailed(status)
        }
        let data = readyOutput.fileHandleForReading.readDataToEndOfFile()
        guard data == Data("R".utf8) else {
            throw ClipboardTestError.processFailed(status)
        }
    }

    func remove() {
        readyExitContinuation.finish()
        if readyReader.isRunning {
            readyReader.terminate()
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private func runOSC52Read(
    response: GhosttyClipboardConfirmationResponse,
    clipboardText: String
) async throws {
    let encoded = response == .allow ? Data(clipboardText.utf8).base64EncodedString() : ""
    let expected = Data("\u{1B}]52;c;\(encoded)\u{1B}\\".utf8)
    let fixture = try ClipboardPTYFixture(
        configContents: "clipboard-read = ask\n"
    ) { readyFIFOURL, resultURL in
        "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
            + "printf '\\033]52;c;?\\007'; "
            + "dd bs=1 count=\(expected.count) "
            + "of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
    }
    defer { fixture.remove() }
    let store = InMemoryClipboardStore()
    store.contents[.standard] = [
        GhosttyClipboardContent(mime: "text/plain", data: clipboardText)
    ]
    let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
    defer { processExitContinuation.finish() }
    let bridge = try GhosttyBridge(
        configURL: fixture.configURL,
        runtimeActionHandler: { action in
            if action == .showChildExited {
                processExitContinuation.yield()
            }
        },
        clipboardClient: store.client
    )
    defer { bridge.shutdown() }
    let (confirmations, confirmationContinuation) = AsyncStream.makeStream(
        of: GhosttyClipboardConfirmationEvent.self
    )
    defer { confirmationContinuation.finish() }
    bridge.clipboardConfirmationHandler = { event in
        confirmationContinuation.yield(event)
    }
    let (closeEvents, closeContinuation) = AsyncStream.makeStream(
        of: ClipboardSurfaceCloseEvent.self
    )
    defer { closeContinuation.finish() }

    try fixture.startReadyReader()
    let surface = try bridge.makeSurface(
        configuration: GhosttySurfaceConfiguration(command: fixture.command)
    ) { paneID, processAlive in
        closeContinuation.yield(
            ClipboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
        )
    }
    try await fixture.awaitReady(timeout: .seconds(10))

    let confirmation = try await firstClipboardRequest(
        from: confirmations,
        timeout: .seconds(10)
    )
    #expect(confirmation.request.paneID == surface.paneID)
    #expect(confirmation.request.kind == .osc52Read)
    #expect(confirmation.request.location == .standard)
    #expect(
        confirmation.request.contents
            == [GhosttyClipboardContent(mime: "text/plain", data: clipboardText)]
    )
    _ = closeEvents
    confirmation.response(response)

    _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
    #expect(try Data(contentsOf: fixture.resultURL) == expected)
    #expect(surface.pendingClipboardReadCountForTesting == 0)
}

@MainActor
private func runOSC52Write(
    response: GhosttyClipboardConfirmationResponse,
    payload: String
) async throws {
    let encoded = Data(payload.utf8).base64EncodedString()
    let fixture = try ClipboardPTYFixture(
        configContents: "clipboard-write = ask\n"
    ) { readyFIFOURL, resultURL in
        "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
            + "printf '\\033]52;c;\(encoded)\\007'; "
            + "dd bs=1 count=1 of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
    }
    defer { fixture.remove() }
    let store = InMemoryClipboardStore()
    let original = [GhosttyClipboardContent(mime: "text/plain", data: "original")]
    store.contents[.standard] = original
    let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
    defer { processExitContinuation.finish() }
    let bridge = try GhosttyBridge(
        configURL: fixture.configURL,
        runtimeActionHandler: { action in
            if action == .showChildExited {
                processExitContinuation.yield()
            }
        },
        clipboardClient: store.client
    )
    defer { bridge.shutdown() }
    let (confirmations, confirmationContinuation) = AsyncStream.makeStream(
        of: GhosttyClipboardConfirmationEvent.self
    )
    defer { confirmationContinuation.finish() }
    bridge.clipboardConfirmationHandler = { event in
        confirmationContinuation.yield(event)
    }
    let (closeEvents, closeContinuation) = AsyncStream.makeStream(
        of: ClipboardSurfaceCloseEvent.self
    )
    defer { closeContinuation.finish() }

    try fixture.startReadyReader()
    let surface = try bridge.makeSurface(
        configuration: GhosttySurfaceConfiguration(command: fixture.command)
    ) { paneID, processAlive in
        closeContinuation.yield(
            ClipboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
        )
    }
    try await fixture.awaitReady(timeout: .seconds(10))

    let confirmation = try await firstClipboardRequest(
        from: confirmations,
        timeout: .seconds(10)
    )
    #expect(confirmation.request.paneID == surface.paneID)
    #expect(confirmation.request.kind == .osc52Write)
    #expect(confirmation.request.location == .standard)
    #expect(
        confirmation.request.contents
            == [GhosttyClipboardContent(mime: "text/plain", data: payload)]
    )
    #expect(surface.pendingClipboardWriteCountForTesting == 1)
    _ = closeEvents

    confirmation.response(response)
    confirmation.response(response)
    surface.insertText("!", replacementRange: NSRange())

    _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
    #expect(try Data(contentsOf: fixture.resultURL) == Data("!".utf8))
    #expect(surface.pendingClipboardWriteCountForTesting == 0)
    if response == .allow {
        #expect(
            store.contents[.standard]
                == [GhosttyClipboardContent(mime: "text/plain", data: payload)]
        )
        #expect(store.writeCount == 1)
        #expect(
            surface.clipboardObservationsForTesting.filter {
                $0
                    == .write(
                        location: .standard,
                        contents: [GhosttyClipboardContent(mime: "text/plain", data: payload)]
                    )
            }.count == 1
        )
    } else {
        #expect(store.contents[.standard] == original)
        #expect(store.writeCount == 0)
    }
}

@MainActor
private func runOSC52WriteWithoutConfirmation(payload: String) async throws {
    let encoded = Data(payload.utf8).base64EncodedString()
    let fixture = try ClipboardPTYFixture(
        configContents: "clipboard-write = allow\n"
    ) { readyFIFOURL, resultURL in
        "stty raw -echo; printf R > \(shellQuoteClipboard(readyFIFOURL.path)); "
            + "printf '\\033]52;c;\(encoded)\\007'; "
            + "dd bs=1 count=1 of=\(shellQuoteClipboard(resultURL.path)) 2>/dev/null"
    }
    defer { fixture.remove() }
    let store = InMemoryClipboardStore()
    let (writes, writeContinuation) = AsyncStream.makeStream(of: ClipboardWriteEvent.self)
    defer { writeContinuation.finish() }
    store.writeHandler = { event in
        writeContinuation.yield(event)
    }
    let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
    defer { processExitContinuation.finish() }
    let bridge = try GhosttyBridge(
        configURL: fixture.configURL,
        runtimeActionHandler: { action in
            if action == .showChildExited {
                processExitContinuation.yield()
            }
        },
        clipboardClient: store.client
    )
    defer { bridge.shutdown() }

    try fixture.startReadyReader()
    let surface = try bridge.makeSurface(
        configuration: GhosttySurfaceConfiguration(command: fixture.command)
    )
    try await fixture.awaitReady(timeout: .seconds(10))

    let write = try await firstClipboardValue(from: writes, timeout: .seconds(10))
    let expected = [GhosttyClipboardContent(mime: "text/plain", data: payload)]
    #expect(write == ClipboardWriteEvent(location: .standard, contents: expected))
    #expect(store.contents[.standard] == expected)
    #expect(store.writeCount == 1)
    #expect(surface.pendingClipboardWriteCountForTesting == 0)

    surface.insertText("!", replacementRange: NSRange())
    _ = try await firstClipboardValue(from: processExits, timeout: .seconds(10))
    #expect(try Data(contentsOf: fixture.resultURL) == Data("!".utf8))
}

@MainActor
private func awaitClipboardMainActorSentinel(timeout: Duration) async throws {
    let (sentinels, continuation) = AsyncStream.makeStream(of: Void.self)
    Task { @MainActor in
        continuation.yield()
        continuation.finish()
    }
    _ = try await firstClipboardValue(from: sentinels, timeout: timeout)
}

private func firstClipboardRequest(
    from stream: AsyncStream<GhosttyClipboardConfirmationEvent>,
    timeout: Duration
) async throws -> CapturedClipboardRequest {
    try await withThrowingTaskGroup(of: CapturedClipboardRequest.self) { group in
        group.addTask {
            for await event in stream {
                guard case .request(let request, let response) = event else { continue }
                return CapturedClipboardRequest(request: request, response: response)
            }
            throw ClipboardTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ClipboardTestError.timeout
        }

        guard let request = try await group.next() else {
            throw ClipboardTestError.streamEnded
        }
        group.cancelAll()
        return request
    }
}

private func firstClipboardCompletion(
    from stream: AsyncStream<GhosttySurfaceClipboardObservation>,
    confirmed: Bool,
    timeout: Duration
) async throws -> GhosttySurfaceClipboardObservation {
    try await withThrowingTaskGroup(of: GhosttySurfaceClipboardObservation.self) { group in
        group.addTask {
            for await observation in stream {
                guard case .completion(_, let value) = observation,
                    value == confirmed
                else { continue }
                return observation
            }
            throw ClipboardTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ClipboardTestError.timeout
        }

        guard let observation = try await group.next() else {
            throw ClipboardTestError.streamEnded
        }
        group.cancelAll()
        return observation
    }
}

private func firstClipboardValue<Value: Sendable>(
    from stream: AsyncStream<Value>,
    timeout: Duration
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw ClipboardTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ClipboardTestError.timeout
        }

        guard let value = try await group.next() else {
            throw ClipboardTestError.streamEnded
        }
        group.cancelAll()
        return value
    }
}

@MainActor
private final class ConfirmationQueueRecorder {
    var presentations: [GhosttyConfirmationPresentation] = []
    var completions: [GhosttyConfirmationQueue.Completion] = []
    var responses: [(UUID, GhosttyClipboardConfirmationResponse)] = []
    var closeResponses: [GhosttyClipboardConfirmationResponse] = []
    var dismissCount = 0
}

private func makeConfirmationRequest(
    paneID: PaneID,
    kind: GhosttyClipboardConfirmationKind = .paste,
    text: String
) -> GhosttyClipboardConfirmationRequest {
    GhosttyClipboardConfirmationRequest(
        id: UUID(),
        paneID: paneID,
        kind: kind,
        location: .standard,
        contents: [GhosttyClipboardContent(mime: "text/plain", data: text)]
    )
}

private func shellQuoteClipboard(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
