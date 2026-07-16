import AppKit
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct PresentationStateMachineTests {
    @Test
    func geometrySelectsCursorScreenAndBuildsVisibleAndHiddenFrames() throws {
        let left = NSRect(x: -1_200, y: 0, width: 1_200, height: 800)
        let right = NSRect(x: 0, y: 24, width: 1_440, height: 876)
        let geometry = try #require(QuakeWindowGeometry(heightFraction: 0.75, padding: 10))

        let selected = QuakeWindowGeometry.visibleFrame(
            under: NSPoint(x: 800, y: 400),
            from: [.zero, left, right]
        )
        let target = try #require(geometry.targetFrame(in: right))
        let hidden = geometry.hiddenFrame(for: target, above: right)

        #expect(selected == right)
        #expect(target == NSRect(x: 10, y: 233, width: 1_420, height: 657))
        #expect(hidden == NSRect(x: 10, y: 900, width: 1_420, height: 657))
        #expect(hidden.minY == right.maxY)
    }

    @Test
    func geometryNormalizesManualHeightWithFixedWidthAndTopAnchor() throws {
        let geometry = try #require(QuakeWindowGeometry(heightFraction: 0.75, padding: 10))
        let visibleFrame = NSRect(x: 100, y: 20, width: 1_200, height: 800)

        let resized = try #require(
            geometry.normalizedManualFrame(
                proposedHeight: 260,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        )
        let minimum = try #require(
            geometry.normalizedManualFrame(
                proposedHeight: 10,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        )
        let maximum = try #require(
            geometry.normalizedManualFrame(
                proposedHeight: 2_000,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        )
        let tiny = try #require(
            geometry.normalizedManualFrame(
                proposedHeight: 260,
                in: NSRect(x: 0, y: 0, width: 500, height: 120),
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        )

        #expect(resized == NSRect(x: 110, y: 550, width: 1_180, height: 260))
        #expect(resized.maxY == visibleFrame.maxY - 10)
        #expect(minimum.height == QuakeWindow.minimumContentHeight)
        #expect(maximum.height == 780)
        #expect(tiny == NSRect(x: 10, y: 10, width: 480, height: 100))
    }

    @Test
    func geometryUsesNearestVisibleFrameForMenuBarAndRejectsInvalidConfiguration() {
        let left = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = NSRect(x: 1_000, y: 0, width: 1_000, height: 760)

        #expect(
            QuakeWindowGeometry.visibleFrame(
                under: NSPoint(x: 1_800, y: 790),
                from: [left, right]
            ) == right
        )
        #expect(QuakeWindowGeometry(heightFraction: 0, padding: 0) == nil)
        #expect(QuakeWindowGeometry(heightFraction: 1.01, padding: 0) == nil)
        #expect(QuakeWindowGeometry(heightFraction: 0.75, padding: -1) == nil)
    }

    @Test
    func quakeWindowIsBorderlessResizableAndHasMinimumHeight() {
        let window = QuakeWindow()

        #expect(window.styleMask.contains(.borderless))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize.height == QuakeWindow.minimumContentHeight)
    }

    @Test
    func liveResizePersistsNormalizedHeightOnceAndIgnoresProgrammaticFrames() throws {
        let window = QuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        var persistedHeights: [Double] = []
        let controller = QuakeWindowController(
            window: window,
            configuration: QuakeWindowConfiguration(
                geometry: QuakeWindowGeometry(heightFraction: 0.75, padding: 0)!
            ),
            visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
            cursorLocation: { NSPoint(x: 500, y: 500) },
            animator: animator,
            animationDeferrer: ImmediatePresentationDeferrer(),
            scheduler: scheduler,
            isFocusLossSuppressed: { false },
            priorApplicationProvider: { nil },
            persistQuakeHeight: { persistedHeights.append($0) }
        )
        let notification = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)

        controller.setPresentationFrame(NSRect(x: 1, y: 2, width: 3, height: 4))
        controller.windowDidEndLiveResize(notification)
        #expect(persistedHeights.isEmpty)

        controller.windowWillStartLiveResize(
            Notification(name: NSWindow.willStartLiveResizeNotification, object: window)
        )
        #expect(
            controller.windowWillResize(window, to: NSSize(width: 600, height: 300))
                == NSSize(width: 1_200, height: 300)
        )
        window.setFrame(NSRect(x: 100, y: 400, width: 600, height: 300), display: false)
        controller.windowDidEndLiveResize(notification)
        controller.windowDidEndLiveResize(notification)

        #expect(persistedHeights == [300.0 / 780.0])
        #expect(window.frame == NSRect(x: 0, y: 500, width: 1_200, height: 300))
    }

    @Test
    func transitionsReparentOneControllerRestoreFrameAndPersistOnlySuccess() throws {
        let content = NSViewController()
        content.view = NSView()
        let originalFrame = NSRect(x: 40, y: 50, width: 900, height: 600)
        let normal = FakePresentationContainer(frame: originalFrame)
        let quake = FakeQuakeContainer()
        var persistedModes: [PresentationMode] = []
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { persistedModes.append($0) }
        )

        try controller.transition(to: .quake)

        #expect(controller.mode == .quake)
        #expect(controller.savedNormalFrame == originalFrame)
        #expect(normal.installedContentViewController == nil)
        #expect(quake.installedContentViewController === content)
        #expect(!normal.isPresentationVisible)
        #expect(quake.isPresentationVisible)
        #expect(persistedModes == [.quake])

        normal.setPresentationFrame(NSRect(x: 1, y: 2, width: 300, height: 200))
        try controller.transition(to: .normal)
        try controller.transition(to: .normal)

        #expect(controller.mode == .normal)
        #expect(normal.presentationFrame == originalFrame)
        #expect(normal.installedContentViewController === content)
        #expect(quake.installedContentViewController == nil)
        #expect(normal.isPresentationVisible)
        #expect(!quake.isPresentationVisible)
        #expect(persistedModes == [.quake, .normal])
    }

    @Test
    func configDrivenTransitionDoesNotPersistWhileReparentingContent() throws {
        let content = NSViewController()
        content.view = NSView()
        let normal = FakePresentationContainer()
        let quake = FakeQuakeContainer()
        var persistedModes: [PresentationMode] = []
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { persistedModes.append($0) }
        )

        try controller.transition(to: .quake, persist: false)

        #expect(controller.mode == .quake)
        #expect(normal.installedContentViewController == nil)
        #expect(quake.installedContentViewController === content)
        #expect(persistedModes.isEmpty)
    }

    @Test
    func transitionDoesNotHideSourceBeforeDestinationShows() throws {
        let content = NSViewController()
        content.view = NSView()
        let events = PresentationTransitionEvents()
        let normal = FakePresentationContainer(events: events)
        let quake = FakeQuakeContainer(events: events)
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { _ in }
        )

        events.reset()
        try controller.transition(to: .quake)
        let quakeShow = try #require(events.values.firstIndex(of: "quake.show"))
        let normalHide = try #require(events.values.firstIndex(of: "normal.hide"))
        #expect(quakeShow < normalHide)

        events.reset()
        try controller.transition(to: .normal)
        let normalShow = try #require(events.values.firstIndex(of: "normal.show"))
        let quakeDeactivate = try #require(events.values.firstIndex(of: "quake.deactivate"))
        #expect(normalShow < quakeDeactivate)
    }

    @Test
    func failedTransitionRollsBackOwnershipVisibilityAndPersistence() throws {
        let content = NSViewController()
        content.view = NSView()
        let events = PresentationTransitionEvents()
        let normal = FakePresentationContainer(
            frame: NSRect(x: 20, y: 30, width: 800, height: 500),
            events: events
        )
        let quake = FakeQuakeContainer(events: events)
        var persistedModes: [PresentationMode] = []
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { persistedModes.append($0) }
        )
        events.reset()
        quake.failNextInstall = true

        #expect(throws: FakePresentationError.installFailed) {
            try controller.transition(to: .quake)
        }

        #expect(controller.mode == .normal)
        #expect(controller.savedNormalFrame == nil)
        #expect(normal.installedContentViewController === content)
        #expect(quake.installedContentViewController == nil)
        #expect(normal.isPresentationVisible)
        #expect(!quake.isPresentationVisible)
        #expect(!events.values.contains("normal.hide"))
        #expect(persistedModes.isEmpty)
    }

    @Test
    func quakeAnimationRequestsAreIdempotentAndLastRequestWins() throws {
        let window = FakeQuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        let priorApplication = FakeApplicationActivation()
        var priorApplicationRequests = 0
        let controller = makeQuakeController(
            window: window,
            animator: animator,
            scheduler: scheduler,
            priorApplicationProvider: {
                priorApplicationRequests += 1
                return priorApplication
            }
        )

        try controller.requestVisibility(.shown)
        try controller.requestVisibility(.shown)
        try controller.requestVisibility(.hidden)

        #expect(animator.requests.count == 2)
        #expect(animator.requests[0].cancellation.isCancelled)
        #expect(priorApplicationRequests == 1)

        animator.completeRequest(at: 0)
        #expect(window.focusCount == 0)
        #expect(window.isPresentationVisible)

        animator.completeRequest(at: 1)
        #expect(!window.isPresentationVisible)
        #expect(priorApplication.activationCount == 1)

        try controller.requestVisibility(.hidden)
        #expect(animator.requests.count == 2)
    }

    @Test
    func deferredShowUsesExpectedLevelCurveAndCompletionOrder() throws {
        let window = FakeQuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        let deferrer = ManualPresentationDeferrer()
        let controller = makeQuakeController(
            window: window,
            animator: animator,
            scheduler: scheduler,
            animationDeferrer: deferrer
        )

        try controller.requestVisibility(.shown)

        #expect(window.events.suffix(3) == ["frame", "level.popUpMenu", "front"])
        #expect(animator.requests.isEmpty)
        deferrer.runActiveRequests()
        #expect(animator.requests.count == 1)
        #expect(
            animator.requests[0].request
                == QuakeAnimationRequest(
                    visibility: .shown,
                    curve: .easeOut
                ))

        animator.completeRequest(at: 0)
        let restore = try #require(window.events.lastIndex(of: "level.floating"))
        let focus = try #require(window.events.lastIndex(of: "focus"))
        #expect(restore < focus)
    }

    @Test
    func cancellingDeferredShowPreventsItsAnimationAndHideRaisesLevelBeforeAnimating() throws {
        let window = FakeQuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        let deferrer = ManualPresentationDeferrer()
        let priorApplication = FakeApplicationActivation()
        let controller = makeQuakeController(
            window: window,
            animator: animator,
            scheduler: scheduler,
            animationDeferrer: deferrer,
            priorApplicationProvider: { priorApplication }
        )

        try controller.requestVisibility(.shown)
        try controller.requestVisibility(.hidden)

        #expect(deferrer.requests[0].cancellation.isCancelled)
        #expect(window.events.last == "level.popUpMenu")
        #expect(!window.events.contains("out"))
        deferrer.runActiveRequests()
        #expect(animator.requests.count == 1)
        #expect(
            animator.requests[0].request
                == QuakeAnimationRequest(
                    visibility: .hidden,
                    curve: .easeIn
                ))

        animator.completeRequest(at: 0)
        let orderOut = try #require(window.events.lastIndex(of: "out"))
        let floating = try #require(window.events.lastIndex(of: "level.floating"))
        #expect(orderOut < floating)
        #expect(priorApplication.activationCount == 1)
    }

    @Test
    func reversingHideKeepsIntermediateFrameAndIgnoresOldCompletion() throws {
        let window = FakeQuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        let controller = makeQuakeController(
            window: window,
            animator: animator,
            scheduler: scheduler
        )
        let visibleTarget = NSRect(x: 0, y: 215, width: 1_200, height: 585)
        let intermediateFrame = NSRect(x: 0, y: 500, width: 1_200, height: 585)

        try controller.requestVisibility(.shown)
        animator.completeRequest(at: 0)
        try controller.requestVisibility(.hidden)
        window.setPresentationFrame(intermediateFrame)
        let frameSetsBeforeReversal = window.presentationFrames

        try controller.requestVisibility(.shown)

        #expect(animator.requests.count == 3)
        #expect(animator.requests[1].cancellation.isCancelled)
        #expect(animator.requests[2].frame == visibleTarget)
        #expect(window.presentationFrames == frameSetsBeforeReversal)

        animator.completeRequest(at: 1)
        #expect(window.isPresentationVisible)
        #expect(!window.events.contains("out"))
        #expect(controller.requestedVisibility == .shown)
    }

    @Test
    func focusLossDelayCancelsAndHonorsInjectedSuppression() throws {
        let window = FakeQuakeWindow()
        let animator = ManualQuakeAnimator()
        let scheduler = ManualPresentationScheduler()
        let suppression = FocusLossSuppressionState()
        let controller = makeQuakeController(
            window: window,
            animator: animator,
            scheduler: scheduler,
            isFocusLossSuppressed: { suppression.isSuppressed }
        )

        try controller.requestVisibility(.shown)
        animator.completeRequest(at: 0)
        controller.focusDidResignKey()
        controller.focusDidBecomeKey()

        #expect(scheduler.requests.count == 1)
        #expect(scheduler.requests[0].cancellation.isCancelled)
        scheduler.runActiveRequests()
        #expect(controller.requestedVisibility == .shown)

        suppression.isSuppressed = true
        controller.focusDidResignKey()
        scheduler.runActiveRequests()
        #expect(controller.requestedVisibility == .shown)

        suppression.isSuppressed = false
        controller.focusDidResignKey()
        scheduler.runActiveRequests()
        #expect(controller.requestedVisibility == .hidden)
        #expect(animator.requests.count == 2)
    }

    @Test
    func hotKeyIntegrationCallbackOnlyTogglesInQuakeMode() throws {
        let content = NSViewController()
        content.view = NSView()
        let normal = FakePresentationContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let quake = FakeQuakeContainer()
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { _ in }
        )

        controller.toggleQuakeVisibility()
        #expect(quake.visibilityRequestCount == 0)

        try controller.transition(to: .quake)
        controller.toggleQuakeVisibility()
        controller.toggleQuakeVisibility()

        #expect(quake.visibilityRequestCount == 3)
        #expect(quake.requestedVisibility == .shown)
    }

    private func makeQuakeController(
        window: FakeQuakeWindow,
        animator: ManualQuakeAnimator,
        scheduler: ManualPresentationScheduler,
        animationDeferrer: any PresentationDeferring = ImmediatePresentationDeferrer(),
        isFocusLossSuppressed: @escaping @MainActor () -> Bool = { false },
        priorApplicationProvider:
            @escaping @MainActor () ->
            (any PresentationApplicationActivation)? = { nil }
    ) -> QuakeWindowController {
        QuakeWindowController(
            window: window,
            configuration: QuakeWindowConfiguration(
                geometry: QuakeWindowGeometry(heightFraction: 0.75, padding: 0)!,
                animationDuration: 0.2,
                focusLossDelay: 0.1
            ),
            visibleFrames: { [NSRect(x: 0, y: 20, width: 1_200, height: 780)] },
            cursorLocation: { NSPoint(x: 500, y: 500) },
            animator: animator,
            animationDeferrer: animationDeferrer,
            scheduler: scheduler,
            isFocusLossSuppressed: isFocusLossSuppressed,
            priorApplicationProvider: priorApplicationProvider
        )
    }
}

private enum FakePresentationError: Error {
    case installFailed
    case showFailed
}

@MainActor
private final class PresentationTransitionEvents {
    private(set) var values: [String] = []

    func record(_ event: String) {
        values.append(event)
    }

    func reset() {
        values.removeAll()
    }
}

@MainActor
private final class FakePresentationContainer: PresentationWindowContainer {
    private(set) var presentationFrame: NSRect
    private(set) var isPresentationVisible = false
    private(set) var installedContentViewController: NSViewController?
    private let events: PresentationTransitionEvents?
    var failNextInstall = false
    var failNextShow = false

    init(frame: NSRect = .zero, events: PresentationTransitionEvents? = nil) {
        presentationFrame = frame
        self.events = events
    }

    func setPresentationFrame(_ frame: NSRect) {
        presentationFrame = frame
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        if failNextInstall {
            failNextInstall = false
            throw FakePresentationError.installFailed
        }
        installedContentViewController = contentViewController
    }

    func showPresentationWindow() throws {
        if failNextShow {
            failNextShow = false
            throw FakePresentationError.showFailed
        }
        isPresentationVisible = true
        events?.record("normal.show")
    }

    func hidePresentationWindow() {
        isPresentationVisible = false
        events?.record("normal.hide")
    }
}

@MainActor
private final class FakeQuakeContainer: QuakePresentationWindowContainer {
    private(set) var presentationFrame: NSRect = .zero
    private(set) var isPresentationVisible = false
    private(set) var installedContentViewController: NSViewController?
    private(set) var requestedVisibility: QuakeVisibility = .hidden
    private(set) var visibilityRequestCount = 0
    private let events: PresentationTransitionEvents?
    var failNextInstall = false
    var failNextShow = false

    init(events: PresentationTransitionEvents? = nil) {
        self.events = events
    }

    func setPresentationFrame(_ frame: NSRect) {
        presentationFrame = frame
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        if failNextInstall {
            failNextInstall = false
            throw FakePresentationError.installFailed
        }
        installedContentViewController = contentViewController
    }

    func showPresentationWindow() throws {
        if failNextShow {
            failNextShow = false
            throw FakePresentationError.showFailed
        }
        try requestVisibility(.shown)
        events?.record("quake.show")
    }

    func hidePresentationWindow() {
        deactivateForModeTransition()
    }

    func requestVisibility(_ visibility: QuakeVisibility) throws {
        guard requestedVisibility != visibility else { return }
        visibilityRequestCount += 1
        requestedVisibility = visibility
        isPresentationVisible = visibility == .shown
    }

    func deactivateForModeTransition() {
        requestedVisibility = .hidden
        isPresentationVisible = false
        events?.record("quake.deactivate")
    }

    func focusDidResignKey() {}

    func focusDidBecomeKey() {}
}

@MainActor
private final class FakeQuakeWindow: QuakeWindowRepresenting {
    private(set) var presentationFrame: NSRect = .zero
    private(set) var isPresentationVisible = false
    private(set) var installedContentViewController: NSViewController?
    var hasAttachedSheet = false
    private(set) var focusCount = 0
    private(set) var events: [String] = []
    private(set) var presentationFrames: [NSRect] = []

    func setPresentationFrame(_ frame: NSRect) {
        presentationFrame = frame
        presentationFrames.append(frame)
        events.append("frame")
    }

    func setPresentationLevel(_ level: QuakePresentationLevel) {
        events.append(level == .floating ? "level.floating" : "level.popUpMenu")
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        installedContentViewController = contentViewController
    }

    func orderFrontForPresentation() {
        isPresentationVisible = true
        events.append("front")
    }

    func focusForPresentation() {
        focusCount += 1
        isPresentationVisible = true
        events.append("focus")
    }

    func orderOutForPresentation() {
        isPresentationVisible = false
        events.append("out")
    }
}

@MainActor
private final class ManualCancellation: PresentationCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class ManualQuakeAnimator: QuakeFrameAnimating {
    struct Request {
        let frame: NSRect
        let request: QuakeAnimationRequest
        let completion: @MainActor () -> Void
        let cancellation: ManualCancellation
    }

    private(set) var requests: [Request] = []

    func animate(
        window: any QuakeWindowRepresenting,
        to frame: NSRect,
        request: QuakeAnimationRequest,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> any PresentationCancellation {
        let cancellation = ManualCancellation()
        requests.append(
            Request(
                frame: frame,
                request: request,
                completion: completion,
                cancellation: cancellation
            )
        )
        return cancellation
    }

    func completeRequest(at index: Int) {
        requests[index].completion()
    }
}

@MainActor
private final class ManualPresentationDeferrer: PresentationDeferring {
    struct Request {
        let action: @MainActor @Sendable () -> Void
        let cancellation: ManualCancellation
    }

    private(set) var requests: [Request] = []

    func deferAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let cancellation = ManualCancellation()
        requests.append(Request(action: action, cancellation: cancellation))
        return cancellation
    }

    func runActiveRequests() {
        let pendingRequests = requests
        requests.removeAll()
        for request in pendingRequests where !request.cancellation.isCancelled {
            request.action()
        }
    }
}

@MainActor
private final class ImmediatePresentationDeferrer: PresentationDeferring {
    func deferAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        action()
        return ManualCancellation()
    }
}

@MainActor
private final class ManualPresentationScheduler: PresentationScheduling {
    struct Request {
        let action: @MainActor @Sendable () -> Void
        let cancellation: ManualCancellation
    }

    private(set) var requests: [Request] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let cancellation = ManualCancellation()
        requests.append(Request(action: action, cancellation: cancellation))
        return cancellation
    }

    func runActiveRequests() {
        let pendingRequests = requests
        requests.removeAll()
        for request in pendingRequests where !request.cancellation.isCancelled {
            request.action()
        }
    }
}

@MainActor
private final class FocusLossSuppressionState {
    var isSuppressed = false
}

@MainActor
private final class FakeApplicationActivation: PresentationApplicationActivation {
    private(set) var activationCount = 0

    func activate() {
        activationCount += 1
    }
}
