import AppKit

@MainActor
final class TerminalControlPermissionController {
    typealias AsyncPresenter =
        @MainActor (TerminalAutomationResolvedSession) async -> TerminalAutomationPermissionDecision
    typealias Completion = @MainActor (TerminalAutomationPermissionDecision) -> Void

    struct Sheet {
        let isAttached: @MainActor () -> Bool
        let dismiss: @MainActor () -> Void
    }

    typealias SheetPresenter =
        @MainActor (TerminalControlPermissionPresentation, NSWindow, @escaping Completion) -> Sheet?

    private struct Pending {
        let id: UUID
        let session: TerminalAutomationSessionIdentity
        let deadline: ContinuousClock.Instant
        let isCurrent: @MainActor () -> Bool
        let continuation: CheckedContinuation<TerminalAutomationPermissionDecision, Never>
        var sheet: Sheet?
        var worker: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
    }

    private let timeout: TimeInterval
    private let sheetPresenter: SheetPresenter
    private var pending: Pending?

    init(
        timeout: TimeInterval = 60,
        sheetPresenter: @escaping SheetPresenter = TerminalControlPermissionController.presentSheet
    ) {
        self.timeout = timeout.isFinite ? min(60, max(0, timeout)) : 60
        self.sheetPresenter = sheetPresenter
    }

    isolated deinit { cancel() }

    func present(
        for session: TerminalAutomationResolvedSession,
        on window: NSWindow?,
        using presenter: AsyncPresenter? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> TerminalAutomationPermissionDecision {
        guard !Task.isCancelled, pending == nil, let window,
            Self.isUsable(window), window.attachedSheet == nil, isCurrent()
        else { return .unavailable }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                pending = Pending(
                    id: id, session: session.identity,
                    deadline: ContinuousClock().now.advanced(by: .seconds(timeout)),
                    isCurrent: { [weak window] in
                        guard let window else { return false }
                        return Self.isUsable(window) && isCurrent()
                    }, continuation: continuation)
                if let presenter {
                    // WHY: A cancelled injected presenter may never return; it must not own the waiter.
                    pending?.worker = Task { @MainActor [weak self] in
                        let decision = await presenter(session)
                        guard !Task.isCancelled else { return }
                        self?.finish(id: id, decision: decision)
                    }
                } else {
                    let sheet = sheetPresenter(
                        TerminalControlPermissionPresentation(
                            adapterID: session.identity.adapterID), window
                    ) { [weak self] decision in
                        self?.finish(id: id, decision: decision)
                    }
                    guard pending?.id == id else {
                        sheet?.dismiss()
                        return
                    }
                    guard let sheet else {
                        finish(id: id, decision: .unavailable)
                        return
                    }
                    pending?.sheet = sheet
                }
                pending?.watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard self?.validatePending(id: id) == true,
                            let deadline = self?.pending?.deadline
                        else { return }
                        let remaining = ContinuousClock().now.duration(to: deadline)
                        do { try await Task.sleep(for: min(.milliseconds(25), remaining)) } catch {
                            return
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, decision: .unavailable) }
        }
    }

    func cancel(session: TerminalAutomationSessionIdentity? = nil) {
        guard let pending, session == nil || pending.session == session else { return }
        finish(id: pending.id, decision: .unavailable)
    }

    private func validatePending(id: UUID) -> Bool {
        guard let pending, pending.id == id else { return false }
        guard ContinuousClock().now < pending.deadline, pending.isCurrent(),
            pending.sheet?.isAttached() != false
        else {
            finish(id: id, decision: .unavailable)
            return false
        }
        return true
    }

    private func finish(id: UUID, decision: TerminalAutomationPermissionDecision) {
        guard let pending, pending.id == id else { return }
        // WHY: Validation and dismissal can reenter; retire identity before invoking either callback.
        self.pending = nil
        let result: TerminalAutomationPermissionDecision =
            ContinuousClock().now < pending.deadline && pending.isCurrent()
            ? decision : .unavailable
        pending.worker?.cancel()
        pending.watchdog?.cancel()
        pending.sheet?.dismiss()
        pending.continuation.resume(returning: result)
    }

    private static func isUsable(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.sheetParent == nil
    }

    static func makeAlert(_ presentation: TerminalControlPermissionPresentation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = TerminalControlPermissionPresentation.disclosure
        alert.addButton(withTitle: "Не разрешать").keyEquivalent = "\u{1B}"
        alert.addButton(withTitle: "Разрешить").keyEquivalent = ""
        return alert
    }

    private static func presentSheet(
        _ presentation: TerminalControlPermissionPresentation,
        on window: NSWindow,
        completion: @escaping Completion
    ) -> Sheet? {
        guard isUsable(window), window.attachedSheet == nil else { return nil }
        let alert = makeAlert(presentation)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn ? .allowed : .denied)
        }
        guard alert.window.sheetParent === window else {
            alert.window.orderOut(nil)
            return nil
        }
        return Sheet(
            isAttached: { [weak window, alert] in
                guard let window else { return false }
                return alert.window.sheetParent === window && window.attachedSheet === alert.window
            },
            dismiss: { [weak window, alert] in
                // WHY: Never dismiss a confirmation or integration sheet owned by another controller.
                if let window, alert.window.sheetParent === window {
                    window.endSheet(alert.window, returnCode: .abort)
                }
                alert.window.orderOut(nil)
            })
    }
}
