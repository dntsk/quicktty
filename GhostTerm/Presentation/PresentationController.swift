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

    var toggleQuakeVisibility: @MainActor () -> Void {
        { [weak self] in
            guard let self, self.mode == .quake else { return }
            let visibility: QuakeVisibility =
                self.quakeWindowController.requestedVisibility == .shown ? .hidden : .shown
            do {
                try self.quakeWindowController.requestVisibility(visibility)
            } catch {
                self.onError(error)
            }
        }
    }

    func transition(to targetMode: PresentationMode) throws {
        guard targetMode != mode else { return }
        switch (mode, targetMode) {
        case (.normal, .quake):
            try transitionFromNormalToQuake()
        case (.quake, .normal):
            try transitionFromQuakeToNormal()
        default:
            return
        }
        mode = targetMode
        persistSuccessfulMode(targetMode)
    }

    func requestQuakeVisibility(_ visibility: QuakeVisibility) throws {
        guard mode == .quake else { return }
        try quakeWindowController.requestVisibility(visibility)
    }

    private func installInitialPresentation() throws {
        try clearUnexpectedContent(in: normalWindowController)
        try clearUnexpectedContent(in: quakeWindowController)
        normalWindowController.hidePresentationWindow()
        quakeWindowController.deactivateForModeTransition()

        switch mode {
        case .normal:
            if let savedNormalFrame {
                normalWindowController.setPresentationFrame(savedNormalFrame)
            }
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
        let normalFrame = normalWindowController.presentationFrame
        let previousSavedFrame = savedNormalFrame
        let normalWasVisible = normalWindowController.isPresentationVisible
        normalWindowController.hidePresentationWindow()

        do {
            try reparentContent(from: normalWindowController, to: quakeWindowController)
            try quakeWindowController.showPresentationWindow()
            savedNormalFrame = normalFrame
        } catch {
            quakeWindowController.deactivateForModeTransition()
            try? quakeWindowController.installContentViewController(nil)
            try? normalWindowController.installContentViewController(contentViewController)
            normalWindowController.setPresentationFrame(normalFrame)
            if normalWasVisible {
                try? normalWindowController.showPresentationWindow()
            }
            savedNormalFrame = previousSavedFrame
            throw error
        }
    }

    private func transitionFromQuakeToNormal() throws {
        let quakeVisibility = quakeWindowController.requestedVisibility
        let normalFrame = normalWindowController.presentationFrame
        quakeWindowController.deactivateForModeTransition()
        if let savedNormalFrame {
            normalWindowController.setPresentationFrame(savedNormalFrame)
        }

        do {
            try reparentContent(from: quakeWindowController, to: normalWindowController)
            try normalWindowController.showPresentationWindow()
        } catch {
            normalWindowController.hidePresentationWindow()
            normalWindowController.setPresentationFrame(normalFrame)
            try? normalWindowController.installContentViewController(nil)
            try? quakeWindowController.installContentViewController(contentViewController)
            if quakeVisibility == .shown {
                try? quakeWindowController.showPresentationWindow()
            }
            throw error
        }
    }

    private func reparentContent(
        from source: any PresentationWindowContainer,
        to destination: any PresentationWindowContainer
    ) throws {
        guard source.installedContentViewController === contentViewController,
            destination.installedContentViewController == nil
        else { throw PresentationContainerError.unexpectedContentOwner }

        try source.installContentViewController(nil)
        do {
            try destination.installContentViewController(contentViewController)
        } catch {
            try? source.installContentViewController(contentViewController)
            throw error
        }
    }
}
