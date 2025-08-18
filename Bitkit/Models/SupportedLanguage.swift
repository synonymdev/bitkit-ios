import Foundation

/// Represents a supported language in the app
struct SupportedLanguage: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let name: String
    let localizedName: String

    init(code: String, name: String, localizedName: String? = nil) {
        self.code = code
        self.name = name
        self.localizedName = localizedName ?? name
    }
}

extension SupportedLanguage {
    /// All supported languages in the app based on available .lproj folders
    static let allLanguages: [SupportedLanguage] = [
        SupportedLanguage(code: "en", name: "English"),
        SupportedLanguage(code: "es", name: "Spanish", localizedName: "Español"),
        SupportedLanguage(code: "es-419", name: "Spanish (Latin America)", localizedName: "Español (Latinoamérica)"),
        SupportedLanguage(code: "fr", name: "French", localizedName: "Français"),
        SupportedLanguage(code: "de", name: "German", localizedName: "Deutsch"),
        SupportedLanguage(code: "it", name: "Italian", localizedName: "Italiano"),
        SupportedLanguage(code: "pt", name: "Portuguese", localizedName: "Português"),
        SupportedLanguage(code: "pt-BR", name: "Portuguese (Brazil)", localizedName: "Português (Brasil)"),
        SupportedLanguage(code: "ru", name: "Russian", localizedName: "Русский"),
        SupportedLanguage(code: "nl", name: "Dutch", localizedName: "Nederlands"),
        SupportedLanguage(code: "pl", name: "Polish", localizedName: "Polski"),
        SupportedLanguage(code: "el", name: "Greek", localizedName: "Ελληνικά"),
        SupportedLanguage(code: "ca", name: "Catalan", localizedName: "Català"),
        SupportedLanguage(code: "cs", name: "Czech", localizedName: "Čeština"),
        SupportedLanguage(code: "ar", name: "Arabic", localizedName: "العربية"),
    ]

    /// Safe fallback to English language
    static var english: SupportedLanguage {
        return allLanguages.first { $0.code == "en" }!
    }

    /// Finds a language by code with English fallback
    static func language(for code: String) -> SupportedLanguage {
        return allLanguages.first { $0.code == code } ?? english
    }
}
