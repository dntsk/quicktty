@MainActor
struct TelegramConnectionPreferences {
    let loadEnabled: @MainActor () -> Bool
    let saveEnabled: @MainActor (Bool) -> Void

    static func standard() -> Self {
        // A saved bot must not opt a new application session into Telegram network activity.
        .transient()
    }

    static func transient(enabled: Bool = false) -> Self {
        var enabled = enabled
        return Self(loadEnabled: { enabled }, saveEnabled: { enabled = $0 })
    }
}
