import Foundation
import Synchronization

final class AgentMessageRouter: Sendable {
    private enum State: Sendable {
        case waiting
        case ready(AgentSessionController)
        case disabled
    }

    private let state = Mutex(State.waiting)

    func install(_ controller: AgentSessionController) {
        state.withLock { state in
            guard case .waiting = state else { return }
            state = .ready(controller)
        }
    }

    func disable() {
        state.withLock { $0 = .disabled }
    }

    func credential(for preflight: AgentIPCPreflight) -> String? {
        let controller = state.withLock { state -> AgentSessionController? in
            guard case .ready(let controller) = state else { return nil }
            return controller
        }
        return controller?.credential(for: preflight)
    }

    func route(_ message: AgentIPCMessage) async -> Bool {
        let controller = state.withLock { state -> AgentSessionController? in
            guard case .ready(let controller) = state else { return nil }
            return controller
        }
        guard let controller, let validatedMessage = controller.validate(message) else {
            return false
        }
        return await controller.handle(validatedMessage)
    }
}

@MainActor
final class AgentLifecycleActionRouter {
    private var coordinator: WindowCoordinator?
    private var isDisabled = false

    func install(_ coordinator: WindowCoordinator) {
        guard !isDisabled else { return }
        self.coordinator = coordinator
    }

    func disable() {
        isDisabled = true
        coordinator = nil
    }

    func route(_ action: AgentSessionLifecycleAction) -> Bool {
        guard !isDisabled, let coordinator else { return false }
        return coordinator.handleAgentSessionLifecycleAction(action)
    }
}
