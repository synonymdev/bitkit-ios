import Foundation

/// Rewrites Core types that bitkit-android encoded with kotlinx.serialization into the shape Swift's
/// synthesized `Codable` reads, so a backup made on Android restores here.
///
/// kotlinx differs from `Codable` in two ways these envelopes hit: it writes an `Activity` as
/// `{"type":"com.synonym.bitkitcore.Activity.Onchain","v1":record}` instead of `{"onchain":{"_0":record}}`,
/// and an enum as `"REGTEST"` instead of `{"regtest":{}}`. Envelopes this app wrote pass through
/// unchanged. Explicit nulls need nothing: `Codable` reads them as nil.
enum AndroidBackupJson {
    /// Fields of the Core types in the ACTIVITY and BLOCKTANK envelopes that hold an enum.
    private static let enumFields: Set<String> = ["txType", "status", "state", "state2", "network"]

    static func normalized(_ dataBytes: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: dataBytes),
              let data = try? JSONSerialization.data(withJSONObject: normalize(root))
        else { return dataBytes }
        return data
    }

    private static func normalize(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(normalize)
        }
        guard var object = value as? [String: Any] else { return value }

        if let type = object["type"] as? String, let record = object["v1"], object.count == 2 {
            return [swiftCase(type.components(separatedBy: ".").last ?? type): ["_0": normalize(record)]]
        }
        for (key, field) in object {
            if enumFields.contains(key), let name = field as? String, isKotlinEnumName(name) {
                object[key] = [swiftCase(name): [String: Any]()]
            } else {
                object[key] = normalize(field)
            }
        }
        return object
    }

    private static func isKotlinEnumName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "_" }
    }

    private static func swiftCase(_ name: String) -> String {
        let words = name.split(separator: "_").map { $0.lowercased() }
        guard let head = words.first else { return name.lowercased() }
        if words.count == 1, name.contains(where: \.isLowercase) {
            return name.prefix(1).lowercased() + name.dropFirst()
        }
        return head + words.dropFirst().map(\.capitalized).joined()
    }
}
