import Foundation
import SwiftUI
import WidgetKit

/// Manages the app's language settings and provides dynamic language switching
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// App Group used to mirror the selected language so the WidgetKit extension can read it
    /// (widget extensions have a separate `UserDefaults.standard`).
    private static let appGroupSuiteName = "group.bitkit"
    private static let selectedLanguageCodeKey = "selectedLanguageCode"

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

        // Backfill App Group for existing installs that selected a language before the
        // widget extension shipped.
        syncSelectedLanguageToAppGroup(selectedLanguageCode)
    }

    /// Sets the app language and persists the selection
    func setLanguage(_ language: SupportedLanguage) {
        currentLanguage = language
        selectedLanguageCode = language.code

        // Set the language preference for the current session
        UserDefaults.standard.set([language.code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()

        syncSelectedLanguageToAppGroup(language.code)
    }

    /// Mirrors the selected language into the App Group and refreshes home-screen widget
    /// timelines so they pick up the new locale.
    private func syncSelectedLanguageToAppGroup(_ code: String) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupSuiteName) else { return }
        defaults.set(code, forKey: Self.selectedLanguageCodeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Gets the display name of the current language in the current language
    var currentLanguageDisplayName: String {
        return currentLanguage.localizedName
    }
}
