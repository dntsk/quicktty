import AppKit
import Foundation
import GhosttyKit
import UniformTypeIdentifiers

enum GhosttyClipboardLocation: Hashable, Sendable {
    case standard
    case selection

    init?(cValue: ghostty_clipboard_e) {
        switch cValue {
        case GHOSTTY_CLIPBOARD_STANDARD:
            self = .standard
        case GHOSTTY_CLIPBOARD_SELECTION:
            self = .selection
        default:
            return nil
        }
    }
}

struct GhosttyClipboardContent: Equatable, Sendable {
    let mime: String
    let data: String

    init(mime: String, data: String) {
        self.mime = mime
        self.data = data
    }

    init?(cValue: ghostty_clipboard_content_s) {
        guard let mime = cValue.mime,
            let data = cValue.data,
            let ownedMIME = String(validatingCString: mime),
            let ownedData = String(validatingCString: data)
        else { return nil }

        self.init(mime: ownedMIME, data: ownedData)
    }

    static func copying(
        _ pointer: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> [GhosttyClipboardContent] {
        UnsafeBufferPointer(start: pointer, count: count).compactMap {
            GhosttyClipboardContent(cValue: $0)
        }
    }
}

enum GhosttyClipboardConfirmationKind: Equatable, Sendable {
    case paste
    case osc52Read
    case osc52Write

    init?(cValue: ghostty_clipboard_request_e) {
        switch cValue {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            self = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            self = .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            self = .osc52Write
        default:
            return nil
        }
    }
}

struct GhosttyClipboardConfirmationRequest: Equatable, Sendable {
    let id: UUID
    let paneID: PaneID
    let kind: GhosttyClipboardConfirmationKind
    let location: GhosttyClipboardLocation
    let contents: [GhosttyClipboardContent]
}

enum GhosttyClipboardConfirmationResponse: Equatable, Sendable {
    case deny
    case allow
}

enum GhosttyClipboardConfirmationEvent: Sendable {
    case request(
        GhosttyClipboardConfirmationRequest,
        response: @MainActor @Sendable (GhosttyClipboardConfirmationResponse) -> Void
    )
    case invalidate(PaneID)
}

typealias GhosttyClipboardConfirmationHandler =
    @MainActor (GhosttyClipboardConfirmationEvent) -> Void

@MainActor
struct GhosttyClipboardClient {
    typealias Read = @MainActor @Sendable (GhosttyClipboardLocation) -> String?
    typealias Write =
        @MainActor @Sendable (GhosttyClipboardLocation, [GhosttyClipboardContent]) -> Void

    static let selectionPasteboardName = "com.dntsk.GhostTerm.selection"

    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name(selectionPasteboardName)
    )

    private let readValue: Read
    private let writeValue: Write

    init(read: @escaping Read, write: @escaping Write) {
        readValue = read
        writeValue = write
    }

    func read(_ location: GhosttyClipboardLocation) -> String? {
        readValue(location)
    }

    func write(
        _ location: GhosttyClipboardLocation,
        _ contents: [GhosttyClipboardContent]
    ) {
        writeValue(location, contents)
    }

    static let system = GhosttyClipboardClient(
        read: { location in
            let pasteboard = pasteboard(for: location)
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return opinionatedString(
                urls: urls,
                fallback: pasteboard.string(forType: .string)
            )
        },
        write: { location, contents in
            let pasteboard = pasteboard(for: location)
            let mapped = contents.compactMap { content -> (NSPasteboard.PasteboardType, String)? in
                guard let type = pasteboardType(for: content.mime) else { return nil }
                return (type, content.data)
            }
            guard !mapped.isEmpty else { return }

            pasteboard.clearContents()
            pasteboard.declareTypes(mapped.map(\.0), owner: nil)
            for (type, data) in mapped {
                pasteboard.setString(data, forType: type)
            }
        }
    )

    static func pasteboardType(for mime: String) -> NSPasteboard.PasteboardType? {
        switch mime {
        case "text/plain":
            return .string
        case "text/html":
            return .html
        default:
            break
        }

        if let type = UTType(mimeType: mime) {
            return NSPasteboard.PasteboardType(type.identifier)
        }
        return NSPasteboard.PasteboardType(mime)
    }

    static func opinionatedString(urls: [URL], fallback: String?) -> String? {
        guard !urls.isEmpty else { return fallback }
        return urls.map { url in
            url.isFileURL ? shellEscape(url.path) : url.absoluteString
        }.joined(separator: " ")
    }

    private static func pasteboard(for location: GhosttyClipboardLocation) -> NSPasteboard {
        switch location {
        case .standard:
            return .general
        case .selection:
            // The app namespace intentionally preserves upstream's separate-board semantics.
            return selectionPasteboard
        }
    }

    // Adapted from Ghostty.Shell.swift at 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28.
    private static func shellEscape(_ value: String) -> String {
        let characters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = value
        for character in characters {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return result
    }
}
