import Carbon
import Foundation

private let globalHotKeySignature = OSType(0x4754_484B)
private let globalHotKeyIdentifier: UInt32 = 1

@MainActor
protocol HotKeyControlling: AnyObject {
    func register(_ descriptor: HotKeyDescriptor) throws
    func unregister() throws
}

enum GlobalHotKeyError: Error, Equatable, Sendable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)
}

@MainActor
final class GlobalHotKeyController: HotKeyControlling {
    struct CarbonHotKey: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private let action: @MainActor () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var registeredDescriptor: HotKeyDescriptor?
    private var callbackContext: Unmanaged<CallbackContext>?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    isolated deinit {
        unregisterSilently()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        callbackContext?.release()
    }

    func register(_ descriptor: HotKeyDescriptor) throws {
        guard descriptor != registeredDescriptor else { return }
        try unregister()
        try installEventHandlerIfNeeded()

        let carbonHotKey = Self.carbonHotKey(for: descriptor)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            carbonHotKey.keyCode,
            carbonHotKey.modifiers,
            EventHotKeyID(signature: globalHotKeySignature, id: globalHotKeyIdentifier),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            throw GlobalHotKeyError.registrationFailed(status)
        }
        hotKey = registeredHotKey
        registeredDescriptor = descriptor
    }

    func unregister() throws {
        guard let hotKey else { return }
        let status = UnregisterEventHotKey(hotKey)
        guard status == noErr else {
            throw GlobalHotKeyError.unregistrationFailed(status)
        }
        self.hotKey = nil
        registeredDescriptor = nil
    }

    static func carbonHotKey(for descriptor: HotKeyDescriptor) -> CarbonHotKey {
        var modifiers: UInt32 = 0
        if descriptor.command { modifiers |= UInt32(cmdKey) }
        if descriptor.option { modifiers |= UInt32(optionKey) }
        if descriptor.control { modifiers |= UInt32(controlKey) }
        if descriptor.shift { modifiers |= UInt32(shiftKey) }
        return CarbonHotKey(keyCode: keyCode(for: descriptor.key), modifiers: modifiers)
    }

    private func installEventHandlerIfNeeded() throws {
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
            throw GlobalHotKeyError.eventHandlerInstallationFailed(status)
        }
        callbackContext = context
        eventHandler = installedHandler
    }

    private func unregisterSilently() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        registeredDescriptor = nil
    }

    private static func keyCode(for key: HotKeyDescriptor.Key) -> UInt32 {
        switch key {
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
        }
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
