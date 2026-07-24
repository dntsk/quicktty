struct GhosttyProgressReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case remove
        case set
        case error
        case indeterminate
        case pause
    }

    let state: State
    let progress: UInt8?
}

struct GhosttyCommandFinished: Equatable, Sendable {
    let exitCode: UInt8?
    let durationNanoseconds: UInt64
}
