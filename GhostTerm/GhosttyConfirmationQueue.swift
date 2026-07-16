import Foundation

enum GhosttyConfirmationPresentation: Equatable, Sendable {
    case clipboard(GhosttyClipboardConfirmationRequest)
    case close(PaneID)
}

@MainActor
final class GhosttyConfirmationQueue {
    typealias Completion =
        @MainActor @Sendable (GhosttyClipboardConfirmationResponse) -> Void
    typealias Dismiss = @MainActor () -> Void
    typealias Presenter =
        @MainActor (
            GhosttyConfirmationPresentation,
            @escaping Completion
        ) -> Dismiss?

    private struct Item {
        let id: UUID
        let presentation: GhosttyConfirmationPresentation
        let completion: Completion
    }

    private struct ActiveItem {
        let item: Item
        var dismiss: Dismiss?
    }

    private let presenter: Presenter
    private var pending: [Item] = []
    private var active: ActiveItem?

    init(presenter: @escaping Presenter) {
        self.presenter = presenter
    }

    var activePresentation: GhosttyConfirmationPresentation? {
        active?.item.presentation
    }

    var pendingCount: Int {
        pending.count
    }

    func enqueueClipboard(
        _ request: GhosttyClipboardConfirmationRequest,
        completion: @escaping Completion
    ) {
        guard !hasCloseRequest(for: request.paneID) else {
            completion(.deny)
            return
        }

        pending.append(
            Item(
                id: UUID(),
                presentation: .clipboard(request),
                completion: completion
            )
        )
        presentNextIfNeeded()
    }

    func enqueueClose(
        paneID: PaneID,
        completion: @escaping Completion
    ) {
        guard !hasCloseRequest(for: paneID) else { return }

        cancelClipboardRequests(for: paneID)
        if let active, case .clipboard = active.item.presentation {
            self.active = nil
            active.dismiss?()
            if case .clipboard(let request) = active.item.presentation,
                request.paneID != paneID
            {
                pending.insert(
                    Item(
                        id: UUID(),
                        presentation: active.item.presentation,
                        completion: active.item.completion
                    ),
                    at: 0
                )
            }
        }

        let insertionIndex =
            pending.firstIndex { item in
                if case .clipboard = item.presentation { return true }
                return false
            } ?? pending.endIndex
        pending.insert(
            Item(
                id: UUID(),
                presentation: .close(paneID),
                completion: completion
            ),
            at: insertionIndex
        )
        presentNextIfNeeded()
    }

    func invalidateClipboard(for paneID: PaneID) {
        cancelClipboardRequests(for: paneID)
        presentNextIfNeeded()
    }

    func invalidatePane(_ paneID: PaneID) {
        cancelClipboardRequests(for: paneID)

        if let active, case .close(let activePaneID) = active.item.presentation,
            activePaneID == paneID
        {
            self.active = nil
            active.dismiss?()
        }
        pending.removeAll { item in
            guard case .close(let queuedPaneID) = item.presentation else { return false }
            return queuedPaneID == paneID
        }
        presentNextIfNeeded()
    }

    func invalidateAll() {
        let active = active
        let pending = pending
        self.active = nil
        self.pending.removeAll()

        active?.dismiss?()
        active?.item.completion(.deny)
        for item in pending {
            item.completion(.deny)
        }
    }

    private func hasCloseRequest(for paneID: PaneID) -> Bool {
        if let active, case .close(let activePaneID) = active.item.presentation,
            activePaneID == paneID
        {
            return true
        }
        return pending.contains { item in
            guard case .close(let queuedPaneID) = item.presentation else { return false }
            return queuedPaneID == paneID
        }
    }

    private func cancelClipboardRequests(for paneID: PaneID) {
        if let active, case .clipboard(let request) = active.item.presentation,
            request.paneID == paneID
        {
            self.active = nil
            active.dismiss?()
            active.item.completion(.deny)
        }

        var kept: [Item] = []
        for item in pending {
            guard case .clipboard(let request) = item.presentation,
                request.paneID == paneID
            else {
                kept.append(item)
                continue
            }
            item.completion(.deny)
        }
        pending = kept
    }

    private func presentNextIfNeeded() {
        guard active == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        active = ActiveItem(item: item, dismiss: nil)

        let dismiss = presenter(item.presentation) { [weak self] response in
            self?.resolve(id: item.id, response: response)
        }
        if active?.item.id == item.id {
            active?.dismiss = dismiss
        }
    }

    private func resolve(id: UUID, response: GhosttyClipboardConfirmationResponse) {
        guard let active, active.item.id == id else { return }
        self.active = nil
        active.item.completion(response)
        presentNextIfNeeded()
    }
}
