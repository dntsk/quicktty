import Foundation
import Synchronization

enum AgentSessionLifecycleAction: Equatable, Sendable {
    case register(paneID: PaneID, binding: AgentResumeBinding)
    case replace(
        paneID: PaneID,
        previousSessionID: String,
        binding: AgentResumeBinding
    )
    case unregister(paneID: PaneID, adapterID: AgentAdapterID, sessionID: String)
}

enum AgentValidatedLifecycleEvent: Equatable, Sendable {
    case register(
        adapterID: AgentAdapterID,
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    )
    case replace(
        adapterID: AgentAdapterID,
        previousSessionID: String,
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    )
    case unregister(adapterID: AgentAdapterID, sessionID: String)
}

struct AgentValidatedLifecycleMessage: Equatable, Sendable {
    let paneID: PaneID
    let paneToken: String
    let event: AgentValidatedLifecycleEvent
}

final class AgentLifecycleCredentialStore: Sendable {
    private struct State: Sendable {
        var paneTokens: [PaneID: String] = [:]
        var isFrozen = false
    }

    let instanceID: UUID

    private let state = Mutex(State())

    init(instanceID: UUID) {
        self.instanceID = instanceID
    }

    func register(paneID: PaneID, makeToken: () -> String) -> String? {
        state.withLock { state in
            guard !state.isFrozen else { return nil }
            let token = makeToken()
            state.paneTokens[paneID] = token
            return token
        }
    }

    func rotate(paneID: PaneID, makeToken: () -> String) -> String? {
        state.withLock { state in
            guard !state.isFrozen, state.paneTokens[paneID] != nil else { return nil }
            let token = makeToken()
            state.paneTokens[paneID] = token
            return token
        }
    }

    func revoke(paneID: PaneID) {
        _ = state.withLock { $0.paneTokens.removeValue(forKey: paneID) }
    }

    func token(for paneID: PaneID) -> String? {
        state.withLock { state in
            guard !state.isFrozen else { return nil }
            return state.paneTokens[paneID]
        }
    }

    func credential(for preflight: AgentIPCPreflight) -> String? {
        state.withLock { state in
            let paneID = PaneID(rawValue: preflight.paneID)
            guard !state.isFrozen, preflight.instanceID == instanceID else {
                return nil
            }
            return state.paneTokens[paneID]
        }
    }

    func freeze() {
        state.withLock { state in
            state.isFrozen = true
            state.paneTokens.removeAll(keepingCapacity: false)
        }
    }

    func validate(_ message: AgentIPCMessage) -> AgentValidatedLifecycleMessage? {
        guard message.version == AgentIPCProtocol.version else { return nil }

        let identity: AgentIPCIdentity
        switch message.event {
        case .register(let payload):
            identity = payload.identity
        case .replaceSession(let payload):
            identity = payload.identity
        case .unregister(let payload):
            identity = payload.identity
        }

        let paneID = PaneID(rawValue: identity.paneID)
        guard
            state.withLock({ state in
                !state.isFrozen
                    && identity.instanceID == instanceID
                    && state.paneTokens[paneID] == identity.paneToken
            }),
            let adapterID = try? AgentAdapterID(rawValue: identity.adapterID),
            let definition = AgentIntegrationRegistry.definition(for: adapterID)
        else {
            return nil
        }

        let event: AgentValidatedLifecycleEvent
        switch message.event {
        case .register(let payload):
            guard
                definition.validateLifecycle(
                    sessionID: payload.sessionID,
                    cwd: payload.cwd,
                    metadata: payload.metadata
                ) == .valid
            else {
                return nil
            }
            event = .register(
                adapterID: adapterID,
                sessionID: payload.sessionID,
                cwd: payload.cwd,
                metadata: payload.metadata
            )

        case .replaceSession(let payload):
            guard payload.previousSessionID != payload.sessionID,
                definition.validateUnregister(sessionID: payload.previousSessionID) == .valid,
                definition.validateLifecycle(
                    sessionID: payload.sessionID,
                    cwd: payload.cwd,
                    metadata: payload.metadata
                ) == .valid
            else {
                return nil
            }
            event = .replace(
                adapterID: adapterID,
                previousSessionID: payload.previousSessionID,
                sessionID: payload.sessionID,
                cwd: payload.cwd,
                metadata: payload.metadata
            )

        case .unregister(let payload):
            guard definition.validateUnregister(sessionID: payload.sessionID) == .valid else {
                return nil
            }
            event = .unregister(adapterID: adapterID, sessionID: payload.sessionID)
        }

        return AgentValidatedLifecycleMessage(
            paneID: paneID,
            paneToken: identity.paneToken,
            event: event
        )
    }

    func isCurrent(_ message: AgentValidatedLifecycleMessage) -> Bool {
        state.withLock { state in
            !state.isFrozen && state.paneTokens[message.paneID] == message.paneToken
        }
    }
}

enum AgentSessionControllerValidationError: Error, Equatable, Sendable {
    case invalidSocketPath
    case invalidHelperPath
}

@MainActor
final class AgentSessionController {
    typealias TokenGenerator = @MainActor @Sendable () -> [UInt8]
    typealias DateProvider = @MainActor @Sendable () -> Date
    typealias ActionHandler = @MainActor @Sendable (AgentSessionLifecycleAction) -> Bool
    typealias MainActorHopObserver = @MainActor @Sendable () -> Void

    nonisolated let instanceID: UUID

    var bundledHelperPath: String {
        helperPath
    }

    private let socketPath: String
    private let helperPath: String
    private let tokenGenerator: TokenGenerator
    private let dateProvider: DateProvider
    private let onAction: ActionHandler
    private let onMainActorHop: MainActorHopObserver
    nonisolated private let credentialStore: AgentLifecycleCredentialStore

    init(
        socketPath: String,
        helperPath: String,
        instanceID: UUID = UUID(),
        tokenGenerator: @escaping TokenGenerator = AgentSessionController.randomTokenBytes,
        dateProvider: @escaping DateProvider = { Date() },
        onMainActorHop: @escaping MainActorHopObserver = {},
        onAction: @escaping ActionHandler
    ) throws {
        guard Self.isValidAbsolutePath(socketPath),
            (try? AgentUnixSocketAddress(path: socketPath)) != nil
        else {
            throw AgentSessionControllerValidationError.invalidSocketPath
        }
        guard Self.isValidAbsolutePath(helperPath) else {
            throw AgentSessionControllerValidationError.invalidHelperPath
        }

        self.socketPath = socketPath
        self.helperPath = helperPath
        self.instanceID = instanceID
        self.tokenGenerator = tokenGenerator
        self.dateProvider = dateProvider
        self.onMainActorHop = onMainActorHop
        self.onAction = onAction
        credentialStore = AgentLifecycleCredentialStore(instanceID: instanceID)
    }

    @discardableResult
    func register(paneID: PaneID) -> [String: String]? {
        guard
            let token = credentialStore.register(
                paneID: paneID,
                makeToken: makeToken
            )
        else {
            return nil
        }
        return environment(for: paneID, token: token)
    }

    @discardableResult
    func rotate(paneID: PaneID) -> [String: String]? {
        guard
            let token = credentialStore.rotate(
                paneID: paneID,
                makeToken: makeToken
            )
        else {
            return nil
        }
        return environment(for: paneID, token: token)
    }

    func revoke(paneID: PaneID) {
        credentialStore.revoke(paneID: paneID)
    }

    func environment(for paneID: PaneID) -> [String: String]? {
        guard let token = credentialStore.token(for: paneID) else {
            return nil
        }
        return environment(for: paneID, token: token)
    }

    func freeze() {
        credentialStore.freeze()
    }

    nonisolated func credential(for preflight: AgentIPCPreflight) -> String? {
        credentialStore.credential(for: preflight)
    }

    nonisolated func validate(
        _ message: AgentIPCMessage
    ) -> AgentValidatedLifecycleMessage? {
        credentialStore.validate(message)
    }

    nonisolated func handle(_ message: AgentIPCMessage) async -> Bool {
        guard let validatedMessage = validate(message) else { return false }
        return await handle(validatedMessage)
    }

    func handle(_ message: AgentValidatedLifecycleMessage) -> Bool {
        onMainActorHop()
        guard credentialStore.isCurrent(message) else { return false }

        switch message.event {
        case .register(let adapterID, let sessionID, let cwd, let metadata):
            guard
                let binding = makeBinding(
                    adapterID: adapterID,
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: metadata
                )
            else {
                return false
            }
            return onAction(.register(paneID: message.paneID, binding: binding))

        case .replace(
            let adapterID,
            let previousSessionID,
            let sessionID,
            let cwd,
            let metadata
        ):
            guard
                let binding = makeBinding(
                    adapterID: adapterID,
                    sessionID: sessionID,
                    cwd: cwd,
                    metadata: metadata
                )
            else {
                return false
            }
            return onAction(
                .replace(
                    paneID: message.paneID,
                    previousSessionID: previousSessionID,
                    binding: binding
                ))

        case .unregister(let adapterID, let sessionID):
            return onAction(
                .unregister(
                    paneID: message.paneID,
                    adapterID: adapterID,
                    sessionID: sessionID
                ))
        }
    }

    private func environment(for paneID: PaneID, token: String) -> [String: String] {
        [
            "QUICKTTY_PANE_ID": paneID.rawValue.uuidString,
            "QUICKTTY_AGENT_SOCKET": socketPath,
            "QUICKTTY_INSTANCE_ID": instanceID.uuidString,
            "QUICKTTY_PANE_TOKEN": token,
            "QUICKTTY_AGENT_HELPER": helperPath,
        ]
    }

    private func makeBinding(
        adapterID: AgentAdapterID,
        sessionID: String,
        cwd: String,
        metadata: [String: String]
    ) -> AgentResumeBinding? {
        try? AgentResumeBinding(
            adapterID: adapterID,
            sessionID: sessionID,
            workingDirectory: cwd,
            registeredAt: dateProvider(),
            launchMetadata: metadata,
            restoreState: .active
        )
    }

    private func makeToken() -> String {
        let bytes = tokenGenerator()
        precondition(bytes.count == 32, "Agent pane tokens require exactly 256 random bits")

        let hexadecimalDigits = Array("0123456789abcdef".utf8)
        var tokenBytes: [UInt8] = []
        tokenBytes.reserveCapacity(64)
        for byte in bytes {
            tokenBytes.append(hexadecimalDigits[Int(byte >> 4)])
            tokenBytes.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: tokenBytes, as: UTF8.self)
    }

    private static func randomTokenBytes() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
    }

    private static func isValidAbsolutePath(_ path: String) -> Bool {
        (1...4_096).contains(path.utf8.count)
            && path.hasPrefix("/")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
