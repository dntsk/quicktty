import AppKit
import Darwin
import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct GhosttySplitTreeViewTests {
    @Test
    func surfaceFailurePresentationPreservesMessageAndValueSemantics() {
        let message = "The terminal failed to start."
        let presentation = SurfaceFailurePresentation(message: message)

        #expect(presentation.message == message)
        #expect(presentation == SurfaceFailurePresentation(message: message))
        #expect(presentation != SurfaceFailurePresentation(message: "A different error"))
        requireSendable(presentation)
    }

    @Test
    func descriptorRecursivelyMapsNestedSplitTreeForUpstreamRendering() {
        let firstPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdPaneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let outerSplitID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let innerSplitID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let root = SplitNode.split(
            id: outerSplitID,
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(firstPaneID),
            second: .split(
                id: innerSplitID,
                axis: .vertical,
                ratio: 0.7,
                first: .pane(secondPaneID),
                second: .pane(thirdPaneID)
            )
        )

        #expect(
            GhosttySplitTreeDescriptor(root: root)
                == .split(
                    id: outerSplitID,
                    direction: .horizontal,
                    ratio: 0.4,
                    first: .pane(firstPaneID),
                    second: .split(
                        id: innerSplitID,
                        direction: .vertical,
                        ratio: 0.7,
                        first: .pane(secondPaneID),
                        second: .pane(thirdPaneID)
                    )
                )
        )
    }

    @Test
    func switchingPaneRootsReplacesTheActualHostedSurfaceView() async throws {
        let fixture = try SizeSensitiveChildFixture()
        defer { fixture.remove() }
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        try fixture.startReadyReader()
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: fixture.command)
        )
        try await fixture.awaitReady(timeout: .seconds(10))
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        let controller = WorkspaceViewController()
        let window = mountWorkspace(controller)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])

        controller.displayTerminal(
            root: .pane(second.paneID),
            surfaces: [second.paneID: second],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(second)])

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)

        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])
        #expect(!first.processExitedForTesting)
        #expect(!second.processExitedForTesting)
        let firstObservations = first.sizeRequestObservationsForTesting
        #expect(!firstObservations.isEmpty)
        #expect(
            firstObservations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
        let secondObservations = second.sizeRequestObservationsForTesting
        #expect(!secondObservations.isEmpty)
        #expect(
            secondObservations.allSatisfy {
                $0.resultingSize.columns >= 5 && $0.resultingSize.rows >= 2
            })
    }

    private func settleWorkspace(_ controller: WorkspaceViewController, in window: NSWindow) async {
        for _ in 0..<4 {
            layoutWorkspace(controller, in: window)
            await Task.yield()
            runMainLoopOnce()
        }
        layoutWorkspace(controller, in: window)
    }

    private func layoutWorkspace(_ controller: WorkspaceViewController, in window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
    }

    private func runMainLoopOnce() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func mountWorkspace(_ controller: WorkspaceViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        guard let contentView = window.contentView else {
            preconditionFailure("Expected test window content view")
        }
        let controllerView = controller.view
        controllerView.frame = contentView.bounds
        controllerView.autoresizingMask = [.width, .height]
        contentView.addSubview(controllerView)
        contentView.layoutSubtreeIfNeeded()
        controllerView.layoutSubtreeIfNeeded()
        return window
    }

    @Test
    func splitCallbacksKeepSplitAndUnavailablePaneIdentity() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let unavailablePaneID = PaneID()
        var resized: (UUID, Double)?
        var equalized: UUID?
        var retriedPaneID: PaneID?
        var closedPaneID: PaneID?
        let callbacks = GhosttySplitTreeCallbacks(
            onResize: { id, ratio in resized = (id, ratio) },
            onEqualize: { id in equalized = id },
            onRetryUnavailablePane: { retriedPaneID = $0 },
            onCloseUnavailablePane: { closedPaneID = $0 }
        )

        callbacks.resize(splitID, ratio: 0.625)
        callbacks.equalize(splitID)
        callbacks.retryUnavailablePane(unavailablePaneID)
        callbacks.closeUnavailablePane(unavailablePaneID)

        #expect(resized?.0 == splitID)
        #expect(resized?.1 == 0.625)
        #expect(equalized == splitID)
        #expect(retriedPaneID == unavailablePaneID)
        #expect(closedPaneID == unavailablePaneID)
    }

    @Test
    func unavailablePaneMountsPlaceholderAndButtonsRouteItsPaneIdentity() async throws {
        let controller = WorkspaceViewController()
        let paneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let message = "Surface creation failed for this pane."
        var retriedPaneIDs: [PaneID] = []
        var closedPaneIDs: [PaneID] = []
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(paneID),
            surfaces: [:],
            failures: [paneID: SurfaceFailurePresentation(message: message)],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { retriedPaneIDs.append($0) },
            onCloseUnavailablePane: { closedPaneIDs.append($0) }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let mountedViews = mountedViews(in: splitHost)
        #expect(mountedViews.contains { $0 is SurfaceErrorPlaceholderView })
        #expect(mountedText(in: mountedViews).contains("Terminal unavailable"))
        #expect(mountedText(in: mountedViews).contains(message))
        #expect(buttonTitles(in: mountedViews) == ["Retry", "Close Pane"])
        let retryButton = try #require(button(titled: "Retry", in: mountedViews))
        let closeButton = try #require(button(titled: "Close Pane", in: mountedViews))
        #expect(retryButton.accessibilityLabel() == "Retry")
        #expect(closeButton.accessibilityLabel() == "Close Pane")

        retryButton.performClick(nil)
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs.isEmpty)
        closeButton.performClick(nil)
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs == [paneID])
        #expect(controller.hostedSurfaceIdentifiersForTesting.isEmpty)
        #expect(!controller.emptyWorkspaceLabelIsVisibleForTesting)
    }

    @Test
    func placeholderAppliesCustomPaletteToAllVisibleControls() throws {
        let palette = GhosttyChromePalette(
            background: GhosttyRGB(red: 17, green: 49, blue: 83),
            foreground: GhosttyRGB(red: 211, green: 187, blue: 149)
        )
        let message = "Surface creation failed for this pane."
        let placeholder = SurfaceErrorPlaceholderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )

        placeholder.apply(
            presentation: SurfaceFailurePresentation(message: message),
            palette: palette,
            onRetry: {},
            onClosePane: {}
        )
        placeholder.layoutSubtreeIfNeeded()

        let views = mountedViews(in: placeholder)
        let expectedBackground = NSColor(ghosttyRGB: palette.background)
        let expectedForeground = NSColor(ghosttyRGB: palette.foreground)
        let backgroundColor = try #require(placeholder.layer?.backgroundColor)
        let titleLabel = try #require(textField(with: "Terminal unavailable", in: views))
        let messageLabel = try #require(textField(with: message, in: views))
        let retryButton = try #require(button(titled: "Retry", in: views))
        let closeButton = try #require(button(titled: "Close Pane", in: views))

        #expect(colorsMatch(NSColor(cgColor: backgroundColor), expectedBackground))
        #expect(colorsMatch(titleLabel.textColor, expectedForeground))
        #expect(colorsMatch(messageLabel.textColor, expectedForeground))
        #expect(colorsMatch(retryButton.contentTintColor, expectedForeground))
        #expect(colorsMatch(closeButton.contentTintColor, expectedForeground))
    }

    @Test
    func tinyPlaceholderScrollsToBothPaneActionsAndRestoresAfterResize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let host = try #require(window.contentView)
        let placeholder = SurfaceErrorPlaceholderView(
            frame: NSRect(x: 0, y: 0, width: 80, height: 60)
        )
        let adjacentLeaf = NSView(frame: NSRect(x: 80, y: 0, width: 720, height: 600))
        host.addSubview(placeholder)
        host.addSubview(adjacentLeaf)

        let paneID = PaneID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let message = "Surface creation failed for this pane."
        var retriedPaneIDs: [PaneID] = []
        var closedPaneIDs: [PaneID] = []
        let callbacks = GhosttySplitTreeCallbacks(
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { retriedPaneIDs.append($0) },
            onCloseUnavailablePane: { closedPaneIDs.append($0) }
        )
        placeholder.apply(
            presentation: SurfaceFailurePresentation(message: message),
            palette: .fallback,
            onRetry: { callbacks.retryUnavailablePane(paneID) },
            onClosePane: { callbacks.closeUnavailablePane(paneID) }
        )
        host.layoutSubtreeIfNeeded()
        placeholder.layoutSubtreeIfNeeded()

        var views = mountedViews(in: placeholder)
        let scrollView = try #require(views.compactMap { $0 as? NSScrollView }.first)
        let retryButton = try #require(button(titled: "Retry", in: views))
        let closeButton = try #require(button(titled: "Close Pane", in: views))
        #expect(buttonTitles(in: views) == ["Retry", "Close Pane"])
        #expect(placeholder.clipsToBounds)
        #expect(scrollView.contentView.clipsToBounds)
        #expect(scrollView.frame == placeholder.bounds)
        for view in views {
            #expect(!view.hasAmbiguousLayout)
            #expect(hasFiniteNonnegativeSize(view))
        }
        #expect(mountedText(in: views).contains("Terminal unavailable"))
        #expect(mountedText(in: views).contains(message))
        #expect(retryButton.accessibilityLabel() == "Retry")
        #expect(closeButton.accessibilityLabel() == "Close Pane")

        let documentView = try #require(scrollView.documentView)
        let clipView = scrollView.contentView
        let viewport = clipView.bounds
        #expect(documentView.frame.width > viewport.width)
        #expect(documentView.frame.height > viewport.height)
        #expect(documentView.bounds.contains(scrollView.documentVisibleRect))
        #expect(scrollView.documentVisibleRect.width <= viewport.width)
        #expect(scrollView.documentVisibleRect.height <= viewport.height)

        for button in [retryButton, closeButton] {
            let buttonFrame = button.convert(button.bounds, to: documentView)
            let maximumOrigin = NSPoint(
                x: documentView.frame.width - clipView.bounds.width,
                y: documentView.frame.height - clipView.bounds.height
            )
            clipView.scroll(
                to: NSPoint(
                    x: buttonFrame.midX < documentView.bounds.midX ? maximumOrigin.x : 0,
                    y: 0
                )
            )
            scrollView.reflectScrolledClipView(clipView)
            #expect(!scrollView.documentVisibleRect.contains(buttonFrame.center))

            clipView.scroll(
                to: NSPoint(
                    x: min(max(0, buttonFrame.midX - (clipView.bounds.width / 2)), maximumOrigin.x),
                    y: min(max(0, buttonFrame.midY - (clipView.bounds.height / 2)), maximumOrigin.y)
                )
            )
            scrollView.reflectScrolledClipView(clipView)

            #expect(scrollView.documentVisibleRect.contains(buttonFrame.center))
            let pointInHost = button.convert(button.bounds.center, to: host)
            let hitView = host.hitTest(pointInHost)
            #expect(hitView === button || hitView?.isDescendant(of: button) == true)
            button.performClick(nil)
        }
        #expect(retriedPaneIDs == [paneID])
        #expect(closedPaneIDs == [paneID])

        let pointOverAdjacentLeaf = NSPoint(x: adjacentLeaf.frame.minX + 1, y: 30)
        #expect(!placeholder.frame.contains(pointOverAdjacentLeaf))
        let outsideHit = host.hitTest(pointOverAdjacentLeaf)
        #expect(
            outsideHit === adjacentLeaf
                || outsideHit?.isDescendant(of: adjacentLeaf) == true
        )

        placeholder.frame.size = NSSize(width: 640, height: 320)
        adjacentLeaf.frame = NSRect(x: 640, y: 0, width: 160, height: 600)
        host.layoutSubtreeIfNeeded()
        placeholder.layoutSubtreeIfNeeded()
        views = mountedViews(in: placeholder)
        for view in views {
            #expect(!view.hasAmbiguousLayout)
            #expect(hasFiniteNonnegativeSize(view))
        }
        for button in [retryButton, closeButton] {
            let frame = button.convert(button.bounds, to: placeholder)
            #expect(placeholder.bounds.contains(frame))
            let point = button.convert(button.bounds.center, to: host)
            let hitView = host.hitTest(point)
            #expect(hitView === button || hitView?.isDescendant(of: button) == true)
        }
    }

    @Test
    func placeholderMatchesDefaultAppKitHitTestingInAllHostConfigurations() throws {
        let leafFrame = NSRect(x: 700, y: 500, width: 640, height: 320)
        for host in [
            NSView(frame: NSRect(x: 0, y: 0, width: 1_500, height: 1_200)),
            FlippedHitTestHostView(frame: NSRect(x: 0, y: 0, width: 1_500, height: 1_200)),
        ] {
            let defaultLeaf = NSView(frame: leafFrame)
            host.addSubview(defaultLeaf)
            let insideLeaf = NSPoint(x: leafFrame.midX, y: leafFrame.midY)
            let outsideLeaf = NSPoint(x: leafFrame.minX - 1, y: leafFrame.midY)
            #expect(defaultLeaf.hitTest(insideLeaf) === defaultLeaf)
            #expect(defaultLeaf.hitTest(outsideLeaf) == nil)
            defaultLeaf.removeFromSuperview()

            let placeholder = SurfaceErrorPlaceholderView(frame: leafFrame)
            placeholder.apply(
                presentation: SurfaceFailurePresentation(message: "Surface creation failed."),
                palette: .fallback,
                onRetry: {},
                onClosePane: {}
            )
            host.addSubview(placeholder)
            host.layoutSubtreeIfNeeded()
            placeholder.layoutSubtreeIfNeeded()

            let views = mountedViews(in: placeholder)
            let retryButton = try #require(button(titled: "Retry", in: views))
            let closeButton = try #require(button(titled: "Close Pane", in: views))
            for button in [retryButton, closeButton] {
                let pointInHost = button.convert(button.bounds.center, to: host)
                let hitView = placeholder.hitTest(pointInHost)
                #expect(hitView === button || hitView?.isDescendant(of: button) == true)
            }
            #expect(placeholder.hitTest(outsideLeaf) == nil)
        }

        let defaultDetachedLeaf = NSView(frame: leafFrame)
        let detachedPlaceholder = SurfaceErrorPlaceholderView(frame: leafFrame)
        detachedPlaceholder.layoutSubtreeIfNeeded()
        let insideDetachedLeaf = NSPoint(x: leafFrame.midX, y: leafFrame.midY)
        let outsideDetachedLeaf = NSPoint(x: leafFrame.minX - 1, y: leafFrame.midY)
        #expect(defaultDetachedLeaf.hitTest(insideDetachedLeaf) === defaultDetachedLeaf)
        #expect(defaultDetachedLeaf.hitTest(outsideDetachedLeaf) == nil)
        #expect(detachedPlaceholder.hitTest(insideDetachedLeaf) != nil)
        #expect(detachedPlaceholder.hitTest(outsideDetachedLeaf) == nil)
    }

    @Test
    func liveSurfaceTakesPriorityOverFailureForTheSamePane() async throws {
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let surface = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "/bin/cat")
        )
        let controller = WorkspaceViewController()
        let message = "This failure must not replace a live terminal."
        let window = mountWorkspace(controller)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        controller.displayTerminal(
            root: .pane(surface.paneID),
            surfaces: [surface.paneID: surface],
            failures: [surface.paneID: SurfaceFailurePresentation(message: message)],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        await settleWorkspace(controller, in: window)

        let splitHost = try #require(controller.splitHostingViewForTesting)
        let mountedViews = mountedViews(in: splitHost)
        let renderedSurfaces = mountedViews.compactMap { $0 as? GhosttySurfaceView }
        #expect(renderedSurfaces.map(ObjectIdentifier.init) == [ObjectIdentifier(surface)])
        #expect(!mountedViews.contains { $0 is SurfaceErrorPlaceholderView })
        #expect(!mountedText(in: mountedViews).contains("Terminal unavailable"))
        #expect(!mountedText(in: mountedViews).contains(message))
        #expect(button(titled: "Retry", in: mountedViews) == nil)
        #expect(button(titled: "Close Pane", in: mountedViews) == nil)
    }

    @Test
    func missingLeafPreservesSplitHostAndOnlyNilRootShowsEmptyWorkspace() throws {
        let controller = WorkspaceViewController()
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(
            root: .pane(firstPaneID),
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )
        let originalHost = try #require(controller.splitHostingControllerIdentifierForTesting)

        controller.displayTerminal(
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(firstPaneID),
                second: .pane(secondPaneID)
            ),
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == originalHost)
        #expect(!controller.emptyWorkspaceLabelIsVisibleForTesting)

        controller.displayTerminal(
            root: nil,
            surfaces: [:],
            failures: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in },
            onRetryUnavailablePane: { _ in },
            onCloseUnavailablePane: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == nil)
        #expect(controller.emptyWorkspaceLabelIsVisibleForTesting)
    }
}

@MainActor
private func mountedViews(in rootView: NSView) -> [NSView] {
    [rootView] + rootView.subviews.flatMap(mountedViews)
}

@MainActor
private func mountedText(in views: [NSView]) -> Set<String> {
    Set(views.compactMap { ($0 as? NSTextField)?.stringValue })
}

@MainActor
private func textField(with value: String, in views: [NSView]) -> NSTextField? {
    views.compactMap { $0 as? NSTextField }.first { $0.stringValue == value }
}

@MainActor
private func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard
        let lhs = lhs?.usingColorSpace(.deviceRGB),
        let rhs = rhs.usingColorSpace(.deviceRGB)
    else {
        return false
    }
    let tolerance = CGFloat(1) / 255
    return abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
}

@MainActor
private func button(titled title: String, in views: [NSView]) -> NSButton? {
    views.compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func buttonTitles(in views: [NSView]) -> Set<String> {
    Set(views.compactMap { ($0 as? NSButton)?.title })
}

@MainActor
private final class FlippedHitTestHostView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func hasFiniteNonnegativeSize(_ view: NSView) -> Bool {
    let frame = view.frame
    return frame.origin.x.isFinite && frame.origin.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.width >= 0 && frame.height >= 0
}

extension NSRect {
    fileprivate var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private func requireSendable<T: Sendable>(_: T) {}

private enum SizeSensitiveChildError: Error {
    case fifoCreationFailed(Int32)
    case childProcessFailed(Int32)
    case eventStreamEnded
    case timeout
}

@MainActor
private final class SizeSensitiveChildFixture {
    let directoryURL: URL
    let command: String

    private let readyFIFOURL: URL
    private let readyReader = Process()
    private let readyOutput = Pipe()
    private let readyExits: AsyncStream<Int32>
    private let readyExitContinuation: AsyncStream<Int32>.Continuation

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        readyFIFOURL = directoryURL.appending(path: "ready.fifo")
        let fifoResult = readyFIFOURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fifoResult == 0 else {
            throw SizeSensitiveChildError.fifoCreationFailed(errno)
        }

        let scriptURL = directoryURL.appending(path: "size-sensitive-child")
        let script = """
            #!/bin/sh
            check_size() {
                set -- $(stty size)
                [ "$#" -eq 2 ] && [ "$1" -ge 2 ] && [ "$2" -ge 5 ] || exit 91
            }
            trap 'check_size' WINCH
            printf R > \(shellQuoteSizeSensitiveChild(readyFIFOURL.path))
            while :; do
                sleep 1 &
                wait $!
            done
            """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        command = "/bin/sh \(shellQuoteSizeSensitiveChild(scriptURL.path))"

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
        let status = try await firstSizeSensitiveChildExit(
            from: readyExits,
            timeout: timeout
        )
        guard status == 0 else {
            throw SizeSensitiveChildError.childProcessFailed(status)
        }
        guard readyOutput.fileHandleForReading.readDataToEndOfFile() == Data("R".utf8) else {
            throw SizeSensitiveChildError.childProcessFailed(status)
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

private func firstSizeSensitiveChildExit(
    from stream: AsyncStream<Int32>,
    timeout: Duration
) async throws -> Int32 {
    try await withThrowingTaskGroup(of: Int32.self) { group in
        group.addTask {
            for await status in stream {
                return status
            }
            throw SizeSensitiveChildError.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SizeSensitiveChildError.timeout
        }

        guard let status = try await group.next() else {
            throw SizeSensitiveChildError.eventStreamEnded
        }
        group.cancelAll()
        return status
    }
}

private func shellQuoteSizeSensitiveChild(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
