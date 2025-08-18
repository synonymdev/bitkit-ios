import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private var shareText: String {
        return localizedString(
            "settings__about__shareText",
            variables: ["appStoreUrl": Env.appStoreUrl, "playStoreUrl": Env.playStoreUrl]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(localizedString("settings__about__text"))
                .padding(.vertical, 16)

            VStack(spacing: 0) {
                Button(action: {
                    openURL(URL(string: Env.termsOfServiceUrl)!)
                }) {
                    SettingsListLabel(title: localizedString("settings__about__legal"))
                }

                ShareLink(
                    item: shareText,
                    message: Text(shareText)
                ) {
                    SettingsListLabel(title: localizedString("settings__about__share"))
                }

                Button(action: {
                    openURL(URL(string: Env.githubReleasesUrl)!)
                }) {
                    SettingsListLabel(
                        title: localizedString("settings__about__version"),
                        rightText: appVersion,
                        rightIcon: nil
                    )
                }
            }

            Spacer(minLength: 32)

            VStack(alignment: .center, spacing: 0) {
                Image("logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 82)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 32)

            Social()
        }
        .navigationTitle(localizedString("settings__about__title"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationView {
        AboutView()
    }
    .preferredColorScheme(.dark)
}
