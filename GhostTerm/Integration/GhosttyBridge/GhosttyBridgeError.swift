import Foundation

enum GhosttyBridgeError: Error, Equatable, LocalizedError {
    case configurationCreationFailed
    case applicationCreationFailed
    case duplicatePaneID(PaneID)
    case invalidConfiguration([String])
    case runtimeNotReady
    case surfaceCreationFailed(PaneID)

    var errorDescription: String? {
        switch self {
        case .configurationCreationFailed:
            "Ghostty configuration creation failed."
        case .applicationCreationFailed:
            "Ghostty application creation failed."
        case .duplicatePaneID(let paneID):
            "A Ghostty surface already exists for pane \(paneID.rawValue.uuidString)."
        case .invalidConfiguration(let diagnostics):
            diagnostics.joined(separator: "\n")
        case .runtimeNotReady:
            "Ghostty runtime is not ready."
        case .surfaceCreationFailed(let paneID):
            "Ghostty surface creation failed for pane \(paneID.rawValue.uuidString)."
        }
    }
}
