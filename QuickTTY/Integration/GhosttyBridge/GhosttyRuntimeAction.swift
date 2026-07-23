struct GhosttyOpenURL: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unknown
        case text
        case html
    }

    let kind: Kind
    let url: String
}

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
    case openURL(GhosttyOpenURL)
    case unknown(rawValue: UInt32)

    var isSupported: Bool {
        if case .unknown = self {
            return false
        }
        return true
    }
}
