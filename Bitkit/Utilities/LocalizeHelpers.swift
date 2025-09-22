import Foundation

/// Centralized localization helper with English fallback support
enum LocalizationHelper {
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

    /// Formats a string using ICU MessageFormat with pluralization support
    static func formatPlural(_ pattern: String, arguments: [String: Any], locale: Locale = Locale.current) -> String {
        return formatterPlural(pattern, arguments: arguments)
    }

    // TODO: implement a ICU message format library
    /// Fallback pluralization formatter for when ICU MessageFormat isn't available
    private static func formatterPlural(_ pattern: String, arguments: [String: Any]) -> String {
        var result = pattern

        // Handle basic plural syntax: {count, plural, one {...} other {...}}
        let pluralRegex = try! NSRegularExpression(pattern: "\\{(\\w+),\\s*plural,\\s*one\\s*\\{([^}]+)\\}\\s*other\\s*\\{([^}]+)\\}\\}", options: [])

        let matches = pluralRegex.matches(in: pattern, options: [], range: NSRange(location: 0, length: pattern.count))

        for match in matches.reversed() { // Process in reverse to maintain string indices
            let fullMatchRange = match.range
            let countVarRange = match.range(at: 1)
            let oneFormRange = match.range(at: 2)
            let otherFormRange = match.range(at: 3)

            let countVarName = String(pattern[Range(countVarRange, in: pattern)!])
            let oneForm = String(pattern[Range(oneFormRange, in: pattern)!])
            let otherForm = String(pattern[Range(otherFormRange, in: pattern)!])

            if let countValue = arguments[countVarName] {
                let count: Int = if let intValue = countValue as? Int {
                    intValue
                } else if let doubleValue = countValue as? Double {
                    Int(doubleValue)
                } else if let stringValue = countValue as? String, let intValue = Int(stringValue) {
                    intValue
                } else {
                    0
                }

                let selectedForm = (count == 1) ? oneForm : otherForm
                var processedForm = selectedForm.replacingOccurrences(of: "#", with: "\(count)")

                // Replace other variables in the selected form
                for (key, value) in arguments {
                    if key != countVarName {
                        processedForm = processedForm.replacingOccurrences(of: "{\(key)}", with: "\(value)")
                    }
                }

                result = result.replacingCharacters(in: Range(fullMatchRange, in: result)!, with: processedForm)
            }
        }

        // Replace any remaining simple variables
        for (key, value) in arguments {
            result = result.replacingOccurrences(of: "{\(key)}", with: "\(value)")
        }

        return result
    }
}

// MARK: - Public API

// The main function for getting a localized string
func t(_ key: String, comment: String = "", variables: [String: String] = [:]) -> String {
    var localizedString = LocalizationHelper.getString(for: key, comment: comment)

    // Replace variables
    for (name, value) in variables {
        localizedString = localizedString.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return localizedString
}

func tPlural(_ key: String, comment: String = "", arguments: [String: Any] = [:]) -> String {
    let localizedString = LocalizationHelper.getString(for: key, comment: comment)
    return LocalizationHelper.formatPlural(localizedString, arguments: arguments)
}

// These are for keys that are not yet translated
func tTodo(_ key: String, comment: String = "", variables: [String: String] = [:]) -> String {
    var localizedString = key

    // Replace variables
    for (name, value) in variables {
        localizedString = localizedString.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return localizedString
}

// Get a random line from a localized string
func localizedRandom(_ key: String, comment: String = "") -> String {
    let localizedString = LocalizationHelper.getString(for: key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")
    guard components.count > 1 else { return localizedString }
    return components.randomElement() ?? localizedString
}
