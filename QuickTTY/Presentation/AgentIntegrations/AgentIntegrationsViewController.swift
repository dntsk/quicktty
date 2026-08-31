import AppKit

struct AgentIntegrationBindingSnapshot: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case active = "Active"
        case restoring = "Restoring"
        case unverified = "Unverified"
        case failed = "Failed"
    }

    let paneID: PaneID
    let agentName: String
    let state: State
    let canRetry: Bool
    let canForget: Bool
}

struct AgentIntegrationGeneratedResponse<Value: Sendable>: Sendable {
    let generation: UUID
    let value: Value
}

struct AgentIntegrationConfirmationRequest: Equatable, Sendable {
    let title: String
    let confirmTitle: String
    let previewText: String
}

struct AgentIntegrationInstallerClient: Sendable {
    let adapterIDs: [String]
    let status:
        @Sendable (UUID) async throws -> AgentIntegrationGeneratedResponse<
            [AgentIntegrationAdapterSummary]
        >
    let prepare:
        @Sendable (UUID, AgentIntegrationInstallerAction, [String]) async throws
            -> AgentIntegrationGeneratedResponse<AgentIntegrationPreparedSummary>
    let apply:
        @Sendable (UUID, String) async throws
            -> AgentIntegrationGeneratedResponse<AgentIntegrationApplySummary>

    init(
        adapterIDs: [String],
        status:
            @escaping @Sendable (UUID) async throws -> AgentIntegrationGeneratedResponse<
                [AgentIntegrationAdapterSummary]
            >,
        prepare:
            @escaping @Sendable (UUID, AgentIntegrationInstallerAction, [String]) async throws
            -> AgentIntegrationGeneratedResponse<AgentIntegrationPreparedSummary>,
        apply:
            @escaping @Sendable (UUID, String) async throws
            -> AgentIntegrationGeneratedResponse<AgentIntegrationApplySummary>
    ) {
        self.adapterIDs = adapterIDs
        self.status = status
        self.prepare = prepare
        self.apply = apply
    }

    init(
        adapterIDs: [String],
        status: @escaping @Sendable () async throws -> [AgentIntegrationAdapterSummary],
        prepare: @escaping @Sendable ([String]) async throws -> AgentIntegrationPreparedSummary,
        apply: @escaping @Sendable (String) async throws -> AgentIntegrationApplySummary
    ) {
        self.init(
            adapterIDs: adapterIDs,
            status: { generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await status()
                )
            },
            prepare: { generation, _, selected in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await prepare(selected)
                )
            },
            apply: { generation, planID in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await apply(planID)
                )
            }
        )
    }

    static func live(_ installer: AgentIntegrationInstaller) -> Self {
        Self(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.status()
                )
            },
            prepare: { generation, action, selected in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.prepare(
                        action: action,
                        selectedAdapterIDs: selected
                    )
                )
            },
            apply: { generation, planID in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.apply(planID: planID)
                )
            }
        )
    }
}

struct CommandLineLauncherInstallerClient: Sendable {
    let status:
        @Sendable (UUID) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherStatus>
    let prepare:
        @Sendable (UUID, CommandLineLauncherAction) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherSummary>
    let apply:
        @Sendable (UUID, String) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherStatus>

    init(
        status:
            @escaping @Sendable (UUID) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherStatus>,
        prepare:
            @escaping @Sendable (UUID, CommandLineLauncherAction) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherSummary>,
        apply:
            @escaping @Sendable (UUID, String) async throws
            -> AgentIntegrationGeneratedResponse<CommandLineLauncherStatus>
    ) {
        self.status = status
        self.prepare = prepare
        self.apply = apply
    }

    init(
        prepare: @escaping @Sendable () async throws -> CommandLineLauncherSummary,
        apply: @escaping @Sendable (String) async throws -> CommandLineLauncherStatus
    ) {
        self.init(
            status: { generation in
                AgentIntegrationGeneratedResponse(generation: generation, value: .available)
            },
            prepare: { generation, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await prepare()
                )
            },
            apply: { generation, planID in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await apply(planID)
                )
            }
        )
    }

    static func live(_ installer: CommandLineLauncherInstaller) -> Self {
        Self(
            status: { generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.status()
                )
            },
            prepare: { generation, action in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.prepare(action: action)
                )
            },
            apply: { generation, planID in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await installer.apply(planID: planID)
                )
            }
        )
    }
}

@MainActor
final class AgentIntegrationsViewController: NSViewController {
    typealias BindingProvider = @MainActor () -> [AgentIntegrationBindingSnapshot]
    typealias BindingAction = @MainActor (PaneID) -> Void
    typealias PreviewCopy = @MainActor (String) -> Void
    typealias ConfirmationPresenter =
        @MainActor (AgentIntegrationConfirmationRequest) async -> Bool

    private static let maximumRenderedOperations = 8
    private static let maximumRenderedPathLength = 512
    private static let maximumCopiedCharacters = 131_072

    private let installer: AgentIntegrationInstallerClient
    private let launcherInstaller: CommandLineLauncherInstallerClient
    private let bindingProvider: BindingProvider
    private let retryBinding: BindingAction
    private let forgetBinding: BindingAction
    private let copyPreview: PreviewCopy
    private let confirmationPresenter: ConfirmationPresenter?

    private let contentStack = NSStackView()
    private let integrationsStack = NSStackView()
    private let launcherStack = NSStackView()
    private let bindingsStack = NSStackView()
    private let actionSelector = NSSegmentedControl(
        labels: ["Install", "Uninstall"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let integrationButton = NSButton(
        title: "Install Selected",
        target: nil,
        action: nil
    )
    private let launcherButton = NSButton(
        title: "Install Command-Line Tool",
        target: nil,
        action: nil
    )
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")

    private var statusTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var currentGeneration = UUID()
    private var applyGeneration: UUID?
    private var isOperationVisible = false
    private var isClosed = false
    private var preparedSummary: AgentIntegrationPreparedSummary?
    private var preparedSelection: [String] = []
    private var preparedAction: AgentIntegrationInstallerAction?
    private var launcherPreparedSummary: CommandLineLauncherSummary?
    private var launcherPreparedAction: AgentIntegrationInstallerAction?
    private var launcherStatus: CommandLineLauncherStatus?
    private var resultAction: AgentIntegrationInstallerAction?
    private(set) var summaries: [AgentIntegrationAdapterSummary]
    private(set) var applySummaries: [AgentIntegrationAdapterSummary] = []
    private(set) var bindingSnapshots: [AgentIntegrationBindingSnapshot] = []
    private(set) var selectedAdapterIDs: Set<String> = []
    private(set) var selectedAction: AgentIntegrationInstallerAction = .install
    private(set) var isApplying = false
    private var isConfirming = false

    var onRequestClose: (@MainActor () -> Void)?
    var canDismiss: Bool { !isApplying && !isConfirming }
    var orderedAdapterIDs: [String] { AgentIntegrationInstaller.adapterIDs }

    init(
        installer: AgentIntegrationInstallerClient,
        launcherInstaller: CommandLineLauncherInstallerClient,
        bindingProvider: @escaping BindingProvider,
        retryBinding: @escaping BindingAction,
        forgetBinding: @escaping BindingAction,
        copyPreview: @escaping PreviewCopy = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        },
        confirmationPresenter: ConfirmationPresenter? = nil
    ) {
        self.installer = installer
        self.launcherInstaller = launcherInstaller
        self.bindingProvider = bindingProvider
        self.retryBinding = retryBinding
        self.forgetBinding = forgetBinding
        self.copyPreview = copyPreview
        self.confirmationPresenter = confirmationPresenter
        summaries = Self.initialSummaries()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityLabel("Agent Integrations")
        isOperationVisible = true
        isClosed = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Agent Integrations")
        title.font = .preferredFont(forTextStyle: .title1)
        title.setAccessibilityLabel("Agent Integrations")
        contentStack.addArrangedSubview(title)

        let explanation = NSTextField(
            wrappingLabelWithString:
                "Review detected integrations, preview bounded changes, then confirm before applying."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.setAccessibilityLabel("Agent integrations instructions")
        contentStack.addArrangedSubview(explanation)

        actionSelector.selectedSegment = 0
        actionSelector.target = self
        actionSelector.action = #selector(changeSelectedAction(_:))
        actionSelector.setAccessibilityLabel("Integration action")
        contentStack.addArrangedSubview(actionSelector)

        integrationButton.target = self
        integrationButton.action = #selector(changeSelectedIntegrations)
        integrationButton.keyEquivalent = "\r"
        launcherButton.target = self
        launcherButton.action = #selector(changeCommandLineTool)
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityLabel("Close Agent Integrations")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Applying agent integrations")

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 2
        messageLabel.setAccessibilityLabel("Agent integrations operation status")

        integrationButton.setAccessibilityLabel("Change selected agent integrations")
        contentStack.addArrangedSubview(integrationButton)
        contentStack.addArrangedSubview(messageLabel)

        configureSectionStack(integrationsStack, label: "Available agent integrations")
        contentStack.addArrangedSubview(section(title: "Integrations", content: integrationsStack))

        configureSectionStack(launcherStack, label: "Command-line tool")
        launcherStack.addArrangedSubview(launcherButton)
        contentStack.addArrangedSubview(
            section(title: "Command-Line Tool", content: launcherStack)
        )

        configureSectionStack(bindingsStack, label: "Agent session bindings")
        contentStack.addArrangedSubview(section(title: "Session Bindings", content: bindingsStack))

        let footer = NSStackView(views: [progressIndicator, NSView(), closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: 20
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -20
            ),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalToConstant: 700),
        ])

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityLabel("Agent Integrations content")
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 740),
            root.heightAnchor.constraint(equalToConstant: 640),
        ])
        view = root
        renderAll()
    }

    func reload() {
        guard !isBusy else { return }
        isClosed = false
        isOperationVisible = true
        bindingSnapshots = bindingProvider()
        let generation = beginStatusRefresh()
        renderAll()
        statusTask = Task { @MainActor [weak self] in
            await self?.performStatusRefresh(generation: generation)
        }
    }

    func reloadStatus() async {
        guard !isBusy else { return }
        isClosed = false
        isOperationVisible = true
        let generation = beginStatusRefresh()
        renderAll()
        await performStatusRefresh(generation: generation)
        guard accepts(generation: generation) else { return }
        bindingSnapshots = bindingProvider()
        renderAll()
    }

    func setAction(_ action: AgentIntegrationInstallerAction) {
        guard !isBusy, selectedAction != action else { return }
        cancelNonApplyTasks()
        advanceGeneration()
        selectedAction = action
        actionSelector.selectedSegment = action == .install ? 0 : 1
        selectedAdapterIDs.formIntersection(selectableAdapterIDs)
        invalidatePreparedPlan(clearResults: true)
        launcherPreparedSummary = nil
        launcherPreparedAction = nil
        messageLabel.stringValue = ""
        renderAll()
    }

    func setSelected(_ adapterID: String, selected: Bool) {
        guard !isBusy, selectableAdapterIDs.contains(adapterID) else { return }
        if selected {
            selectedAdapterIDs.insert(adapterID)
        } else {
            selectedAdapterIDs.remove(adapterID)
        }
        cancelNonApplyTasks()
        advanceGeneration()
        invalidatePreparedPlan(clearResults: true)
        renderAll()
    }

    func prepareSelection() async {
        guard operationCanStart else { return }
        let selection = orderedAdapterIDs.filter(selectedAdapterIDs.contains)
        guard !selection.isEmpty else { return }
        cancelNonApplyTasks()
        let generation = advanceGeneration()
        invalidatePreparedPlan(clearResults: true)
        launcherPreparedSummary = nil
        launcherPreparedAction = nil
        renderAll()
        do {
            let response = try await installer.prepare(generation, selectedAction, selection)
            guard accepts(response: response, generation: generation) else { return }
            let prepared = bounded(response.value, selectedAdapterIDs: Set(selection))
            preparedSummary = prepared
            preparedSelection = selection
            preparedAction = selectedAction
            messageLabel.stringValue =
                selectedAction == .install
                ? "Confirm the installation preview before applying changes."
                : "Confirm the removal preview before applying changes."
        } catch is CancellationError {
            return
        } catch {
            guard accepts(generation: generation) else { return }
            messageLabel.stringValue =
                selectedAction == .install
                ? "The installation preview could not be prepared."
                : "The removal preview could not be prepared."
            invalidatePreparedPlan(clearResults: true)
        }
        renderAll()
    }

    func confirmApply() async {
        guard operationCanStart,
            let preparedSummary,
            let preparedAction,
            preparedAction == selectedAction,
            preparedSelection == orderedAdapterIDs.filter(selectedAdapterIDs.contains)
        else { return }
        cancelNonApplyTasks()
        let generation = advanceGeneration()
        applyGeneration = generation
        isApplying = true
        defer {
            if isApplying, applyGeneration == generation {
                invalidatePreparedPlan(clearResults: true)
                finishApply(message: "Integration changes were cancelled or became unavailable.")
            }
        }
        resultAction = nil
        applySummaries = []
        renderAll()
        progressIndicator.startAnimation(nil)
        messageLabel.stringValue =
            preparedAction == .install ? "Installing integrations…" : "Removing integrations…"

        do {
            let response = try await installer.apply(generation, preparedSummary.planID)
            guard acceptsApply(response: response, generation: generation) else { return }
            applySummaries = orderedAndBoundedSubset(response.value.adapters)
            resultAction = preparedAction
            self.preparedSummary = nil
            preparedSelection = []
            self.preparedAction = nil
            selectedAdapterIDs.removeAll()
            renderAll()

            do {
                let statusResponse = try await installer.status(generation)
                guard acceptsApply(response: statusResponse, generation: generation) else { return }
                guard let fullStatus = validatedFullStatus(statusResponse.value) else {
                    finishApply(
                        message: "Changes applied, but integration status is unavailable."
                    )
                    return
                }
                summaries = fullStatus
                finishApply(
                    message: preparedAction == .install
                        ? "Integration installation finished."
                        : "Integration removal finished."
                )
            } catch is CancellationError {
                return
            } catch {
                guard acceptsApply(generation: generation) else { return }
                finishApply(message: "Changes applied, but integration status is unavailable.")
            }
        } catch is CancellationError {
            return
        } catch {
            guard acceptsApply(generation: generation) else { return }
            self.preparedSummary = nil
            preparedSelection = []
            self.preparedAction = nil
            finishApply(
                message: preparedAction == .install
                    ? "Installation failed and was rolled back where required."
                    : "Removal failed and was rolled back where required."
            )
        }
    }

    func changeSelectedIntegrationsWithConfirmation() async {
        await prepareSelection()
        guard operationCanStart, preparedSummary != nil, !Task.isCancelled else { return }

        let action = selectedAction
        let request = confirmationRequest(
            title: action == .install
                ? "Install selected integrations?" : "Uninstall selected integrations?",
            confirmTitle: action == .install ? "Install" : "Uninstall"
        )
        isConfirming = true
        renderAll()
        let confirmed = await requestConfirmation(request)
        isConfirming = false

        guard !Task.isCancelled, isOperationVisible, !isClosed else {
            invalidatePreparedPlan(clearResults: true)
            renderAll()
            return
        }
        guard confirmed else {
            invalidatePreparedPlan(clearResults: true)
            messageLabel.stringValue =
                action == .install ? "Installation cancelled." : "Removal cancelled."
            renderAll()
            return
        }
        await confirmApply()
    }

    func prepareCommandLineTool() async {
        guard operationCanStart, launcherActionIsAvailable else { return }
        cancelNonApplyTasks()
        let generation = advanceGeneration()
        launcherPreparedSummary = nil
        launcherPreparedAction = nil
        invalidatePreparedPlan(clearResults: true)
        renderAll()
        do {
            let response = try await launcherInstaller.prepare(
                generation,
                commandLineLauncherAction
            )
            guard accepts(response: response, generation: generation) else { return }
            launcherPreparedSummary = bounded(response.value)
            launcherPreparedAction = selectedAction
            messageLabel.stringValue =
                selectedAction == .install
                ? "Confirm command line tool installation at ~/.local/bin/quicktty."
                : "Confirm command line tool removal at ~/.local/bin/quicktty."
        } catch is CancellationError {
            return
        } catch {
            guard accepts(generation: generation) else { return }
            launcherPreparedSummary = nil
            launcherPreparedAction = nil
            messageLabel.stringValue =
                selectedAction == .install
                ? "The command line tool installation preview could not be prepared."
                : "The command line tool removal preview could not be prepared."
        }
        renderAll()
    }

    func confirmCommandLineToolChange() async {
        guard operationCanStart,
            let summary = launcherPreparedSummary,
            let action = launcherPreparedAction,
            action == selectedAction
        else { return }
        cancelNonApplyTasks()
        let generation = advanceGeneration()
        applyGeneration = generation
        isApplying = true
        defer {
            if isApplying, applyGeneration == generation {
                launcherPreparedSummary = nil
                launcherPreparedAction = nil
                finishApply(
                    message: "Command line tool change was cancelled or became unavailable.")
            }
        }
        renderAll()
        progressIndicator.startAnimation(nil)
        messageLabel.stringValue =
            action == .install
            ? "Installing command line tool…" : "Removing command line tool…"
        do {
            let response = try await launcherInstaller.apply(generation, summary.planID)
            guard acceptsApply(response: response, generation: generation) else { return }
            launcherPreparedSummary = nil
            launcherPreparedAction = nil
            do {
                let statusResponse = try await launcherInstaller.status(generation)
                guard acceptsApply(response: statusResponse, generation: generation) else { return }
                launcherStatus = statusResponse.value
                finishApply(
                    message: action == .install
                        ? "Command line tool installation finished."
                        : "Command line tool removal finished."
                )
            } catch is CancellationError {
                return
            } catch {
                guard acceptsApply(generation: generation) else { return }
                finishApply(message: "Command line tool status is unavailable.")
            }
        } catch is CancellationError {
            return
        } catch {
            guard acceptsApply(generation: generation) else { return }
            launcherPreparedSummary = nil
            launcherPreparedAction = nil
            finishApply(
                message: action == .install
                    ? "Command line tool installation failed."
                    : "Command line tool removal failed."
            )
        }
    }

    func changeCommandLineToolWithConfirmation() async {
        await prepareCommandLineTool()
        guard operationCanStart, launcherPreparedSummary != nil, !Task.isCancelled else {
            return
        }

        let action = selectedAction
        let request = confirmationRequest(
            title: action == .install
                ? "Install command-line tool?" : "Uninstall command-line tool?",
            confirmTitle: action == .install ? "Install" : "Uninstall"
        )
        isConfirming = true
        renderAll()
        let confirmed = await requestConfirmation(request)
        isConfirming = false

        guard !Task.isCancelled, isOperationVisible, !isClosed else {
            launcherPreparedSummary = nil
            launcherPreparedAction = nil
            renderAll()
            return
        }
        guard confirmed else {
            launcherPreparedSummary = nil
            launcherPreparedAction = nil
            messageLabel.stringValue =
                action == .install
                ? "Command-line tool installation cancelled."
                : "Command-line tool removal cancelled."
            renderAll()
            return
        }
        await confirmCommandLineToolChange()
    }

    func confirmCommandLineToolInstallation() async {
        await confirmCommandLineToolChange()
    }

    func retry(snapshot: AgentIntegrationBindingSnapshot) {
        guard !isBusy, snapshot.canRetry,
            bindingSnapshots.contains(snapshot)
        else { return }
        retryBinding(snapshot.paneID)
        bindingSnapshots = bindingProvider()
        renderBindings()
    }

    func forget(snapshot: AgentIntegrationBindingSnapshot) {
        guard !isBusy, snapshot.canForget,
            bindingSnapshots.contains(snapshot)
        else { return }
        forgetBinding(snapshot.paneID)
        bindingSnapshots = bindingProvider()
        renderBindings()
    }

    func cancelDismissibleTasks() {
        guard canDismiss else { return }
        applyTask?.cancel()
        applyTask = nil
        cancelNonApplyTasks()
        advanceGeneration()
        invalidatePreparedPlan(clearResults: true)
        launcherPreparedSummary = nil
        launcherPreparedAction = nil
        isOperationVisible = false
        isClosed = true
        renderAll()
    }

    private var isBusy: Bool { isApplying || isConfirming }

    private var operationCanStart: Bool {
        !isBusy && isOperationVisible && !isClosed
    }

    private var selectableAdapterIDs: Set<String> {
        Set(
            summaries.compactMap { summary in
                guard summary.capability != .blocked else { return nil }
                let selectable: Bool
                switch selectedAction {
                case .install:
                    selectable =
                        summary.status == .available || summary.status == .updateAvailable
                        || summary.status == .conflict
                case .uninstall:
                    selectable = summary.status == .installed
                }
                return selectable ? summary.adapterID : nil
            }
        )
    }

    private var commandLineLauncherAction: CommandLineLauncherAction {
        selectedAction == .install ? .install : .uninstall
    }

    private var launcherActionIsAvailable: Bool {
        guard let launcherStatus else { return false }
        switch selectedAction {
        case .install:
            return launcherStatus == .available || launcherStatus == .conflict
        case .uninstall:
            return launcherStatus == .installed
        }
    }

    private func beginStatusRefresh() -> UUID {
        cancelNonApplyTasks()
        let generation = advanceGeneration()
        invalidatePreparedPlan(clearResults: true)
        launcherPreparedSummary = nil
        launcherPreparedAction = nil
        messageLabel.stringValue = ""
        return generation
    }

    private func performStatusRefresh(generation: UUID) async {
        do {
            let statusResponse = try await installer.status(generation)
            guard accepts(response: statusResponse, generation: generation) else { return }
            let launcherResponse = try await launcherInstaller.status(generation)
            guard accepts(response: launcherResponse, generation: generation) else { return }
            guard let fullStatus = validatedFullStatus(statusResponse.value) else {
                messageLabel.stringValue = "Integration status is unavailable."
                renderAll()
                return
            }
            summaries = fullStatus
            launcherStatus = launcherResponse.value
            selectedAdapterIDs.formIntersection(selectableAdapterIDs)
            messageLabel.stringValue = ""
        } catch is CancellationError {
            return
        } catch {
            guard accepts(generation: generation) else { return }
            messageLabel.stringValue = "Integration status is unavailable."
        }
        renderAll()
    }

    private func finishApply(message: String) {
        messageLabel.stringValue = boundedText(message, limit: 160)
        isApplying = false
        applyGeneration = nil
        progressIndicator.stopAnimation(nil)
        bindingSnapshots = bindingProvider()
        renderAll()
    }

    @discardableResult
    private func advanceGeneration() -> UUID {
        let generation = UUID()
        currentGeneration = generation
        return generation
    }

    private func accepts(generation: UUID) -> Bool {
        currentGeneration == generation && isOperationVisible && !isClosed && !Task.isCancelled
    }

    private func accepts<Value: Sendable>(
        response: AgentIntegrationGeneratedResponse<Value>,
        generation: UUID
    ) -> Bool {
        response.generation == generation && accepts(generation: generation)
    }

    private func acceptsApply(generation: UUID) -> Bool {
        applyGeneration == generation && accepts(generation: generation)
    }

    private func acceptsApply<Value: Sendable>(
        response: AgentIntegrationGeneratedResponse<Value>,
        generation: UUID
    ) -> Bool {
        response.generation == generation && acceptsApply(generation: generation)
    }

    private func cancelNonApplyTasks() {
        statusTask?.cancel()
        statusTask = nil
    }

    private static func initialSummaries() -> [AgentIntegrationAdapterSummary] {
        AgentIntegrationInstaller.adapterIDs.map { adapterID in
            let capability = installerCapability(for: adapterID) ?? .blocked
            return AgentIntegrationAdapterSummary(
                adapterID: adapterID,
                capability: capability,
                status: capability == .blocked ? .blocked : .unverified,
                operations: []
            )
        }
    }

    private static func installerCapability(
        for adapterID: String
    ) -> AgentIntegrationInstallerCapability? {
        guard
            let capability = AgentIntegrationRegistry.definitions.first(where: {
                $0.id.rawValue == adapterID
            })?.capability
        else { return nil }
        switch capability {
        case .nativeLifecycle: return .nativeLifecycle
        case .wrapperLifecycle: return .wrapperLifecycle
        case .blocked: return .blocked
        }
    }

    private func validatedFullStatus(
        _ values: [AgentIntegrationAdapterSummary]
    ) -> [AgentIntegrationAdapterSummary]? {
        guard values.count == orderedAdapterIDs.count else { return nil }
        var byID: [String: AgentIntegrationAdapterSummary] = [:]
        for value in values {
            guard byID[value.adapterID] == nil,
                let expectedCapability = Self.installerCapability(for: value.adapterID),
                value.capability == expectedCapability
            else { return nil }
            byID[value.adapterID] = bounded(value)
        }
        guard Set(byID.keys) == Set(orderedAdapterIDs) else { return nil }
        return orderedAdapterIDs.compactMap { byID[$0] }
    }

    private func orderedAndBoundedSubset(
        _ values: [AgentIntegrationAdapterSummary]
    ) -> [AgentIntegrationAdapterSummary] {
        var byID: [String: AgentIntegrationAdapterSummary] = [:]
        for value in values.prefix(orderedAdapterIDs.count) where byID[value.adapterID] == nil {
            guard orderedAdapterIDs.contains(value.adapterID),
                Self.installerCapability(for: value.adapterID) == value.capability
            else { continue }
            byID[value.adapterID] = bounded(value)
        }
        return orderedAdapterIDs.compactMap { byID[$0] }
    }

    private func bounded(
        _ summary: AgentIntegrationPreparedSummary,
        selectedAdapterIDs: Set<String>
    ) -> AgentIntegrationPreparedSummary {
        AgentIntegrationPreparedSummary(
            planID: summary.planID,
            adapters: orderedAndBoundedSubset(summary.adapters).filter {
                selectedAdapterIDs.contains($0.adapterID)
            }
        )
    }

    private func bounded(_ summary: CommandLineLauncherSummary) -> CommandLineLauncherSummary {
        CommandLineLauncherSummary(
            planID: summary.planID,
            displayPath: boundedRelativePath(summary.displayPath),
            kind: ["symlinkCreate", "symlinkRemove"].contains(summary.kind)
                ? summary.kind : "operation",
            createsBackup: summary.createsBackup,
            status: summary.status
        )
    }

    private func bounded(
        _ summary: AgentIntegrationAdapterSummary
    ) -> AgentIntegrationAdapterSummary {
        AgentIntegrationAdapterSummary(
            adapterID: summary.adapterID,
            capability: summary.capability,
            status: summary.status,
            operations: summary.operations.prefix(Self.maximumRenderedOperations).map { operation in
                AgentIntegrationOperationSummary(
                    displayPath: boundedRelativePath(operation.displayPath),
                    kind: operation.kind,
                    createsBackup: operation.createsBackup,
                    operation: operation.operation,
                    mode: operation.mode
                )
            }
        )
    }

    private func boundedRelativePath(_ value: String) -> String {
        let bounded = boundedText(value, limit: Self.maximumRenderedPathLength)
        guard bounded.hasPrefix("~/") || bounded.hasPrefix("Application Support/") else {
            return "(invalid relative path)"
        }
        return bounded
    }

    private func boundedText(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private func configureSectionStack(_ stack: NSStackView, label: String) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setAccessibilityLabel(label)
    }

    private func section(title: String, content: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.setAccessibilityLabel(title)
        let stack = NSStackView(views: [titleLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func renderAll() {
        guard isViewLoaded else { return }
        renderIntegrations()
        renderBindings()

        let isInstall = selectedAction == .install
        let selection = orderedAdapterIDs.filter(selectedAdapterIDs.contains)
        integrationButton.title = isInstall ? "Install Selected" : "Uninstall Selected"
        integrationButton.setAccessibilityLabel(integrationButton.title)
        integrationButton.isEnabled = !isBusy && !selection.isEmpty
        actionSelector.isEnabled = !isBusy
        launcherButton.title =
            isInstall ? "Install Command-Line Tool" : "Uninstall Command-Line Tool"
        launcherButton.setAccessibilityLabel(launcherButton.title)
        launcherButton.isEnabled = !isBusy && launcherActionIsAvailable
        closeButton.isEnabled = !isBusy
    }

    private func renderIntegrations() {
        integrationsStack.arrangedSubviews.forEach {
            integrationsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.adapterID, $0) })
        for adapterID in orderedAdapterIDs {
            let summary = byID[adapterID]
            let definition = AgentIntegrationRegistry.definitions.first {
                $0.id.rawValue == adapterID
            }
            let checkbox = NSButton(
                checkboxWithTitle: "",
                target: self,
                action: #selector(toggleAdapter(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(adapterID)
            checkbox.state = selectedAdapterIDs.contains(adapterID) ? .on : .off
            checkbox.isEnabled = !isBusy && selectableAdapterIDs.contains(adapterID)
            checkbox.setAccessibilityLabel("Select \(definition?.displayName ?? adapterID)")
            let capability = summary?.capability.rawValue ?? capabilityText(definition?.capability)
            let status = summary?.status.rawValue ?? "loading"
            let label = NSTextField(
                labelWithString:
                    "\(definition?.displayName ?? adapterID) — \(capability) — \(status)"
            )
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityLabel(
                "\(definition?.displayName ?? adapterID), \(capability), \(status)"
            )
            let row = NSStackView(views: [checkbox, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            integrationsStack.addArrangedSubview(row)
        }
    }

    private func confirmationRequest(
        title: String,
        confirmTitle: String
    ) -> AgentIntegrationConfirmationRequest {
        AgentIntegrationConfirmationRequest(
            title: title,
            confirmTitle: confirmTitle,
            previewText: boundedText(
                visiblePreviewLines.joined(separator: "\n"),
                limit: Self.maximumCopiedCharacters
            )
        )
    }

    private func requestConfirmation(_ request: AgentIntegrationConfirmationRequest) async
        -> Bool
    {
        if let confirmationPresenter {
            return await confirmationPresenter(request)
        }
        guard let parentWindow = view.window else { return false }

        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = request.title
            alert.informativeText = request.previewText
            alert.addButton(withTitle: request.confirmTitle)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy Preview")
            let response = await alert.beginSheetModal(for: parentWindow)
            switch response {
            case .alertFirstButtonReturn:
                return true
            case .alertThirdButtonReturn:
                copyPreview(request.previewText)
            default:
                return false
            }
        }
    }

    private var visiblePreviewLines: [String] {
        if let launcherPreparedSummary,
            let launcherPreparedAction,
            launcherPreparedAction == selectedAction
        {
            let verb = launcherPreparedAction == .install ? "Installation" : "Removal"
            let backup = launcherPreparedSummary.createsBackup ? ", backup" : ""
            return [
                "\(verb) — Command Line Tool: \(launcherPreparedSummary.displayPath), \(launcherPreparedSummary.kind)\(backup)"
            ]
        }

        let displayed: [AgentIntegrationAdapterSummary]
        let action: AgentIntegrationInstallerAction?
        if !applySummaries.isEmpty {
            displayed = applySummaries
            action = resultAction
        } else {
            displayed = preparedSummary?.adapters ?? []
            action = preparedAction
        }
        guard !displayed.isEmpty, let action else { return [] }
        let verb = action == .install ? "Installation" : "Removal"
        var lines: [String] = []
        for summary in displayed.prefix(orderedAdapterIDs.count) {
            lines.append("\(verb) — \(summary.adapterID): \(summary.status.rawValue)")
            for operation in summary.operations.prefix(Self.maximumRenderedOperations) {
                let backup = operation.createsBackup ? ", backup" : ""
                let mode = operation.mode.map { ", mode \($0.rawValue)" } ?? ""
                lines.append(
                    "  \(operation.operation.rawValue) \(operation.kind.rawValue) \(operation.displayPath)\(mode)\(backup)"
                )
            }
        }
        return lines
    }

    private func renderBindings() {
        guard isViewLoaded else { return }
        bindingsStack.arrangedSubviews.forEach {
            bindingsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if bindingSnapshots.isEmpty {
            let label = NSTextField(labelWithString: "No saved agent session bindings.")
            label.setAccessibilityLabel("No saved agent session bindings")
            bindingsStack.addArrangedSubview(label)
            return
        }
        let knownNames = Set(AgentIntegrationRegistry.definitions.map(\.displayName))
        for (index, snapshot) in bindingSnapshots.enumerated() {
            let agentName =
                knownNames.contains(snapshot.agentName) ? snapshot.agentName : "Unknown Agent"
            let label = NSTextField(
                labelWithString:
                    "Pane \(index + 1) — \(agentName) — \(snapshot.state.rawValue)"
            )
            label.setAccessibilityLabel(
                "Pane \(index + 1), \(agentName), \(snapshot.state.rawValue)"
            )
            let retry = NSButton(
                title: "Retry",
                target: self,
                action: #selector(retryBindingAction(_:))
            )
            retry.tag = index
            retry.isEnabled = !isBusy && snapshot.canRetry
            retry.setAccessibilityLabel("Retry agent session for pane \(index + 1)")
            let forget = NSButton(
                title: "Forget",
                target: self,
                action: #selector(forgetBindingAction(_:))
            )
            forget.tag = index
            forget.isEnabled = !isBusy && snapshot.canForget
            forget.setAccessibilityLabel("Forget agent session for pane \(index + 1)")
            let row = NSStackView(views: [label, retry, forget])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            bindingsStack.addArrangedSubview(row)
        }
    }

    private func capabilityText(_ capability: AgentIntegrationCapability?) -> String {
        switch capability {
        case .nativeLifecycle: "nativeLifecycle"
        case .wrapperLifecycle: "wrapperLifecycle"
        case .blocked: "blocked"
        case nil: "unknown"
        }
    }

    private func invalidatePreparedPlan(clearResults: Bool) {
        preparedSummary = nil
        preparedSelection = []
        preparedAction = nil
        if clearResults {
            applySummaries = []
            resultAction = nil
        }
    }

    @objc private func changeSelectedAction(_ sender: NSSegmentedControl) {
        setAction(sender.selectedSegment == 1 ? .uninstall : .install)
    }

    @objc private func toggleAdapter(_ sender: NSButton) {
        guard let adapterID = sender.identifier?.rawValue else { return }
        setSelected(adapterID, selected: sender.state == .on)
    }

    @objc private func changeSelectedIntegrations() {
        guard applyTask == nil else { return }
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await changeSelectedIntegrationsWithConfirmation()
            applyTask = nil
        }
    }

    @objc private func changeCommandLineTool() {
        guard applyTask == nil else { return }
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await changeCommandLineToolWithConfirmation()
            applyTask = nil
        }
    }

    @objc private func retryBindingAction(_ sender: NSButton) {
        let index = sender.tag
        guard bindingSnapshots.indices.contains(index) else { return }
        retry(snapshot: bindingSnapshots[index])
    }

    @objc private func forgetBindingAction(_ sender: NSButton) {
        let index = sender.tag
        guard bindingSnapshots.indices.contains(index) else { return }
        forget(snapshot: bindingSnapshots[index])
    }

    @objc private func closeSheet() {
        guard canDismiss else { return }
        cancelDismissibleTasks()
        onRequestClose?()
    }

    #if DEBUG
        var preparedSummaryForTesting: AgentIntegrationPreparedSummary? { preparedSummary }
        func waitForApplyTaskForTesting() async { await applyTask?.value }
        var launcherPreparedSummaryForTesting: CommandLineLauncherSummary? {
            launcherPreparedSummary
        }
        var launcherStatusForTesting: CommandLineLauncherStatus? { launcherStatus }
        var integrationButtonForTesting: NSButton { integrationButton }
        var launcherButtonForTesting: NSButton { launcherButton }
        var closeButtonForTesting: NSButton { closeButton }
        var actionSelectorForTesting: NSSegmentedControl { actionSelector }
        var messageForTesting: String { messageLabel.stringValue }
    #endif
}
