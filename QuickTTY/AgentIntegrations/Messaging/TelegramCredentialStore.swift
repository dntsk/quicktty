import Foundation
import LocalAuthentication
import Security

struct TelegramSavedConnection: Sendable {
    let token: TelegramBotToken
    let peer: TelegramPeer
}

enum TelegramCredentialError: Error, Equatable, Sendable {
    case unavailable
    case temporarilyUnavailable
    case invalidRecord
}

struct TelegramCredentialStore: Sendable {
    let load: @Sendable () throws -> TelegramSavedConnection?
    let save: @Sendable (TelegramBotToken, TelegramPeer) throws -> Void
    let remove: @Sendable () throws -> Void

    static func keychain() -> Self {
        Self(
            load: {
                var query = query()
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound { return nil }
                if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
                    throw TelegramCredentialError.temporarilyUnavailable
                }
                guard status == errSecSuccess, let data = result as? Data else {
                    throw TelegramCredentialError.unavailable
                }
                do {
                    let saved = try TelegramBotToken.fromKeychainData(data)
                    return TelegramSavedConnection(token: saved.token, peer: saved.peer)
                } catch {
                    throw TelegramCredentialError.invalidRecord
                }
            },
            save: { token, peer in
                let data = try token.keychainData(peer: peer)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    // Remote questions must still work after the user locks the screen.
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                let query = query()
                let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                if status == errSecSuccess { return }
                guard status == errSecItemNotFound else {
                    throw TelegramCredentialError.unavailable
                }
                let insertion = query.merging(attributes) { _, new in new }
                guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                    throw TelegramCredentialError.unavailable
                }
            },
            remove: {
                let status = SecItemDelete(query() as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw TelegramCredentialError.unavailable
                }
            }
        )
    }

    private static func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.dntsk.QuickTTY.agent-telegram",
            kSecAttrAccount as String: "connection-v1",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
    }
}
