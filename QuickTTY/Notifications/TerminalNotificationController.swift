import Foundation
import UserNotifications

@MainActor
final class TerminalNotificationController: NSObject {
    typealias EnabledProvider = @MainActor () -> Bool
    typealias DestinationProvider = @MainActor (PaneID) -> TerminalDestination?
    typealias CurrentEventValidation = @MainActor (TerminalNotificationEvent) -> Bool
    typealias SuppressionProvider = @MainActor (TerminalDestination) -> Bool
    typealias DestinationActivation = @MainActor (TerminalDestination) -> Void
    typealias ErrorLogger = @MainActor (TerminalNotificationClientError) -> Void

    private enum AuthorizationState {
        case unresolved
        case resolving
        case requesting
        case resolved(TerminalNotificationAuthorizationStatus)
    }

    private struct PendingNotification: Equatable {
        let event: TerminalNotificationEvent
        let destination: TerminalDestination
    }

    private struct DestinationMapping: Equatable {
        let identifier: String
        let notification: PendingNotification
    }

    private let client: any TerminalNotificationClient
    private let desktopNotificationsEnabled: EnabledProvider
    private let destinationProvider: DestinationProvider
    private let isCurrentEvent: CurrentEventValidation
    private let isSuppressed: SuppressionProvider
    private let activateDestination: DestinationActivation
    private let logger: ErrorLogger
    private var authorizationState = AuthorizationState.unresolved
    private var pendingNotifications: [PaneID: PendingNotification] = [:]
    private var destinationMappings: [PaneID: DestinationMapping] = [:]
    private var callbackGeneration = 0
    private var isShutdown = false

    init(
        client: any TerminalNotificationClient,
        desktopNotificationsEnabled: @escaping EnabledProvider,
        destinationProvider: @escaping DestinationProvider,
        isCurrentEvent: @escaping CurrentEventValidation,
        isSuppressed: @escaping SuppressionProvider,
        activateDestination: @escaping DestinationActivation,
        logger: @escaping ErrorLogger = { _ in }
    ) {
        self.client = client
        self.desktopNotificationsEnabled = desktopNotificationsEnabled
        self.destinationProvider = destinationProvider
        self.isCurrentEvent = isCurrentEvent
        self.isSuppressed = isSuppressed
        self.activateDestination = activateDestination
        self.logger = logger
    }

    convenience init(
        client: any TerminalNotificationClient,
        desktopNotificationsEnabled: @escaping EnabledProvider,
        destinationProvider: @escaping DestinationProvider,
        isCurrentEffect: @escaping @MainActor (TerminalActivityEffect) -> Bool,
        isSuppressed: @escaping SuppressionProvider,
        activateDestination: @escaping DestinationActivation,
        logger: @escaping ErrorLogger = { _ in }
    ) {
        self.init(
            client: client,
            desktopNotificationsEnabled: desktopNotificationsEnabled,
            destinationProvider: destinationProvider,
            isCurrentEvent: { event in
                guard case .activity(let effect) = event else { return false }
                return effect.isNotificationEligible && isCurrentEffect(effect)
            },
            isSuppressed: isSuppressed,
            activateDestination: activateDestination,
            logger: logger
        )
    }

    func handle(_ event: TerminalNotificationEvent) {
        invalidate(paneID: event.paneID)
        guard let pending = validatedNotification(for: event) else { return }
        pendingNotifications[event.paneID] = pending
        resolveAuthorizationIfNeeded()
    }

    func handle(_ effect: TerminalActivityEffect) {
        handle(.activity(effect))
    }

    func invalidate(paneID: PaneID) {
        pendingNotifications.removeValue(forKey: paneID)
        destinationMappings.removeValue(forKey: paneID)
    }

    func revalidate() {
        guard !isShutdown else { return }
        pendingNotifications = pendingNotifications.filter { isStillValid($0.value) }
        destinationMappings = destinationMappings.filter { isStillValid($0.value.notification) }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        callbackGeneration += 1
        pendingNotifications.removeAll()
        destinationMappings.removeAll()
    }

    func willPresent(
        identifier: String,
        userInfo: [String: String],
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard !isShutdown,
            let destination = TerminalDestination(userInfo: userInfo),
            let mapping = destinationMappings[destination.paneID],
            mapping.identifier == identifier,
            mapping.notification.destination == destination,
            isStillValid(mapping.notification)
        else {
            completion(false)
            return
        }
        completion(true)
    }

    func handleDefaultResponse(identifier: String, userInfo: [String: String]) {
        guard !isShutdown,
            let entry = destinationMappings.first(where: { $0.value.identifier == identifier })
        else { return }
        destinationMappings.removeValue(forKey: entry.key)
        guard let destination = TerminalDestination(userInfo: userInfo),
            entry.value.notification.destination == destination,
            isStillValid(entry.value.notification)
        else { return }
        activateDestination(destination)
    }

    private func validatedNotification(
        for event: TerminalNotificationEvent
    ) -> PendingNotification? {
        guard !isShutdown, desktopNotificationsEnabled(), isCurrentEvent(event),
            let destination = destinationProvider(event.paneID),
            destination.paneID == event.paneID,
            !isSuppressed(destination)
        else {
            return nil
        }
        return PendingNotification(event: event, destination: destination)
    }

    private func isStillValid(_ pending: PendingNotification) -> Bool {
        desktopNotificationsEnabled() && isCurrentEvent(pending.event)
            && destinationProvider(pending.destination.paneID) == pending.destination
            && !isSuppressed(pending.destination)
    }

    private func resolveAuthorizationIfNeeded() {
        switch authorizationState {
        case .unresolved:
            authorizationState = .resolving
            let generation = callbackGeneration
            client.authorizationStatus { [weak self] status in
                guard let self, !isShutdown, generation == callbackGeneration else { return }
                authorizationStatusDidResolve(status)
            }
        case .resolved(let status):
            if status.canDeliver {
                deliverPendingNotifications()
            } else if status == .denied {
                pendingNotifications.removeAll()
            }
        case .resolving, .requesting:
            break
        }
    }

    private func authorizationStatusDidResolve(
        _ status: TerminalNotificationAuthorizationStatus
    ) {
        switch status {
        case .notDetermined:
            pendingNotifications = pendingNotifications.filter { isStillValid($0.value) }
            guard !pendingNotifications.isEmpty else {
                authorizationState = .unresolved
                return
            }
            authorizationState = .requesting
            let generation = callbackGeneration
            client.requestAuthorization { [weak self] result in
                guard let self, !isShutdown, generation == callbackGeneration else { return }
                authorizationRequestDidResolve(result)
            }
        case .denied:
            authorizationState = .resolved(.denied)
            pendingNotifications.removeAll()
        case .authorized, .provisional, .ephemeral:
            authorizationState = .resolved(status)
            deliverPendingNotifications()
        }
    }

    private func authorizationRequestDidResolve(
        _ result: Result<Bool, TerminalNotificationClientError>
    ) {
        switch result {
        case .success(true):
            authorizationState = .resolved(.authorized)
            deliverPendingNotifications()
        case .success(false):
            authorizationState = .resolved(.denied)
            pendingNotifications.removeAll()
        case .failure(let error):
            authorizationState = .unresolved
            pendingNotifications.removeAll()
            logger(error)
        }
    }

    private func deliverPendingNotifications() {
        let pending = pendingNotifications.values
        pendingNotifications.removeAll()
        for notification in pending where isStillValid(notification) {
            add(notification)
        }
    }

    private func add(_ pending: PendingNotification) {
        guard isStillValid(pending) else { return }
        let identifier = UUID().uuidString
        let request = TerminalNotificationRequest(
            identifier: identifier,
            title: "QuickTTY",
            body: pending.event.notificationBody,
            userInfo: pending.destination.userInfo
        )
        let mapping = DestinationMapping(identifier: identifier, notification: pending)
        destinationMappings[pending.destination.paneID] = mapping
        let generation = callbackGeneration
        client.add(request) { [weak self] result in
            guard let self, !isShutdown, generation == callbackGeneration,
                destinationMappings[pending.destination.paneID] == mapping
            else {
                return
            }
            if case .failure(let error) = result {
                destinationMappings.removeValue(forKey: pending.destination.paneID)
                logger(error)
            }
        }
    }

    #if DEBUG
        var pendingNotificationCountForTesting: Int {
            pendingNotifications.count
        }

        var destinationMappingCountForTesting: Int {
            destinationMappings.count
        }

        var trackedNotificationCountForTesting: Int {
            pendingNotifications.count + destinationMappings.count
        }
    #endif
}

extension TerminalNotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (
                UNNotificationPresentationOptions
            ) -> Void
    ) {
        let identifier = notification.request.identifier
        let userInfo = TerminalDestination.userInfo(from: notification.request.content.userInfo)
        Task { @MainActor [weak self] in
            guard let self, let userInfo else {
                completionHandler([])
                return
            }
            willPresent(identifier: identifier, userInfo: userInfo) { shouldPresent in
                completionHandler(shouldPresent ? [.banner] : [])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let identifier = response.notification.request.identifier
        let userInfo = TerminalDestination.userInfo(
            from: response.notification.request.content.userInfo
        )
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard actionIdentifier == UNNotificationDefaultActionIdentifier,
                let self,
                let userInfo
            else {
                return
            }
            handleDefaultResponse(identifier: identifier, userInfo: userInfo)
        }
    }
}

extension TerminalNotificationAuthorizationStatus {
    fileprivate var canDeliver: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}
