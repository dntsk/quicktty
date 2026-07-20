import Foundation

struct ConfigDiagnosticPresentation: Equatable, Sendable {
    let path: String
    let messages: [String]
}
