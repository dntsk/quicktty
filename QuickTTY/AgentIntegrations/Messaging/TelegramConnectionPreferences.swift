import Foundation

@MainActor
struct TelegramConnectionPreferences {
    private static let enabledKey = "com.dntsk.QuickTTY.AgentTelegram.enabled"

    let loadEnabled: @MainActor () -> Bool
    let saveEnabled: @MainActor (Bool) -> Void

    static func standard(defaults: UserDefaults = .standard) -> Self {
        Self(
            // Existing paired bots predate this preference and should reconnect without re-pairing.
            loadEnabled: {
                defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
            },
            saveEnabled: { defaults.set($0, forKey: enabledKey) }
        )
    }

    static func transient(enabled: Bool = false) -> Self {
        var enabled = enabled
        return Self(loadEnabled: { enabled }, saveEnabled: { enabled = $0 })
    }
}
