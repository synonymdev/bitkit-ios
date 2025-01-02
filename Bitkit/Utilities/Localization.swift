import Foundation
import SwiftUI

// MARK: - Translation Section Type
enum TranslationSection: String, CaseIterable {
    case onboarding, wallet, common, settings, lightning, cards, fee
}

// MARK: - Translation Function Type
struct Translation {
    let section: TranslationSection
    
    func callAsFunction(_ key: String, _ args: [String: String] = [:]) -> String {
        LocalizationManager.shared.t(section: section, key: key, args: args)
    }
}

// MARK: - Global Translation Functions
func t(_ key: String, _ args: [String: String] = [:]) -> String {
    // Default to common section if no section specified
    LocalizationManager.shared.t(section: .common, key: key, args: args)
}

// MARK: - Translation Hook
func useTranslation(_ section: TranslationSection) -> Translation {
    Translation(section: section)
}

// MARK: - Localization Manager
class LocalizationManager {
    static let shared = LocalizationManager()
    private var currentLanguage: String
    private var translations: [TranslationSection: [String: Any]] = [:]
    
    private init() {
        self.currentLanguage = Locale.current.languageCode ?? "en"
        loadTranslations()
    }
    
    func loadTranslations() {
        translations = [:] // Clear existing translations
        
        // First load English as base translations
        for section in TranslationSection.allCases {
            let filename = "en_\(section.rawValue)"
            if let url = Bundle.main.url(forResource: filename, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                translations[section] = json
            }
        }
        
        // Then overlay requested language if it's not English
        if currentLanguage != "en" {
            for section in TranslationSection.allCases {
                let filename = "\(currentLanguage)_\(section.rawValue)"
                if let url = Bundle.main.url(forResource: filename, withExtension: "json"),
                   let data = try? Data(contentsOf: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Merge with existing translations for this section
                    if let existing = translations[section] {
                        var merged = existing
                        merged.merge(json) { _, new in new }
                        translations[section] = merged
                    } else {
                        translations[section] = json
                    }
                }
            }
        }
    }
    
    func t(section: TranslationSection, key: String, args: [String: String] = [:]) -> String {
        // Try to get translation from specified section
        if let translation = getTranslation(from: section, key: key, args: args) {
            return translation
        }
        
        // If not found and section isn't already common, try common section
        if section != .common {
            if let commonTranslation = getTranslation(from: .common, key: key, args: args) {
                return commonTranslation
            }
        }
        
        // If still not found, return the key
        Logger.warn("Missing translation key: \(key) in both \(section) and common sections")
        return key
    }
    
    // Helper function to get translation from a specific section
    private func getTranslation(from section: TranslationSection, key: String, args: [String: String]) -> String? {
        guard let sectionTranslations = translations[section] else {
            return nil
        }
        
        var current: Any = sectionTranslations
        let keyPath = key.split(separator: ".")
        
        // Navigate through nested dictionary
        for component in keyPath {
            guard let dict = current as? [String: Any],
                  let value = dict[String(component)] else {
                return nil
            }
            current = value
        }
        
        // Handle the nested "string" property in the JSON
        guard let stringDict = current as? [String: Any],
              let finalString = stringDict["string"] as? String else {
            return nil
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
