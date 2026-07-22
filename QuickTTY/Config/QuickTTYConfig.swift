import CoreGraphics
import Foundation

struct QuickTTYConfig: Equatable, Sendable {
    enum Key: String, CaseIterable, Sendable {
        case presentationMode = "quicktty-presentation-mode"
        case globalToggle = "quicktty-global-toggle"
        case quakeHeight = "quicktty-quake-height"
        case quakeAnimationDuration = "quicktty-quake-animation-duration"
        case quakePadding = "quicktty-quake-padding"
        case hideOnFocusLoss = "quicktty-hide-on-focus-loss"
        case restoreWorkspaces = "quicktty-restore-workspaces"
        case configEditor = "quicktty-config-editor"
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
