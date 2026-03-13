import SwiftUI

private struct DiagonalCut: Shape {
    var cornerRadius: CGFloat = 36

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.width / 4, rect.height / 4)

        let leftCutY = rect.maxY - 210
        path.move(to: CGPoint(x: rect.minX, y: leftCutY))

        let rightCutY = rect.maxY - 300
        path.addLine(to: CGPoint(x: rect.maxX, y: rightCutY))

        // Right edge to just above bottom-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        // Rounded bottom-right corner
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: Angle(radians: 0),
            endAngle: Angle(radians: .pi / 2),
            clockwise: false
        )
        // Bottom edge to just before bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        // Rounded bottom-left corner
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: Angle(radians: .pi / 2),
            endAngle: Angle(radians: .pi),
            clockwise: false
        )
        path.closeSubpath()

        return path
    }
}

struct SupportScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.openURL) private var openURL

    @State private var versionTapCount = 0

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug

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
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__support__title"))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    ZStack {
                        // Orange diagonal background (scrolls with content)
                        Color.brandAccent
                            .clipShape(DiagonalCut())
                            .ignoresSafeArea()

                        VStack(alignment: .leading, spacing: 0) {
                            BodyMText(t("settings__support__text"))
                                .padding(.bottom, 16)

                            VStack(spacing: 0) {
                                NavigationLink(value: Route.reportIssue) {
                                    SettingsRow(title: t("settings__support__report"), iconName: "warning")
                                }

                                Button(action: {
                                    openURL(URL(string: Env.helpUrl)!)
                                }) {
                                    SettingsRow(title: t("settings__support__help"), iconName: "question")
                                }

                                NavigationLink(value: Route.appStatus) {
                                    SettingsRow(title: t("settings__support__status"), iconName: "power")
                                }
                                .accessibilityIdentifier("AppStatus")

                                Button(action: {
                                    openURL(URL(string: Env.termsOfServiceUrl)!)
                                }) {
                                    SettingsRow(title: t("settings__about__legal"), iconName: "file-text")
                                }

                                ShareLink(item: shareText, message: Text(shareText)) {
                                    SettingsRow(title: t("settings__about__share"), iconName: "share")
                                }

                                Button(action: {
                                    onVersionTap()
                                }) {
                                    SettingsRow(
                                        title: t("settings__about__version"),
                                        iconName: "stack",
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
                                    .frame(maxHeight: 100)
                                    .accessibilityIdentifier("AboutLogo")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 16)

                            Social()
                                .padding(.bottom, 16)

                            BodyMText("Bitkit was crafted by Synonym Software, S.A. DE C.V. ©2025. All rights reserved.")
                                .padding(.bottom, 16)

                            HStack(alignment: .center, spacing: 10) {
                                Image("synonym-logo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 24)

                                Image("tether-logo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 16)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .frame(height: 24)
                            .padding(.bottom, 32)
                        }
                        .frame(minHeight: geometry.size.height)
                        .padding(.horizontal, 16)
                        .bottomSafeAreaPadding()
                    }
                }
            }
            .ignoresSafeArea()
        }
        .navigationBarHidden(true)
    }

    private func onVersionTap() {
        versionTapCount += 1

        // When tapped 5 times, toggle developer mode
        if versionTapCount >= 5 {
            versionTapCount = 0
            showDevSettings.toggle()

            app.toast(
                type: .info,
                title: t(showDevSettings ? "settings__dev_enabled_title" : "settings__dev_disabled_title"),
                description: t(showDevSettings ? "settings__dev_enabled_message" : "settings__dev_disabled_message")
            )
        }
    }
}
