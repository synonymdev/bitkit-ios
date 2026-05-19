import Foundation
import SwiftUI
import WidgetKit

/// Manages the app's language settings and provides dynamic language switching
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    nonisolated static let appGroupSuiteName = "group.bitkit"
    nonisolated static let selectedLanguageCodeKey = "selectedLanguageCode"

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

    private func syncSelectedLanguageToAppGroup(_ code: String) {
        Self.mirrorToAppGroup(code: code)
    }

    /// Thread-safe mirror of the language code into the App Group, suitable for callers that
    /// can't reach the `@MainActor` instance (e.g. `MigrationsService` writing during restore
    /// flows). `UserDefaults` and `WidgetCenter` are both safe to call off the main actor.
    nonisolated static func mirrorToAppGroup(code: String) {
        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else { return }
        defaults.set(code, forKey: selectedLanguageCodeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Gets the display name of the current language in the current language
    var currentLanguageDisplayName: String {
        return currentLanguage.localizedName
    }
}
