import AppKit

@MainActor
final class ShortcutController {
    private(set) var activeConfiguration: ShortcutConfiguration
    private var menuItems: [ShortcutAction: NSMenuItem] = [:]

    init(configuration: ShortcutConfiguration = .defaults) {
        activeConfiguration = configuration
    }

    func apply(_ configuration: ShortcutConfiguration) {
        activeConfiguration = configuration
        for (action, item) in menuItems {
            synchronize(item, for: action)
        }
    }

    @discardableResult
    func register(_ item: NSMenuItem, for action: ShortcutAction) -> NSMenuItem {
        if let registeredItem = menuItems[action] {
            synchronize(registeredItem, for: action)
            return registeredItem
        }

        menuItems[action] = item
        synchronize(item, for: action)
        return item
    }

    func menuItem(for action: ShortcutAction) -> NSMenuItem? {
        menuItems[action]
    }

    func action(matching event: NSEvent) -> ShortcutAction? {
        guard let chord = ShortcutEventMatcher.chord(matching: event) else { return nil }
        return activeConfiguration.owner(of: chord)
    }

    private func synchronize(_ item: NSMenuItem, for action: ShortcutAction) {
        // A menu equivalent always consumes the event, so performable actions stay responder-only.
        guard action.menuPolicy == .command,
            let chord = activeConfiguration.chord(for: action)
        else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = Self.keyEquivalent(for: chord.key)
        item.keyEquivalentModifierMask = Self.modifierMask(for: chord.modifiers)
    }

    static func modifierMask(
        for modifiers: Set<ShortcutModifier>
    ) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) {
            mask.insert(.command)
        }
        if modifiers.contains(.option) {
            mask.insert(.option)
        }
        if modifiers.contains(.control) {
            mask.insert(.control)
        }
        if modifiers.contains(.shift) {
            mask.insert(.shift)
        }
        return mask
    }

    static func keyEquivalent(for key: ShortcutKey) -> String {
        switch key {
        case .a: "a"
        case .b: "b"
        case .c: "c"
        case .d: "d"
        case .e: "e"
        case .f: "f"
        case .g: "g"
        case .h: "h"
        case .i: "i"
        case .j: "j"
        case .k: "k"
        case .l: "l"
        case .m: "m"
        case .n: "n"
        case .o: "o"
        case .p: "p"
        case .q: "q"
        case .r: "r"
        case .s: "s"
        case .t: "t"
        case .u: "u"
        case .v: "v"
        case .w: "w"
        case .x: "x"
        case .y: "y"
        case .z: "z"
        case .zero: "0"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        case .f1: functionKey(NSF1FunctionKey)
        case .f2: functionKey(NSF2FunctionKey)
        case .f3: functionKey(NSF3FunctionKey)
        case .f4: functionKey(NSF4FunctionKey)
        case .f5: functionKey(NSF5FunctionKey)
        case .f6: functionKey(NSF6FunctionKey)
        case .f7: functionKey(NSF7FunctionKey)
        case .f8: functionKey(NSF8FunctionKey)
        case .f9: functionKey(NSF9FunctionKey)
        case .f10: functionKey(NSF10FunctionKey)
        case .f11: functionKey(NSF11FunctionKey)
        case .f12: functionKey(NSF12FunctionKey)
        case .f13: functionKey(NSF13FunctionKey)
        case .f14: functionKey(NSF14FunctionKey)
        case .f15: functionKey(NSF15FunctionKey)
        case .f16: functionKey(NSF16FunctionKey)
        case .f17: functionKey(NSF17FunctionKey)
        case .f18: functionKey(NSF18FunctionKey)
        case .f19: functionKey(NSF19FunctionKey)
        case .f20: functionKey(NSF20FunctionKey)
        case .left: functionKey(NSLeftArrowFunctionKey)
        case .right: functionKey(NSRightArrowFunctionKey)
        case .up: functionKey(NSUpArrowFunctionKey)
        case .down: functionKey(NSDownArrowFunctionKey)
        case .home: functionKey(NSHomeFunctionKey)
        case .end: functionKey(NSEndFunctionKey)
        case .pageUp: functionKey(NSPageUpFunctionKey)
        case .pageDown: functionKey(NSPageDownFunctionKey)
        case .tab: "\t"
        case .enter: "\r"
        case .escape: "\u{1B}"
        case .space: " "
        case .delete: "\u{8}"
        case .forwardDelete: functionKey(NSDeleteFunctionKey)
        case .grave: "`"
        case .minus: "-"
        case .equal: "="
        case .leftBracket: "["
        case .rightBracket: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .quote: "'"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        }
    }

    private static func functionKey(_ value: Int) -> String {
        String(UnicodeScalar(value)!)
    }
}

@MainActor
enum ShortcutEventMatcher {
    static func chord(matching event: NSEvent) -> ShortcutChord? {
        chord(
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            unmodifiedCharacters: event.characters(byApplyingModifiers: [])
        )
    }

    static func chord(
        modifierFlags flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        unmodifiedCharacters: String?
    ) -> ShortcutChord? {
        let matchedKey: ShortcutKey?
        if let unmodifiedCharacters, !unmodifiedCharacters.isEmpty {
            let logicalKey = key(matching: unmodifiedCharacters, shifted: false)
            if logicalKey != nil || !isSyntheticControlOutput(unmodifiedCharacters) {
                matchedKey = logicalKey
            } else {
                matchedKey = key(
                    matching: charactersIgnoringModifiers,
                    shifted: flags.contains(.shift)
                )
            }
        } else {
            matchedKey = key(
                matching: charactersIgnoringModifiers,
                shifted: flags.contains(.shift)
            )
        }
        guard let key = matchedKey else { return nil }

        var modifiers = Set<ShortcutModifier>()
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        return ShortcutChord(key: key, modifiers: modifiers)
    }

    private static func key(
        matching characters: String?,
        shifted: Bool
    ) -> ShortcutKey? {
        guard let characters, !characters.isEmpty else { return nil }

        let canonicalCharacters = characters.lowercased()
        if canonicalCharacters.count == 1,
            let key = ShortcutKey(rawValue: canonicalCharacters)
        {
            return key
        }
        if shifted, let key = shiftedPrintableKey(matching: characters) {
            return key
        }

        switch characters {
        case "\u{3}", "\r": return .enter
        case "\t", "\u{19}": return .tab
        case "\u{1B}": return .escape
        case " ": return .space
        case "\u{8}", "\u{7F}": return .delete
        default:
            return ShortcutKey.allCases.first {
                ShortcutController.keyEquivalent(for: $0) == characters
            }
        }
    }

    private static func isSyntheticControlOutput(_ characters: String) -> Bool {
        characters.unicodeScalars.allSatisfy { $0.value < 0x20 }
    }

    private static func shiftedPrintableKey(matching characters: String) -> ShortcutKey? {
        switch characters {
        case "!": .one
        case "@": .two
        case "#": .three
        case "$": .four
        case "%": .five
        case "^": .six
        case "&": .seven
        case "*": .eight
        case "(": .nine
        case ")": .zero
        case "~": .grave
        case "_": .minus
        case "+": .equal
        case "{": .leftBracket
        case "}": .rightBracket
        case "|": .backslash
        case ":": .semicolon
        case "\"": .quote
        case "<": .comma
        case ">": .period
        case "?": .slash
        default: nil
        }
    }
}
