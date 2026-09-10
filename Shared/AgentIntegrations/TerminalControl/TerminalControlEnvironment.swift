import Darwin
import Foundation

struct TerminalControlEnvironment: Equatable, Sendable {
    let instanceID: UUID
    let paneID: UUID
    let paneToken: String
    let socketPath: String

    private init(instanceID: UUID, paneID: UUID, paneToken: String, socketPath: String) {
        self.instanceID = instanceID
        self.paneID = paneID
        self.paneToken = paneToken
        self.socketPath = socketPath
    }

    static func read(
        value: (String, Int) -> Data? = processValue
    ) -> TerminalControlEnvironment? {
        func string(_ key: String, maximumBytes: Int) -> String? {
            guard let bytes = value(key, maximumBytes), bytes.count <= maximumBytes else {
                return nil
            }
            // WHY: Replacement decoding could turn malformed credentials or endpoints into different values.
            return String(data: bytes, encoding: .utf8)
        }

        guard let instanceValue = string("QUICKTTY_INSTANCE_ID", maximumBytes: 36),
            let instanceID = TerminalCLIValueParser.uuid(instanceValue),
            let paneValue = string("QUICKTTY_PANE_ID", maximumBytes: 36),
            let paneID = TerminalCLIValueParser.uuid(paneValue),
            let paneToken = string("QUICKTTY_PANE_TOKEN", maximumBytes: 64),
            (try? AgentIPCValueValidator.validatePaneToken(paneToken)) != nil,
            let socketPath = string(
                "QUICKTTY_CONTROL_SOCKET",
                maximumBytes: MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
            ),
            socketPath != "/",
            AgentWorkingDirectoryValidator.isCanonicalAbsolutePath(socketPath),
            (try? AgentUnixSocketAddress(path: socketPath)) != nil
        else {
            return nil
        }
        return TerminalControlEnvironment(
            instanceID: instanceID, paneID: paneID, paneToken: paneToken, socketPath: socketPath
        )
    }

    private static func processValue(_ key: String, maximumBytes: Int) -> Data? {
        // WHY: Only these requested app-owned values are read, never an environment snapshot.
        guard let pointer = getenv(key) else { return nil }
        let count = strnlen(pointer, maximumBytes + 1)
        guard count <= maximumBytes else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
