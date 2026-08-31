struct AgentResumePresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case restoring
        case unverified
        case failed(AgentResumeDiagnosticCode?)
    }

    static let maximumCopyBytes = 256

    let state: State
    let canRetry: Bool

    static let restoring = AgentResumePresentation(
        state: .restoring,
        canRetry: false
    )

    static let unverified = AgentResumePresentation(
        state: .unverified,
        canRetry: true
    )

    static let restoreDisabled = AgentResumePresentation(
        state: .failed(nil),
        canRetry: false
    )

    static func failed(
        diagnosticCode: AgentResumeDiagnosticCode
    ) -> AgentResumePresentation {
        let canRetry =
            switch diagnosticCode {
            case .unsupportedVersion, .duplicateBinding, .missingExecutable,
                .surfaceCreation, .immediateExit, .interruptedRestore:
                true
            case .missingAdapter, .invalidSessionID, .invalidMetadata:
                false
            }
        return AgentResumePresentation(
            state: .failed(diagnosticCode),
            canRetry: canRetry
        )
    }

    var title: String {
        switch state {
        case .restoring:
            "Restoring agent session"
        case .unverified:
            "Agent session unverified"
        case .failed:
            "Agent session not restored"
        }
    }

    var message: String {
        switch state {
        case .restoring:
            "Waiting for the resumed agent to confirm this pane."
        case .unverified:
            "The agent did not confirm the resumed session. Retry or forget the saved session."
        case .failed(nil):
            "Automatic agent restore is disabled. A fresh shell was opened."
        case .failed(.missingAdapter):
            "This agent cannot currently be resumed. A fresh shell was opened."
        case .failed(.unsupportedVersion):
            "The installed agent version cannot be verified for resume. A fresh shell was opened."
        case .failed(.invalidSessionID), .failed(.invalidMetadata):
            "The saved agent session data is invalid. A fresh shell was opened."
        case .failed(.duplicateBinding):
            "Multiple panes claim the same agent session. Forget one binding before retrying."
        case .failed(.missingExecutable):
            "A verified agent executable was not found. A fresh shell was opened."
        case .failed(.surfaceCreation):
            "The resume terminal could not be created. Retry or forget the saved session."
        case .failed(.immediateExit):
            "The resumed agent exited before confirmation. Retry or forget the saved session."
        case .failed(.interruptedRestore):
            "The previous restore attempt was interrupted. Retry or forget the saved session."
        }
    }

    var accessibilityLabel: String {
        "Agent session status"
    }

    var accessibilityValue: String {
        "\(title). \(message)"
    }
}
