import CoreFoundation
import Foundation

enum StateMigrationError: Error, Equatable, Sendable {
    case missingVersion
    case nullVersion
    case nonIntegerVersion
    case unsupportedOlderVersion(Int)
    case unsupportedNewerVersion(Int)
}

enum StateMigration {
    static func decode(_ data: Data) throws -> ApplicationState {
        let version = try probeVersion(in: data)
        switch version {
        case ApplicationState.currentVersion:
            return try JSONDecoder().decode(ApplicationState.self, from: data)
        case ..<ApplicationState.currentVersion:
            throw StateMigrationError.unsupportedOlderVersion(version)
        default:
            throw StateMigrationError.unsupportedNewerVersion(version)
        }
    }

    private static func probeVersion(in data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any],
            let value = document["version"]
        else {
            throw StateMigrationError.missingVersion
        }
        guard !(value is NSNull) else {
            throw StateMigrationError.nullVersion
        }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw StateMigrationError.nonIntegerVersion
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
            doubleValue.rounded(.towardZero) == doubleValue,
            let version = Int(exactly: doubleValue)
        else {
            throw StateMigrationError.nonIntegerVersion
        }
        return version
    }
}
