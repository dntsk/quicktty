enum GhosttyRuntimeAction: Equatable, Sendable {
    case quit
    case newWindow
    case newTab
    case closeAllWindows
    case toggleVisibility
    case openConfig
    case reloadConfig(soft: Bool)
    case configChanged
    case showChildExited
    case unknown(rawValue: UInt32)

    var isSupported: Bool {
        if case .unknown = self {
            return false
        }
        return true
    }
}
