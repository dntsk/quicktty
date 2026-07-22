enum PresentationMode: String, CaseIterable, Codable, Sendable {
    case normal
    case quake

    var toggled: PresentationMode {
        switch self {
        case .normal:
            .quake
        case .quake:
            .normal
        }
    }
}
