import Foundation

/// Validates the complete APNs payload before it can wake encrypted sync.
///
/// `aps.content-available` is the only APNs control field permitted here and
/// `kind` is the only application field. The relay cursor and encrypted event
/// envelopes remain the source of truth; a notification must never carry
/// journal, capture, or projection content.
enum DayflowMobilePushWakeContract {
    static let syncAvailable = "sync_available"

    static func accepts(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo.count == 2,
              userInfo.keys.allSatisfy({ key in
                  guard let key = key as? String else { return false }
                  return key == "aps" || key == "kind"
              }),
              userInfo["kind"] as? String == syncAvailable,
              let aps = userInfo["aps"] as? [AnyHashable: Any],
              aps.count == 1,
              aps.keys.allSatisfy({ ($0 as? String) == "content-available" }),
              let contentAvailable = aps["content-available"]
        else {
            return false
        }

        if contentAvailable is Bool {
            return false
        }
        if let integer = contentAvailable as? Int {
            return integer == 1
        }
        if let number = contentAvailable as? NSNumber {
            // JSON booleans bridge to NSNumber too; reject them before
            // accepting the numeric silent-push value.
            return number.intValue == 1
                && String(cString: number.objCType) != "c"
        }
        return false
    }
}
