import Foundation
import GhosttyKit

@MainActor
final class GhosttyConfiguration {
    enum Source: Equatable {
        case builtInDefaults
        case file(URL)
    }

    let chromePalette: GhosttyChromePalette
    let splitAppearance: GhosttySplitAppearance
    let diagnostics: [String]
    let source: Source

    private var handle: ghostty_config_t?

    init(configURL: URL?) throws {
        source = configURL.map(Source.file) ?? .builtInDefaults

        guard let handle = ghostty_config_new() else {
            throw GhosttyBridgeError.configurationCreationFailed
        }

        if case .file(let configURL) = source {
            configURL.path.withCString { path in
                ghostty_config_load_file(handle, path)
            }
            ghostty_config_load_recursive_files(handle)
        }

        ghostty_config_finalize(handle)

        self.handle = handle
        chromePalette = Self.chromePalette(from: handle)
        splitAppearance = Self.splitAppearance(
            from: handle,
            background: chromePalette.background
        )
        diagnostics = Self.loadDiagnostics(from: handle)
    }

    isolated deinit {
        if let handle {
            ghostty_config_free(handle)
        }
    }

    func withHandle(_ body: (ghostty_config_t) -> Void) {
        guard let handle else {
            preconditionFailure("Ghostty configuration handle used after release")
        }
        body(handle)
    }

    func release() {
        guard let handle else { return }
        self.handle = nil
        ghostty_config_free(handle)
    }

    private static func chromePalette(from handle: ghostty_config_t) -> GhosttyChromePalette {
        GhosttyChromePalette(
            background: configuredColor(
                named: "background",
                from: handle,
                fallback: GhosttyChromePalette.fallback.background
            ),
            foreground: configuredColor(
                named: "foreground",
                from: handle,
                fallback: GhosttyChromePalette.fallback.foreground
            )
        )
    }

    private static func splitAppearance(
        from handle: ghostty_config_t,
        background: GhosttyRGB
    ) -> GhosttySplitAppearance {
        var surfaceOpacity = 0.7
        let opacityKey = "unfocused-split-opacity"
        _ = withUnsafeMutablePointer(to: &surfaceOpacity) { pointer in
            opacityKey.withCString { key in
                ghostty_config_get(
                    handle,
                    UnsafeMutableRawPointer(pointer),
                    key,
                    UInt(opacityKey.lengthOfBytes(using: .utf8))
                )
            }
        }

        return GhosttySplitAppearance(
            unfocusedFill: configuredColor(
                named: "unfocused-split-fill",
                from: handle
            ) ?? background,
            unfocusedOverlayOpacity: min(max(1 - surfaceOpacity, 0), 1)
        )
    }

    private static func configuredColor(
        named name: String,
        from handle: ghostty_config_t,
        fallback: GhosttyRGB
    ) -> GhosttyRGB {
        configuredColor(named: name, from: handle) ?? fallback
    }

    private static func configuredColor(
        named name: String,
        from handle: ghostty_config_t
    ) -> GhosttyRGB? {
        var color = ghostty_config_color_s()
        let wasRead = withUnsafeMutablePointer(to: &color) { pointer in
            name.withCString { key in
                ghostty_config_get(
                    handle,
                    UnsafeMutableRawPointer(pointer),
                    key,
                    UInt(name.lengthOfBytes(using: .utf8))
                )
            }
        }
        guard wasRead else { return nil }
        return GhosttyRGB(red: color.r, green: color.g, blue: color.b)
    }

    private static func loadDiagnostics(from handle: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(handle)
        return (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(handle, index)
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }
}
