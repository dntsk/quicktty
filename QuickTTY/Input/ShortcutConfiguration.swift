enum ShortcutAssignment: Equatable, Hashable, Sendable {
    case chord(ShortcutChord)
    case disabled
}

struct ShortcutConflict: Equatable, Hashable, Sendable {
    let chord: ShortcutChord
    let previous: ShortcutAction
    let winner: ShortcutAction
}

struct ShortcutConfiguration: Equatable, Sendable {
    private(set) var chords: [ShortcutAction: ShortcutChord]
    private var owners: [ShortcutChord: ShortcutAction]

    static let defaults = ShortcutConfiguration()

    private init() {
        chords = [:]
        owners = [:]
        for action in ShortcutAction.allCases {
            guard let chord = action.defaultChord else { continue }
            _ = assign(chord, to: action)
        }
    }

    func chord(for action: ShortcutAction) -> ShortcutChord? {
        chords[action]
    }

    func owner(of chord: ShortcutChord) -> ShortcutAction? {
        owners[chord]
    }

    func resolvingGlobalPrecedence(_ globalChord: ShortcutChord?) -> ShortcutConfiguration {
        resolvingGlobalPrecedence(globalChord.map { [$0] } ?? [])
    }

    func resolvingGlobalPrecedence<Chords: Sequence>(
        _ globalChords: Chords
    ) -> ShortcutConfiguration where Chords.Element == ShortcutChord {
        var resolved = self
        for globalChord in globalChords {
            if let localOwner = resolved.owner(of: globalChord) {
                resolved.disable(localOwner)
            }
        }
        return resolved
    }

    @discardableResult
    mutating func apply(
        _ assignment: ShortcutAssignment,
        to action: ShortcutAction
    ) -> ShortcutConflict? {
        switch assignment {
        case .chord(let chord):
            assign(chord, to: action)
        case .disabled:
            disable(action)
        }
    }

    @discardableResult
    mutating func assign(
        _ chord: ShortcutChord,
        to action: ShortcutAction
    ) -> ShortcutConflict? {
        releaseChord(ownedBy: action)

        let conflict = owners[chord].flatMap { previous -> ShortcutConflict? in
            guard previous != action else { return nil }
            chords[previous] = nil
            return ShortcutConflict(chord: chord, previous: previous, winner: action)
        }
        chords[action] = chord
        owners[chord] = action
        return conflict
    }

    @discardableResult
    mutating func disable(_ action: ShortcutAction) -> ShortcutConflict? {
        releaseChord(ownedBy: action)
        return nil
    }

    private mutating func releaseChord(ownedBy action: ShortcutAction) {
        guard let oldChord = chords.removeValue(forKey: action) else { return }
        if owners[oldChord] == action {
            owners[oldChord] = nil
        }
    }
}
