import AppKit

struct QuakeWindowGeometry: Equatable, Sendable {
    let heightFraction: CGFloat
    let padding: CGFloat

    init?(heightFraction: CGFloat, padding: CGFloat) {
        guard heightFraction.isFinite, heightFraction > 0, heightFraction <= 1,
            padding.isFinite, padding >= 0
        else { return nil }
        self.heightFraction = heightFraction
        self.padding = padding
    }

    static func visibleFrame(under point: NSPoint, from visibleFrames: [NSRect]) -> NSRect? {
        let validFrames = visibleFrames.filter(isValidVisibleFrame)
        if let containingFrame = validFrames.first(where: { $0.contains(point) }) {
            return containingFrame
        }
        return validFrames.min {
            squaredDistance(from: point, to: $0) < squaredDistance(from: point, to: $1)
        }
    }

    func targetFrame(in visibleFrame: NSRect) -> NSRect? {
        guard Self.isValidVisibleFrame(visibleFrame) else { return nil }
        let availableWidth = visibleFrame.width - (padding * 2)
        let availableHeight = visibleFrame.height - (padding * 2)
        guard availableWidth > 0, availableHeight > 0 else { return nil }
        let height = min(visibleFrame.height * heightFraction, availableHeight)
        return NSRect(
            x: visibleFrame.minX + padding,
            y: visibleFrame.maxY - padding - height,
            width: availableWidth,
            height: height
        )
    }

    func hiddenFrame(for targetFrame: NSRect, above visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: targetFrame.minX,
            y: visibleFrame.maxY,
            width: targetFrame.width,
            height: targetFrame.height
        )
    }

    func normalizedManualFrame(
        proposedHeight: CGFloat,
        in visibleFrame: NSRect,
        minimumHeight: CGFloat
    ) -> NSRect? {
        guard
            proposedHeight.isFinite,
            minimumHeight.isFinite,
            minimumHeight > 0,
            let targetFrame = targetFrame(in: visibleFrame)
        else { return nil }
        let maximumHeight = visibleFrame.height - (padding * 2)
        let height = min(max(proposedHeight, min(minimumHeight, maximumHeight)), maximumHeight)
        return NSRect(
            x: targetFrame.minX,
            y: visibleFrame.maxY - padding - height,
            width: targetFrame.width,
            height: height
        )
    }

    private static func isValidVisibleFrame(_ frame: NSRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite
            && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    private static func squaredDistance(from point: NSPoint, to frame: NSRect) -> CGFloat {
        let nearestX = min(max(point.x, frame.minX), frame.maxX)
        let nearestY = min(max(point.y, frame.minY), frame.maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY
        return (deltaX * deltaX) + (deltaY * deltaY)
    }
}

enum QuakeVisibility: Equatable, Sendable {
    case hidden
    case shown
}

struct QuakeWindowConfiguration: Equatable, Sendable {
    var geometry: QuakeWindowGeometry
    var animationDuration: TimeInterval
    var focusLossDelay: TimeInterval
    var hideOnFocusLoss: Bool

    init(
        geometry: QuakeWindowGeometry = QuakeWindowGeometry(
            heightFraction: 0.75,
            padding: 0
        )!,
        animationDuration: TimeInterval = 0.18,
        focusLossDelay: TimeInterval = 0.15,
        hideOnFocusLoss: Bool = true
    ) {
        precondition(animationDuration.isFinite && animationDuration >= 0)
        precondition(focusLossDelay.isFinite && focusLossDelay >= 0)
        self.geometry = geometry
        self.animationDuration = animationDuration
        self.focusLossDelay = focusLossDelay
        self.hideOnFocusLoss = hideOnFocusLoss
    }
}

enum QuakePresentationError: Error, Equatable {
    case noVisibleScreen
    case invalidVisibleFrame
}

@MainActor
protocol PresentationCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol PresentationScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation
}

enum QuakePresentationLevel: Equatable, Sendable {
    case floating
    case popUpMenu
}

enum QuakeAnimationCurve: Equatable, Sendable {
    case easeIn
    case easeOut
}

struct QuakeAnimationRequest: Equatable, Sendable {
    let visibility: QuakeVisibility
    let curve: QuakeAnimationCurve
}

@MainActor
protocol PresentationDeferring: AnyObject {
    func deferAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation
}

@MainActor
protocol QuakeFrameAnimating: AnyObject {
    func animate(
        window: any QuakeWindowRepresenting,
        to frame: NSRect,
        request: QuakeAnimationRequest,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> any PresentationCancellation
}

@MainActor
protocol PresentationApplicationActivation: AnyObject {
    func activate()
}

@MainActor
protocol QuakeWindowRepresenting: AnyObject {
    var presentationFrame: NSRect { get }
    var isPresentationVisible: Bool { get }
    var installedContentViewController: NSViewController? { get }
    var hasAttachedSheet: Bool { get }

    func setPresentationFrame(_ frame: NSRect)
    func setPresentationLevel(_ level: QuakePresentationLevel)
    func installContentViewController(_ contentViewController: NSViewController?) throws
    func orderFrontForPresentation()
    func focusForPresentation()
    func orderOutForPresentation()
}

@MainActor
protocol QuakePresentationWindowContainer: PresentationWindowContainer {
    var requestedVisibility: QuakeVisibility { get }

    func requestVisibility(_ visibility: QuakeVisibility) throws
    func deactivateForModeTransition()
    func focusDidResignKey()
    func focusDidBecomeKey()
}

@MainActor
final class QuakeWindowController: NSObject, NSWindowDelegate, QuakePresentationWindowContainer {
    typealias VisibleFramesProvider = @MainActor () -> [NSRect]
    typealias CursorLocationProvider = @MainActor () -> NSPoint
    typealias FocusLossSuppression = @MainActor () -> Bool
    typealias PriorApplicationProvider = @MainActor () -> (any PresentationApplicationActivation)?
    typealias ErrorHandler = @MainActor (Error) -> Void
    typealias QuakeHeightPersistence = @MainActor (Double) -> Void

    private let quakeWindow: any QuakeWindowRepresenting
    private var configuration: QuakeWindowConfiguration
    private let visibleFrames: VisibleFramesProvider
    private let cursorLocation: CursorLocationProvider
    private let animator: any QuakeFrameAnimating
    private let animationDeferrer: any PresentationDeferring
    private let scheduler: any PresentationScheduling
    private let isFocusLossSuppressed: FocusLossSuppression
    private let priorApplicationProvider: PriorApplicationProvider
    private let persistQuakeHeight: QuakeHeightPersistence
    private let onError: ErrorHandler
    private var animationCancellation: (any PresentationCancellation)?
    private var deferredAnimationCancellation: (any PresentationCancellation)?
    private var focusLossCancellation: (any PresentationCancellation)?
    private var animationGeneration = 0
    private var lastVisibleFrame: NSRect?
    private var priorApplication: (any PresentationApplicationActivation)?
    private var isLiveResizing = false
    private var isNormalizingLiveResize = false
    private var liveResizeVisibleFrame: NSRect?
    private(set) var requestedVisibility: QuakeVisibility

    init(
        window: any QuakeWindowRepresenting,
        configuration: QuakeWindowConfiguration = QuakeWindowConfiguration(),
        visibleFrames: @escaping VisibleFramesProvider,
        cursorLocation: @escaping CursorLocationProvider,
        animator: any QuakeFrameAnimating,
        animationDeferrer: any PresentationDeferring = MainRunLoopPresentationDeferrer(),
        scheduler: any PresentationScheduling,
        isFocusLossSuppressed: @escaping FocusLossSuppression,
        priorApplicationProvider: @escaping PriorApplicationProvider,
        persistQuakeHeight: @escaping QuakeHeightPersistence = { _ in },
        onError: @escaping ErrorHandler = { _ in }
    ) {
        quakeWindow = window
        self.configuration = configuration
        self.visibleFrames = visibleFrames
        self.cursorLocation = cursorLocation
        self.animator = animator
        self.animationDeferrer = animationDeferrer
        self.scheduler = scheduler
        self.isFocusLossSuppressed = isFocusLossSuppressed
        self.priorApplicationProvider = priorApplicationProvider
        self.persistQuakeHeight = persistQuakeHeight
        self.onError = onError
        requestedVisibility = window.isPresentationVisible ? .shown : .hidden
        super.init()
        (window as? NSWindow)?.delegate = self
    }

    convenience override init() {
        self.init(configuration: QuakeWindowConfiguration())
    }

    convenience init(
        configuration: QuakeWindowConfiguration,
        persistQuakeHeight: @escaping QuakeHeightPersistence = { _ in }
    ) {
        let window = QuakeWindow()
        self.init(
            window: window,
            configuration: configuration,
            visibleFrames: { NSScreen.screens.map(\.visibleFrame) },
            cursorLocation: { NSEvent.mouseLocation },
            animator: AppKitQuakeFrameAnimator(),
            animationDeferrer: MainRunLoopPresentationDeferrer(),
            scheduler: TaskPresentationScheduler(),
            isFocusLossSuppressed: {
                window.hasAttachedSheet || NSApp.modalWindow != nil
                    || NSApp.mainMenu?.highlightedItem != nil
            },
            priorApplicationProvider: {
                RunningApplicationActivationAdapter.frontmostOtherApplication()
            },
            persistQuakeHeight: persistQuakeHeight
        )
    }

    var appKitWindow: NSWindow? { quakeWindow as? NSWindow }

    isolated deinit {
        animationCancellation?.cancel()
        deferredAnimationCancellation?.cancel()
        focusLossCancellation?.cancel()
        if let window = quakeWindow as? NSWindow, window.delegate === self {
            window.delegate = nil
        }
    }

    var presentationFrame: NSRect { quakeWindow.presentationFrame }

    var isPresentationVisible: Bool { quakeWindow.isPresentationVisible }

    var installedContentViewController: NSViewController? {
        quakeWindow.installedContentViewController
    }

    func setPresentationFrame(_ frame: NSRect) {
        quakeWindow.setPresentationFrame(frame)
    }

    func installContentViewController(_ contentViewController: NSViewController?) throws {
        try quakeWindow.installContentViewController(contentViewController)
    }

    func showPresentationWindow() throws {
        try requestVisibility(.shown)
    }

    func hidePresentationWindow() {
        deactivateForModeTransition()
    }

    func updateConfiguration(_ configuration: QuakeWindowConfiguration) {
        self.configuration = configuration
    }

    func requestVisibility(_ visibility: QuakeVisibility) throws {
        guard visibility != requestedVisibility else { return }
        switch visibility {
        case .shown:
            try requestShow()
        case .hidden:
            try requestHide()
        }
    }

    func deactivateForModeTransition() {
        beginAnimationRequest(.hidden)
        cancelFocusLossHide()
        quakeWindow.setPresentationLevel(.floating)
        quakeWindow.orderOutForPresentation()
        priorApplication = nil
    }

    func focusDidResignKey() {
        guard configuration.hideOnFocusLoss, requestedVisibility == .shown else { return }
        cancelFocusLossHide()
        focusLossCancellation = scheduler.schedule(after: configuration.focusLossDelay) {
            [weak self] in
            guard let self else { return }
            self.focusLossCancellation = nil
            guard !self.isFocusLossSuppressed() else { return }
            do {
                try self.requestVisibility(.hidden)
            } catch {
                self.onError(error)
            }
        }
    }

    func focusDidBecomeKey() {
        cancelFocusLossHide()
    }

    func windowDidResignKey(_ notification: Notification) {
        focusDidResignKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusDidBecomeKey()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === appKitWindow else { return }
        isLiveResizing = true
        liveResizeVisibleFrame = try? selectedVisibleFrame()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard
            sender === appKitWindow,
            isLiveResizing,
            !isNormalizingLiveResize,
            let visibleFrame = liveResizeVisibleFrame,
            let frame = configuration.geometry.normalizedManualFrame(
                proposedHeight: frameSize.height,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        else { return frameSize }
        return frame.size
    }

    func windowDidResize(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window === appKitWindow,
            isLiveResizing,
            !isNormalizingLiveResize,
            let visibleFrame = liveResizeVisibleFrame,
            let frame = configuration.geometry.normalizedManualFrame(
                proposedHeight: window.frame.height,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        else { return }
        guard window.frame != frame else { return }
        isNormalizingLiveResize = true
        window.setFrame(frame, display: true)
        isNormalizingLiveResize = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        defer {
            isLiveResizing = false
            liveResizeVisibleFrame = nil
        }
        guard
            let window = notification.object as? NSWindow,
            window === appKitWindow,
            isLiveResizing,
            let visibleFrame = liveResizeVisibleFrame,
            let frame = configuration.geometry.normalizedManualFrame(
                proposedHeight: window.frame.height,
                in: visibleFrame,
                minimumHeight: QuakeWindow.minimumContentHeight
            )
        else { return }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        let heightFraction = frame.height / visibleFrame.height
        guard
            let geometry = QuakeWindowGeometry(
                heightFraction: heightFraction,
                padding: configuration.geometry.padding
            )
        else { return }
        configuration.geometry = geometry
        lastVisibleFrame = visibleFrame
        persistQuakeHeight(heightFraction)
    }

    private func requestShow() throws {
        let visibleFrame = try selectedVisibleFrame()
        guard let targetFrame = configuration.geometry.targetFrame(in: visibleFrame) else {
            throw QuakePresentationError.invalidVisibleFrame
        }
        let hiddenFrame = configuration.geometry.hiddenFrame(
            for: targetFrame,
            above: visibleFrame
        )

        cancelFocusLossHide()
        beginAnimationRequest(.shown)
        lastVisibleFrame = visibleFrame
        if priorApplication == nil {
            priorApplication = priorApplicationProvider()
        }
        if !quakeWindow.isPresentationVisible {
            quakeWindow.setPresentationFrame(hiddenFrame)
        }
        quakeWindow.setPresentationLevel(.popUpMenu)
        quakeWindow.orderFrontForPresentation()
        let generation = animationGeneration
        deferredAnimationCancellation = animationDeferrer.deferAction { [weak self] in
            guard
                let self,
                self.animationGeneration == generation,
                self.requestedVisibility == .shown
            else { return }
            self.deferredAnimationCancellation = nil
            self.animate(to: targetFrame, visibility: .shown)
        }
    }

    private func requestHide() throws {
        let visibleFrame = try lastVisibleFrame ?? selectedVisibleFrame()
        guard let targetFrame = configuration.geometry.targetFrame(in: visibleFrame) else {
            throw QuakePresentationError.invalidVisibleFrame
        }
        let hiddenFrame = configuration.geometry.hiddenFrame(
            for: targetFrame,
            above: visibleFrame
        )

        cancelFocusLossHide()
        beginAnimationRequest(.hidden)
        quakeWindow.setPresentationLevel(.popUpMenu)
        animate(to: hiddenFrame, visibility: .hidden)
    }

    private func selectedVisibleFrame() throws -> NSRect {
        guard
            let frame = QuakeWindowGeometry.visibleFrame(
                under: cursorLocation(),
                from: visibleFrames()
            )
        else { throw QuakePresentationError.noVisibleScreen }
        return frame
    }

    private func beginAnimationRequest(_ visibility: QuakeVisibility) {
        animationGeneration += 1
        let hasOutstandingAnimation =
            animationCancellation != nil
            || deferredAnimationCancellation != nil
        animationCancellation?.cancel()
        animationCancellation = nil
        deferredAnimationCancellation?.cancel()
        deferredAnimationCancellation = nil
        if hasOutstandingAnimation {
            quakeWindow.setPresentationLevel(.floating)
        }
        requestedVisibility = visibility
    }

    private func animate(to frame: NSRect, visibility: QuakeVisibility) {
        let generation = animationGeneration
        let request = QuakeAnimationRequest(
            visibility: visibility,
            curve: visibility == .shown ? .easeOut : .easeIn
        )
        animationCancellation = animator.animate(
            window: quakeWindow,
            to: frame,
            request: request,
            duration: configuration.animationDuration
        ) { [weak self] in
            guard let self, self.animationGeneration == generation,
                self.requestedVisibility == visibility
            else { return }
            self.animationCancellation = nil
            self.quakeWindow.setPresentationFrame(frame)
            switch visibility {
            case .shown:
                self.quakeWindow.setPresentationLevel(.floating)
                self.quakeWindow.focusForPresentation()
            case .hidden:
                self.quakeWindow.orderOutForPresentation()
                self.quakeWindow.setPresentationLevel(.floating)
                let priorApplication = self.priorApplication
                self.priorApplication = nil
                priorApplication?.activate()
            }
        }
    }

    private func cancelFocusLossHide() {
        focusLossCancellation?.cancel()
        focusLossCancellation = nil
    }
}

@MainActor
private final class PresentationCancellationToken: PresentationCancellation {
    private(set) var isCancelled = false
    private let onCancel: @MainActor () -> Void

    init(onCancel: @escaping @MainActor () -> Void = {}) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }
}

@MainActor
private final class MainRunLoopPresentationDeferrer: PresentationDeferring {
    func deferAction(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let cancellation = PresentationCancellationToken()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !cancellation.isCancelled else { return }
                action()
            }
        }
        return cancellation
    }
}

@MainActor
private final class TaskPresentationScheduler: PresentationScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> any PresentationCancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return PresentationCancellationToken { task.cancel() }
    }
}

@MainActor
private final class AppKitQuakeFrameAnimator: QuakeFrameAnimating {
    func animate(
        window: any QuakeWindowRepresenting,
        to frame: NSRect,
        request: QuakeAnimationRequest,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) -> any PresentationCancellation {
        let cancellation = PresentationCancellationToken()
        guard duration > 0, let appKitWindow = window as? NSWindow else {
            window.setPresentationFrame(frame)
            completion()
            return cancellation
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                name: request.curve == .easeOut ? .easeOut : .easeIn
            )
            appKitWindow.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                guard !cancellation.isCancelled else { return }
                completion()
            }
        }
        return cancellation
    }
}

@MainActor
private final class RunningApplicationActivationAdapter: PresentationApplicationActivation {
    private let application: NSRunningApplication

    private init(application: NSRunningApplication) {
        self.application = application
    }

    static func frontmostOtherApplication() -> RunningApplicationActivationAdapter? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return RunningApplicationActivationAdapter(application: application)
    }

    func activate() {
        application.activate(options: [])
    }
}
