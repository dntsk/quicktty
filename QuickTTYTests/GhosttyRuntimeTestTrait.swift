import Testing

private actor GhosttyRuntimeTestGate {
    static let shared = GhosttyRuntimeTestGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

struct GhosttyRuntimeTestTrait: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await GhosttyRuntimeTestGate.shared.acquire()
        do {
            try await function()
        } catch {
            await GhosttyRuntimeTestGate.shared.release()
            throw error
        }
        await GhosttyRuntimeTestGate.shared.release()
    }
}

extension SuiteTrait where Self == GhosttyRuntimeTestTrait {
    static var ghosttyRuntime: Self { Self() }
}
