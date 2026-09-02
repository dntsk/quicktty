import AppKit
import Testing

@testable import QuickTTY

@MainActor
struct AgentIntegrationsViewControllerTests {
    @Test
    func registryParitySelectionPreviewConfirmationApplyAndLauncherRouting() async throws {
        let ids = AgentIntegrationInstaller.adapterIDs
        let nativeIDs: Set<String> = [
            "claude", "codex", "pi", "omp", "cursor", "gemini", "hermes", "copilot", "droid",
            "qoder", "kimi",
        ]
        let wrapperIDs: Set<String> = ["amp", "antigravity", "opencode"]
        #expect(ids.count == 20)
        #expect(Set(ids) == nativeIDs.union(wrapperIDs).union(blockedIDs))
        let statuses = ids.map { id in
            let capability: AgentIntegrationInstallerCapability =
                if nativeIDs.contains(id) {
                    .nativeLifecycle
                } else if wrapperIDs.contains(id) {
                    .wrapperLifecycle
                } else {
                    .blocked
                }
            return AgentIntegrationAdapterSummary(
                adapterID: id,
                capability: capability,
                status: blockedIDs.contains(id) ? .blocked : .available,
                operations: []
            )
        }
        let recorder = IntegrationInstallerRecorder(statuses: statuses)
        let launcherRecorder = LauncherInstallerRecorder()
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: launcherRecorder
        )
        viewController.loadView()

        await viewController.reloadStatus()

        #expect(viewController.orderedAdapterIDs == ids)
        #expect(viewController.summaries.map(\.adapterID) == ids)
        viewController.setSelected("claude", selected: true)
        viewController.setSelected("grok", selected: true)
        #expect(viewController.selectedAdapterIDs == ["claude"])

        await viewController.prepareSelection()
        let prepared = try #require(viewController.preparedSummaryForTesting)
        #expect(prepared.adapters.first?.operations.first?.displayPath == "~/.claude/settings.json")
        #expect(prepared.adapters.first?.operations.first?.kind == .jsonHook)
        #expect(prepared.adapters.first?.operations.first?.createsBackup == true)

        await viewController.confirmApply()
        #expect(!viewController.isApplying)
        #expect(viewController.selectedAdapterIDs.isEmpty)
        #expect(await recorder.appliedPlanIDs == ["prepared-plan"])

        await viewController.prepareCommandLineTool()
        #expect(
            viewController.launcherPreparedSummaryForTesting?.displayPath == "~/.local/bin/quicktty"
        )
        await viewController.confirmCommandLineToolInstallation()
        #expect(await launcherRecorder.appliedPlanIDs == ["launcher-plan"])
    }

    @Test
    func primaryButtonsPrepareConfirmAndApplyWithoutSelfCancellation() async throws {
        let recorder = IntegrationInstallerRecorder(statuses: integrationStatuses())
        let launcherRecorder = LauncherInstallerRecorder()
        let confirmations = ConfirmationRecorder(result: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: launcherRecorder,
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        await viewController.reloadStatus()
        viewController.setSelected("claude", selected: true)

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(await recorder.appliedPlanIDs == ["prepared-plan"])
        #expect(confirmations.requests.first?.title == "Install selected integrations?")
        #expect(confirmations.requests.first?.confirmTitle == "Install")
        #expect(
            confirmations.requests.first?.previewText.contains("~/.claude/settings.json") == true)

        viewController.launcherButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(await launcherRecorder.appliedPlanIDs == ["launcher-plan"])
        #expect(confirmations.requests.last?.title == "Install command-line tool?")
        #expect(confirmations.requests.count == 2)
    }

    @Test
    func updateOfferRefreshSelectsOnlyUpdatesInRegistryOrder() async {
        let statuses = integrationStatuses(overrides: [
            "claude": .updateAvailable,
            "codex": .conflict,
            "amp": .available,
            "pi": .updateAvailable,
        ])
        let viewController = makeViewController(
            recorder: IntegrationInstallerRecorder(statuses: statuses),
            launcherRecorder: LauncherInstallerRecorder()
        )
        viewController.loadView()

        let shouldOffer = await viewController.prepareUpdateOffer()

        #expect(shouldOffer)
        #expect(
            viewController.orderedAdapterIDs.filter(viewController.selectedAdapterIDs.contains)
                == ["claude", "pi"]
        )
        #expect(viewController.integrationButtonForTesting.title == "Update Selected")
    }

    @Test
    func launcherStatusFailureDoesNotSuppressUpdateOfferButManualReloadStillChecksLauncher() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable])
        )
        let launcherRecorder = LauncherInstallerRecorder(failsStatus: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: launcherRecorder
        )
        viewController.loadView()

        #expect(await viewController.prepareUpdateOffer())
        #expect(await launcherRecorder.statusRequestCount == 0)
        #expect(viewController.selectedAdapterIDs == Set(["claude"]))

        await viewController.reloadStatus()

        #expect(await launcherRecorder.statusRequestCount == 1)
    }

    @Test
    func updateOfferWithoutUpdatesReturnsFalseAndClearsSelection() async {
        let viewController = makeViewController(
            recorder: IntegrationInstallerRecorder(statuses: integrationStatuses()),
            launcherRecorder: LauncherInstallerRecorder()
        )
        viewController.loadView()
        viewController.setSelected("claude", selected: true)

        let shouldOffer = await viewController.prepareUpdateOffer()

        #expect(!shouldOffer)
        #expect(viewController.selectedAdapterIDs.isEmpty)
    }

    @Test
    func updateOnlySelectionUsesUpdateCopyAndAppliesOnlyAfterConfirmation() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmations = ConfirmationRecorder(result: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())
        #expect(await recorder.appliedPlanIDs.isEmpty)

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(confirmations.requests.first?.title == "Update selected integrations?")
        #expect(confirmations.requests.first?.confirmTitle == "Update")
        #expect(confirmations.requests.first?.previewText.contains("Update — claude") == true)
        #expect(await recorder.appliedPlanIDs == ["prepared-plan"])
        #expect(viewController.messageForTesting == "Integration update finished.")
    }

    @Test
    func updateProgressUsesExactCopyWhileApplyIsPending() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable]),
            gateApply: true
        )
        let confirmations = ConfirmationRecorder(result: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())

        viewController.integrationButtonForTesting.performClick(nil)
        await recorder.waitUntilApplyStarts()

        #expect(viewController.messageForTesting == "Updating integrations…")
        await recorder.resumeApply()
        await viewController.waitForApplyTaskForTesting()
        #expect(viewController.messageForTesting == "Integration update finished.")
    }

    @Test
    func updateApplyFailureUsesExactRollbackCopy() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable]),
            failure: .apply
        )
        let confirmations = ConfirmationRecorder(result: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(
            viewController.messageForTesting
                == "Update failed and was rolled back where required."
        )
    }

    @Test
    func updatePostApplyStatusFailureUsesExactUnavailableCopy() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable]),
            failure: .postApplyStatus
        )
        let confirmations = ConfirmationRecorder(result: true)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(
            viewController.messageForTesting
                == "Update applied, but integration status is unavailable."
        )
    }

    @Test
    func rejectedUpdateConfirmationDoesNotApply() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmations = ConfirmationRecorder(result: false)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        #expect(await viewController.prepareUpdateOffer())

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(await recorder.appliedPlanIDs.isEmpty)
        #expect(viewController.messageForTesting == "Update cancelled.")
    }

    @Test
    func mixedAvailableAndUpdateSelectionKeepsInstallCopy() async {
        let recorder = IntegrationInstallerRecorder(
            statuses: integrationStatuses(overrides: ["claude": .updateAvailable])
        )
        let confirmations = ConfirmationRecorder(result: false)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        await viewController.reloadStatus()
        viewController.setSelected("claude", selected: true)
        viewController.setSelected("codex", selected: true)

        #expect(viewController.integrationButtonForTesting.title == "Install Selected")
        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(confirmations.requests.first?.title == "Install selected integrations?")
        #expect(confirmations.requests.first?.confirmTitle == "Install")
        #expect(viewController.messageForTesting == "Installation cancelled.")
    }

    @Test
    func staleGenerationAndCancellationCannotPrepareUpdateOffer() async {
        let statuses = integrationStatuses(overrides: ["claude": .updateAvailable])
        let staleInstaller = AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { _ in
                AgentIntegrationGeneratedResponse(generation: UUID(), value: statuses)
            },
            prepare: { generation, _, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: AgentIntegrationPreparedSummary(planID: "unused", adapters: [])
                )
            },
            apply: { generation, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: AgentIntegrationApplySummary(adapters: [])
                )
            }
        )
        let staleViewController = AgentIntegrationsViewController(
            installer: staleInstaller,
            launcherInstaller: LauncherInstallerRecorder().client,
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
        staleViewController.loadView()

        #expect(await staleViewController.prepareUpdateOffer() == false)
        #expect(staleViewController.selectedAdapterIDs.isEmpty)

        let cancelledViewController = makeViewController(
            recorder: IntegrationInstallerRecorder(statuses: statuses),
            launcherRecorder: LauncherInstallerRecorder()
        )
        cancelledViewController.loadView()
        let task = Task { @MainActor in
            await cancelledViewController.prepareUpdateOffer()
        }
        task.cancel()

        #expect(await task.value == false)
        #expect(cancelledViewController.selectedAdapterIDs.isEmpty)
    }

    @Test
    func cancellingConfirmationInvalidatesPreviewWithoutApplying() async throws {
        let recorder = IntegrationInstallerRecorder(statuses: integrationStatuses())
        let confirmations = ConfirmationRecorder(result: false)
        let viewController = makeViewController(
            recorder: recorder,
            launcherRecorder: LauncherInstallerRecorder(),
            confirmationPresenter: { request in confirmations.present(request) }
        )
        viewController.loadView()
        await viewController.reloadStatus()
        viewController.setSelected("claude", selected: true)

        viewController.integrationButtonForTesting.performClick(nil)
        await viewController.waitForApplyTaskForTesting()

        #expect(await recorder.appliedPlanIDs.isEmpty)
        #expect(viewController.preparedSummaryForTesting == nil)
        #expect(viewController.messageForTesting == "Installation cancelled.")
        #expect(confirmations.requests.count == 1)
    }

    @Test
    func cancelledIntegrationApplyFinalizesAndInvalidatesPreparedPlan() async throws {
        let statuses = integrationStatuses()
        let installer = AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { generation in
                AgentIntegrationGeneratedResponse(generation: generation, value: statuses)
            },
            prepare: { generation, _, selected in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: AgentIntegrationPreparedSummary(
                        planID: "cancelled-plan",
                        adapters: statuses.filter { selected.contains($0.adapterID) }
                    )
                )
            },
            apply: { _, _ in throw CancellationError() }
        )
        let viewController = AgentIntegrationsViewController(
            installer: installer,
            launcherInstaller: LauncherInstallerRecorder().client,
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
        viewController.loadView()
        await viewController.reloadStatus()
        viewController.setSelected("claude", selected: true)
        await viewController.prepareSelection()

        await viewController.confirmApply()

        #expect(!viewController.isApplying)
        #expect(viewController.closeButtonForTesting.isEnabled)
        #expect(viewController.preparedSummaryForTesting == nil)
        #expect(viewController.applySummaries.isEmpty)
        #expect(
            viewController.messageForTesting
                == "Integration changes were cancelled or became unavailable."
        )
    }

    @Test
    func mismatchedLauncherApplyGenerationFinalizesAndInvalidatesPreparedPlan() async {
        let integrationRecorder = IntegrationInstallerRecorder(statuses: integrationStatuses())
        let launcher = CommandLineLauncherInstallerClient(
            status: { generation in
                AgentIntegrationGeneratedResponse(generation: generation, value: .available)
            },
            prepare: { generation, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: CommandLineLauncherSummary(
                        planID: "stale-launcher-plan",
                        displayPath: "~/.local/bin/quicktty",
                        kind: "symlinkCreate",
                        createsBackup: false,
                        status: .available
                    )
                )
            },
            apply: { _, _ in
                AgentIntegrationGeneratedResponse(generation: UUID(), value: .succeeded)
            }
        )
        let viewController = AgentIntegrationsViewController(
            installer: integrationRecorder.client,
            launcherInstaller: launcher,
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in }
        )
        viewController.loadView()
        await viewController.reloadStatus()
        await viewController.prepareCommandLineTool()

        await viewController.confirmCommandLineToolChange()

        #expect(!viewController.isApplying)
        #expect(viewController.closeButtonForTesting.isEnabled)
        #expect(viewController.launcherPreparedSummaryForTesting == nil)
        #expect(viewController.launcherStatusForTesting == .available)
        #expect(viewController.applySummaries.isEmpty)
        #expect(
            viewController.messageForTesting
                == "Command line tool change was cancelled or became unavailable."
        )
    }

    @Test
    func bindingSnapshotsExposeOnlyTypedRedactedStateAndRouteEligibleActions() async throws {
        let paneID = PaneID()
        let retryRecorder = PaneActionRecorder()
        let forgetRecorder = PaneActionRecorder()
        let snapshot = AgentIntegrationBindingSnapshot(
            paneID: paneID,
            agentName: "Claude Code",
            state: .unverified,
            canRetry: true,
            canForget: true
        )
        let installerRecorder = IntegrationInstallerRecorder(statuses: [])
        let launcherRecorder = LauncherInstallerRecorder()
        let viewController = AgentIntegrationsViewController(
            installer: installerRecorder.client,
            launcherInstaller: launcherRecorder.client,
            bindingProvider: { [snapshot] },
            retryBinding: { retryRecorder.record($0) },
            forgetBinding: { forgetRecorder.record($0) }
        )
        viewController.loadView()
        await viewController.reloadStatus()

        #expect(viewController.bindingSnapshots == [snapshot])
        viewController.retry(snapshot: snapshot)
        viewController.forget(snapshot: snapshot)
        #expect(retryRecorder.paneIDs == [paneID])
        #expect(forgetRecorder.paneIDs == [paneID])

        let rendered = viewController.view.accessibilityLabel() ?? ""
        #expect(!rendered.contains("session"))
        #expect(!rendered.contains("/Users/"))
        #expect(!rendered.contains("token"))
    }

    private var blockedIDs: Set<String> {
        ["grok", "campfire", "kiro", "rovo-dev", "codebuddy", "ollama"]
    }

    private func integrationStatuses(
        overrides: [String: AgentIntegrationInstallerStatus] = [:]
    ) -> [AgentIntegrationAdapterSummary] {
        let wrapperIDs: Set<String> = ["amp", "antigravity", "opencode"]
        return AgentIntegrationInstaller.adapterIDs.map { adapterID in
            let capability: AgentIntegrationInstallerCapability =
                if blockedIDs.contains(adapterID) {
                    .blocked
                } else if wrapperIDs.contains(adapterID) {
                    .wrapperLifecycle
                } else {
                    .nativeLifecycle
                }
            return AgentIntegrationAdapterSummary(
                adapterID: adapterID,
                capability: capability,
                status: blockedIDs.contains(adapterID)
                    ? .blocked : overrides[adapterID] ?? .available,
                operations: []
            )
        }
    }

    private func makeViewController(
        recorder: IntegrationInstallerRecorder,
        launcherRecorder: LauncherInstallerRecorder,
        confirmationPresenter: AgentIntegrationsViewController.ConfirmationPresenter? = nil
    ) -> AgentIntegrationsViewController {
        AgentIntegrationsViewController(
            installer: recorder.client,
            launcherInstaller: launcherRecorder.client,
            bindingProvider: { [] },
            retryBinding: { _ in },
            forgetBinding: { _ in },
            confirmationPresenter: confirmationPresenter
        )
    }
}

@MainActor
private final class ConfirmationRecorder {
    let result: Bool
    private(set) var requests: [AgentIntegrationConfirmationRequest] = []

    init(result: Bool) {
        self.result = result
    }

    func present(_ request: AgentIntegrationConfirmationRequest) -> Bool {
        requests.append(request)
        return result
    }
}

private enum IntegrationInstallerRecorderFailure: Error, Equatable, Sendable {
    case apply
    case postApplyStatus
}

private actor IntegrationInstallerRecorder {
    let statuses: [AgentIntegrationAdapterSummary]
    let failure: IntegrationInstallerRecorderFailure?
    let gateApply: Bool
    private let applyStarts: AsyncStream<Void>
    private let applyStartContinuation: AsyncStream<Void>.Continuation
    private var applyContinuation: CheckedContinuation<Void, Never>?
    private(set) var appliedPlanIDs: [String] = []

    init(
        statuses: [AgentIntegrationAdapterSummary],
        failure: IntegrationInstallerRecorderFailure? = nil,
        gateApply: Bool = false
    ) {
        self.statuses = statuses
        self.failure = failure
        self.gateApply = gateApply
        (applyStarts, applyStartContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    nonisolated var client: AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [self] in try await requestStatus() },
            prepare: { [self] selected in await prepare(selected) },
            apply: { [self] planID in try await apply(planID) }
        )
    }

    func waitUntilApplyStarts() async {
        for await _ in applyStarts {
            return
        }
    }

    func resumeApply() {
        applyContinuation?.resume()
        applyContinuation = nil
    }

    private func requestStatus() throws -> [AgentIntegrationAdapterSummary] {
        if failure == .postApplyStatus, !appliedPlanIDs.isEmpty {
            throw IntegrationInstallerRecorderFailure.postApplyStatus
        }
        return statuses
    }

    private func prepare(_ selected: [String]) -> AgentIntegrationPreparedSummary {
        AgentIntegrationPreparedSummary(
            planID: "prepared-plan",
            adapters: selected.map { id in
                AgentIntegrationAdapterSummary(
                    adapterID: id,
                    capability: .nativeLifecycle,
                    status: .available,
                    operations: [
                        AgentIntegrationOperationSummary(
                            displayPath: "~/.claude/settings.json",
                            kind: .jsonHook,
                            createsBackup: true
                        )
                    ]
                )
            }
        )
    }

    private func apply(_ planID: String) async throws -> AgentIntegrationApplySummary {
        applyStartContinuation.yield()
        if gateApply {
            await withCheckedContinuation { continuation in
                applyContinuation = continuation
            }
        }
        if failure == .apply {
            throw IntegrationInstallerRecorderFailure.apply
        }
        appliedPlanIDs.append(planID)
        return AgentIntegrationApplySummary(
            adapters: [
                AgentIntegrationAdapterSummary(
                    adapterID: "claude",
                    capability: .nativeLifecycle,
                    status: .succeeded,
                    operations: []
                )
            ]
        )
    }
}

private enum LauncherInstallerRecorderError: Error {
    case status
}

private actor LauncherInstallerRecorder {
    let failsStatus: Bool
    private(set) var statusRequestCount = 0
    private(set) var appliedPlanIDs: [String] = []

    init(failsStatus: Bool = false) {
        self.failsStatus = failsStatus
    }

    nonisolated var client: CommandLineLauncherInstallerClient {
        CommandLineLauncherInstallerClient(
            status: { [self] generation in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: try await requestStatus()
                )
            },
            prepare: { generation, _ in
                AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: CommandLineLauncherSummary(
                        planID: "launcher-plan",
                        displayPath: "~/.local/bin/quicktty",
                        kind: "symlinkCreate",
                        createsBackup: false,
                        status: .available
                    )
                )
            },
            apply: { [self] generation, planID in
                await recordApply(planID)
                return AgentIntegrationGeneratedResponse(
                    generation: generation,
                    value: .succeeded
                )
            }
        )
    }

    private func requestStatus() throws -> CommandLineLauncherStatus {
        statusRequestCount += 1
        if failsStatus {
            throw LauncherInstallerRecorderError.status
        }
        return .available
    }

    private func recordApply(_ planID: String) {
        appliedPlanIDs.append(planID)
    }
}

@MainActor
private final class PaneActionRecorder {
    private(set) var paneIDs: [PaneID] = []

    func record(_ paneID: PaneID) {
        paneIDs.append(paneID)
    }
}
