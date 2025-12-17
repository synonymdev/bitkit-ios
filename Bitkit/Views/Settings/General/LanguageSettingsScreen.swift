import SwiftUI

struct LanguageSettingsScreen: View {
    @StateObject private var languageManager = LanguageManager.shared
    @State private var showAlert = false

    private func languageRow(_ language: SupportedLanguage) -> some View {
        Button(action: {
            selectLanguage(language)
        }) {
            SettingsListLabel(
                title: language.name,
                rightIcon: languageManager.currentLanguage.code == language.code ? .checkmark : nil
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func selectLanguage(_ language: SupportedLanguage) {
        guard language.code != languageManager.currentLanguage.code else { return }

        languageManager.setLanguage(language)
        showAlert = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__language_title"))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("settings__general__language_other"))
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(SupportedLanguage.allLanguages, id: \.id) { language in
                        languageRow(language)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(t("settings__general__language_changed_title"), isPresented: $showAlert) {
            Button(t("common__ok"), role: .cancel) {}
        } message: {
            Text(t("settings__general__language_changed_message"))
        }
    }
}
