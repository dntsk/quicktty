import Darwin
import Dispatch
import Foundation
import Synchronization

enum ClaudeQuestionCommand {
    static func run(input: Data, requireVerifiedRuntime: Bool = false) -> Int32 {
        guard let hook = try? ClaudeQuestionHook(input: input),
            let identity = TerminalControlEnvironment.read(socketKey: "QUICKTTY_MESSAGE_SOCKET")
        else { return write(Data("{}".utf8)) }
        if requireVerifiedRuntime, !ClaudeQuestionRuntime.isVerified() {
            return write(Data("{}".utf8))
        }
        let cancelled = Mutex(false)
        let parent = getppid()
        let sources = [SIGTERM, SIGINT].map { number in
            let previous = Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancelled.withLock { $0 = true } }
            source.resume()
            return (source, number, previous)
        }
        defer {
            for (source, number, previous) in sources {
                source.cancel()
                _ = Darwin.signal(number, previous)
            }
        }
        let resolver = ClaudeQuestionResolver(
            send: { try AgentMessagingSocketClient(identity: identity).send($0) },
            isCancelled: { getppid() != parent || cancelled.withLock { $0 } })
        do {
            return write(try resolver.resolve(hook))
        } catch ClaudeQuestionResolver.Failure.unavailable {
            return write(Data("{}".utf8))
        } catch {
            return write(
                Data(
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"QuickTTY question closed without a complete answer. No action was approved. Do not retry automatically; ask the user locally.\"}}"
                        .utf8))
        }
    }

    private static func write(_ data: Data) -> Int32 {
        FileHandle.standardOutput.write(data + Data([10]))
        return EXIT_SUCCESS
    }
}
