import Foundation
import SwiftUI

/// Manages the app's language settings and provides dynamic language switching
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var currentLanguage: SupportedLanguage
    @AppStorage("selectedLanguageCode") private var selectedLanguageCode: String = ""

    private init() {
        // Initialize stored properties first
        currentLanguage = .english

        // Then set the actual current language
        let deviceLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"

        if selectedLanguageCode.isEmpty {
            currentLanguage = SupportedLanguage.language(for: deviceLanguageCode)
        } else {
            currentLanguage = SupportedLanguage.language(for: selectedLanguageCode)
        }
    }

    /// Sets the app language and persists the selection
    func setLanguage(_ language: SupportedLanguage) {
        currentLanguage = language
        selectedLanguageCode = language.code

        // Set the language preference for the current session
        UserDefaults.standard.set([language.code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

    /// Gets the display name of the current language in the current language
    var currentLanguageDisplayName: String {
        return currentLanguage.localizedName
    }
}
