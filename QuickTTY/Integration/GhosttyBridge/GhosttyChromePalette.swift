import Foundation

struct GhosttyRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    func blended(with color: GhosttyRGB, fraction: Double) -> GhosttyRGB {
        let fraction = min(max(fraction, 0), 1)
        return GhosttyRGB(
            red: blendedComponent(red, color.red, fraction: fraction),
            green: blendedComponent(green, color.green, fraction: fraction),
            blue: blendedComponent(blue, color.blue, fraction: fraction)
        )
    }

    private func blendedComponent(_ base: UInt8, _ overlay: UInt8, fraction: Double) -> UInt8 {
        UInt8((Double(base) + (Double(overlay) - Double(base)) * fraction).rounded())
    }
}

struct GhosttyChromePalette: Equatable, Sendable {
    static let fallback = GhosttyChromePalette(
        background: GhosttyRGB(red: 0, green: 0, blue: 0),
        foreground: GhosttyRGB(red: 255, green: 255, blue: 255)
    )

    let background: GhosttyRGB
    let foreground: GhosttyRGB

    var usesDarkAppearance: Bool {
        background.relativeLuminance < 0.5
    }
}

extension GhosttyRGB {
    fileprivate var relativeLuminance: Double {
        0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    fileprivate func linearized(_ component: UInt8) -> Double {
        let value = Double(component) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
