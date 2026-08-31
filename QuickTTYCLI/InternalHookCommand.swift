import Darwin
import Foundation

enum InternalHookCommand {
    static func run(adapterID: String, event: String) -> Int32 {
        guard let input = readStandardInput(),
            let identity = makeIdentity(adapterID: adapterID),
            let message = NativeLifecycleHookNormalizer.normalize(
                adapterID: adapterID,
                event: event,
                input: input,
                identity: identity
            ),
            let socketPath = boundedEnvironmentValue("QUICKTTY_AGENT_SOCKET", maximumBytes: 103),
            (try? AgentSocketClient.send(message, to: socketPath)) == true
        else {
            return EXIT_FAILURE
        }
        return EXIT_SUCCESS
    }

    private static func readStandardInput() -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while result.count <= NativeLifecycleHookNormalizer.maximumInputBytes {
            let remaining = NativeLifecycleHookNormalizer.maximumInputBytes - result.count + 1
            let count = Darwin.read(STDIN_FILENO, &buffer, min(buffer.count, remaining))
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { return result }
            if errno != EINTR { return nil }
        }
        return nil
    }

    private static func makeIdentity(adapterID: String) -> AgentIPCIdentity? {
        guard
            let instanceValue = boundedEnvironmentValue(
                "QUICKTTY_INSTANCE_ID", maximumBytes: 36),
            let instanceID = UUID(uuidString: instanceValue),
            let paneValue = boundedEnvironmentValue("QUICKTTY_PANE_ID", maximumBytes: 36),
            let paneID = UUID(uuidString: paneValue),
            let paneToken = boundedEnvironmentValue(
                "QUICKTTY_PANE_TOKEN", maximumBytes: 64)
        else { return nil }
        return try? AgentIPCIdentity(
            instanceID: instanceID,
            paneID: paneID,
            paneToken: paneToken,
            adapterID: adapterID
        )
    }

    private static func boundedEnvironmentValue(
        _ key: String,
        maximumBytes: Int
    ) -> String? {
        guard let pointer = getenv(key) else { return nil }
        let count = strnlen(pointer, maximumBytes + 1)
        guard count <= maximumBytes else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                count: count
            ),
            as: UTF8.self
        )
    }
}
