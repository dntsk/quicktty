import AppKit

@MainActor
protocol PresentationWindowContainer: AnyObject {
    var presentationFrame: NSRect { get }
    var isPresentationVisible: Bool { get }
    var installedContentViewController: NSViewController? { get }

    func setPresentationFrame(_ frame: NSRect)
    func installContentViewController(_ contentViewController: NSViewController?) throws
    func showPresentationWindow() throws
    func hidePresentationWindow()
}

enum PresentationContainerError: Error, Equatable {
    case windowUnavailable
    case unexpectedContentOwner
}

@MainActor
final class PresentationController {
    typealias ModePersistence = @MainActor (PresentationMode) -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void

    let contentViewController: NSViewController
    private let normalWindowController: any PresentationWindowContainer
    private let quakeWindowController: any QuakePresentationWindowContainer
    private let persistSuccessfulMode: ModePersistence
    private let onError: ErrorHandler
    private var isRetiredForTermination = false
    private(set) var mode: PresentationMode
    private(set) var savedNormalFrame: NSRect?

    init(
        contentViewController: NSViewController,
        normalWindowController: any PresentationWindowContainer,
        quakeWindowController: any QuakePresentationWindowContainer,
        initialMode: PresentationMode = .normal,
        savedNormalFrame: NSRect? = nil,
        persistSuccessfulMode: @escaping ModePersistence,
        onError: @escaping ErrorHandler = { _ in }
    ) throws {
        self.contentViewController = contentViewController
        self.normalWindowController = normalWindowController
        self.quakeWindowController = quakeWindowController
        mode = initialMode
        self.savedNormalFrame = savedNormalFrame
        self.persistSuccessfulMode = persistSuccessfulMode
        self.onError = onError

        try installInitialPresentation()
    }

    var normalFrameForPersistence: NSRect {
        switch mode {
        case .normal:
            normalWindowController.presentationFrame
        case .quake:
            savedNormalFrame ?? normalWindowController.presentationFrame
        }
    }

    // WHY: A native container call can synchronously freeze its caller. Retirement only
    // denies the next operation; it neither cancels that call nor repairs partial ownership.
    func retireForApplicationTermination() {
        isRetiredForTermination = true
    }

    var toggleQuakeVisibility: @MainActor () -> Void {
        { [weak self] in
            guard let self, !self.isRetiredForTermination, self.mode == .quake else { return }
            let visibility: QuakeVisibility =
                self.quakeWindowController.requestedVisibility == .shown ? .hidden : .shown
            do {
                try self.quakeWindowController.requestVisibility(visibility)
            } catch {
                guard !self.isRetiredForTermination else { return }
                self.onError(error)
            }
        }
    }

    func transition(to targetMode: PresentationMode, persist: Bool = true) throws {
        guard !isRetiredForTermination, targetMode != mode else { return }
        switch (mode, targetMode) {
        case (.normal, .quake):
            try transitionFromNormalToQuake()
        case (.quake, .normal):
            try transitionFromQuakeToNormal()
        default:
            return
        }
        guard !isRetiredForTermination else { return }
        mode = targetMode
        // WHY: Mode is committed before persistence; a freeze inside persistence must not undo it.
        if persist {
            persistSuccessfulMode(targetMode)
        }
    }

    func requestQuakeVisibility(_ visibility: QuakeVisibility) throws {
        guard !isRetiredForTermination, mode == .quake else { return }
        try quakeWindowController.requestVisibility(visibility)
    }

    func showCurrentPresentation() throws {
        guard !isRetiredForTermination else { return }
        switch mode {
        case .normal:
            try normalWindowController.showPresentationWindow()
        case .quake:
            try quakeWindowController.requestVisibility(.shown)
        }
    }

    private func installInitialPresentation() throws {
        try clearUnexpectedContent(in: normalWindowController)
        try clearUnexpectedContent(in: quakeWindowController)
        normalWindowController.hidePresentationWindow()
        quakeWindowController.deactivateForModeTransition()
        if let savedNormalFrame {
            normalWindowController.setPresentationFrame(savedNormalFrame)
        }

        switch mode {
        case .normal:
            try normalWindowController.installContentViewController(contentViewController)
            try normalWindowController.showPresentationWindow()
        case .quake:
            try quakeWindowController.installContentViewController(contentViewController)
            try quakeWindowController.showPresentationWindow()
        }
    }

    private func clearUnexpectedContent(in container: any PresentationWindowContainer) throws {
        guard let installed = container.installedContentViewController else { return }
        guard installed === contentViewController else {
            throw PresentationContainerError.unexpectedContentOwner
        }
        try container.installContentViewController(nil)
    }

    private func transitionFromNormalToQuake() throws {
        guard !isRetiredForTermination else { return }
        let normalFrame = normalWindowController.presentationFrame
        let previousSavedFrame = savedNormalFrame
        let normalWasVisible = normalWindowController.isPresentationVisible

        do {
            try reparentContent(from: normalWindowController, to: quakeWindowController)
            guard !isRetiredForTermination else { return }
            try quakeWindowController.showPresentationWindow()
            guard !isRetiredForTermination else { return }
            normalWindowController.hidePresentationWindow()
            guard !isRetiredForTermination else { return }
            savedNormalFrame = normalFrame
        } catch {
            guard !isRetiredForTermination else { return }
            quakeWindowController.deactivateForModeTransition()
            guard !isRetiredForTermination else { return }
            try? quakeWindowController.installContentViewController(nil)
            guard !isRetiredForTermination else { return }
            try? normalWindowController.installContentViewController(contentViewController)
            guard !isRetiredForTermination else { return }
            normalWindowController.setPresentationFrame(normalFrame)
            guard !isRetiredForTermination else { return }
            if normalWasVisible {
                try? normalWindowController.showPresentationWindow()
                guard !isRetiredForTermination else { return }
            }
            savedNormalFrame = previousSavedFrame
            throw error
        }
    }

    private func transitionFromQuakeToNormal() throws {
        guard !isRetiredForTermination else { return }
        let quakeVisibility = quakeWindowController.requestedVisibility
        let normalFrame = normalWindowController.presentationFrame
        if let savedNormalFrame {
            normalWindowController.setPresentationFrame(savedNormalFrame)
            guard !isRetiredForTermination else { return }
        }

        do {
            try reparentContent(from: quakeWindowController, to: normalWindowController)
            guard !isRetiredForTermination else { return }
            try normalWindowController.showPresentationWindow()
            guard !isRetiredForTermination else { return }
            quakeWindowController.deactivateForModeTransition()
        } catch {
            guard !isRetiredForTermination else { return }
            normalWindowController.hidePresentationWindow()
            guard !isRetiredForTermination else { return }
            normalWindowController.setPresentationFrame(normalFrame)
            guard !isRetiredForTermination else { return }
            try? normalWindowController.installContentViewController(nil)
            guard !isRetiredForTermination else { return }
            try? quakeWindowController.installContentViewController(contentViewController)
            guard !isRetiredForTermination else { return }
            if quakeVisibility == .shown {
                try? quakeWindowController.showPresentationWindow()
                guard !isRetiredForTermination else { return }
            }
            throw error
        }
    }

    private func reparentContent(
        from source: any PresentationWindowContainer,
        to destination: any PresentationWindowContainer
    ) throws {
        guard !isRetiredForTermination else { return }
        guard source.installedContentViewController === contentViewController,
            destination.installedContentViewController == nil
        else { throw PresentationContainerError.unexpectedContentOwner }

        try source.installContentViewController(nil)
        guard !isRetiredForTermination else { return }
        do {
            try destination.installContentViewController(contentViewController)
        } catch {
            guard !isRetiredForTermination else { return }
            try? source.installContentViewController(contentViewController)
            guard !isRetiredForTermination else { return }
            throw error
        }
    }
}
