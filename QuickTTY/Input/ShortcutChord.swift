enum ShortcutModifier: String, CaseIterable, Equatable, Hashable, Sendable {
    case command = "cmd"
    case option = "opt"
    case control = "ctrl"
    case shift
}

enum ShortcutKey: String, CaseIterable, Equatable, Hashable, Sendable {
    case a
    case b
    case c
    case d
    case e
    case f
    case g
    case h
    case i
    case j
    case k
    case l
    case m
    case n
    case o
    case p
    case q
    case r
    case s
    case t
    case u
    case v
    case w
    case x
    case y
    case z
    case zero = "0"
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case five = "5"
    case six = "6"
    case seven = "7"
    case eight = "8"
    case nine = "9"
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp = "page-up"
    case pageDown = "page-down"
    case tab
    case enter
    case escape
    case space
    case delete
    case forwardDelete = "forward-delete"
    case grave
    case minus
    case equal
    case leftBracket = "left-bracket"
    case rightBracket = "right-bracket"
    case backslash
    case semicolon
    case quote
    case comma
    case period
    case slash
}

struct ShortcutChord: Equatable, Hashable, Sendable {
    enum ParseError: Error, Equatable, Sendable {
        case empty
        case emptyComponent(position: Int)
        case missingKey
        case duplicateModifier(ShortcutModifier)
        case unsupportedModifier(String)
        case unsupportedKey(String)
        case multipleKeys(String, String)
    }

    let key: ShortcutKey
    let modifiers: Set<ShortcutModifier>

    init(key: ShortcutKey, modifiers: Set<ShortcutModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    init(parsing source: String) throws {
        guard !source.isEmpty else { throw ParseError.empty }

        let components = source.split(separator: "+", omittingEmptySubsequences: false).map(
            String.init)
        for (index, component) in components.enumerated() where component.isEmpty {
            throw ParseError.emptyComponent(position: index + 1)
        }

        let keyToken = components[components.count - 1]
        if ShortcutModifier(rawValue: keyToken) != nil {
            throw ParseError.missingKey
        }
        guard let key = ShortcutKey(rawValue: keyToken) else {
            throw ParseError.unsupportedKey(keyToken)
        }

        var modifiers = Set<ShortcutModifier>()
        for token in components.dropLast() {
            if ShortcutKey(rawValue: token) != nil {
                throw ParseError.multipleKeys(token, keyToken)
            }
            guard let modifier = ShortcutModifier(rawValue: token) else {
                throw ParseError.unsupportedModifier(token)
            }
            guard modifiers.insert(modifier).inserted else {
                throw ParseError.duplicateModifier(modifier)
            }
        }

        self.init(key: key, modifiers: modifiers)
    }

    var stringValue: String {
        let canonicalOrder: [ShortcutModifier] = [.command, .option, .control, .shift]
        return (canonicalOrder.filter(modifiers.contains).map(\.rawValue) + [key.rawValue])
            .joined(separator: "+")
    }
}
