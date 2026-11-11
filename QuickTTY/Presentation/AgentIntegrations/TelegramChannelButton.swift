import AppKit

@MainActor
final class TelegramChannelButton: NSButton {
    private let toggle: @MainActor () -> Void
    private(set) var channelState = TelegramChannelState.unavailable

    init(
        toggle: @escaping @MainActor () -> Void = {
            AgentMessagingService.current?.connection.toggleEnabled()
        }
    ) {
        self.toggle = toggle
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        imagePosition = .imageLeading
        target = self
        action = #selector(toggleChannel)
        setAccessibilityLabel("Telegram channel for all agents")
        NotificationCenter.default.addObserver(
            self, selector: #selector(channelDidChange(_:)),
            name: AgentMessagingService.didChangeNotification, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func apply(_ state: TelegramChannelState) {
        channelState = state
        title = state.title
        isEnabled = state != .unavailable
        let symbol: String
        switch state {
        case .active:
            symbol = "paperplane.fill"
            contentTintColor = .systemGreen
        case .connecting, .setup:
            symbol = "arrow.triangle.2.circlepath"
            contentTintColor = .systemOrange
        case .failed:
            symbol = "exclamationmark.triangle"
            contentTintColor = .systemOrange
        case .off, .unavailable:
            symbol = "paperplane"
            contentTintColor = .secondaryLabelColor
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        toolTip =
            "Telegram: \(state.accessibilityValue). Toggle for all agents; default shortcut ⌘⌥T. Configure the bot in Agent Integrations…"
        setAccessibilityValue(state.accessibilityValue)
    }

    private func refresh() {
        guard let connection = AgentMessagingService.current?.connection else {
            apply(.unavailable)
            return
        }
        apply(
            TelegramChannelState(
                isEnabled: connection.isEnabled, phase: connection.phase,
                hasError: connection.lastError != nil))
    }

    @objc private func channelDidChange(_ notification: Notification) {
        refresh()
    }

    @objc private func toggleChannel() {
        toggle()
    }
}
