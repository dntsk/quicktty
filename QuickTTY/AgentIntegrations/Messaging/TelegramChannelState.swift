enum TelegramChannelState: Equatable, Sendable {
    case unavailable, off, connecting, active, setup, failed

    init(isEnabled: Bool, phase: TelegramConnectionPhase, hasError: Bool = false) {
        switch phase {
        case .pairing: self = .setup
        case .verifying: self = .connecting
        case .failed: self = .failed
        case .connected where isEnabled && hasError: self = .failed
        case .connected where isEnabled: self = .active
        case .disconnected where isEnabled: self = .connecting
        default: self = .off
        }
    }

    var title: String {
        switch self {
        case .unavailable: "Telegram —"
        case .off: "Telegram Off"
        case .connecting: "Telegram…"
        case .active: "Telegram On"
        case .setup: "Telegram Setup"
        case .failed: "Telegram Error"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .unavailable: "Unavailable"
        case .off: "Off"
        case .connecting: "Connecting"
        case .active: "Active for all agents"
        case .setup: "Setup required"
        case .failed: "Connection error"
        }
    }
}
