import CoreGraphics
import Foundation

struct GhostTermConfig: Equatable, Sendable {
    enum Key: String, CaseIterable, Sendable {
        case presentationMode = "ghostterm-presentation-mode"
        case globalToggle = "ghostterm-global-toggle"
        case quakeHeight = "ghostterm-quake-height"
        case quakeAnimationDuration = "ghostterm-quake-animation-duration"
        case quakePadding = "ghostterm-quake-padding"
        case hideOnFocusLoss = "ghostterm-hide-on-focus-loss"
        case restoreWorkspaces = "ghostterm-restore-workspaces"
        case configEditor = "ghostterm-config-editor"
    }

    var presentationMode: PresentationMode = .normal
    var globalToggle = HotKeyDescriptor(key: .f12)
    var quakeHeight: Double = 0.75
    var quakeAnimationDuration: TimeInterval = 0.18
    var quakePadding: CGFloat = 0
    var hideOnFocusLoss = true
    var restoreWorkspaces = true
    var configEditor = "nano"
}
