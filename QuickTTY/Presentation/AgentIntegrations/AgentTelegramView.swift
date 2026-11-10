import AppKit

@MainActor
final class AgentTelegramView: NSStackView {
    private let service: AgentMessagingService
    private let tokenField = NSSecureTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Not connected")
    private let statusImage = NSImageView()
    private let pairingLabel = NSTextField(wrappingLabelWithString: "")
    private let setupStack = NSStackView()
    private let pairingStack = NSStackView()
    private let settingsStack = NSStackView()
    private let agentLabel = NSTextField(wrappingLabelWithString: "")
    private let questionStack = NSStackView()
    private let emptyQuestionsLabel = NSTextField(labelWithString: "No questions waiting.")
    private let privacyLabel = NSTextField(
        wrappingLabelWithString:
            "Only explicitly submitted questions and brief notices leave this Mac. Bot chats are not end-to-end encrypted. Never send passwords or secrets. Supported integrations provide tools or startup instructions automatically; native permission dialogs are not intercepted."
    )
    private var cards: [UUID: AgentTelegramQuestionCard] = [:]
    private var candidateButton: AgentTelegramButton?
    private var candidateID: UUID?
    private var connectTask: Task<Void, Never>?
    private var isChangingBot = false
    private lazy var enabledButton = AgentTelegramButton("Use Telegram for agents", checkbox: true)
    {
        [weak self] in
        guard let self else { return }
        if service.connection.isEnabled {
            disconnect(forget: false)
        } else {
            service.connection.resume()
        }
        refresh()
    }
    private lazy var cancelButton = AgentTelegramButton("Cancel setup") { [weak self] in
        self?.cancelSetup()
    }
    private lazy var retryButton = AgentTelegramButton("Reconnect") { [weak self] in
        self?.service.connection.resume()
    }

    init(service: AgentMessagingService) {
        self.service = service
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        setAccessibilityLabel("Telegram agent questions and decisions")
        enabledButton.toolTip =
            "Connect automatically when QuickTTY starts. Applies to registered agents in all current and future workspaces. Does not approve actions."
        addArrangedSubview(enabledButton)
        statusImage.setAccessibilityElement(false)
        statusImage.widthAnchor.constraint(equalToConstant: 16).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let statusRow = NSStackView(views: [statusImage, statusLabel])
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        addArrangedSubview(statusRow)
        statusLabel.setAccessibilityLabel("Telegram connection status")
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Connect once. QuickTTY reconnects on launch and lets registered agents in every workspace send questions and receive your replies. Each action still needs your approval."
        )
        explanation.textColor = .secondaryLabelColor
        addArrangedSubview(explanation)

        configure(setupStack)
        let tokenLabel = NSTextField(labelWithString: "Bot token (saved securely in Keychain)")
        setupStack.addArrangedSubview(tokenLabel)
        tokenField.placeholderString = "Paste the token from BotFather"
        tokenField.setAccessibilityLabel("Telegram bot token")
        tokenField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        setupStack.addArrangedSubview(tokenField)
        setupStack.addArrangedSubview(
            AgentTelegramButton("Connect bot") { [weak self] in self?.connect() })
        addArrangedSubview(setupStack)
        configure(pairingStack)
        pairingLabel.isSelectable = true
        pairingLabel.setAccessibilityLabel("Telegram pairing instructions")
        pairingStack.addArrangedSubview(pairingLabel)
        addArrangedSubview(pairingStack)
        addArrangedSubview(cancelButton)

        agentLabel.textColor = .secondaryLabelColor
        agentLabel.setAccessibilityLabel("Agents using Telegram")
        addArrangedSubview(agentLabel)
        let heading = NSTextField(labelWithString: "Waiting for your reply")
        heading.font = .preferredFont(forTextStyle: .headline)
        addArrangedSubview(heading)
        emptyQuestionsLabel.textColor = .secondaryLabelColor
        addArrangedSubview(emptyQuestionsLabel)
        configure(questionStack)
        addArrangedSubview(questionStack)

        configure(settingsStack)
        settingsStack.addArrangedSubview(retryButton)
        settingsStack.addArrangedSubview(
            AgentTelegramButton("Change bot…") { [weak self] in
                guard let self else { return }
                isChangingBot.toggle()
                refresh()
                if isChangingBot { window?.makeFirstResponder(tokenField) }
            })
        settingsStack.addArrangedSubview(
            AgentTelegramButton("Forget bot") { [weak self] in self?.disconnect(forget: true) })
        let integrationHelp = NSTextField(
            wrappingLabelWithString:
                "Install or update supported agent integrations below once. They supply their tools or startup instructions automatically; you do not need to copy instructions into each session. CLI-only adapters do not automatically forward native prompts."
        )
        integrationHelp.textColor = .secondaryLabelColor
        settingsStack.addArrangedSubview(integrationHelp)
        addDisclosure("Connection settings", content: settingsStack)
        privacyLabel.textColor = .secondaryLabelColor
        addDisclosure("Privacy and compatibility", content: privacyLabel)
        for label in [
            explanation, statusLabel, pairingLabel, agentLabel, integrationHelp, privacyLabel,
        ] {
            label.preferredMaxLayoutWidth = 660
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 660).isActive = true
        }
        service.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    isolated deinit { connectTask?.cancel() }

    func cancelSetup() {
        let ownsSetup = connectTask != nil
        connectTask?.cancel()
        connectTask = nil
        tokenField.stringValue = ""
        // Closing a settings sheet must not cancel the application's automatic reconnect task.
        guard ownsSetup else { return }
        switch service.connection.phase {
        case .verifying, .pairing: service.connection.disconnect()
        default: break
        }
    }

    func refresh() {
        let connection = service.connection
        enabledButton.state = connection.isEnabled ? .on : .off
        var candidate: TelegramPairingCandidate?
        var isSettingUp = false
        var isConnected = false
        let symbol: String
        let color: NSColor
        switch connection.phase {
        case .disconnected:
            statusLabel.stringValue = "Off. Turn on to reconnect, or connect a bot below."
            pairingLabel.stringValue = ""
            symbol = "pause.circle"
            color = .secondaryLabelColor
        case .verifying:
            statusLabel.stringValue =
                connection.isRetryingConnection
                ? "Waiting for connection; retrying automatically…" : "Connecting…"
            pairingLabel.stringValue = ""
            isSettingUp = true
            symbol = "arrow.triangle.2.circlepath"
            color = .secondaryLabelColor
        case .pairing(let code, let proposed):
            statusLabel.stringValue = "One-time setup: confirm your Telegram account."
            pairingLabel.stringValue =
                "Open your bot in a private Telegram chat and send:\n/start \(code)\nThis code expires after 5 minutes. Confirm your account here to finish."
            candidate = proposed
            isSettingUp = true
            symbol = "person.crop.circle.badge.questionmark"
            color = .secondaryLabelColor
        case .connected(let peer):
            statusLabel.stringValue =
                connection.lastError == nil
                ? "Connected · Telegram user \(peer.userID)"
                : "Connection interrupted; retrying automatically. You can answer here."
            pairingLabel.stringValue = ""
            isConnected = true
            symbol =
                connection.lastError == nil
                ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
            color = connection.lastError == nil ? .systemGreen : .secondaryLabelColor
        case .failed(let failure):
            switch failure {
            case .credentials:
                statusLabel.stringValue =
                    "Cannot access the saved bot in Keychain. Reconnect or connect another bot."
            case .pairingExpired:
                statusLabel.stringValue = "Setup expired. Connect your bot again for a new code."
            case .network(.conflict):
                statusLabel.stringValue =
                    "Another app or webhook is using this bot. Use a dedicated bot."
            case .network(.invalidToken):
                statusLabel.stringValue = "Enter a valid bot token from BotFather."
            case .network(.unauthorized):
                statusLabel.stringValue =
                    "Telegram rejected the token. Connect your bot with a new token."
            default:
                statusLabel.stringValue =
                    "Could not connect. Reconnect or answer pending questions here."
            }
            pairingLabel.stringValue = ""
            symbol = "exclamationmark.circle"
            color = .systemOrange
        }
        statusImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusImage.contentTintColor = color
        setupStack.isHidden = (isConnected || isSettingUp) && !isChangingBot
        pairingStack.isHidden = pairingLabel.stringValue.isEmpty
        enabledButton.isEnabled = !isSettingUp || connection.isEnabled
        retryButton.isEnabled = !isSettingUp
        cancelButton.isHidden = !isSettingUp || connectTask == nil
        if candidate?.id != candidateID {
            candidateButton?.removeFromSuperview()
            candidateButton = nil
            candidateID = candidate?.id
            if let candidate {
                let button = AgentTelegramButton("Confirm Telegram user \(candidate.peer.userID)") {
                    [weak self] in
                    self?.service.connection.confirmPairing(candidateID: candidate.id)
                }
                candidateButton = button
                pairingStack.addArrangedSubview(button)
            }
        }
        let origins = service.origins()
        let ready = isConnected ? origins.filter { service.isAuthorized($0.origin) } : []
        agentLabel.stringValue =
            ready.isEmpty
            ? "All workspaces included. Supported agents connect when their integration starts."
            : "All workspaces included · \(ready.count) agent(s) ready: "
                + ready.map { "\($0.agentName) · \($0.workspaceName)" }.joined(separator: "; ")
        let pending = connection.snapshots().filter { $0.state == .pending }
        emptyQuestionsLabel.isHidden = !pending.isEmpty
        let liveIDs = Set(pending.map { $0.request.id })
        for id in Array(cards.keys) where !liveIDs.contains(id) {
            cards.removeValue(forKey: id)?.removeFromSuperview()
        }
        for snapshot in pending where cards[snapshot.request.id] == nil {
            let card = AgentTelegramQuestionCard(snapshot: snapshot, connection: connection)
            cards[snapshot.request.id] = card
            questionStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        for snapshot in pending {
            cards[snapshot.request.id]?.updateDelivery(connection.deliveries[snapshot.request.id])
        }
    }

    private func configure(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
    }

    private func addDisclosure(_ title: String, content: NSView) {
        content.isHidden = true
        let button = AgentTelegramButton(title, checkbox: true) { [weak content] in
            guard let content else { return }
            content.isHidden.toggle()
        }
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .disclosure
        addArrangedSubview(NSStackView(views: [button, NSTextField(labelWithString: title)]))
        addArrangedSubview(content)
    }

    private func connect() {
        connectTask?.cancel()
        let token = tokenField.stringValue
        tokenField.stringValue = ""
        isChangingBot = false
        let connection = service.connection
        connectTask = Task { await connection.connect(tokenText: token) }
    }

    private func disconnect(forget: Bool) {
        connectTask?.cancel()
        connectTask = nil
        tokenField.stringValue = ""
        isChangingBot = false
        service.connection.disconnect(forget: forget)
    }
}

@MainActor
private final class AgentTelegramButton: NSButton {
    private let handler: @MainActor () -> Void
    init(_ title: String, checkbox: Bool = false, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        setButtonType(checkbox ? .switch : .momentaryPushIn)
        if !checkbox { bezelStyle = .rounded }
        target = self
        action = #selector(performAction)
        setAccessibilityLabel(title)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func performAction() { handler() }
}

@MainActor
private final class AgentTelegramQuestionCard: NSStackView {
    private let snapshot: AgentInteractionSnapshot
    private let connection: TelegramConnectionController
    private let answerField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let deliveryLabel = NSTextField(wrappingLabelWithString: "")

    init(snapshot: AgentInteractionSnapshot, connection: TelegramConnectionController) {
        self.snapshot = snapshot
        self.connection = connection
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let title = NSTextField(
            wrappingLabelWithString:
                "\(snapshot.presentation.workspaceName) · \(snapshot.presentation.agentName)")
        title.font = .preferredFont(forTextStyle: .headline)
        addArrangedSubview(title)
        let text: String
        switch snapshot.request.prompt {
        case .question(let question, let choices):
            text = question
            for (index, label) in choices.enumerated() {
                addArrangedSubview(
                    AgentTelegramButton(label) { [weak self] in self?.answer(.choice(index)) })
            }
        case .action(let action):
            text =
                "Action:\n\(action.operation)\n\nResources:\n\(action.resources)\n\nConsequences:\n\(action.consequences)"
            if action.risk == .standard {
                addArrangedSubview(
                    AgentTelegramButton("Allow once") { [weak self] in self?.answer(.approve) })
            }
            addArrangedSubview(AgentTelegramButton("Deny") { [weak self] in self?.answer(.deny) })
        }
        let body = NSTextField(wrappingLabelWithString: text)
        body.isSelectable = true
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 660).isActive = true
        insertArrangedSubview(body, at: 1)
        let label: String?
        switch snapshot.request.prompt {
        case .question: label = "Your reply"
        case .action(let action):
            label =
                action.risk == .elevated
                ? "To allow once, enter exactly: \(snapshot.request.confirmationPhrase)" : nil
        }
        if let label {
            addArrangedSubview(NSTextField(wrappingLabelWithString: label))
            answerField.setAccessibilityLabel(label)
            answerField.widthAnchor.constraint(equalToConstant: 400).isActive = true
            answerField.target = self
            answerField.action = #selector(submitText)
            addArrangedSubview(answerField)
            addArrangedSubview(
                AgentTelegramButton("Send reply") { [weak self] in self?.submitText() })
        }
        deliveryLabel.textColor = .secondaryLabelColor
        deliveryLabel.preferredMaxLayoutWidth = 660
        addArrangedSubview(deliveryLabel)
        addArrangedSubview(
            AgentTelegramButton("Cancel request") { [weak self] in self?.answer(.cancel) })
        errorLabel.textColor = .systemRed
        addArrangedSubview(errorLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func updateDelivery(_ state: TelegramDeliveryState?) {
        switch state {
        case .sending: deliveryLabel.stringValue = "Sending to Telegram… You can also answer here."
        case .sent:
            deliveryLabel.stringValue = "Sent to Telegram. Only the first answer is accepted."
        case .failed(.deliveryUncertain):
            deliveryLabel.stringValue =
                "Telegram delivery is uncertain. Do not resend blindly; you can answer here."
        case .failed:
            deliveryLabel.stringValue =
                "Telegram delivery failed. Answer here; no automatic resend."
        case nil: deliveryLabel.stringValue = ""
        }
    }

    @objc private func submitText() { answer(.text(answerField.stringValue)) }
    private func answer(_ answer: AgentInteractionAnswer) {
        do { try connection.answerLocally(snapshot.request.id, answer: answer) } catch {
            errorLabel.stringValue =
                "Answer not accepted. Check the exact confirmation phrase or whether the request has expired."
        }
    }
}
