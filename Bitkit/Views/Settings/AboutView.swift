import SwiftUI

struct DiagonalCut: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let leftCutX = rect.maxX * 0.15
        path.move(to: CGPoint(x: leftCutX, y: rect.maxY))

        let topCutY = rect.maxY * 0.63
        path.addLine(to: CGPoint(x: rect.maxX, y: topCutY))

        // Line to the top-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Line to the bottom-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        // Line to the bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        // Close the path back to the starting point
        path.closeSubpath()

        return path
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private var shareText: String {
        return t(
            "settings__about__shareText",
            variables: ["appStoreUrl": Env.appStoreUrl, "playStoreUrl": Env.playStoreUrl]
        )
    }

    var body: some View {
        ZStack {
            // Orange diagonal background
            Color.brandAccent
                .clipShape(DiagonalCut())
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                NavigationBar(title: t("settings__about__title"))
                    .padding(.bottom, 16)

                BodyMText(t("settings__about__text"))
                    .padding(.vertical, 16)

                VStack(spacing: 0) {
                    Button(action: {
                        openURL(URL(string: Env.termsOfServiceUrl)!)
                    }) {
                        SettingsListLabel(title: t("settings__about__legal"))
                    }

                    ShareLink(item: shareText, message: Text(shareText)) {
                        SettingsListLabel(title: t("settings__about__share"))
                    }

                    Button(action: {
                        openURL(URL(string: Env.githubReleasesUrl)!)
                    }) {
                        SettingsListLabel(
                            title: t("settings__about__version"),
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
                .padding(.bottom, 32)

                Social(backgroundColor: .clear)
            }
            .navigationBarHidden(true)
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
    }
}

#Preview {
    NavigationView {
        AboutView()
    }
    .preferredColorScheme(.dark)
}
