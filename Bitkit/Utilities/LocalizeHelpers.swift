import Foundation

/// Centralized localization helper with English fallback support
struct LocalizationHelper {
    private static let notFoundValue = "___NOTFOUND___"

    /// Gets the current language code from user preferences
    private static var currentLanguageCode: String {
        let storedCode = UserDefaults.standard.string(forKey: "selectedLanguageCode") ?? ""
        let deviceLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"
        return storedCode.isEmpty ? deviceLanguageCode : storedCode
    }

    /// Checks if a localization key exists in a specific bundle
    private static func keyExists(in bundle: Bundle, key: String) -> Bool {
        let result = NSLocalizedString(key, bundle: bundle, value: notFoundValue, comment: "")
        return result != notFoundValue
    }

    /// Gets a localized string with English fallback
    static func getString(for key: String, comment: String = "") -> String {
        let languageCode = currentLanguageCode

        // Get English bundle for fallback
        guard let englishBundle = getBundle(for: "en") else {
            return key // Ultimate fallback
        }

        // If requesting English or if selected language bundle doesn't exist
        guard languageCode != "en", let selectedBundle = getBundle(for: languageCode) else {
            return getStringFromBundle(englishBundle, key: key, comment: comment)
        }

        // Try selected language first, fallback to English if key missing
        if keyExists(in: selectedBundle, key: key) {
            return NSLocalizedString(key, bundle: selectedBundle, comment: comment)
        } else {
            return getStringFromBundle(englishBundle, key: key, comment: comment)
        }
    }

    /// Gets a bundle for the specified language code
    private static func getBundle(for languageCode: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    /// Gets a string from a bundle with optional key fallback
    private static func getStringFromBundle(_ bundle: Bundle, key: String, comment: String) -> String {
        if keyExists(in: bundle, key: key) {
            return NSLocalizedString(key, bundle: bundle, comment: comment)
        } else {
            return key
        }
    }
}

// MARK: - Public API

func localizedString(_ key: String, comment: String = "", variables: [String: String] = [:]) -> String {
    var localizedString = LocalizationHelper.getString(for: key, comment: comment)

    // Replace variables
    for (name, value) in variables {
        localizedString = localizedString.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return localizedString
}

func localizedRandom(_ key: String, comment: String = "") -> String {
    let localizedString = LocalizationHelper.getString(for: key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")
    guard components.count > 1 else { return localizedString }
    return components.randomElement() ?? localizedString
}
