import AppKit
import CoreServices
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
struct GhosttyWorkspaceURLClient: Sendable {
    enum Destination: Equatable, Sendable {
        case defaultApplication(URL)
        case application(URL, applicationURL: URL)
    }

    struct FailureDiagnostic: Equatable, Sendable {
        let errorDomain: String
        let errorCode: Int
    }

    typealias OpenHandler = @MainActor @Sendable (GhosttyOpenURL) -> Void

    nonisolated private static let logger = Logger(
        subsystem: "com.dntsk.QuickTTY",
        category: "WorkspaceURL"
    )

    private let openHandler: OpenHandler

    init(_ openHandler: @escaping OpenHandler) {
        self.openHandler = openHandler
    }

    func open(_ action: GhosttyOpenURL) {
        openHandler(action)
    }

    static let system = GhosttyWorkspaceURLClient { action in
        let workspace = NSWorkspace.shared
        let destination = destination(
            for: action,
            defaultApplicationForExtension: { pathExtension in
                guard let contentType = UTType(filenameExtension: pathExtension) else {
                    return nil
                }
                return defaultApplicationURL(forContentType: contentType.identifier)
            },
            defaultTextEditor: {
                defaultApplicationURL(forContentType: UTType.plainText.identifier)
            }
        )
        let configuration = NSWorkspace.OpenConfiguration()

        switch destination {
        case .defaultApplication(let url):
            workspace.open(url, configuration: configuration) { _, error in
                logFailure(error)
            }
        case .application(let url, let applicationURL):
            workspace.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                logFailure(error)
            }
        }
    }

    static func destination(
        for action: GhosttyOpenURL,
        defaultApplicationForExtension: @MainActor (String) -> URL?,
        defaultTextEditor: @MainActor () -> URL?
    ) -> Destination {
        let url: URL
        if let candidate = URL(string: action.url), candidate.scheme != nil {
            url = candidate
        } else {
            let standardizedPath = NSString(string: action.url).standardizingPath
            url = URL(filePath: standardizedPath)
        }

        if action.kind == .text,
            let editor =
                defaultApplicationForExtension(url.pathExtension)
                ?? defaultTextEditor()
        {
            return .application(url, applicationURL: editor)
        }

        return .defaultApplication(url)
    }

    private static func defaultApplicationURL(forContentType contentType: String) -> URL? {
        LSCopyDefaultApplicationURLForContentType(
            contentType as CFString,
            .all,
            nil
        )?.takeRetainedValue() as URL?
    }

    nonisolated static func failureDiagnostic(for error: Error?) -> FailureDiagnostic? {
        guard let error else { return nil }
        let nsError = error as NSError
        return FailureDiagnostic(errorDomain: nsError.domain, errorCode: nsError.code)
    }

    nonisolated private static func logFailure(_ error: Error?) {
        guard let diagnostic = failureDiagnostic(for: error) else { return }
        logger.error(
            "Failed to open URL (error domain: \(diagnostic.errorDomain, privacy: .public), code: \(diagnostic.errorCode, privacy: .public))"
        )
    }
}
