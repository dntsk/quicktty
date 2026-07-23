import Carbon
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct HotKeyDescriptorCarbonTests {
    @Test
    func conversionCoversEverySharedShortcutKey() {
        let expected: [ShortcutKey: UInt32] = [
            .a: UInt32(kVK_ANSI_A), .b: UInt32(kVK_ANSI_B), .c: UInt32(kVK_ANSI_C),
            .d: UInt32(kVK_ANSI_D), .e: UInt32(kVK_ANSI_E), .f: UInt32(kVK_ANSI_F),
            .g: UInt32(kVK_ANSI_G), .h: UInt32(kVK_ANSI_H), .i: UInt32(kVK_ANSI_I),
            .j: UInt32(kVK_ANSI_J), .k: UInt32(kVK_ANSI_K), .l: UInt32(kVK_ANSI_L),
            .m: UInt32(kVK_ANSI_M), .n: UInt32(kVK_ANSI_N), .o: UInt32(kVK_ANSI_O),
            .p: UInt32(kVK_ANSI_P), .q: UInt32(kVK_ANSI_Q), .r: UInt32(kVK_ANSI_R),
            .s: UInt32(kVK_ANSI_S), .t: UInt32(kVK_ANSI_T), .u: UInt32(kVK_ANSI_U),
            .v: UInt32(kVK_ANSI_V), .w: UInt32(kVK_ANSI_W), .x: UInt32(kVK_ANSI_X),
            .y: UInt32(kVK_ANSI_Y), .z: UInt32(kVK_ANSI_Z),
            .zero: UInt32(kVK_ANSI_0), .one: UInt32(kVK_ANSI_1),
            .two: UInt32(kVK_ANSI_2), .three: UInt32(kVK_ANSI_3),
            .four: UInt32(kVK_ANSI_4), .five: UInt32(kVK_ANSI_5),
            .six: UInt32(kVK_ANSI_6), .seven: UInt32(kVK_ANSI_7),
            .eight: UInt32(kVK_ANSI_8), .nine: UInt32(kVK_ANSI_9),
            .f1: UInt32(kVK_F1), .f2: UInt32(kVK_F2), .f3: UInt32(kVK_F3),
            .f4: UInt32(kVK_F4), .f5: UInt32(kVK_F5), .f6: UInt32(kVK_F6),
            .f7: UInt32(kVK_F7), .f8: UInt32(kVK_F8), .f9: UInt32(kVK_F9),
            .f10: UInt32(kVK_F10), .f11: UInt32(kVK_F11), .f12: UInt32(kVK_F12),
            .f13: UInt32(kVK_F13), .f14: UInt32(kVK_F14), .f15: UInt32(kVK_F15),
            .f16: UInt32(kVK_F16), .f17: UInt32(kVK_F17), .f18: UInt32(kVK_F18),
            .f19: UInt32(kVK_F19), .f20: UInt32(kVK_F20),
            .left: UInt32(kVK_LeftArrow), .right: UInt32(kVK_RightArrow),
            .up: UInt32(kVK_UpArrow), .down: UInt32(kVK_DownArrow),
            .home: UInt32(kVK_Home), .end: UInt32(kVK_End),
            .pageUp: UInt32(kVK_PageUp), .pageDown: UInt32(kVK_PageDown),
            .tab: UInt32(kVK_Tab), .enter: UInt32(kVK_Return),
            .escape: UInt32(kVK_Escape), .space: UInt32(kVK_Space),
            .delete: UInt32(kVK_Delete), .forwardDelete: UInt32(kVK_ForwardDelete),
            .grave: UInt32(kVK_ANSI_Grave), .minus: UInt32(kVK_ANSI_Minus),
            .equal: UInt32(kVK_ANSI_Equal), .leftBracket: UInt32(kVK_ANSI_LeftBracket),
            .rightBracket: UInt32(kVK_ANSI_RightBracket),
            .backslash: UInt32(kVK_ANSI_Backslash),
            .semicolon: UInt32(kVK_ANSI_Semicolon), .quote: UInt32(kVK_ANSI_Quote),
            .comma: UInt32(kVK_ANSI_Comma), .period: UInt32(kVK_ANSI_Period),
            .slash: UInt32(kVK_ANSI_Slash),
        ]

        #expect(expected.count == ShortcutKey.allCases.count)
        for key in ShortcutKey.allCases {
            #expect(
                GlobalHotKeyController.carbonHotKey(for: ShortcutChord(key: key)).keyCode
                    == expected[key]
            )
        }
    }

    @Test
    func conversionUsesExactCarbonModifierFlagsIncludingNone() {
        #expect(
            GlobalHotKeyController.carbonHotKey(for: ShortcutChord(key: .f12)).modifiers == 0
        )
        let chord = ShortcutChord(
            key: .f12,
            modifiers: [.command, .option, .control, .shift]
        )

        #expect(
            GlobalHotKeyController.carbonHotKey(for: chord).modifiers
                == UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }

    @Test
    func eventHandlerInstallationFailureIsTypedAndDoesNotRegister() {
        let client = FakeCarbonHotKeyClient()
        client.eventHandlerInstallationStatus = -5
        let controller = GlobalHotKeyController(client: client) {}

        #expect(throws: GlobalHotKeyError.eventHandlerInstallationFailed(-5)) {
            try controller.replace(with: ShortcutChord(key: .f12))
        }

        #expect(client.operations == [.installEventHandler])
        #expect(controller.registeredChord == nil)
    }

    @Test
    func installedEventHandlerPreservesMainActorCallback() throws {
        let client = FakeCarbonHotKeyClient()
        var invocationCount = 0
        let controller = GlobalHotKeyController(client: client) {
            invocationCount += 1
        }

        try controller.replace(with: ShortcutChord(key: .f12))
        client.installedAction?()

        #expect(invocationCount == 1)
    }

    @Test
    func replacingWithSameChordIsNoOp() throws {
        let client = FakeCarbonHotKeyClient()
        let controller = GlobalHotKeyController(client: client) {}
        let chord = ShortcutChord(key: .f12)

        try controller.replace(with: chord)
        client.operations.removeAll()
        try controller.replace(with: chord)

        #expect(client.operations.isEmpty)
        #expect(controller.registeredChord == chord)
    }

    @Test
    func successfulReplacementUnregistersOldBeforeTrackingNew() throws {
        let client = FakeCarbonHotKeyClient()
        let controller = GlobalHotKeyController(client: client) {}
        let oldChord = ShortcutChord(key: .f12)
        let newChord = ShortcutChord(key: .space, modifiers: [.command, .option])
        try controller.replace(with: oldChord)
        client.operations.removeAll()

        try controller.replace(with: newChord)

        #expect(
            client.operations == [
                .unregister(CarbonHotKeyToken(rawValue: 1)),
                .register(GlobalHotKeyController.carbonHotKey(for: newChord)),
            ]
        )
        #expect(controller.registeredChord == newChord)
    }

    @Test
    func failedReplacementRestoresPreviousRegistration() throws {
        let client = FakeCarbonHotKeyClient()
        let controller = GlobalHotKeyController(client: client) {}
        let oldChord = ShortcutChord(key: .f12)
        let newChord = ShortcutChord(key: .space, modifiers: [.command])
        try controller.replace(with: oldChord)
        client.operations.removeAll()
        client.registrationStatuses = [-1, noErr]

        #expect(throws: GlobalHotKeyError.registrationFailed(-1)) {
            try controller.replace(with: newChord)
        }

        #expect(
            client.operations == [
                .unregister(CarbonHotKeyToken(rawValue: 1)),
                .register(GlobalHotKeyController.carbonHotKey(for: newChord)),
                .register(GlobalHotKeyController.carbonHotKey(for: oldChord)),
            ]
        )
        #expect(controller.registeredChord == oldChord)
        #expect(
            client.registeredHotKeys.values.first
                == GlobalHotKeyController.carbonHotKey(for: oldChord))
    }

    @Test
    func unregisterFailureKeepsTrackedPreviousRegistration() throws {
        let client = FakeCarbonHotKeyClient()
        let controller = GlobalHotKeyController(client: client) {}
        let oldChord = ShortcutChord(key: .f12)
        try controller.replace(with: oldChord)
        client.unregistrationStatuses = [-2]

        #expect(throws: GlobalHotKeyError.unregistrationFailed(-2)) {
            try controller.replace(with: ShortcutChord(key: .f11))
        }

        #expect(controller.registeredChord == oldChord)
        #expect(client.registeredHotKeys.count == 1)
    }

    @Test
    func rollbackFailureReportsBothStatusesAndTracksNoRegistration() throws {
        let client = FakeCarbonHotKeyClient()
        let controller = GlobalHotKeyController(client: client) {}
        try controller.replace(with: ShortcutChord(key: .f12))
        client.registrationStatuses = [-3, -4]

        #expect(
            throws: GlobalHotKeyError.replacementAndRollbackFailed(
                registrationStatus: -3,
                rollbackStatus: -4
            )
        ) {
            try controller.replace(with: ShortcutChord(key: .f11))
        }

        #expect(controller.registeredChord == nil)
        #expect(client.registeredHotKeys.isEmpty)
    }
}

@MainActor
private final class FakeCarbonHotKeyClient: CarbonHotKeyClient {
    enum Operation: Equatable {
        case installEventHandler
        case register(GlobalHotKeyController.CarbonHotKey)
        case unregister(CarbonHotKeyToken)
    }

    var eventHandlerInstallationStatus: OSStatus = noErr
    var registrationStatuses: [OSStatus] = []
    var unregistrationStatuses: [OSStatus] = []
    var operations: [Operation] = []
    private(set) var installedAction: (@MainActor () -> Void)?
    private(set) var registeredHotKeys: [CarbonHotKeyToken: GlobalHotKeyController.CarbonHotKey] =
        [:]
    private var nextToken: UInt64 = 1
    private var installed = false

    func installEventHandler(action: @escaping @MainActor () -> Void) throws {
        guard !installed else { return }
        operations.append(.installEventHandler)
        guard eventHandlerInstallationStatus == noErr else {
            throw CarbonHotKeyClientError.eventHandlerInstallationFailed(
                eventHandlerInstallationStatus)
        }
        installedAction = action
        installed = true
    }

    func register(
        _ hotKey: GlobalHotKeyController.CarbonHotKey
    ) throws -> CarbonHotKeyToken {
        operations.append(.register(hotKey))
        let status = registrationStatuses.isEmpty ? noErr : registrationStatuses.removeFirst()
        guard status == noErr else { throw CarbonHotKeyClientError.registrationFailed(status) }
        let token = CarbonHotKeyToken(rawValue: nextToken)
        nextToken += 1
        registeredHotKeys[token] = hotKey
        return token
    }

    func unregister(_ token: CarbonHotKeyToken) throws {
        operations.append(.unregister(token))
        let status = unregistrationStatuses.isEmpty ? noErr : unregistrationStatuses.removeFirst()
        guard status == noErr else { throw CarbonHotKeyClientError.unregistrationFailed(status) }
        registeredHotKeys[token] = nil
    }
}
