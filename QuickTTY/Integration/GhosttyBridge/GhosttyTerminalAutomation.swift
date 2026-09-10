import AppKit
import Foundation
import GhosttyKit

struct GhosttyRenderedText: Equatable, Sendable {
    let text: String
    let isTruncated: Bool
}

enum GhosttyAutomationKey: String, CaseIterable, Equatable, Sendable {
    case enter
    case tab
    case escape
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case backspace
    case delete
    case controlC = "ctrl-c"
    case controlD = "ctrl-d"
}

enum GhosttyOutputState: Equatable, Sendable {
    case failed
    case pending
    case complete
}

struct GhosttyTerminalAutomationReadRequest {
    let maximumUTF8Bytes: Int
}

struct GhosttyTerminalAutomationReadBuffer {
    let bytes: Data
    var isTruncated: Bool = false
    let release: @MainActor () -> Void
}

enum GhosttyTerminalAutomationReadResult {
    case success(GhosttyTerminalAutomationReadBuffer)
    case failure
}

struct GhosttyTerminalAutomationClient {
    let readText:
        @MainActor (
            GhosttyTerminalAutomationReadRequest,
            @MainActor () -> GhosttyTerminalAutomationReadResult
        ) -> GhosttyTerminalAutomationReadResult
    let freeText: @MainActor (GhosttyTerminalAutomationReadBuffer) -> Void
    var outputState: @MainActor (@MainActor () -> GhosttyOutputState) -> GhosttyOutputState = {
        $0()
    }

    static let live = Self(
        readText: { _, liveRead in
            liveRead()
        },
        freeText: { buffer in
            buffer.release()
        }
    )
}

private struct GhosttyAutomationKeyDescriptor {
    let keyCode: UInt32
    let unshiftedScalar: UInt32
    let modifiers: GhosttyInputModifiers
}

enum GhosttyTerminalAutomation {
    static let maximumRenderedTextUTF8Bytes = TerminalControlProtocol.maximumSnapshotSize
    static let maximumAutomationTextUTF8Bytes = TerminalControlProtocol.maximumTextSize

    static var allowlistMatchesTerminalControlKey: Bool {
        GhosttyAutomationKey.allCases.map(\.rawValue) == TerminalControlKey.allCases.map(\.rawValue)
    }

    static var abiMatchesPinnedHeader: Bool {
        let keyConstants = [
            UInt32(GHOSTTY_KEY_C.rawValue),
            UInt32(GHOSTTY_KEY_D.rawValue),
            UInt32(GHOSTTY_KEY_BACKSPACE.rawValue),
            UInt32(GHOSTTY_KEY_ENTER.rawValue),
            UInt32(GHOSTTY_KEY_TAB.rawValue),
            UInt32(GHOSTTY_KEY_DELETE.rawValue),
            UInt32(GHOSTTY_KEY_ARROW_DOWN.rawValue),
            UInt32(GHOSTTY_KEY_ARROW_LEFT.rawValue),
            UInt32(GHOSTTY_KEY_ARROW_RIGHT.rawValue),
            UInt32(GHOSTTY_KEY_ARROW_UP.rawValue),
            UInt32(GHOSTTY_KEY_ESCAPE.rawValue),
        ]
        let modifierConstants = [
            UInt32(GHOSTTY_MODS_NONE.rawValue),
            UInt32(GHOSTTY_MODS_CTRL.rawValue),
        ]
        let outputStates = [
            QUICKTTY_OUTPUT_FAILED.rawValue,
            QUICKTTY_OUTPUT_PENDING.rawValue,
            QUICKTTY_OUTPUT_COMPLETE.rawValue,
        ]
        let pointTags = [
            UInt32(GHOSTTY_POINT_ACTIVE.rawValue),
            UInt32(GHOSTTY_POINT_VIEWPORT.rawValue),
            UInt32(GHOSTTY_POINT_SCREEN.rawValue),
            UInt32(GHOSTTY_POINT_SURFACE.rawValue),
        ]
        let pointCoords = [
            UInt32(GHOSTTY_POINT_COORD_EXACT.rawValue),
            UInt32(GHOSTTY_POINT_COORD_TOP_LEFT.rawValue),
            UInt32(GHOSTTY_POINT_COORD_BOTTOM_RIGHT.rawValue),
        ]
        let textLayoutMatchesPinnedHeader =
            MemoryLayout<ghostty_text_s>.size == 40
            && MemoryLayout<ghostty_text_s>.stride == 40
            && MemoryLayout<ghostty_text_s>.alignment == 8
        let pointLayoutMatchesPinnedHeader =
            MemoryLayout<ghostty_point_s>.size == 16
            && MemoryLayout<ghostty_point_s>.stride == 16
            && MemoryLayout<ghostty_point_s>.alignment == 4
        let selectionLayoutMatchesPinnedHeader =
            MemoryLayout<ghostty_selection_s>.size == 36
            && MemoryLayout<ghostty_selection_s>.stride == 36
            && MemoryLayout<ghostty_selection_s>.alignment == 4

        return GhosttyInput.keyABIMatchesPinnedHeader
            && keyConstants == [22, 23, 53, 58, 64, 68, 75, 76, 77, 78, 120]
            && modifierConstants == [0, 2]
            && outputStates == [0, 1, 2]
            && pointTags == [0, 1, 2, 3]
            && pointCoords == [0, 1, 2]
            && textLayoutMatchesPinnedHeader
            && pointLayoutMatchesPinnedHeader
            && selectionLayoutMatchesPinnedHeader
    }

    static func validateRenderedTextLimit(_ maximumUTF8Bytes: Int) throws -> Int {
        guard (1...maximumRenderedTextUTF8Bytes).contains(maximumUTF8Bytes) else {
            throw GhosttyBridgeError.invalidRenderedTextLimit
        }
        return maximumUTF8Bytes
    }

    static func automationTextBytes(from text: String) throws -> Data {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumAutomationTextUTF8Bytes else {
            throw GhosttyBridgeError.invalidAutomationText
        }
        return data
    }

    static func keyEvent(for key: GhosttyAutomationKey) -> GhosttyKeyEvent {
        let descriptor = descriptor(for: key)
        return GhosttyKeyEvent(
            action: .press,
            modifiers: descriptor.modifiers,
            consumedModifiers: [],
            keyCode: descriptor.keyCode,
            unshiftedScalar: descriptor.unshiftedScalar,
            text: nil,
            composing: false
        )
    }

    @MainActor
    static func renderedText(
        request: GhosttyTerminalAutomationReadRequest,
        liveRead: @MainActor () -> GhosttyTerminalAutomationReadResult,
        client: GhosttyTerminalAutomationClient,
        paneID: PaneID
    ) throws -> GhosttyRenderedText {
        let result = client.readText(request, liveRead)
        guard case .success(let buffer) = result else {
            throw GhosttyBridgeError.renderedTextReadFailed(paneID)
        }
        defer {
            client.freeText(buffer)
        }

        guard let string = String(data: buffer.bytes, encoding: .utf8) else {
            throw GhosttyBridgeError.invalidRenderedTextEncoding(paneID)
        }
        let rendered = truncatedRenderedText(
            from: string,
            maximumUTF8Bytes: request.maximumUTF8Bytes
        )
        // WHY: Only the atomic native read knows which screen rows or bytes were omitted.
        return GhosttyRenderedText(
            text: rendered.text,
            isTruncated: buffer.isTruncated || rendered.isTruncated
        )
    }

    @MainActor
    static func liveRenderedText(
        from surface: ghostty_surface_t,
        maximumUTF8Bytes: Int
    ) -> GhosttyTerminalAutomationReadResult {
        var text = ghostty_text_s()
        var isTruncated = false
        guard
            quicktty_surface_read_tail(
                surface, numericCast(maximumUTF8Bytes), &text, &isTruncated)
        else {
            return .failure
        }

        var shouldFreeText = true
        defer {
            if shouldFreeText {
                ghostty_surface_free_text(surface, &text)
            }
        }

        guard let length = Int(exactly: text.text_len), length <= maximumUTF8Bytes else {
            return .failure
        }

        let bytes: Data
        if length == 0 {
            bytes = Data()
        } else {
            guard let pointer = text.text else {
                return .failure
            }
            bytes = Data(bytes: UnsafeRawPointer(pointer), count: length)
        }

        shouldFreeText = false
        return .success(
            GhosttyTerminalAutomationReadBuffer(
                bytes: bytes,
                isTruncated: isTruncated,
                release: {
                    ghostty_surface_free_text(surface, &text)
                }
            )
        )
    }

    private static func descriptor(for key: GhosttyAutomationKey) -> GhosttyAutomationKeyDescriptor
    {
        switch key {
        case .enter:
            GhosttyAutomationKeyDescriptor(
                keyCode: 36,
                unshiftedScalar: 0x0D,
                modifiers: []
            )
        case .tab:
            GhosttyAutomationKeyDescriptor(
                keyCode: 48,
                unshiftedScalar: 0x09,
                modifiers: []
            )
        case .escape:
            GhosttyAutomationKeyDescriptor(
                keyCode: 53,
                unshiftedScalar: 0x1B,
                modifiers: []
            )
        case .arrowUp:
            GhosttyAutomationKeyDescriptor(
                keyCode: 126,
                unshiftedScalar: UInt32(NSUpArrowFunctionKey),
                modifiers: []
            )
        case .arrowDown:
            GhosttyAutomationKeyDescriptor(
                keyCode: 125,
                unshiftedScalar: UInt32(NSDownArrowFunctionKey),
                modifiers: []
            )
        case .arrowLeft:
            GhosttyAutomationKeyDescriptor(
                keyCode: 123,
                unshiftedScalar: UInt32(NSLeftArrowFunctionKey),
                modifiers: []
            )
        case .arrowRight:
            GhosttyAutomationKeyDescriptor(
                keyCode: 124,
                unshiftedScalar: UInt32(NSRightArrowFunctionKey),
                modifiers: []
            )
        case .backspace:
            GhosttyAutomationKeyDescriptor(
                keyCode: 51,
                unshiftedScalar: 0x08,
                modifiers: []
            )
        case .delete:
            GhosttyAutomationKeyDescriptor(
                keyCode: 117,
                unshiftedScalar: UInt32(NSDeleteFunctionKey),
                modifiers: []
            )
        case .controlC:
            GhosttyAutomationKeyDescriptor(
                keyCode: 8,
                unshiftedScalar: "c".unicodeScalars.first!.value,
                modifiers: [.control]
            )
        case .controlD:
            GhosttyAutomationKeyDescriptor(
                keyCode: 2,
                unshiftedScalar: "d".unicodeScalars.first!.value,
                modifiers: [.control]
            )
        }
    }

    private static func truncatedRenderedText(
        from text: String,
        maximumUTF8Bytes: Int
    ) -> GhosttyRenderedText {
        guard text.utf8.count > maximumUTF8Bytes else {
            return GhosttyRenderedText(text: text, isTruncated: false)
        }

        let scalars = text.unicodeScalars
        var lowerBound = scalars.endIndex
        var byteCount = 0

        while lowerBound > scalars.startIndex {
            let previousIndex = scalars.index(before: lowerBound)
            let scalar = scalars[previousIndex]
            let nextByteCount = byteCount + scalar.utf8.count
            guard nextByteCount <= maximumUTF8Bytes else { break }
            byteCount = nextByteCount
            lowerBound = previousIndex
        }

        return GhosttyRenderedText(
            text: String(scalars[lowerBound...]),
            isTruncated: true
        )
    }

}
