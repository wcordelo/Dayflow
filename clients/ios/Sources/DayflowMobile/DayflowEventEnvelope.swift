import Foundation

public struct DayflowEventEnvelope: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maxLogicalClock: UInt64 = 9_007_199_254_740_991

    public let eventID: String
    public let deviceID: String
    public let logicalClock: UInt64
    public let schemaVersion: UInt16
    public let keyVersion: UInt32
    public let nonce: String
    public let ciphertext: String

    public var id: String { eventID }

    public init(
        eventID: String,
        deviceID: String,
        logicalClock: UInt64,
        schemaVersion: UInt16,
        keyVersion: UInt32,
        nonce: String,
        ciphertext: String
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.logicalClock = logicalClock
        self.schemaVersion = schemaVersion
        self.keyVersion = keyVersion
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case deviceID = "device_id"
        case logicalClock = "logical_clock"
        case schemaVersion = "schema_version"
        case keyVersion = "key_version"
        case nonce
        case ciphertext
    }
}

/// The Rust core and relay accept padded/unpadded standard or URL-safe
/// base64. Native persistence applies the same envelope-shape gate before an
/// opaque value can enter the local outbox.
enum DayflowWireEnvelopeValidation {
    private static let eventNonceBytes = 24
    private static let eventAuthTagBytes = 16

    static func hasValidEncryptedFieldShape(nonce: String, ciphertext: String) -> Bool {
        guard let nonceData = decode(nonce), let ciphertextData = decode(ciphertext) else {
            return false
        }
        return nonceData.count == eventNonceBytes && ciphertextData.count >= eventAuthTagBytes
    }

    static func decode(_ value: String) -> Data? {
        guard value.isEmpty == false else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 43, 45, 47, 48...57, 61, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }) else {
            return nil
        }

        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let unpadded: String
        if let paddingIndex = normalized.firstIndex(of: "=") {
            guard normalized.count.isMultiple(of: 4),
                  normalized[paddingIndex...].allSatisfy({ $0 == "=" }),
                  normalized.distance(from: paddingIndex, to: normalized.endIndex) <= 2
            else { return nil }
            unpadded = String(normalized[..<paddingIndex])
        } else {
            unpadded = normalized
        }
        guard unpadded.utf8.count % 4 != 1 else { return nil }
        let padding = String(repeating: "=", count: (4 - unpadded.utf8.count % 4) % 4)
        return Data(base64Encoded: unpadded + padding)
    }
}
