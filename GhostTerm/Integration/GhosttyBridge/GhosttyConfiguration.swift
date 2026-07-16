import Foundation
import GhosttyKit

@MainActor
final class GhosttyConfiguration {
    enum Source: Equatable {
        case builtInDefaults
        case file(URL)
    }

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

    private static func loadDiagnostics(from handle: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(handle)
        return (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(handle, index)
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }
}
