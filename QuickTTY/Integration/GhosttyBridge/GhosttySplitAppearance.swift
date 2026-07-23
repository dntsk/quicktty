import Foundation

struct GhosttySplitAppearance: Equatable, Sendable {
    static let fallback = GhosttySplitAppearance(
        unfocusedFill: GhosttyChromePalette.fallback.background,
        unfocusedOverlayOpacity: 0.3
    )

    let unfocusedFill: GhosttyRGB
    let unfocusedOverlayOpacity: Double
}
