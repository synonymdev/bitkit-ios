import SwiftUI

/// Lightning service providers that sell a channel to any node, offered now that Blocktank no longer opens new channels.
/// Bitkit does not run or endorse them; each opens in the browser, and the channel is claimed through the scanner or
/// manual setup.
struct LightningProvider: Identifiable {
    let name: String
    let url: URL

    var id: String {
        name
    }

    static let all: [LightningProvider] = [
        LightningProvider(name: "LNBIG", url: URL(string: "https://lnbig.com/#/open-channel")!),
        LightningProvider(name: "ZEUS Olympus", url: URL(string: "https://channels.zeuslsp.com/")!),
        LightningProvider(name: "Megalithic", url: URL(string: "https://megalithic.me/get_a_channel")!),
        LightningProvider(name: "Amboss Magma", url: URL(string: "https://amboss.space/magma")!),
    ]
}

struct ChooseLspView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__funding_advanced__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__choose_lsp__title"), accentColor: .purpleAccent)
                        .padding(.bottom, 8)

                    BodyMText(t("lightning__choose_lsp__text"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 32)

                    VStack(spacing: 0) {
                        ForEach(LightningProvider.all) { provider in
                            Button {
                                openURL(provider.url)
                            } label: {
                                SettingsRow(title: provider.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ChooseLspProvider")
                        }
                    }
                }
            }

            BodySText(t("lightning__choose_lsp__explanation"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .padding(.bottom, 16)

            HStack(spacing: 16) {
                CustomButton(title: t("lightning__funding_advanced__button2"), variant: .secondary) {
                    navigation.navigate(.fundManual(nodeUri: nil))
                }
                .accessibilityIdentifier("ChooseLspManual")

                CustomButton(
                    title: t("wallet__receive_show_qr"),
                    icon: Image("scan")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.textPrimary)
                ) {
                    navigation.navigate(.scanner)
                }
                .accessibilityIdentifier("ChooseLspScan")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        ChooseLspView()
            .environmentObject(NavigationViewModel())
            .preferredColorScheme(.dark)
    }
}
