import Foundation

struct HotKeyDescriptor: Codable, Equatable, Hashable, Sendable {
    enum Key: String, CaseIterable, Codable, Sendable {
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
    }

    enum Modifier: String, CaseIterable, Codable, Sendable {
        case command = "cmd"
        case option = "opt"
        case control = "ctrl"
        case shift
    }

    enum ParseError: Error, Equatable, Sendable {
        case empty
        case emptyComponent(position: Int)
        case missingKey
        case duplicateModifier(Modifier)
        case unsupportedModifier(String)
        case unsupportedKey(String)
        case multipleKeys(String, String)
    }

    var command: Bool
    var option: Bool
    var control: Bool
    var shift: Bool
    var key: Key

    init(
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        key: Key
    ) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.key = key
    }

    init(parsing source: String) throws {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !source.isEmpty else { throw ParseError.empty }

        let components = source.split(separator: "+", omittingEmptySubsequences: false).map(
            String.init)
        for (index, component) in components.enumerated() where component.isEmpty {
            throw ParseError.emptyComponent(position: index + 1)
        }
        let keyToken = components[components.count - 1]
        if Modifier(rawValue: keyToken) != nil {
            throw ParseError.missingKey
        }
        guard let key = Key(rawValue: keyToken) else {
            throw ParseError.unsupportedKey(keyToken)
        }

        var modifiers = Set<Modifier>()
        for token in components.dropLast() {
            guard let modifier = Modifier(rawValue: token) else {
                if Key(rawValue: token) != nil {
                    throw ParseError.multipleKeys(token, keyToken)
                }
                throw ParseError.unsupportedModifier(token)
            }
            guard modifiers.insert(modifier).inserted else {
                throw ParseError.duplicateModifier(modifier)
            }
        }
        self.init(
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift),
            key: key
        )
    }

    var stringValue: String {
        var components: [String] = []
        if command { components.append(Modifier.command.rawValue) }
        if option { components.append(Modifier.option.rawValue) }
        if control { components.append(Modifier.control.rawValue) }
        if shift { components.append(Modifier.shift.rawValue) }
        components.append(key.rawValue)
        return components.joined(separator: "+")
    }
}

extension HotKeyDescriptor.ParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty:
            "Hot key is empty."
        case .emptyComponent(let position):
            "Hot key component \(position) is empty."
        case .missingKey:
            "Hot key does not contain a key."
        case .duplicateModifier(let modifier):
            "Hot key repeats modifier '\(modifier.rawValue)'."
        case .unsupportedModifier(let modifier):
            "Unsupported hot key modifier '\(modifier)'."
        case .unsupportedKey(let key):
            "Unsupported hot key key '\(key)'."
        case .multipleKeys(let first, let second):
            "Hot key contains multiple keys: '\(first)' and '\(second)'."
        }
    }
}
