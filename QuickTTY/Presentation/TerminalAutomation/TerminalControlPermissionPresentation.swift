import Foundation

struct TerminalControlPermissionPresentation: Equatable {
    static let disclosure =
        "Агент и запускаемые им инструменты смогут создавать terminal panes, читать их содержимое и отправлять в них ввод до завершения этой agent-сессии."

    let adapterDisplayName: String

    init(adapterID: AgentAdapterID) {
        // WHY: Only registry metadata belongs in the sheet, never an agent-supplied session identifier.
        adapterDisplayName = String(
            (AgentIntegrationRegistry.definition(for: adapterID)?.displayName ?? "Unknown Agent")
                .prefix(128))
    }

    var title: String { "Разрешить \(adapterDisplayName) управлять терминалами?" }
}
