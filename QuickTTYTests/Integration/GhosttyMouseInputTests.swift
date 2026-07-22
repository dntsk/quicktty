import AppKit
import Darwin
import Foundation
import Testing

@testable import QuickTTY

extension GhosttyBridgeTests {
    @Test
    func mouseAndScrollRemainDirectWhenKeyboardProviderTargetsOtherSurfaces() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        bridge.inputTargetProvider = { _ in [source.paneID, other.paneID] }

        source.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                surface: source,
                buttonNumber: 0
            )
        )
        source.scrollWheel(with: try makeScrollEvent(x: 0, y: 1, precise: false, momentum: []))

        #expect(source.mouseButtonObservationsForTesting.count == 1)
        #expect(source.mouseScrollObservationsForTesting.count == 1)
        #expect(other.mouseButtonObservationsForTesting.isEmpty)
        #expect(other.mouseScrollObservationsForTesting.isEmpty)
        #expect(bridge.inputObservationsForTesting.isEmpty)
    }

    @Test
    func mouseTypesMatchPinnedABIAndExactButtonMapping() {
        #expect(GhosttyInput.mouseABIMatchesPinnedHeader)
        #expect(GhosttyMouseAction.release.cValue.rawValue == 0)
        #expect(GhosttyMouseAction.press.cValue.rawValue == 1)

        let expectedButtons: [GhosttyMouseButton] = [
            .left,
            .right,
            .middle,
            .eight,
            .nine,
            .six,
            .seven,
            .four,
            .five,
            .ten,
            .eleven,
        ]
        #expect((0...10).map(GhosttyMouseButton.init(buttonNumber:)) == expectedButtons)
        #expect(GhosttyMouseButton(buttonNumber: -1) == .unknown)
        #expect(GhosttyMouseButton(buttonNumber: 11) == .unknown)
        #expect(
            [
                GhosttyMouseButton.unknown,
                .left,
                .right,
                .middle,
                .four,
                .five,
                .six,
                .seven,
                .eight,
                .nine,
                .ten,
                .eleven,
            ].map(\.cValue.rawValue) == Array(0...11)
        )
    }

    @Test
    func scrollMomentumAndPackedModifiersMatchPinnedABI() {
        let phases: [(NSEvent.Phase, GhosttyScrollMomentum)] = [
            ([], .none),
            (.began, .began),
            (.stationary, .stationary),
            (.changed, .changed),
            (.ended, .ended),
            (.cancelled, .cancelled),
            (.mayBegin, .mayBegin),
        ]

        #expect(phases.map { GhosttyScrollMomentum($0.0) } == phases.map(\.1))
        #expect(phases.map(\.1.rawValue) == Array(0...6))
        #expect(phases.map { Int($0.1.cValue.rawValue) } == Array(0...6))
        for (index, momentum) in phases.map(\.1).enumerated() {
            let packed = GhosttyScrollModifiers(precision: true, momentum: momentum)
            #expect(packed.rawValue == Int32(1 | (index << 1)))
            #expect(packed.precision)
            #expect(packed.momentum == momentum)
            #expect(packed.cValue == packed.rawValue)
        }
    }

    @Test
    func buttonsCallRealSourceSurfaceOnlyWithExactSideMapping() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeMouseTestWindow()
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedMouseSurfaces(source, other, in: window)
        let routeCount = bridge.inputObservationsForTesting.count
        let modifiers: NSEvent.ModifierFlags = [.shift, .option]

        source.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                surface: source,
                buttonNumber: 0,
                modifierFlags: modifiers
            )
        )
        source.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                surface: source,
                buttonNumber: 0,
                modifierFlags: modifiers
            )
        )
        source.rightMouseDown(
            with: try makeMouseEvent(
                type: .rightMouseDown,
                surface: source,
                buttonNumber: 1,
                modifierFlags: modifiers
            )
        )
        source.rightMouseUp(
            with: try makeMouseEvent(
                type: .rightMouseUp,
                surface: source,
                buttonNumber: 1,
                modifierFlags: modifiers
            )
        )

        for buttonNumber in 2...10 {
            source.otherMouseDown(
                with: try makeMouseEvent(
                    type: .otherMouseDown,
                    surface: source,
                    buttonNumber: buttonNumber,
                    modifierFlags: modifiers
                )
            )
            source.otherMouseUp(
                with: try makeMouseEvent(
                    type: .otherMouseUp,
                    surface: source,
                    buttonNumber: buttonNumber,
                    modifierFlags: modifiers
                )
            )
        }
        source.mouseMoved(
            with: try makeMouseEvent(
                type: .mouseMoved,
                surface: source,
                modifierFlags: modifiers
            )
        )
        source.scrollWheel(
            with: try makeScrollEvent(x: 0, y: 1, precise: false, momentum: [])
        )

        let observations = source.mouseButtonObservationsForTesting
        #expect(observations.count == 22)
        #expect(observations[0].action == .press)
        #expect(observations[0].button == .left)
        #expect(observations[1].action == .release)
        #expect(observations[1].button == .left)
        #expect(observations[2].button == .right)
        #expect(observations[3].button == .right)
        let sideButtons = observations.dropFirst(4).enumerated().compactMap {
            offset, observation in
            offset.isMultiple(of: 2) ? observation.button : nil
        }
        #expect(
            sideButtons == [
                .middle,
                .eight,
                .nine,
                .six,
                .seven,
                .four,
                .five,
                .ten,
                .eleven,
            ])
        #expect(observations.allSatisfy { $0.modifiers == [.shift, .option] })
        #expect(source.mousePositionObservationsForTesting.count == 1)
        #expect(source.mouseScrollObservationsForTesting.count == 1)
        #expect(bridge.inputObservationsForTesting.count == routeCount)
        #expect(other.mouseButtonObservationsForTesting.isEmpty)
        #expect(other.mousePositionObservationsForTesting.isEmpty)
        #expect(other.mouseScrollObservationsForTesting.isEmpty)
    }

    @Test
    func positionsUseTopLeftLogicalPointsAndEveryDragUsesPositionPath() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeMouseTestWindow()
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedMouseSurface(surface, in: window, frame: NSRect(x: 40, y: 30, width: 320, height: 240))

        let entered = try makeMouseEvent(
            type: .mouseEntered,
            surface: surface,
            localLocation: NSPoint(x: 12, y: 230),
            modifierFlags: [.control]
        )
        let moved = try makeMouseEvent(
            type: .mouseMoved,
            surface: surface,
            localLocation: NSPoint(x: 20, y: 210),
            modifierFlags: [.option]
        )
        let leftDrag = try makeMouseEvent(
            type: .leftMouseDragged,
            surface: surface,
            localLocation: NSPoint(x: 30, y: 200),
            buttonNumber: 0
        )
        let rightDrag = try makeMouseEvent(
            type: .rightMouseDragged,
            surface: surface,
            localLocation: NSPoint(x: 40, y: 190),
            buttonNumber: 1
        )
        let otherDrag = try makeMouseEvent(
            type: .otherMouseDragged,
            surface: surface,
            localLocation: NSPoint(x: 50, y: 180),
            buttonNumber: 2
        )
        let exited = try makeMouseEvent(
            type: .mouseExited,
            surface: surface,
            localLocation: NSPoint(x: 330, y: 100),
            modifierFlags: [.command]
        )

        surface.mouseEntered(with: entered)
        surface.mouseMoved(with: moved)
        surface.mouseDragged(with: leftDrag)
        surface.rightMouseDragged(with: rightDrag)
        surface.otherMouseDragged(with: otherDrag)
        surface.mouseExited(with: exited)

        let observations = surface.mousePositionObservationsForTesting
        #expect(observations.count == 6)
        #expect(observations[0].eventIdentifier == ObjectIdentifier(entered))
        #expect(observations[0].x == 12)
        #expect(observations[0].y == 10)
        #expect(observations[0].modifiers == [.control])
        #expect(observations[1].x == 20)
        #expect(observations[1].y == 30)
        #expect(observations[2].x == 30)
        #expect(observations[2].y == 40)
        #expect(observations[3].x == 40)
        #expect(observations[3].y == 50)
        #expect(observations[4].x == 50)
        #expect(observations[4].y == 60)
        #expect(observations[5].eventIdentifier == ObjectIdentifier(exited))
        #expect(observations[5].x == -1)
        #expect(observations[5].y == -1)
        #expect(observations[5].modifiers == [.command])
    }

    @Test
    func preciseScrollDoublesBothAxesAndPacksMomentumPhase() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let precise = try makeScrollEvent(
            x: 3,
            y: -4,
            precise: true,
            momentum: .changed
        )
        let discrete = try makeScrollEvent(
            x: -2,
            y: 1,
            precise: false,
            momentum: .ended
        )

        surface.scrollWheel(with: precise)
        surface.scrollWheel(with: discrete)

        let observations = surface.mouseScrollObservationsForTesting
        #expect(observations.count == 2)
        #expect(observations[0].eventIdentifier == ObjectIdentifier(precise))
        #expect(observations[0].x == 6)
        #expect(observations[0].y == -8)
        #expect(observations[0].packedModifiers == 0b0000_0111)
        #expect(observations[1].eventIdentifier == ObjectIdentifier(discrete))
        #expect(observations[1].x == -2)
        #expect(observations[1].y == 1)
        #expect(observations[1].packedModifiers == 0b0000_1000)
    }

    @Test
    func trackingAreaAndFocusMonitorAreReplacedAndRemovedExactly() throws {
        let initialMonitorCount = GhosttySurfaceView.focusMonitorCountForTesting
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )

        let firstAreas = ownedTrackingAreas(of: surface)
        let first = try #require(firstAreas.first)
        #expect(firstAreas.count == 1)
        #expect(first.options.contains(.mouseEnteredAndExited))
        #expect(first.options.contains(.mouseMoved))
        #expect(first.options.contains(.inVisibleRect))
        #expect(first.options.contains(.activeAlways))
        #expect(surface.focusClickMonitorInstalledForTesting)
        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount + 1)

        surface.updateTrackingAreas()

        let replacementAreas = ownedTrackingAreas(of: surface)
        let replacement = try #require(replacementAreas.first)
        #expect(replacementAreas.count == 1)
        #expect(ObjectIdentifier(replacement) != ObjectIdentifier(first))

        bridge.closeSurface(id: surface.paneID)

        #expect(ownedTrackingAreas(of: surface).isEmpty)
        #expect(!surface.focusClickMonitorInstalledForTesting)
        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount)
    }

    @Test
    func focusOnlyClickIsSuppressedWhileActivationClickPassesThrough() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeMouseTestWindow()
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedMouseSurfaces(source, other, in: window)
        _ = window.makeFirstResponder(other)
        let sourceClick = try makeMouseEvent(
            type: .leftMouseDown,
            surface: source,
            buttonNumber: 0
        )
        let sourceUp = try makeMouseEvent(
            type: .leftMouseUp,
            surface: source,
            buttonNumber: 0
        )

        let suppressed = source.processFocusClickForTesting(
            sourceClick,
            applicationIsActive: true
        )
        source.mouseUp(with: sourceUp)

        #expect(suppressed == nil)
        #expect(window.firstResponder === source)
        #expect(source.mouseButtonObservationsForTesting.isEmpty)

        _ = window.makeFirstResponder(other)
        let activationClick = try makeMouseEvent(
            type: .leftMouseDown,
            surface: source,
            buttonNumber: 0,
            timestamp: 2
        )
        let passedThrough = source.processFocusClickForTesting(
            activationClick,
            applicationIsActive: false
        )

        #expect(!source.acceptsFirstMouse(for: activationClick))
        #expect(passedThrough === activationClick)
        #expect(window.firstResponder === source)
        #expect(source.mouseButtonObservationsForTesting.isEmpty)
    }

    @Test
    func installedMonitorChainSuppressesFocusClickForSourceSurfaceOnly() throws {
        let initialMonitorCount = GhosttySurfaceView.focusMonitorCountForTesting
        let bridge = try GhosttyBridge(applicationIsActive: { true })
        defer { bridge.shutdown() }
        let window = makeMouseTestWindow()
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedMouseSurfaces(source, other, in: window)
        _ = window.makeFirstResponder(other)
        let down = try makeMouseEvent(
            type: .leftMouseDown,
            surface: source,
            buttonNumber: 0
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            surface: source,
            buttonNumber: 0
        )

        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount + 2)
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)

        #expect(window.firstResponder === source)
        #expect(source.mouseButtonObservationsForTesting.isEmpty)
        #expect(other.mouseButtonObservationsForTesting.isEmpty)

        bridge.closeSurface(id: source.paneID)
        bridge.closeSurface(id: other.paneID)
        #expect(GhosttySurfaceView.focusMonitorCountForTesting == initialMonitorCount)
    }

    @Test
    func losingFocusClearsPendingFocusClickSuppression() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let window = makeMouseTestWindow()
        let source = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let other = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        embedMouseSurfaces(source, other, in: window)
        _ = window.makeFirstResponder(other)
        let down = try makeMouseEvent(
            type: .leftMouseDown,
            surface: source,
            buttonNumber: 0
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            surface: source,
            buttonNumber: 0
        )

        #expect(source.processFocusClickForTesting(down, applicationIsActive: true) == nil)
        _ = window.makeFirstResponder(other)
        source.mouseUp(with: up)

        let release = try #require(source.mouseButtonObservationsForTesting.last)
        #expect(release.action == .release)
        #expect(release.button == .left)
    }

    @Test
    func allMouseEntrypointsAfterCloseAreNoOps() throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let mouse = try makeMouseEvent(type: .leftMouseDown, surface: surface, buttonNumber: 0)
        let scroll = try makeScrollEvent(x: 1, y: 1, precise: false, momentum: [])
        bridge.closeSurface(id: surface.paneID)

        surface.mouseDown(with: mouse)
        surface.mouseUp(with: mouse)
        surface.rightMouseDown(with: mouse)
        surface.rightMouseUp(with: mouse)
        surface.otherMouseDown(with: mouse)
        surface.otherMouseUp(with: mouse)
        surface.mouseEntered(with: mouse)
        surface.mouseExited(with: mouse)
        surface.mouseMoved(with: mouse)
        surface.mouseDragged(with: mouse)
        surface.rightMouseDragged(with: mouse)
        surface.otherMouseDragged(with: mouse)
        surface.scrollWheel(with: scroll)
        surface.updateTrackingAreas()

        #expect(surface.mouseButtonObservationsForTesting.isEmpty)
        #expect(surface.mousePositionObservationsForTesting.isEmpty)
        #expect(surface.mouseScrollObservationsForTesting.isEmpty)
        #expect(ownedTrackingAreas(of: surface).isEmpty)
    }

    @Test
    func realPTYReportsExactSGRPressReleaseScrollAndConsumedRightClick() async throws {
        let expected = Data(
            ("\u{1B}[<0;1;1M"
                + "\u{1B}[<0;1;1m"
                + "\u{1B}[<64;1;1M"
                + "\u{1B}[<2;1;1M"
                + "\u{1B}[<2;1;1m").utf8
        )
        let fixture = try MousePTYFixture(expectedByteCount: expected.count)
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
            of: MouseSurfaceCloseEvent.self
        )
        defer { closeContinuation.finish() }

        try fixture.startReadyReader()
        let surface = try bridge.makeSurface(
            id: paneID,
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        ) { paneID, processAlive in
            closeContinuation.yield(
                MouseSurfaceCloseEvent(paneID: paneID, processAlive: processAlive)
            )
        }
        let window = makeMouseTestWindow()
        embedMouseSurface(surface, in: window)
        try await fixture.awaitReady(timeout: .seconds(10))

        let position = try makeMouseEvent(
            type: .mouseMoved,
            surface: surface,
            localLocation: NSPoint(x: 1, y: surface.bounds.height - 1)
        )
        let leftDown = try makeMouseEvent(
            type: .leftMouseDown,
            surface: surface,
            localLocation: NSPoint(x: 1, y: surface.bounds.height - 1),
            buttonNumber: 0
        )
        let leftUp = try makeMouseEvent(
            type: .leftMouseUp,
            surface: surface,
            localLocation: NSPoint(x: 1, y: surface.bounds.height - 1),
            buttonNumber: 0
        )
        let scroll = try makeScrollEvent(x: 0, y: 1, precise: false, momentum: [])
        let rightDown = try makeMouseEvent(
            type: .rightMouseDown,
            surface: surface,
            localLocation: NSPoint(x: 1, y: surface.bounds.height - 1),
            buttonNumber: 1
        )
        let rightUp = try makeMouseEvent(
            type: .rightMouseUp,
            surface: surface,
            localLocation: NSPoint(x: 1, y: surface.bounds.height - 1),
            buttonNumber: 1
        )

        surface.mouseMoved(with: position)
        surface.mouseDown(with: leftDown)
        surface.mouseUp(with: leftUp)
        surface.scrollWheel(with: scroll)
        surface.rightMouseDown(with: rightDown)
        surface.rightMouseUp(with: rightUp)

        _ = try await firstMouseValue(from: processExits, timeout: .seconds(10))
        surface.keyDown(with: try makeCommandExitKeyEvent())
        let closeEvent = try await firstMouseCloseEvent(
            from: closeEvents,
            timeout: .seconds(10)
        )
        #expect(closeEvent == MouseSurfaceCloseEvent(paneID: paneID, processAlive: false))
        #expect(try Data(contentsOf: fixture.resultURL) == expected)
        let rightObservations = surface.mouseButtonObservationsForTesting.filter {
            $0.button == .right
        }
        #expect(rightObservations.count == 2)
        #expect(rightObservations.allSatisfy { $0.consumed })
    }
}

private struct MouseSurfaceCloseEvent: Equatable, Sendable {
    let paneID: PaneID
    let processAlive: Bool
}

private enum MouseInputTestError: Error {
    case fifoCreationFailed(Int32)
    case processFailed(Int32)
    case streamEnded
    case timeout
}

@MainActor
private final class MousePTYFixture {
    let directoryURL: URL
    let configURL: URL
    let resultURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init(expectedByteCount: Int) throws {
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
            "abnormal-command-exit-runtime = 0\nmouse-scroll-multiplier = discrete:1\n".utf8
        ).write(to: configURL)

        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw MouseInputTestError.fifoCreationFailed(errno)
        }

        let script =
            "stty raw -echo; "
            + "printf '\\033[?1000h\\033[?1006h\\033[?1000$p'; "
            + "response=\"$(dd bs=1 count=11 2>/dev/null)\"; "
            + "if [ \"$response\" = \"$(printf '\\033[?1000;1$y')\" ]; then "
            + "printf R > \(shellQuoteMouse(readyFIFOURL.path)); "
            + "dd bs=1 count=\(expectedByteCount) of=\(shellQuoteMouse(resultURL.path)) "
            + "2>/dev/null; else printf '%s' \"$response\" > "
            + "\(shellQuoteMouse(resultURL.path)); exit 97; fi"
        command = "/bin/sh -c \(shellQuoteMouse(script))"

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
        let status = try await firstMouseValue(from: readyExits, timeout: timeout)
        guard status == 0 else {
            throw MouseInputTestError.processFailed(status)
        }
        let data = readyOutput.fileHandleForReading.readDataToEndOfFile()
        guard data == Data("R".utf8) else {
            throw MouseInputTestError.processFailed(status)
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
private func makeMouseTestWindow() -> NSWindow {
    MouseTestWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private final class MouseTestWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}

@MainActor
private func embedMouseSurface(
    _ surface: GhosttySurfaceView,
    in window: NSWindow,
    frame: NSRect? = nil
) {
    guard let contentView = window.contentView else {
        Issue.record("Mouse test window has no content view")
        return
    }
    surface.frame = frame ?? contentView.bounds
    contentView.addSubview(surface)
}

@MainActor
private func embedMouseSurfaces(
    _ first: GhosttySurfaceView,
    _ second: GhosttySurfaceView,
    in window: NSWindow
) {
    guard let contentView = window.contentView else {
        Issue.record("Mouse test window has no content view")
        return
    }
    let halfWidth = contentView.bounds.width / 2
    first.frame = NSRect(
        x: 0,
        y: 0,
        width: halfWidth,
        height: contentView.bounds.height
    )
    second.frame = NSRect(
        x: halfWidth,
        y: 0,
        width: halfWidth,
        height: contentView.bounds.height
    )
    contentView.addSubview(first)
    contentView.addSubview(second)
}

@MainActor
private func makeMouseEvent(
    type: NSEvent.EventType,
    surface: GhosttySurfaceView,
    localLocation: NSPoint = NSPoint(x: 10, y: 10),
    buttonNumber: Int = 0,
    modifierFlags: NSEvent.ModifierFlags = [],
    timestamp: TimeInterval = 1
) throws -> NSEvent {
    let location = surface.convert(localLocation, to: nil)
    let windowNumber = surface.window?.windowNumber ?? 0
    if type == .mouseEntered || type == .mouseExited {
        return try #require(
            NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: modifierFlags,
                timestamp: timestamp,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                trackingNumber: 1,
                userData: nil
            )
        )
    }

    let baseEvent = try #require(
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    )
    guard type == .otherMouseDown || type == .otherMouseUp,
        baseEvent.buttonNumber != buttonNumber,
        let coreGraphicsEvent = baseEvent.cgEvent
    else { return baseEvent }

    coreGraphicsEvent.setIntegerValueField(
        .mouseEventButtonNumber,
        value: Int64(buttonNumber)
    )
    return try #require(NSEvent(cgEvent: coreGraphicsEvent))
}

@MainActor
private func makeCommandExitKeyEvent() throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )
    )
}

@MainActor
private func makeScrollEvent(
    x: Int32,
    y: Int32,
    precise: Bool,
    momentum: NSEvent.Phase
) throws -> NSEvent {
    SyntheticScrollEvent(
        x: CGFloat(x),
        y: CGFloat(y),
        precise: precise,
        momentum: momentum
    )
}

private final class SyntheticScrollEvent: NSEvent {
    private let syntheticX: CGFloat
    private let syntheticY: CGFloat
    private let syntheticPrecision: Bool
    private let syntheticMomentum: NSEvent.Phase

    init(x: CGFloat, y: CGFloat, precise: Bool, momentum: NSEvent.Phase) {
        syntheticX = x
        syntheticY = y
        syntheticPrecision = precise
        syntheticMomentum = momentum
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var type: NSEvent.EventType {
        .scrollWheel
    }

    override var scrollingDeltaX: CGFloat {
        syntheticX
    }

    override var scrollingDeltaY: CGFloat {
        syntheticY
    }

    override var hasPreciseScrollingDeltas: Bool {
        syntheticPrecision
    }

    override var momentumPhase: NSEvent.Phase {
        syntheticMomentum
    }
}

@MainActor
private func ownedTrackingAreas(of surface: GhosttySurfaceView) -> [NSTrackingArea] {
    surface.trackingAreas.filter { $0.owner === surface }
}

private func firstMouseCloseEvent(
    from stream: AsyncStream<MouseSurfaceCloseEvent>,
    timeout: Duration
) async throws -> MouseSurfaceCloseEvent {
    try await firstMouseValue(from: stream, timeout: timeout)
}

private func firstMouseValue<Value: Sendable>(
    from stream: AsyncStream<Value>,
    timeout: Duration
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            throw MouseInputTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MouseInputTestError.timeout
        }

        guard let value = try await group.next() else {
            throw MouseInputTestError.streamEnded
        }
        group.cancelAll()
        return value
    }
}

private func shellQuoteMouse(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
