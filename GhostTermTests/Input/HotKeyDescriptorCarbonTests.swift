import Carbon
import Testing

@testable import GhostTerm

@Suite(.serialized)
@MainActor
struct HotKeyDescriptorCarbonTests {
    @Test
    func conversionUsesCarbonFunctionKeyWithoutModifiers() {
        let carbonHotKey = GlobalHotKeyController.carbonHotKey(for: HotKeyDescriptor(key: .f12))

        #expect(carbonHotKey.keyCode == UInt32(kVK_F12))
        #expect(carbonHotKey.modifiers == 0)
    }

    @Test
    func conversionUsesCarbonFunctionKeyAndModifierFlags() {
        let descriptor = HotKeyDescriptor(
            command: true,
            option: true,
            control: true,
            shift: true,
            key: .f12
        )

        let carbonHotKey = GlobalHotKeyController.carbonHotKey(for: descriptor)

        #expect(carbonHotKey.keyCode == UInt32(kVK_F12))
        #expect(
            carbonHotKey.modifiers
                == UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }
}
