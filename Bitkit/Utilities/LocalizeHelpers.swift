import Foundation

/// Centralized localization helper with English fallback support
enum LocalizationHelper {
    private static let notFoundValue = "___NOTFOUND___"
    private static let appGroupSuiteName = "group.bitkit"
    private static let selectedLanguageCodeKey = "selectedLanguageCode"

    private struct PluralArgument: Decodable {
        let name: String
        let isPlural: Bool
    }

    private static var currentLanguageCode: String {
        let appGroupCode = UserDefaults(suiteName: appGroupSuiteName)?.string(forKey: selectedLanguageCodeKey) ?? ""
        if !appGroupCode.isEmpty {
            return appGroupCode
        }

        let standardCode = UserDefaults.standard.string(forKey: selectedLanguageCodeKey) ?? ""
        if !standardCode.isEmpty {
            return standardCode
        }

        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Checks if a localization key exists in a specific bundle
    private static func keyExists(in bundle: Bundle, key: String) -> Bool {
        let result = NSLocalizedString(key, bundle: bundle, value: notFoundValue, comment: "")
        return result != notFoundValue
    }

    /// Gets a localized string with English fallback
    static func getString(for key: String, comment: String = "") -> String {
        guard let resource = localizedResource(for: key) else { return key }
        return NSLocalizedString(key, bundle: resource.bundle, comment: comment)
    }

    /// Formats synchronized plural translations using Foundation's locale-aware rules.
    static func getPluralString(for key: String, comment: String = "", arguments: [String: Any]) -> String {
        guard let resource = localizedResource(for: key) else { return key }
        let source = NSLocalizedString(key, bundle: resource.bundle, comment: comment)
        let fallback = arguments.reduce(source) { result, argument in
            result.replacingOccurrences(of: "{\(argument.key)}", with: String(describing: argument.value))
        }
        guard let metadataURL = resource.bundle.url(forResource: "PluralArguments", withExtension: "plist"),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? PropertyListDecoder().decode([String: [PluralArgument]].self, from: data),
              let parameters = metadata[key]
        else {
            return fallback
        }

        var values: [CVarArg] = []
        for parameter in parameters {
            guard let value = arguments[parameter.name] else { return fallback }
            if parameter.isPlural {
                guard let count = integerCount(value) else { return fallback }
                values.append(count)
            } else {
                values.append(String(describing: value))
            }
        }

        let format = resource.bundle.localizedString(forKey: key, value: key, table: "LocalizablePlurals")
        guard format != key else { return fallback }
        return String(format: format, locale: Locale(identifier: resource.languageCode), arguments: values)
    }

    private static func integerCount(_ value: Any) -> Int64? {
        if let count = value as? Int64 {
            return count
        }
        if let count = value as? UInt64 {
            return Int64(exactly: count)
        }
        if let count = value as? Double {
            return Int64(exactly: count)
        }
        return Int64(String(describing: value))
    }

    private static func localizedResource(for key: String) -> (bundle: Bundle, languageCode: String)? {
        let languageCode = currentLanguageCode

        guard let englishBundle = getBundle(for: "en") else { return nil }

        // If requesting English or if selected language bundle doesn't exist
        guard languageCode != "en", let selectedBundle = getBundle(for: languageCode) else {
            return (englishBundle, "en")
        }

        if keyExists(in: selectedBundle, key: key) {
            return (selectedBundle, languageCode)
        } else {
            return (englishBundle, "en")
        }
    }

    /// Gets a bundle for the specified language code
    private static func getBundle(for languageCode: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}

// MARK: - Public API

/// The main function for getting a localized string
func t(_ key: String, comment: String = "", variables: [String: String] = [:]) -> String {
    var localizedString = LocalizationHelper.getString(for: key, comment: comment)

    // Replace variables
    for (name, value) in variables {
        localizedString = localizedString.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return localizedString
}

func tPlural(_ key: String, comment: String = "", arguments: [String: Any] = [:]) -> String {
    return LocalizationHelper.getPluralString(for: key, comment: comment, arguments: arguments)
}

/// Get a random line from a localized string
func localizedRandom(_ key: String, comment: String = "") -> String {
    let localizedString = LocalizationHelper.getString(for: key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")
    guard components.count > 1 else { return localizedString }
    return components.randomElement() ?? localizedString
}
