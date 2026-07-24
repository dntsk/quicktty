import Foundation
import UserNotifications

enum TerminalNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

struct TerminalNotificationClientError: Error, Equatable, Sendable {
    let domain: String
    let code: Int

    init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
    }
}

struct TerminalNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let userInfo: [String: String]
}

@MainActor
protocol TerminalNotificationClient: AnyObject {
    func authorizationStatus(
        completion:
            @escaping @MainActor @Sendable (
                TerminalNotificationAuthorizationStatus
            ) -> Void
    )

    func requestAuthorization(
        completion:
            @escaping @MainActor @Sendable (
                Result<Bool, TerminalNotificationClientError>
            ) -> Void
    )

    func add(
        _ request: TerminalNotificationRequest,
        completion:
            @escaping @MainActor @Sendable (
                Result<Void, TerminalNotificationClientError>
            ) -> Void
    )
}

@MainActor
final class SystemTerminalNotificationClient: TerminalNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        center.delegate = delegate
    }

    func authorizationStatus(
        completion:
            @escaping @MainActor @Sendable (
                TerminalNotificationAuthorizationStatus
            ) -> Void
    ) {
        center.getNotificationSettings { settings in
            let status = Self.authorizationStatus(from: settings.authorizationStatus)
            Task { @MainActor in
                completion(status)
            }
        }
    }

    func requestAuthorization(
        completion:
            @escaping @MainActor @Sendable (
                Result<Bool, TerminalNotificationClientError>
            ) -> Void
    ) {
        center.requestAuthorization(options: [.alert]) { granted, error in
            let result: Result<Bool, TerminalNotificationClientError> =
                if let error {
                    .failure(TerminalNotificationClientError(error))
                } else {
                    .success(granted)
                }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func add(
        _ request: TerminalNotificationRequest,
        completion:
            @escaping @MainActor @Sendable (
                Result<Void, TerminalNotificationClientError>
            ) -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.userInfo = request.userInfo
        center.add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: nil
            )
        ) { error in
            let result: Result<Void, TerminalNotificationClientError> =
                if let error {
                    .failure(TerminalNotificationClientError(error))
                } else {
                    .success(())
                }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    nonisolated private static func authorizationStatus(
        from status: UNAuthorizationStatus
    ) -> TerminalNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .denied
        }
    }
}
