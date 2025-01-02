import Foundation
import SwiftUI

// MARK: - Global Translation Function
func t(_ key: String, _ args: [String: String] = [:]) -> String {
    LocalizationManager.shared.t(key, args)
}

// MARK: - Localization Manager
class LocalizationManager {
    static let shared = LocalizationManager()
    private var currentLanguage: String
    private var translations: [String: Any] = [:]
    
    private init() {
        self.currentLanguage = Locale.current.languageCode ?? "en"
        loadTranslations()
    }
    
    func loadTranslations() {
        let sections = ["onboarding", "wallet", "common", "settings", "lightning", "cards", "fee"]
        
        for section in sections {
            // Use the full language path to avoid filename conflicts
            let filename = "\(currentLanguage)_\(section)"
            guard let url = Bundle.main.url(forResource: filename, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            translations.merge(json) { current, _ in current }
        }
    }
    
    func t(_ key: String, _ args: [String: String] = [:]) -> String {
        let keyPath = key.split(separator: ".")
        var current: Any = translations
        
        // Navigate through nested dictionary
        for component in keyPath {
            guard let dict = current as? [String: Any],
                  let value = dict[String(component)]
            else {
                return key
            }
            current = value
        }
        
        // Handle the nested "string" property in the JSON
        guard let stringDict = current as? [String: Any],
              let finalString = stringDict["string"] as? String
        else {
            return key
        }
        
        var result = finalString
        // Replace any variables in the string
        for (key, value) in args {
            result = result.replacingOccurrences(of: "{{" + key + "}}", with: value)
        }
        return result.replacingOccurrences(of: "<accent>", with: "")
            .replacingOccurrences(of: "</accent>", with: "")
    }
    
    func setLanguage(_ lang: String) {
        currentLanguage = lang
        loadTranslations()
    }
}
