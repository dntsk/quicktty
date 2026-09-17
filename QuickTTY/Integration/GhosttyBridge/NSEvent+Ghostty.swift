import AppKit

// Adapted from NSEvent+Extension.swift at f9a3f24a56bf05f70894e1a084809d4fffadf420.
extension NSEvent {
    func ghosttyKeyEvent(
        _ action: GhosttyInputAction,
        translationModifiers: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> GhosttyKeyEvent {
        var unshiftedScalar: UInt32 = 0
        if type == .keyDown || type == .keyUp,
            let characters = characters(byApplyingModifiers: []),
            let scalar = characters.unicodeScalars.first
        {
            unshiftedScalar = scalar.value
        }

        return GhosttyKeyEvent(
            action: action,
            modifiers: GhosttyInput.modifiers(from: modifierFlags),
            consumedModifiers: GhosttyInput.modifiers(
                from: (translationModifiers ?? modifierFlags)
                    .subtracting([.control, .command])
            ),
            keyCode: UInt32(keyCode),
            unshiftedScalar: unshiftedScalar,
            text: text,
            composing: composing
        )
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
            let scalar = characters.unicodeScalars.first
        {
            if scalar.value < 0x20 {
                return self.characters(
                    byApplyingModifiers: modifierFlags.subtracting(.control)
                )
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
