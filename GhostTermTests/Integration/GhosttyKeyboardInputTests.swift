import AppKit
import Darwin
import Foundation
import Testing

@testable import GhostTerm

extension GhosttyBridgeTests {
    @Test
    func responderRoutesOriginalEventSynchronouslyToSourceSurfaceOnly() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let sourceID = PaneID()
        let otherID = PaneID()
        let source = try bridge.makeSurface(
            id: sourceID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            id: otherID,
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )

        source.keyDown(with: event)

        let route = try #require(bridge.inputObservationsForTesting.last)
        let processed = try #require(source.inputObservationsForTesting.last)
        #expect(route.paneID == sourceID)
        #expect(route.eventIdentifier == ObjectIdentifier(event))
        #expect(route.wasProcessed)
        #expect(processed.eventIdentifier == ObjectIdentifier(event))
        #expect(processed.translationEventIdentifier == ObjectIdentifier(event))
        #expect(processed.action == .press)
        #expect(other.inputObservationsForTesting.isEmpty)

        bridge.closeSurface(id: sourceID)
        let ignoredEvent = try makeKeyboardEvent(
            type: .keyDown,
            characters: "b",
            charactersIgnoringModifiers: "b",
            keyCode: 11
        )
        let sourceObservationCount = source.inputObservationsForTesting.count

        source.keyDown(with: ignoredEvent)

        let ignoredRoute = try #require(bridge.inputObservationsForTesting.last)
        #expect(ignoredRoute.paneID == sourceID)
        #expect(ignoredRoute.eventIdentifier == ObjectIdentifier(ignoredEvent))
        #expect(!ignoredRoute.wasProcessed)
        #expect(source.inputObservationsForTesting.count == sourceObservationCount)
    }

    @Test
    func installedMonitorRoutesCommandKeyUpOnlyToFocusedSource() throws {
        let initialMonitorCount = GhosttySurfaceView.focusMonitorCountForTesting
        let bridge = try GhosttyBridge(applicationIsActive: { true })
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(source, in: window)
        other.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(source)
        let commandKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            windowNumber: window.windowNumber
        )

        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount + 2)
        NSApp.sendEvent(commandKeyUp)

        let route = try #require(bridge.inputObservationsForTesting.last)
        let input = try #require(source.inputObservationsForTesting.last)
        #expect(bridge.inputObservationsForTesting.count == 1)
        #expect(route.paneID == source.paneID)
        #expect(route.eventIdentifier == ObjectIdentifier(commandKeyUp))
        #expect(source.inputObservationsForTesting.count == 1)
        #expect(input.eventIdentifier == ObjectIdentifier(commandKeyUp))
        #expect(input.action == .release)
        #expect(other.inputObservationsForTesting.isEmpty)

        let nonCommandKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            timestamp: 2,
            windowNumber: window.windowNumber
        )
        #expect(source.processLocalEventForTesting(nonCommandKeyUp) === nonCommandKeyUp)
        #expect(other.processLocalEventForTesting(nonCommandKeyUp) === nonCommandKeyUp)

        #expect(bridge.inputObservationsForTesting.count == 1)
        #expect(source.inputObservationsForTesting.count == 1)
        #expect(other.inputObservationsForTesting.isEmpty)

        let otherWindow = makeKeyboardTestWindow()
        let otherWindowKeyUp = try makeKeyboardEvent(
            type: .keyUp,
            modifierFlags: [.command],
            characters: "c",
            charactersIgnoringModifiers: "c",
            keyCode: 8,
            timestamp: 3,
            windowNumber: otherWindow.windowNumber
        )
        #expect(source.processLocalEventForTesting(otherWindowKeyUp) === otherWindowKeyUp)
    }

    @Test
    func surfaceInputRouteDoesNotRetainBridge() throws {
        weak var weakBridge: GhosttyBridge?
        var retainedSurface: GhosttySurfaceView?
        var bridge: GhosttyBridge? = try GhosttyBridge()
        weakBridge = bridge
        retainedSurface = try bridge?.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        bridge = nil

        #expect(weakBridge == nil)
        #expect(retainedSurface?.isReady == false)
        retainedSurface = nil
    }

    @Test
    func keyEquivalentRoutesBindingsControlReturnAndExactControlSlash() throws {
        let config = try KeyboardShortcutConfig()
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let binding = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let controlReturn = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: 36,
            timestamp: 2
        )
        let controlSlash = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.control],
            characters: "\u{1F}",
            charactersIgnoringModifiers: "/",
            keyCode: 44,
            timestamp: 3
        )

        #expect(surface.performKeyEquivalent(with: binding))
        let bindingRoute = try #require(bridge.inputObservationsForTesting.last)
        #expect(bindingRoute.eventIdentifier == ObjectIdentifier(binding))

        #expect(surface.performKeyEquivalent(with: controlReturn))
        let returnRoute = try #require(bridge.inputObservationsForTesting.last)
        let returnInput = try #require(surface.inputObservationsForTesting.last)
        #expect(returnRoute.eventIdentifier == ObjectIdentifier(controlReturn))
        #expect(returnRoute.paneID == surface.paneID)
        #expect(returnInput.eventIdentifier == ObjectIdentifier(controlReturn))
        #expect(returnInput.keyCode == 36)

        #expect(surface.performKeyEquivalent(with: controlSlash))
        let slashRoute = try #require(bridge.inputObservationsForTesting.last)
        let slashInput = try #require(surface.inputObservationsForTesting.last)
        #expect(slashRoute.eventIdentifier == ObjectIdentifier(controlSlash))
        #expect(slashRoute.paneID == surface.paneID)
        #expect(slashInput.eventIdentifier == ObjectIdentifier(controlSlash))
        #expect(slashInput.keyCode == 44)
        #expect(slashInput.modifiers == [.control])
        #expect(slashInput.text == "_")
        #expect(!slashInput.composing)
    }

    @Test
    func commandTReturnsToAppKitBeforeGhosttyBindingsWhileModifiedTRemainsBindable() throws {
        let config = try KeyboardShortcutConfig(
            contents: "keybind = cmd+KeyT=ignore\nkeybind = cmd+shift+KeyT=ignore\n"
        )
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let commandT = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "t",
            charactersIgnoringModifiers: "t",
            keyCode: 17
        )
        let commandCapsLockT = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .capsLock],
            characters: "T",
            charactersIgnoringModifiers: "T",
            keyCode: 17,
            timestamp: 2
        )
        let commandShiftT = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .shift],
            characters: "T",
            charactersIgnoringModifiers: "t",
            keyCode: 17,
            timestamp: 3
        )

        let initialRouteCount = bridge.inputObservationsForTesting.count
        #expect(!surface.performKeyEquivalent(with: commandT))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)
        #expect(surface.inputObservationsForTesting.isEmpty)

        #expect(!surface.performKeyEquivalent(with: commandCapsLockT))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)
        #expect(surface.inputObservationsForTesting.isEmpty)

        #expect(surface.performKeyEquivalent(with: commandShiftT))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)
    }

    @Test
    func commandDigitsReturnToAppKitBeforeGhosttyBindingsWhileModifiedDigitsRemainBindable() throws
    {
        let config = try KeyboardShortcutConfig(
            contents: "keybind = cmd+Key1=ignore\nkeybind = cmd+shift+Key1=ignore\n"
        )
        defer { config.remove() }
        let bridge = try GhosttyBridge(configURL: config.url)
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let commandOne = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "1",
            charactersIgnoringModifiers: "1",
            keyCode: 18
        )
        let commandCapsLockOne = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .capsLock],
            characters: "1",
            charactersIgnoringModifiers: "1",
            keyCode: 18,
            timestamp: 2
        )
        let commandShiftOne = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command, .shift],
            characters: "!",
            charactersIgnoringModifiers: "1",
            keyCode: 18,
            timestamp: 3
        )

        let initialRouteCount = bridge.inputObservationsForTesting.count
        #expect(surface.isPlainCommandDigitForTesting(commandOne))
        #expect(surface.isPlainCommandDigitForTesting(commandCapsLockOne))
        #expect(!surface.performKeyEquivalent(with: commandOne))
        #expect(!surface.performKeyEquivalent(with: commandCapsLockOne))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)
        #expect(surface.inputObservationsForTesting.isEmpty)

        #expect(!surface.isPlainCommandDigitForTesting(commandShiftOne))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)
    }

    @Test
    func keyEquivalentRedispatchesMatchingTimestampWithoutStealingOtherShortcuts() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)
        let redispatched = try makeKeyboardEvent(
            type: .keyDown,
            modifierFlags: [.command],
            characters: "b",
            charactersIgnoringModifiers: "b",
            keyCode: 11,
            timestamp: 21
        )
        let unrelatedShortcut = try makeKeyboardEvent(
            type: .keyDown,
            characters: "x",
            charactersIgnoringModifiers: "x",
            keyCode: 7,
            timestamp: 22
        )

        let initialRouteCount = bridge.inputObservationsForTesting.count
        #expect(!surface.performKeyEquivalent(with: redispatched))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount)

        #expect(surface.performKeyEquivalent(with: redispatched))
        let redispatchedRoute = try #require(bridge.inputObservationsForTesting.last)
        #expect(redispatchedRoute.eventIdentifier == ObjectIdentifier(redispatched))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)

        #expect(!surface.performKeyEquivalent(with: unrelatedShortcut))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)

        window.makeFirstResponder(nil)
        #expect(!surface.performKeyEquivalent(with: redispatched))
        #expect(bridge.inputObservationsForTesting.count == initialRouteCount + 1)
    }

    @Test
    func keyUpAndSidedModifierChangesUseProductionRoute() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let keyUp = try makeKeyboardEvent(
            type: .keyUp,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let rightShiftFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let rightShiftDown = try makeKeyboardEvent(
            type: .flagsChanged,
            modifierFlags: rightShiftFlags,
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 0x3C
        )
        let rightShiftUpWhileLeftRemains = try makeKeyboardEvent(
            type: .flagsChanged,
            modifierFlags: [.shift],
            characters: "",
            charactersIgnoringModifiers: "",
            keyCode: 0x3C
        )

        surface.keyUp(with: keyUp)
        surface.flagsChanged(with: rightShiftDown)
        surface.flagsChanged(with: rightShiftUpWhileLeftRemains)

        let observations = surface.inputObservationsForTesting
        #expect(observations.count == 3)
        #expect(observations[0].action == .release)
        #expect(observations[1].action == .press)
        #expect(observations[1].modifiers.contains(.shiftRight))
        #expect(observations[2].action == .release)
        #expect(observations[2].modifiers.contains(.shift))
        #expect(!observations[2].modifiers.contains(.shiftRight))

        surface.setMarkedText("compose", selectedRange: NSRange(), replacementRange: NSRange())
        let countBeforeMarkedFlags = surface.inputObservationsForTesting.count
        surface.flagsChanged(with: rightShiftDown)
        #expect(surface.inputObservationsForTesting.count == countBeforeMarkedFlags)
        surface.unmarkText()
    }

    @Test
    func textInputClientObservesRealPreeditCallsAndIMEGeometry() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeKeyboardTestWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedKeyboardSurface(surface, in: window)
        let initialPreeditCount = surface.preeditObservationsForTesting.count

        surface.setMarkedText(
            NSAttributedString(string: "かな"),
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange()
        )

        #expect(surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange(location: 0, length: 2))
        #expect(surface.selectedRange() == NSRange())
        #expect(surface.validAttributesForMarkedText().isEmpty)
        #expect(
            surface.attributedSubstring(
                forProposedRange: NSRange(location: 0, length: 1),
                actualRange: nil
            ) == nil
        )
        #expect(surface.characterIndex(for: .zero) == 0)
        #expect(surface.preeditObservationsForTesting.count == initialPreeditCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .set(Data("かな".utf8)))

        let initialGeometryCount = surface.imeGeometryObservationsForTesting.count
        let rect = surface.firstRect(
            forCharacterRange: surface.markedRange(),
            actualRange: nil
        )
        let geometry = try #require(surface.imeGeometryObservationsForTesting.last)
        #expect(surface.imeGeometryObservationsForTesting.count == initialGeometryCount + 1)
        let expectedWindowRect = surface.convert(geometry.rawViewRect, to: nil)
        let expectedScreenRect = window.convertToScreen(expectedWindowRect)
        #expect(geometry.screenRect == rect)
        #expect(rectanglesApproximatelyEqual(expectedScreenRect, rect))
        #expect(geometry.rawViewRect.origin.x.isFinite)
        #expect(geometry.rawViewRect.origin.y.isFinite)
        #expect(geometry.rawViewRect.width.isFinite)
        #expect(geometry.rawViewRect.height.isFinite)
        #expect(geometry.rawViewRect.width > 0)
        #expect(geometry.rawViewRect.height > 0)
        #expect(rect.origin.x.isFinite)
        #expect(rect.origin.y.isFinite)
        #expect(rect.width.isFinite)
        #expect(rect.height.isFinite)
        #expect(rect.width > 0)
        #expect(rect.height > 0)

        let beforeUnmarkCount = surface.preeditObservationsForTesting.count
        surface.unmarkText()
        #expect(!surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange())
        #expect(surface.preeditObservationsForTesting.count == beforeUnmarkCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)

        surface.setMarkedText("é", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(surface.preeditObservationsForTesting.last == .set(Data("é".utf8)))
        let beforeCommitCount = surface.preeditObservationsForTesting.count
        surface.insertText(
            NSAttributedString(string: "é"),
            replacementRange: NSRange()
        )
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCommitCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)

        surface.setMarkedText("closing", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(surface.preeditObservationsForTesting.last == .set(Data("closing".utf8)))
        let beforeCloseCount = surface.preeditObservationsForTesting.count
        bridge.closeSurface(id: surface.paneID)
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCloseCount + 1)
        #expect(surface.preeditObservationsForTesting.last == .clear)
        surface.setMarkedText("ignored", selectedRange: NSRange(), replacementRange: NSRange())
        #expect(!surface.hasMarkedText())
        #expect(surface.preeditObservationsForTesting.count == beforeCloseCount + 1)
    }

    @Test
    func markedKeyDownCallsProductionKeyWithComposingState() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeKeyboardTestWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedKeyboardSurface(surface, in: window)
        let functionKey = String(UnicodeScalar(NSF1FunctionKey)!)
        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: functionKey,
            charactersIgnoringModifiers: functionKey,
            keyCode: 122
        )

        surface.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange()
        )
        let inputCount = surface.inputObservationsForTesting.count
        surface.keyDown(with: event)

        let observation = try #require(surface.inputObservationsForTesting.last)
        #expect(surface.inputObservationsForTesting.count == inputCount + 1)
        #expect(observation.eventIdentifier == ObjectIdentifier(event))
        #expect(observation.action == .press)
        #expect(observation.keyCode == 122)
        #expect(observation.text == nil)
        #expect(observation.composing)
        #expect(surface.hasMarkedText())
        #expect(surface.markedRange() == NSRange(location: 0, length: 2))
        #expect(surface.preeditObservationsForTesting.last == .set(Data("かな".utf8)))
    }

    @Test
    func realResponderKeyAndMarkedUnicodeCommitReachPTYExactlyOnce() async throws {
        let fixture = try KeyboardPTYFixture(expectedPayloadByteCount: 4)
        defer { fixture.remove() }
        let (processExits, processExitContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { processExitContinuation.finish() }
        let bridge = try GhosttyBridge(
            configURL: fixture.configURL,
            runtimeActionHandler: { action in
                if action == .showChildExited {
                    processExitContinuation.yield()
                }
            }
        )
        defer { bridge.shutdown() }
        let paneID = PaneID()
        let (closeEvents, closeContinuation) = AsyncStream.makeStream(
            of: KeyboardSurfaceCloseEvent.self
        )
        defer { closeContinuation.finish() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        ) { paneID, processAlive in
            closeContinuation.yield(
                KeyboardSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            )
        }
        let window = makeKeyboardTestWindow()
        embedKeyboardSurface(surface, in: window)

        try await fixture.awaitReady(timeout: .seconds(10))

        let event = try makeKeyboardEvent(
            type: .keyDown,
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        let inputCount = surface.inputObservationsForTesting.count
        surface.keyDown(with: event)
        let keyInput = try #require(surface.inputObservationsForTesting.last)
        #expect(surface.inputObservationsForTesting.count == inputCount + 1)
        #expect(keyInput.text == "a")

        let preeditCount = surface.preeditObservationsForTesting.count
        surface.setMarkedText(
            "猫",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange()
        )
        surface.insertText("猫", replacementRange: NSRange())
        #expect(!surface.hasMarkedText())
        #expect(
            Array(surface.preeditObservationsForTesting.dropFirst(preeditCount))
                == [.set(Data("猫".utf8)), .clear]
        )
        surface.insertText("!", replacementRange: NSRange())

        _ = try await firstValue(from: processExits, timeout: .seconds(10))
        surface.keyDown(with: event)
        let closeEvent = try await firstKeyboardCloseEvent(
            from: closeEvents,
            timeout: .seconds(10)
        )

        #expect(closeEvent == KeyboardSurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(try Data(contentsOf: fixture.resultURL) == Data("a猫".utf8))
    }
}

private struct KeyboardShortcutConfig {
    let directoryURL: URL
    let url: URL

    init(contents: String = "keybind = ctrl+KeyA=ignore\n") throws {
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

private struct KeyboardSurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

private enum KeyboardInputTestError: Error {
    case fifoCreationFailed(Int32)
    case processFailed(Int32)
    case streamEnded
    case timeout
}

@MainActor
private final class KeyboardPTYFixture {
    let directoryURL: URL
    let configURL: URL
    let resultURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let captureURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init(expectedPayloadByteCount: Int) throws {
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
        captureURL = directoryURL.appending(path: "capture")
        try Data("abnormal-command-exit-runtime = 0\n".utf8).write(to: configURL)

        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw KeyboardInputTestError.fifoCreationFailed(errno)
        }

        let transmittedByteCount = expectedPayloadByteCount + 1
        let script =
            "stty raw -echo; printf R > \(shellQuote(readyFIFOURL.path)); "
            + "dd bs=1 count=\(transmittedByteCount) of=\(shellQuote(captureURL.path)) 2>/dev/null; "
            + "if [ \"$(dd bs=1 skip=\(expectedPayloadByteCount) count=1 "
            + "if=\(shellQuote(captureURL.path)) 2>/dev/null)\" = '!' ]; then "
            + "dd bs=1 count=\(expectedPayloadByteCount) if=\(shellQuote(captureURL.path)) "
            + "of=\(shellQuote(resultURL.path)) 2>/dev/null; else "
            + "cp \(shellQuote(captureURL.path)) \(shellQuote(resultURL.path)); fi"
        command = "/bin/sh -c \(shellQuote(script))"

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
        let status = try await firstValue(from: readyExits, timeout: timeout)
        guard status == 0 else {
            throw KeyboardInputTestError.processFailed(status)
        }
        let data = readyOutput.fileHandleForReading.readDataToEndOfFile()
        guard data == Data("R".utf8) else {
            throw KeyboardInputTestError.processFailed(status)
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
private func makeKeyboardEvent(
    type: NSEvent.EventType,
    modifierFlags: NSEvent.ModifierFlags = [],
    characters: String,
    charactersIgnoringModifiers: String,
    keyCode: UInt16,
    timestamp: TimeInterval = 1,
    windowNumber: Int = 0
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

@MainActor
private func makeKeyboardTestWindow() -> NSWindow {
    KeyboardTestWindow(
        contentRect: NSRect(x: 120, y: 120, width: 800, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private final class KeyboardTestWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}

@MainActor
private func embedKeyboardSurface(_ surface: GhosttySurfaceView, in window: NSWindow) {
    guard let contentView = window.contentView else {
        Issue.record("Keyboard test window has no content view")
        return
    }
    surface.frame = contentView.bounds
    surface.autoresizingMask = [.width, .height]
    contentView.addSubview(surface)
    window.makeFirstResponder(surface)
}

private func firstKeyboardCloseEvent(
    from stream: AsyncStream<KeyboardSurfaceCloseEvent>,
    timeout: Duration
) async throws -> KeyboardSurfaceCloseEvent {
    try await firstValue(from: stream, timeout: timeout)
}

private func firstValue<Value: Sendable>(
    from stream: AsyncStream<Value>,
    timeout: Duration
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw KeyboardInputTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw KeyboardInputTestError.timeout
        }

        guard let value = try await group.next() else {
            throw KeyboardInputTestError.streamEnded
        }
        group.cancelAll()
        return value
    }
}

private func rectanglesApproximatelyEqual(
    _ lhs: NSRect,
    _ rhs: NSRect,
    tolerance: CGFloat = 0.000_001
) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
