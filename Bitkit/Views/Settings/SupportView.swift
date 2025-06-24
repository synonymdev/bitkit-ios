import SwiftUI

struct SupportView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(localizedString("settings__support__text"))
                .padding(.vertical, 16)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                NavigationLink(destination: ReportIssue()) {
                    SettingsListLabel(title: localizedString("settings__support__report"))
                }

                Button(action: {
                    openURL(URL(string: Env.helpUrl)!)
                }) {
                    SettingsListLabel(title: localizedString("settings__support__help"))
                }

                NavigationLink(destination: AppStatusView()) {
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
            .padding(.horizontal, 16)

            Spacer(minLength: 32)

            Social()
                .padding(.horizontal, 16)
        }
        .padding(.top, 16)
        .navigationTitle(localizedString("settings__support__title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        SupportView()
    }
    .preferredColorScheme(.dark)
}
