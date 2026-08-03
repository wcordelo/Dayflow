import Foundation

/// The iOS secure-store wire representation of every account key version
/// retained for local event replay. Key bytes are base64 only inside this
/// Keychain-protected blob and are never sent to the relay.
public struct DayflowMobileAccountKeyRing: Codable, Equatable, Sendable {
    public let activeKeyVersion: UInt32
    public let keys: [String: String]

    public init(activeKeyVersion: UInt32, keyData: [UInt32: Data]) throws {
        guard activeKeyVersion > 0,
              keyData.isEmpty == false,
              keyData[activeKeyVersion]?.count == 32,
              keyData.keys.allSatisfy({ $0 > 0 })
        else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        self.activeKeyVersion = activeKeyVersion
        self.keys = keyData.reduce(into: [:]) { result, entry in
            result[String(entry.key)] = entry.value.base64EncodedString()
        }
    }

    public init(rootKey: Data) throws {
        try self.init(activeKeyVersion: 1, keyData: [1: rootKey])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let activeKeyVersion = try container.decode(UInt32.self, forKey: .activeKeyVersion)
        let keys = try container.decode([String: String].self, forKey: .keys)
        guard let activeEncoded = keys[String(activeKeyVersion)],
              let activeData = Data(base64Encoded: activeEncoded),
              activeKeyVersion > 0,
              keys.isEmpty == false,
              keys.keys.allSatisfy({ (UInt32($0) ?? 0) > 0 }),
              activeData.count == 32,
              keys.values.allSatisfy({ Data(base64Encoded: $0)?.count == 32 })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .keys,
                in: container,
                debugDescription: "Dayflow account key ring contains invalid key material"
            )
        }
        self.activeKeyVersion = activeKeyVersion
        self.keys = keys
    }

    private enum CodingKeys: String, CodingKey {
        case activeKeyVersion = "active_key_version"
        case keys
    }

    public var jsonData: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public func keyData(for version: UInt32) -> Data? {
        guard let encoded = keys[String(version)],
              let data = Data(base64Encoded: encoded),
              data.count == 32
        else { return nil }
        return data
    }

    public func adding(
        _ key: Data,
        version: UInt32,
        active: Bool = false
    ) throws -> DayflowMobileAccountKeyRing {
        var keyData = keys.reduce(into: [UInt32: Data]()) { result, entry in
            guard let version = UInt32(entry.key),
                  let data = Data(base64Encoded: entry.value)
            else { return }
            result[version] = data
        }
        keyData[version] = key
        return try DayflowMobileAccountKeyRing(
            activeKeyVersion: active ? version : activeKeyVersion,
            keyData: keyData
        )
    }

    public func withActiveVersion(_ version: UInt32) throws -> DayflowMobileAccountKeyRing {
        guard keyData(for: version) != nil else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        let keyData = keys.reduce(into: [UInt32: Data]()) { result, entry in
            guard let version = UInt32(entry.key),
                  let data = Data(base64Encoded: entry.value)
            else { return }
            result[version] = data
        }
        return try DayflowMobileAccountKeyRing(activeKeyVersion: version, keyData: keyData)
    }
}
