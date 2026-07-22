import AppKit
import Testing

@testable import QuickTTY

@Suite
@MainActor
struct GhosttyInputConversionTests {
    @Test
    func modifierBitsMatchPinnedABI() {
        #expect(GhosttyInput.modifierBitsMatchPinnedABI)
    }

    @Test
    func keyEventConversionPreservesActionKeyCodeModifiersAndUnshiftedScalar() throws {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "synthetic-shifted",
                charactersIgnoringModifiers: "synthetic-unshifted",
                isARepeat: true,
                keyCode: 0
            )
        )

        let expectedCharacters = try #require(event.characters(byApplyingModifiers: []))
        let expectedScalar = try #require(expectedCharacters.unicodeScalars.first)
        let converted = event.ghosttyKeyEvent(.repeat)

        #expect(expectedCharacters != event.charactersIgnoringModifiers)
        #expect(converted.action == .repeat)
        #expect(converted.keyCode == 0)
        #expect(converted.modifiers.contains(.shift))
        #expect(converted.modifiers.contains(.shiftRight))
        #expect(converted.consumedModifiers.contains(.shift))
        #expect(converted.consumedModifiers.contains(.shiftRight))
        #expect(converted.unshiftedScalar == expectedScalar.value)
    }

    @Test
    func consumedModifiersExcludeControlAndCommandButUseTranslationModifiers() throws {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "Å",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        let converted = event.ghosttyKeyEvent(
            .press,
            translationModifiers: [.shift, .control, .command]
        )

        #expect(converted.modifiers.contains(.shift))
        #expect(converted.modifiers.contains(.control))
        #expect(converted.modifiers.contains(.option))
        #expect(converted.modifiers.contains(.command))
        #expect(converted.consumedModifiers == [.shift])
    }

    @Test
    func translationModifierReplacementPreservesHiddenEventBits() {
        let original = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
        )

        let translated = GhosttyInput.translationModifiers(
            original: original,
            reported: [.shift]
        )

        #expect(translated.contains(.shift))
        #expect(!translated.contains(.option))
        #expect(translated.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0)
    }

    @Test
    func charactersReplaceControlScalarsAndFilterPrivateUseFunctionKeys() throws {
        let controlEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "\u{1}",
                charactersIgnoringModifiers: "synthetic-control-ignoring",
                isARepeat: false,
                keyCode: 0
            )
        )
        let functionEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 2,
                windowNumber: 0,
                context: nil,
                characters: String(UnicodeScalar(NSF1FunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSF1FunctionKey)!),
                isARepeat: false,
                keyCode: 122
            )
        )

        let replacementModifiers = controlEvent.modifierFlags.subtracting(.control)
        let expectedControlReplacement = try #require(
            controlEvent.characters(byApplyingModifiers: replacementModifiers)
        )

        #expect(expectedControlReplacement != controlEvent.charactersIgnoringModifiers)
        #expect(controlEvent.ghosttyCharacters == expectedControlReplacement)
        #expect(functionEvent.ghosttyCharacters == nil)
    }
}
