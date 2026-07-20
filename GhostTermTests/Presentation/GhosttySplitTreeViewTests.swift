import AppKit
import Darwin
import Foundation
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct GhosttySplitTreeViewTests {
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
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])

        controller.displayTerminal(
            root: .pane(second.paneID),
            surfaces: [second.paneID: second],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        await settleWorkspace(controller, in: window)
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(second)])

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
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
    func resizeAndEqualizeCallbacksKeepTheSplitIdentity() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        var resized: (UUID, Double)?
        var equalized: UUID?
        let callbacks = GhosttySplitTreeCallbacks(
            onResize: { id, ratio in resized = (id, ratio) },
            onEqualize: { id in equalized = id }
        )

        callbacks.resize(splitID, ratio: 0.625)
        callbacks.equalize(splitID)

        #expect(resized?.0 == splitID)
        #expect(resized?.1 == 0.625)
        #expect(equalized == splitID)
    }

    @Test
    func workspaceControllerRetainsSplitHostWhenUpdatingRootAndRemovesItWhenEmpty() throws {
        let controller = WorkspaceViewController()
        let firstPaneID = PaneID()
        let secondPaneID = PaneID()

        controller.apply(WorkspaceStore())
        controller.displayTerminal(
            root: .pane(firstPaneID),
            surfaces: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
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
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == originalHost)
        #expect(!controller.emptyWorkspaceLabelIsVisibleForTesting)

        controller.displayTerminal(
            root: nil,
            surfaces: [:],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )

        #expect(controller.splitHostingControllerIdentifierForTesting == nil)
        #expect(controller.emptyWorkspaceLabelIsVisibleForTesting)
    }
}

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
