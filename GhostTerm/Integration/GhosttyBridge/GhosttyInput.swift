import AppKit
import Carbon
import GhosttyKit

// Adapted from Ghostty.Input.swift and Helpers/KeyboardLayout.swift at 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
enum GhosttyInputAction: Equatable, Sendable {
    case release
    case press
    case `repeat`

    var cValue: ghostty_input_action_e {
        switch self {
        case .release:
            GHOSTTY_ACTION_RELEASE
        case .press:
            GHOSTTY_ACTION_PRESS
        case .repeat:
            GHOSTTY_ACTION_REPEAT
        }
    }
}

enum GhosttyMouseAction: Equatable, Sendable {
    case release
    case press

    var cValue: ghostty_input_mouse_state_e {
        switch self {
        case .release:
            GHOSTTY_MOUSE_RELEASE
        case .press:
            GHOSTTY_MOUSE_PRESS
        }
    }
}

enum GhosttyMouseButton: CaseIterable, Equatable, Sendable {
    case unknown
    case left
    case right
    case middle
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case ten
    case eleven

    init(buttonNumber: Int) {
        self =
            switch buttonNumber {
            case 0: .left
            case 1: .right
            case 2: .middle
            case 3: .eight
            case 4: .nine
            case 5: .six
            case 6: .seven
            case 7: .four
            case 8: .five
            case 9: .ten
            case 10: .eleven
            default: .unknown
            }
    }

    var cValue: ghostty_input_mouse_button_e {
        switch self {
        case .unknown:
            GHOSTTY_MOUSE_UNKNOWN
        case .left:
            GHOSTTY_MOUSE_LEFT
        case .right:
            GHOSTTY_MOUSE_RIGHT
        case .middle:
            GHOSTTY_MOUSE_MIDDLE
        case .four:
            GHOSTTY_MOUSE_FOUR
        case .five:
            GHOSTTY_MOUSE_FIVE
        case .six:
            GHOSTTY_MOUSE_SIX
        case .seven:
            GHOSTTY_MOUSE_SEVEN
        case .eight:
            GHOSTTY_MOUSE_EIGHT
        case .nine:
            GHOSTTY_MOUSE_NINE
        case .ten:
            GHOSTTY_MOUSE_TEN
        case .eleven:
            GHOSTTY_MOUSE_ELEVEN
        }
    }
}

enum GhosttyScrollMomentum: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case began = 1
    case stationary = 2
    case changed = 3
    case ended = 4
    case cancelled = 5
    case mayBegin = 6

    init(_ phase: NSEvent.Phase) {
        self =
            switch phase {
            case .began: .began
            case .stationary: .stationary
            case .changed: .changed
            case .ended: .ended
            case .cancelled: .cancelled
            case .mayBegin: .mayBegin
            default: .none
            }
    }

    var cValue: ghostty_input_mouse_momentum_e {
        switch self {
        case .none:
            GHOSTTY_MOUSE_MOMENTUM_NONE
        case .began:
            GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary:
            GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:
            GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:
            GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:
            GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:
            GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        }
    }
}

struct GhosttyScrollModifiers: Equatable, Sendable {
    let rawValue: Int32

    init(precision: Bool = false, momentum: GhosttyScrollMomentum = .none) {
        rawValue = (precision ? 1 : 0) | (Int32(momentum.rawValue) << 1)
    }

    var precision: Bool {
        rawValue & 0b0000_0001 != 0
    }

    var momentum: GhosttyScrollMomentum {
        GhosttyScrollMomentum(rawValue: UInt8((rawValue >> 1) & 0b0000_0111)) ?? .none
    }

    var cValue: ghostty_input_scroll_mods_t {
        rawValue
    }
}

struct GhosttyInputModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let capsLock = Self(rawValue: 1 << 4)
    static let numericPad = Self(rawValue: 1 << 5)
    static let shiftRight = Self(rawValue: 1 << 6)
    static let controlRight = Self(rawValue: 1 << 7)
    static let optionRight = Self(rawValue: 1 << 8)
    static let commandRight = Self(rawValue: 1 << 9)

    var cValue: ghostty_input_mods_e {
        ghostty_input_mods_e(rawValue)
    }
}

enum GhosttyInput {
    static var mouseABIMatchesPinnedHeader: Bool {
        let actions = [GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_PRESS].map {
            Int($0.rawValue)
        }
        let buttons = [
            GHOSTTY_MOUSE_UNKNOWN,
            GHOSTTY_MOUSE_LEFT,
            GHOSTTY_MOUSE_RIGHT,
            GHOSTTY_MOUSE_MIDDLE,
            GHOSTTY_MOUSE_FOUR,
            GHOSTTY_MOUSE_FIVE,
            GHOSTTY_MOUSE_SIX,
            GHOSTTY_MOUSE_SEVEN,
            GHOSTTY_MOUSE_EIGHT,
            GHOSTTY_MOUSE_NINE,
            GHOSTTY_MOUSE_TEN,
            GHOSTTY_MOUSE_ELEVEN,
        ].map { Int($0.rawValue) }
        let momentum = [
            GHOSTTY_MOUSE_MOMENTUM_NONE,
            GHOSTTY_MOUSE_MOMENTUM_BEGAN,
            GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
            GHOSTTY_MOUSE_MOMENTUM_CHANGED,
            GHOSTTY_MOUSE_MOMENTUM_ENDED,
            GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
            GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
        ].map { Int($0.rawValue) }

        return actions == [0, 1]
            && buttons == Array(0...11)
            && momentum == Array(0...6)
            && MemoryLayout<ghostty_input_scroll_mods_t>.size == MemoryLayout<Int32>.size
            && MemoryLayout<ghostty_input_scroll_mods_t>.stride == MemoryLayout<Int32>.stride
            && MemoryLayout<ghostty_input_scroll_mods_t>.alignment == MemoryLayout<Int32>.alignment
    }

    static var modifierBitsMatchPinnedABI: Bool {
        [
            GHOSTTY_MODS_SHIFT.rawValue,
            GHOSTTY_MODS_CTRL.rawValue,
            GHOSTTY_MODS_ALT.rawValue,
            GHOSTTY_MODS_SUPER.rawValue,
            GHOSTTY_MODS_CAPS.rawValue,
            GHOSTTY_MODS_NUM.rawValue,
            GHOSTTY_MODS_SHIFT_RIGHT.rawValue,
            GHOSTTY_MODS_CTRL_RIGHT.rawValue,
            GHOSTTY_MODS_ALT_RIGHT.rawValue,
            GHOSTTY_MODS_SUPER_RIGHT.rawValue,
        ] == (0..<10).map { UInt32(1 << $0) }
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> GhosttyInputModifiers {
        var modifiers: GhosttyInputModifiers = []

        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { modifiers.insert(.shiftRight) }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { modifiers.insert(.controlRight) }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { modifiers.insert(.optionRight) }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { modifiers.insert(.commandRight) }

        return modifiers
    }

    static func modifierFlags(from modifiers: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let rawValue = modifiers.rawValue

        if rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }

        return flags
    }

    static func translationModifiers(
        original: NSEvent.ModifierFlags,
        reported: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        var result = original
        for flag in [
            NSEvent.ModifierFlags.shift,
            .control,
            .option,
            .command,
        ] {
            if reported.contains(flag) {
                result.insert(flag)
            } else {
                result.remove(flag)
            }
        }
        return result
    }

    @MainActor
    static var currentKeyboardLayoutID: String? {
        guard
            let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }

        return unsafeBitCast(pointer, to: CFString.self) as String
    }
}

struct GhosttyKeyEvent: Equatable, Sendable {
    let action: GhosttyInputAction
    let modifiers: GhosttyInputModifiers
    let consumedModifiers: GhosttyInputModifiers
    let keyCode: UInt32
    let unshiftedScalar: UInt32
    let text: String?
    let composing: Bool

    func withCValue<Result>(_ body: (ghostty_input_key_s) -> Result) -> Result {
        var value = ghostty_input_key_s()
        value.action = action.cValue
        value.mods = modifiers.cValue
        value.consumed_mods = consumedModifiers.cValue
        value.keycode = keyCode
        value.unshifted_codepoint = unshiftedScalar
        value.composing = composing

        guard let text else {
            value.text = nil
            return body(value)
        }

        return text.withCString { pointer in
            value.text = pointer
            return body(value)
        }
    }
}
