import SwiftUI

struct FundAdvancedOptions: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    DisplayText(
                        t("lightning__funding_advanced__title"),
                        accentColor: .purpleAccent
                    )
                    .padding(.bottom, 8)

                    BodyMText(t("lightning__funding_advanced__text"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 32)

                    VStack(spacing: 8) {
                        NavigationLink(destination: ScannerView()) {
                            RectangleButton(
                                icon: Image("scan")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(.purpleAccent),
                                title: t("lightning__funding_advanced__button1")
                            )
                        }

                        RectangleButton(
                            icon: Image("pencil")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .foregroundColor(.purpleAccent),
                            title: t("lightning__funding_advanced__button2")
                        ) {
                            navigation.navigate(.fundManual(nodeUri: nil))
                        }
                    }

                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(t("lightning__funding_advanced__nav_title"))
        .backToWalletButton()
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }
}

#Preview {
    NavigationStack {
        FundAdvancedOptions()
            .preferredColorScheme(.dark)
    }
}
