import AppKit
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
        let bridge = try GhosttyBridge()
        defer { bridge.shutdown() }
        let first = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let second = try bridge.makeSurface(
            configuration: GhosttySurfaceConfiguration(command: "exec /bin/cat")
        )
        let controller = WorkspaceViewController()

        controller.displayTerminal(
            root: .pane(first.paneID),
            surfaces: [first.paneID: first],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        await Task.yield()
        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(first)])

        controller.displayTerminal(
            root: .pane(second.paneID),
            surfaces: [second.paneID: second],
            palette: .fallback,
            onResize: { _, _ in },
            onEqualize: { _ in }
        )
        await Task.yield()

        #expect(controller.renderedSurfaceIdentifiersForTesting == [ObjectIdentifier(second)])
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
