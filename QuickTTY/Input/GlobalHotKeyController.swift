import Carbon
import Foundation

private let globalHotKeySignature = OSType(0x4754_484B)
private let globalHotKeyIdentifier: UInt32 = 1

@MainActor
protocol HotKeyControlling: AnyObject {
    var registeredChord: ShortcutChord? { get }

    func replace(with chord: ShortcutChord) throws
    func unregister() throws
}

enum GlobalHotKeyError: Error, Equatable, Sendable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)
    case replacementAndRollbackFailed(registrationStatus: OSStatus, rollbackStatus: OSStatus)
}

struct CarbonHotKeyToken: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

enum CarbonHotKeyClientError: Error, Equatable, Sendable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)
}

@MainActor
protocol CarbonHotKeyClient: AnyObject {
    func installEventHandler(action: @escaping @MainActor () -> Void) throws
    func register(_ hotKey: GlobalHotKeyController.CarbonHotKey) throws -> CarbonHotKeyToken
    func unregister(_ token: CarbonHotKeyToken) throws
}

@MainActor
final class GlobalHotKeyController: HotKeyControlling {
    struct CarbonHotKey: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private struct Registration {
        let chord: ShortcutChord
        let carbonHotKey: CarbonHotKey
        let token: CarbonHotKeyToken
    }

    private let client: any CarbonHotKeyClient
    private let action: @MainActor () -> Void
    private var registration: Registration?

    var registeredChord: ShortcutChord? {
        registration?.chord
    }

    init(
        client: any CarbonHotKeyClient,
        action: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.action = action
    }

    convenience init(action: @escaping @MainActor () -> Void) {
        self.init(client: SystemCarbonHotKeyClient(), action: action)
    }

    isolated deinit {
        if let registration {
            try? client.unregister(registration.token)
        }
    }

    func replace(with chord: ShortcutChord) throws {
        guard chord != registration?.chord else { return }
        try installEventHandlerIfNeeded()

        guard let previous = registration else {
            let carbonHotKey = Self.carbonHotKey(for: chord)
            let token = try register(carbonHotKey)
            registration = Registration(chord: chord, carbonHotKey: carbonHotKey, token: token)
            return
        }

        do {
            try client.unregister(previous.token)
        } catch let error as CarbonHotKeyClientError {
            throw Self.globalError(from: error)
        }
        registration = nil

        let replacement = Self.carbonHotKey(for: chord)
        do {
            let token = try client.register(replacement)
            registration = Registration(chord: chord, carbonHotKey: replacement, token: token)
        } catch let replacementError as CarbonHotKeyClientError {
            let registrationStatus = Self.registrationStatus(from: replacementError)
            do {
                let rollbackToken = try client.register(previous.carbonHotKey)
                registration = Registration(
                    chord: previous.chord,
                    carbonHotKey: previous.carbonHotKey,
                    token: rollbackToken
                )
            } catch let rollbackError as CarbonHotKeyClientError {
                let rollbackStatus = Self.registrationStatus(from: rollbackError)
                throw GlobalHotKeyError.replacementAndRollbackFailed(
                    registrationStatus: registrationStatus,
                    rollbackStatus: rollbackStatus
                )
            }
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
    }

    func unregister() throws {
        guard let registration else { return }
        do {
            try client.unregister(registration.token)
        } catch let error as CarbonHotKeyClientError {
            throw Self.globalError(from: error)
        }
        self.registration = nil
    }

    static func carbonHotKey(for chord: ShortcutChord) -> CarbonHotKey {
        var modifiers: UInt32 = 0
        if chord.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if chord.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if chord.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if chord.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return CarbonHotKey(keyCode: keyCode(for: chord.key), modifiers: modifiers)
    }

    private func installEventHandlerIfNeeded() throws {
        do {
            try client.installEventHandler(action: action)
        } catch let error as CarbonHotKeyClientError {
            throw Self.globalError(from: error)
        }
    }

    private func register(_ hotKey: CarbonHotKey) throws -> CarbonHotKeyToken {
        do {
            return try client.register(hotKey)
        } catch let error as CarbonHotKeyClientError {
            throw Self.globalError(from: error)
        }
    }

    private static func globalError(from error: CarbonHotKeyClientError) -> GlobalHotKeyError {
        switch error {
        case .eventHandlerInstallationFailed(let status):
            .eventHandlerInstallationFailed(status)
        case .registrationFailed(let status):
            .registrationFailed(status)
        case .unregistrationFailed(let status):
            .unregistrationFailed(status)
        }
    }

    private static func registrationStatus(from error: CarbonHotKeyClientError) -> OSStatus {
        guard case .registrationFailed(let status) = error else {
            preconditionFailure("Carbon client returned a non-registration error while registering")
        }
        return status
    }

    private static func keyCode(for key: ShortcutKey) -> UInt32 {
        switch key {
        case .a: UInt32(kVK_ANSI_A)
        case .b: UInt32(kVK_ANSI_B)
        case .c: UInt32(kVK_ANSI_C)
        case .d: UInt32(kVK_ANSI_D)
        case .e: UInt32(kVK_ANSI_E)
        case .f: UInt32(kVK_ANSI_F)
        case .g: UInt32(kVK_ANSI_G)
        case .h: UInt32(kVK_ANSI_H)
        case .i: UInt32(kVK_ANSI_I)
        case .j: UInt32(kVK_ANSI_J)
        case .k: UInt32(kVK_ANSI_K)
        case .l: UInt32(kVK_ANSI_L)
        case .m: UInt32(kVK_ANSI_M)
        case .n: UInt32(kVK_ANSI_N)
        case .o: UInt32(kVK_ANSI_O)
        case .p: UInt32(kVK_ANSI_P)
        case .q: UInt32(kVK_ANSI_Q)
        case .r: UInt32(kVK_ANSI_R)
        case .s: UInt32(kVK_ANSI_S)
        case .t: UInt32(kVK_ANSI_T)
        case .u: UInt32(kVK_ANSI_U)
        case .v: UInt32(kVK_ANSI_V)
        case .w: UInt32(kVK_ANSI_W)
        case .x: UInt32(kVK_ANSI_X)
        case .y: UInt32(kVK_ANSI_Y)
        case .z: UInt32(kVK_ANSI_Z)
        case .zero: UInt32(kVK_ANSI_0)
        case .one: UInt32(kVK_ANSI_1)
        case .two: UInt32(kVK_ANSI_2)
        case .three: UInt32(kVK_ANSI_3)
        case .four: UInt32(kVK_ANSI_4)
        case .five: UInt32(kVK_ANSI_5)
        case .six: UInt32(kVK_ANSI_6)
        case .seven: UInt32(kVK_ANSI_7)
        case .eight: UInt32(kVK_ANSI_8)
        case .nine: UInt32(kVK_ANSI_9)
        case .f1: UInt32(kVK_F1)
        case .f2: UInt32(kVK_F2)
        case .f3: UInt32(kVK_F3)
        case .f4: UInt32(kVK_F4)
        case .f5: UInt32(kVK_F5)
        case .f6: UInt32(kVK_F6)
        case .f7: UInt32(kVK_F7)
        case .f8: UInt32(kVK_F8)
        case .f9: UInt32(kVK_F9)
        case .f10: UInt32(kVK_F10)
        case .f11: UInt32(kVK_F11)
        case .f12: UInt32(kVK_F12)
        case .f13: UInt32(kVK_F13)
        case .f14: UInt32(kVK_F14)
        case .f15: UInt32(kVK_F15)
        case .f16: UInt32(kVK_F16)
        case .f17: UInt32(kVK_F17)
        case .f18: UInt32(kVK_F18)
        case .f19: UInt32(kVK_F19)
        case .f20: UInt32(kVK_F20)
        case .left: UInt32(kVK_LeftArrow)
        case .right: UInt32(kVK_RightArrow)
        case .up: UInt32(kVK_UpArrow)
        case .down: UInt32(kVK_DownArrow)
        case .home: UInt32(kVK_Home)
        case .end: UInt32(kVK_End)
        case .pageUp: UInt32(kVK_PageUp)
        case .pageDown: UInt32(kVK_PageDown)
        case .tab: UInt32(kVK_Tab)
        case .enter: UInt32(kVK_Return)
        case .escape: UInt32(kVK_Escape)
        case .space: UInt32(kVK_Space)
        case .delete: UInt32(kVK_Delete)
        case .forwardDelete: UInt32(kVK_ForwardDelete)
        // Printable tokens intentionally use documented physical ANSI key positions.
        case .grave: UInt32(kVK_ANSI_Grave)
        case .minus: UInt32(kVK_ANSI_Minus)
        case .equal: UInt32(kVK_ANSI_Equal)
        case .leftBracket: UInt32(kVK_ANSI_LeftBracket)
        case .rightBracket: UInt32(kVK_ANSI_RightBracket)
        case .backslash: UInt32(kVK_ANSI_Backslash)
        case .semicolon: UInt32(kVK_ANSI_Semicolon)
        case .quote: UInt32(kVK_ANSI_Quote)
        case .comma: UInt32(kVK_ANSI_Comma)
        case .period: UInt32(kVK_ANSI_Period)
        case .slash: UInt32(kVK_ANSI_Slash)
        }
    }
}

@MainActor
private final class SystemCarbonHotKeyClient: CarbonHotKeyClient {
    private var eventHandler: EventHandlerRef?
    private var callbackContext: Unmanaged<CallbackContext>?
    private var hotKeys: [CarbonHotKeyToken: EventHotKeyRef] = [:]
    private var nextToken: UInt64 = 1

    isolated deinit {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        callbackContext?.release()
    }

    func installEventHandler(action: @escaping @MainActor () -> Void) throws {
        guard eventHandler == nil else { return }
        let context = Unmanaged.passRetained(CallbackContext(action: action))
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            context.toOpaque(),
            &installedHandler
        )
        guard status == noErr, let installedHandler else {
            context.release()
            throw CarbonHotKeyClientError.eventHandlerInstallationFailed(status)
        }
        callbackContext = context
        eventHandler = installedHandler
    }

    func register(
        _ hotKey: GlobalHotKeyController.CarbonHotKey
    ) throws -> CarbonHotKeyToken {
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: globalHotKeySignature, id: globalHotKeyIdentifier),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            throw CarbonHotKeyClientError.registrationFailed(status)
        }
        let token = CarbonHotKeyToken(rawValue: nextToken)
        nextToken += 1
        hotKeys[token] = registeredHotKey
        return token
    }

    func unregister(_ token: CarbonHotKeyToken) throws {
        guard let hotKey = hotKeys[token] else { return }
        let status = UnregisterEventHotKey(hotKey)
        guard status == noErr else {
            throw CarbonHotKeyClientError.unregistrationFailed(status)
        }
        hotKeys[token] = nil
    }
}

@MainActor
private final class CallbackContext {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}

private func globalHotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == globalHotKeySignature,
        identifier.id == globalHotKeyIdentifier
    else { return OSStatus(eventNotHandledErr) }

    let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        context.action()
    }
    return noErr
}
