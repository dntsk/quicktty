import Foundation

enum AgentMessagingCommand {
    static func run() -> Int32 {
        let request: AgentMessagingRequest
        do {
            var data = Data()
            while data.count <= AgentMessagingProtocol.maximumRequestBytes {
                guard
                    let chunk = try FileHandle.standardInput.read(
                        upToCount: min(
                            4_096, AgentMessagingProtocol.maximumRequestBytes + 1 - data.count)),
                    !chunk.isEmpty
                else { break }
                data.append(chunk)
            }
            request = try AgentMessagingProtocol.decodeRequest(data, canonical: false)
        } catch { return write(.failure("invalidRequest"), exitCode: 2) }
        guard let identity = TerminalControlEnvironment.read(socketKey: "QUICKTTY_MESSAGE_SOCKET")
        else {
            return write(.failure("unavailable", requestID: request.requestID), exitCode: 1)
        }
        do {
            let response = try AgentMessagingSocketClient(identity: identity).send(request)
            return write(response, exitCode: response.state == "error" ? 1 : 0)
        } catch {
            // A transport failure does not prove that a question or notification was not submitted.
            return write(.failure("deliveryUncertain", requestID: request.requestID), exitCode: 1)
        }
    }

    private static func write(_ response: AgentMessagingResponse, exitCode: Int32) -> Int32 {
        guard var data = try? AgentMessagingProtocol.encode(response) else { return 1 }
        data.append(10)
        FileHandle.standardOutput.write(data)
        return exitCode
    }
}
