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
    func failedTransitionRollsBackOwnershipVisibilityAndPersistence() throws {
        let content = NSViewController()
        content.view = NSView()
        let normal = FakePresentationContainer(
            frame: NSRect(x: 20, y: 30, width: 800, height: 500)
        )
        let quake = FakeQuakeContainer()
        var persistedModes: [PresentationMode] = []
        let controller = try PresentationController(
            contentViewController: content,
            normalWindowController: normal,
            quakeWindowController: quake,
            persistSuccessfulMode: { persistedModes.append($0) }
        )
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
private final class FakePresentationContainer: PresentationWindowContainer {
    private(set) var presentationFrame: NSRect
    private(set) var isPresentationVisible = false
    private(set) var installedContentViewController: NSViewController?
    var failNextInstall = false
    var failNextShow = false

    init(frame: NSRect = .zero) {
        presentationFrame = frame
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
    }

    func hidePresentationWindow() {
        isPresentationVisible = false
    }
}

@MainActor
private final class FakeQuakeContainer: QuakePresentationWindowContainer {
    private(set) var presentationFrame: NSRect = .zero
    private(set) var isPresentationVisible = false
    private(set) var installedContentViewController: NSViewController?
    private(set) var requestedVisibility: QuakeVisibility = .hidden
    private(set) var visibilityRequestCount = 0
    var failNextInstall = false
    var failNextShow = false

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

    func setPresentationFrame(_ frame: NSRect) {
        presentationFrame = frame
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        installedContentViewController = contentViewController
    }

    func orderFrontForPresentation() {
        isPresentationVisible = true
    }

    func focusForPresentation() {
        focusCount += 1
        isPresentationVisible = true
    }

    func orderOutForPresentation() {
        isPresentationVisible = false
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
        let completion: @MainActor () -> Void
        let cancellation: ManualCancellation
    }

    private(set) var requests: [Request] = []

    func animate(
        window: any QuakeWindowRepresenting,
        to frame: NSRect,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> any PresentationCancellation {
        let cancellation = ManualCancellation()
        requests.append(Request(frame: frame, completion: completion, cancellation: cancellation))
        return cancellation
    }

    func completeRequest(at index: Int) {
        requests[index].completion()
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
