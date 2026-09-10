import Foundation

enum GhosttyBridgeError: Error, Equatable, LocalizedError {
    case configurationCreationFailed
    case applicationCreationFailed
    case duplicatePaneID(PaneID)
    case invalidAutomationText
    case invalidConfiguration([String])
    case invalidRenderedTextEncoding(PaneID)
    case invalidRenderedTextLimit
    case renderedTextReadFailed(PaneID)
    case runtimeNotReady
    case surfaceCreationFailed(PaneID)
    case surfaceUnavailable(PaneID)

    var errorDescription: String? {
        switch self {
        case .configurationCreationFailed:
            "Ghostty configuration creation failed."
        case .applicationCreationFailed:
            "Ghostty application creation failed."
        case .duplicatePaneID(let paneID):
            "A Ghostty surface already exists for pane \(paneID.rawValue.uuidString)."
        case .invalidAutomationText:
            "Ghostty automation text must be non-empty UTF-8 within the supported size limit."
        case .invalidConfiguration(let diagnostics):
            diagnostics.joined(separator: "\n")
        case .invalidRenderedTextEncoding(let paneID):
            "Ghostty rendered text for pane \(paneID.rawValue.uuidString) is not valid UTF-8."
        case .invalidRenderedTextLimit:
            "Ghostty rendered text reads require a positive UTF-8 limit up to 64 KiB."
        case .renderedTextReadFailed(let paneID):
            "Ghostty rendered text read failed for pane \(paneID.rawValue.uuidString)."
        case .runtimeNotReady:
            "Ghostty runtime is not ready."
        case .surfaceCreationFailed(let paneID):
            "Ghostty surface creation failed for pane \(paneID.rawValue.uuidString)."
        case .surfaceUnavailable(let paneID):
            "Ghostty surface is unavailable for pane \(paneID.rawValue.uuidString)."
        }
    }
}
