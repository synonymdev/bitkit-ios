import SwiftUI

struct SupportView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(localizedString("settings__support__text"))
                .padding(.vertical, 16)

            VStack(spacing: 0) {
                NavigationLink(value: Route.reportIssue) {
                    SettingsListLabel(title: localizedString("settings__support__report"))
                }

                Button(action: {
                    openURL(URL(string: Env.helpUrl)!)
                }) {
                    SettingsListLabel(title: localizedString("settings__support__help"))
                }

                NavigationLink(value: Route.appStatus) {
                    SettingsListLabel(
                        title: localizedString("settings__support__status")
                    )
                }
            }

            Spacer(minLength: 32)

            VStack {
                Image("question-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 256)
            }

            Spacer(minLength: 32)

            Social()
        }
        .navigationTitle(localizedString("settings__support__title"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationView {
        SupportView()
    }
    .preferredColorScheme(.dark)
}
