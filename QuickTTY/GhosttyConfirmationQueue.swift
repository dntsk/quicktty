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

    struct CloseToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    private struct Item {
        let id: UUID
        let presentation: GhosttyConfirmationPresentation
        var completions: [Completion]
        var closeTokens: [CloseToken] = []
    }

    @MainActor
    private final class ActiveItem {
        var item: Item
        private var dismiss: Dismiss?
        private var isCancelled = false

        init(item: Item) { self.item = item }

        func installDismiss(_ dismiss: Dismiss?) {
            // WHY: A presenter can synchronously cancel a previously queued participant.
            if isCancelled { dismiss?() } else { self.dismiss = dismiss }
        }

        func cancel() {
            isCancelled = true
            let dismiss = dismiss
            self.dismiss = nil
            dismiss?()
        }
    }

    private let presenter: Presenter
    private var pending: [Item] = []
    private var active: ActiveItem?
    private var closeCompletions: [CloseToken: Completion] = [:]

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
                completions: [completion]
            )
        )
        presentNextIfNeeded()
    }

    @discardableResult
    func enqueueClose(
        paneID: PaneID,
        completion: @escaping Completion
    ) -> CloseToken {
        let token = CloseToken()
        closeCompletions[token] = completion
        let participant: Completion = { [weak self] response in
            // WHY: A preceding coalesced callback can cancel a participant during resolution.
            let completion = self?.closeCompletions.removeValue(forKey: token)
            completion?(response)
        }
        if appendCloseCompletion(for: paneID, token: token, completion: participant) {
            return token
        }

        cancelClipboardRequests(for: paneID)
        if let active, case .clipboard = active.item.presentation {
            self.active = nil
            active.cancel()
            if case .clipboard(let request) = active.item.presentation,
                request.paneID != paneID
            {
                pending.insert(
                    Item(
                        id: UUID(),
                        presentation: active.item.presentation,
                        completions: active.item.completions
                    ),
                    at: 0
                )
            }
        }

        if appendCloseCompletion(for: paneID, token: token, completion: participant) {
            return token
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
                completions: [participant],
                closeTokens: [token]
            ),
            at: insertionIndex
        )
        presentNextIfNeeded()
        return token
    }

    func cancelClose(_ token: CloseToken) {
        // WHY: Remove authority before dismissal or any reentrant presenter callback.
        guard closeCompletions.removeValue(forKey: token) != nil else { return }
        if let active, let index = active.item.closeTokens.firstIndex(of: token) {
            active.item.closeTokens.remove(at: index)
            active.item.completions.remove(at: index)
            if active.item.completions.isEmpty {
                self.active = nil
                active.cancel()
            }
        } else if let itemIndex = pending.firstIndex(where: { $0.closeTokens.contains(token) }),
            let index = pending[itemIndex].closeTokens.firstIndex(of: token)
        {
            pending[itemIndex].closeTokens.remove(at: index)
            pending[itemIndex].completions.remove(at: index)
            if pending[itemIndex].completions.isEmpty { pending.remove(at: itemIndex) }
        }
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
            for token in active.item.closeTokens { closeCompletions.removeValue(forKey: token) }
            active.cancel()
        }
        let removed = pending.filter { $0.presentation == .close(paneID) }
        pending.removeAll { $0.presentation == .close(paneID) }
        for item in removed {
            for token in item.closeTokens { closeCompletions.removeValue(forKey: token) }
        }
        presentNextIfNeeded()
    }

    func invalidateAll() {
        let active = active
        let pending = pending
        self.active = nil
        self.pending.removeAll()

        active?.cancel()
        if let active {
            for completion in active.item.completions {
                completion(.deny)
            }
        }
        for item in pending {
            for completion in item.completions {
                completion(.deny)
            }
        }
    }

    private func appendCloseCompletion(
        for paneID: PaneID,
        token: CloseToken,
        completion: @escaping Completion
    ) -> Bool {
        if let active, case .close(let activePaneID) = active.item.presentation,
            activePaneID == paneID
        {
            active.item.completions.append(completion)
            active.item.closeTokens.append(token)
            return true
        }
        guard
            let index = pending.firstIndex(where: { item in
                guard case .close(let queuedPaneID) = item.presentation else { return false }
                return queuedPaneID == paneID
            })
        else {
            return false
        }
        pending[index].completions.append(completion)
        pending[index].closeTokens.append(token)
        return true
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
            active.cancel()
            for completion in active.item.completions {
                completion(.deny)
            }
        }

        let removed = pending.filter { item in
            guard case .clipboard(let request) = item.presentation else { return false }
            return request.paneID == paneID
        }
        let removedIDs = Set(removed.map(\.id))
        // WHY: A denied clipboard callback can cancel a queued close; never restore a stale array.
        pending.removeAll { removedIDs.contains($0.id) }
        for item in removed {
            for completion in item.completions {
                completion(.deny)
            }
        }
    }

    private func presentNextIfNeeded() {
        guard active == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let presented = ActiveItem(item: item)
        active = presented

        let dismiss = presenter(item.presentation) { [weak self] response in
            self?.resolve(id: item.id, response: response)
        }
        presented.installDismiss(dismiss)
    }

    private func resolve(id: UUID, response: GhosttyClipboardConfirmationResponse) {
        guard let active, active.item.id == id else { return }
        self.active = nil
        let completions = active.item.completions
        for completion in completions {
            completion(response)
        }
        presentNextIfNeeded()
    }
}
