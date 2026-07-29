import AppKit
import Testing

@testable import QuickTTY

struct GhosttySurfaceSearchOverlayTests {
    @Test
    func countFormattingMatchesPinnedGhostty() {
        #expect(GhosttySearchPresentation.countText(selected: 3, total: 17) == "4/17")
        #expect(GhosttySearchPresentation.countText(selected: nil, total: 5) == "-/5")
        #expect(GhosttySearchPresentation.countText(selected: nil, total: nil) == nil)
        #expect(GhosttySearchPresentation.countText(selected: 0, total: nil) == "1/?")
    }

    @Test
    func returnUsesExactNativeNavigationActions() {
        #expect(
            GhosttySearchPresentation.returnAction(shiftPressed: false)
                == "navigate_search:next"
        )
        #expect(
            GhosttySearchPresentation.returnAction(shiftPressed: true)
                == "navigate_search:previous"
        )
        #expect(GhosttySearchPresentation.nextAction == "navigate_search:next")
        #expect(GhosttySearchPresentation.previousAction == "navigate_search:previous")
    }

    @Test
    func escapeAlwaysCloses() {
        #expect(
            GhosttySearchPresentation.escapeDecision(needle: "") == .close
        )
        #expect(
            GhosttySearchPresentation.escapeDecision(needle: "needle") == .close
        )
    }

    @Test
    func interactionRegionConvertsSwiftUICoordinatesForBothHostOrientations() {
        let flippedRegion = GhosttySearchInteractionRegion(
            swiftUIFrame: CGRect(x: 771.5, y: 8, width: 320.5, height: 44)
        )
        let flippedBounds = CGRect(x: 0, y: 0, width: 1100, height: 672)

        #expect(
            flippedRegion.contains(
                hostPoint: CGPoint(x: 900, y: 640),
                hostBounds: flippedBounds,
                hostIsFlipped: true
            )
        )
        #expect(
            !flippedRegion.contains(
                hostPoint: CGPoint(x: 900, y: 20),
                hostBounds: flippedBounds,
                hostIsFlipped: true
            )
        )

        let nonFlippedRegion = GhosttySearchInteractionRegion(
            swiftUIFrame: CGRect(x: 10, y: 10, width: 80, height: 30)
        )
        let nonFlippedBounds = CGRect(x: 0, y: 0, width: 200, height: 100)

        #expect(
            nonFlippedRegion.contains(
                hostPoint: CGPoint(x: 20, y: 20),
                hostBounds: nonFlippedBounds,
                hostIsFlipped: false
            )
        )
        #expect(
            !nonFlippedRegion.contains(
                hostPoint: CGPoint(x: 20, y: 80),
                hostBounds: nonFlippedBounds,
                hostIsFlipped: false
            )
        )
    }

    @Test
    @MainActor
    func hostedOverlayMeasuresTopRightHitRegionAndUpdatesItAfterResize() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        let interactionState = GhosttySearchInteractionState()
        let searchState = SearchState()
        let overlay = GhosttySurfaceSearchOverlay(
            searchState: searchState,
            interactionState: interactionState,
            onBindingAction: { _ in },
            onSearchFieldFocusChanged: { _ in },
            onClose: {}
        )
        let hostingView = GhosttySearchHostingView(
            rootView: overlay,
            interactionState: interactionState
        )
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        #expect(
            waitForOverlayCondition {
                contentView.layoutSubtreeIfNeeded()
                hostingView.layoutSubtreeIfNeeded()
                return interactionState.interactionRegion != nil
            }
        )
        let initialRegion = try #require(interactionState.interactionRegion)
        #expect(initialRegion.swiftUIFrame.minX > hostingView.bounds.midX)
        #expect(abs(initialRegion.swiftUIFrame.maxX - (hostingView.bounds.maxX - 8)) < 1)

        let initialInside = hostingPoint(
            swiftUIPoint: CGPoint(
                x: initialRegion.swiftUIFrame.midX,
                y: initialRegion.swiftUIFrame.midY
            ),
            in: hostingView
        )
        let initialOutside = hostingPoint(
            swiftUIPoint: CGPoint(x: 1, y: hostingView.bounds.maxY - 1),
            in: hostingView
        )
        #expect(hostingView.hitTest(initialInside) != nil)
        #expect(hostingView.hitTest(initialOutside) == nil)

        window.setContentSize(NSSize(width: 900, height: 320))
        #expect(
            waitForOverlayCondition {
                contentView.layoutSubtreeIfNeeded()
                hostingView.layoutSubtreeIfNeeded()
                guard let updated = interactionState.interactionRegion else { return false }
                return updated.swiftUIFrame.minX > initialRegion.swiftUIFrame.minX + 100
            }
        )
        let updatedRegion = try #require(interactionState.interactionRegion)
        #expect(updatedRegion.swiftUIFrame.size == initialRegion.swiftUIFrame.size)
        #expect(abs(updatedRegion.swiftUIFrame.maxX - (hostingView.bounds.maxX - 8)) < 1)

        let formerLeadingEdge = hostingPoint(
            swiftUIPoint: CGPoint(
                x: initialRegion.swiftUIFrame.minX + 1,
                y: initialRegion.swiftUIFrame.midY
            ),
            in: hostingView
        )
        let updatedInside = hostingPoint(
            swiftUIPoint: CGPoint(
                x: updatedRegion.swiftUIFrame.midX,
                y: updatedRegion.swiftUIFrame.midY
            ),
            in: hostingView
        )
        #expect(hostingView.hitTest(formerLeadingEdge) == nil)
        #expect(hostingView.hitTest(updatedInside) != nil)
    }

    @Test
    @MainActor
    func hostingViewPassesThroughBeforeMeasurementAndRestrictsHitsToMeasuredBar() {
        let interactionState = GhosttySearchInteractionState()
        let searchState = SearchState()
        let overlay = GhosttySurfaceSearchOverlay(
            searchState: searchState,
            interactionState: interactionState,
            onBindingAction: { _ in },
            onSearchFieldFocusChanged: { _ in },
            onClose: {}
        )
        let hostingView = GhosttySearchHostingView(
            rootView: overlay,
            interactionState: interactionState
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        var baseHitTestCallCount = 0
        hostingView.baseHitTestForTesting = { _ in
            baseHitTestCallCount += 1
            return hostingView
        }

        #expect(hostingView.hitTest(CGPoint(x: 20, y: 20)) == nil)
        #expect(baseHitTestCallCount == 0)

        interactionState.interactionRegion = GhosttySearchInteractionRegion(
            swiftUIFrame: CGRect(x: 10, y: 10, width: 80, height: 30)
        )
        let inside = hostingPoint(
            swiftUIPoint: CGPoint(x: 20, y: 20),
            in: hostingView
        )
        let outside = hostingPoint(
            swiftUIPoint: CGPoint(x: 150, y: 70),
            in: hostingView
        )

        #expect(hostingView.hitTest(outside) == nil)
        #expect(baseHitTestCallCount == 0)
        #expect(hostingView.hitTest(inside) === hostingView)
        #expect(baseHitTestCallCount == 1)
    }

    @MainActor
    private func waitForOverlayCondition(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.01))
            )
        }
        return condition()
    }

    @MainActor
    private func hostingPoint(
        swiftUIPoint: CGPoint,
        in hostingView: NSView
    ) -> CGPoint {
        CGPoint(
            x: hostingView.bounds.minX + swiftUIPoint.x,
            y: hostingView.isFlipped
                ? hostingView.bounds.maxY - swiftUIPoint.y
                : hostingView.bounds.minY + swiftUIPoint.y
        )
    }
}
