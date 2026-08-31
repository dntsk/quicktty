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

    private func integrationStatuses() -> [AgentIntegrationAdapterSummary] {
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
                status: blockedIDs.contains(adapterID) ? .blocked : .available,
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

private actor IntegrationInstallerRecorder {
    let statuses: [AgentIntegrationAdapterSummary]
    private(set) var appliedPlanIDs: [String] = []

    init(statuses: [AgentIntegrationAdapterSummary]) {
        self.statuses = statuses
    }

    nonisolated var client: AgentIntegrationInstallerClient {
        AgentIntegrationInstallerClient(
            adapterIDs: AgentIntegrationInstaller.adapterIDs,
            status: { [statuses] in statuses },
            prepare: { selected in
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
            },
            apply: { [self] planID in
                await recordApply(planID)
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
        )
    }

    private func recordApply(_ planID: String) {
        appliedPlanIDs.append(planID)
    }
}

private actor LauncherInstallerRecorder {
    private(set) var appliedPlanIDs: [String] = []

    nonisolated var client: CommandLineLauncherInstallerClient {
        CommandLineLauncherInstallerClient(
            prepare: {
                CommandLineLauncherSummary(
                    planID: "launcher-plan",
                    displayPath: "~/.local/bin/quicktty",
                    kind: "symlinkCreate",
                    createsBackup: false,
                    status: .available
                )
            },
            apply: { [self] planID in
                await recordApply(planID)
                return .succeeded
            }
        )
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
