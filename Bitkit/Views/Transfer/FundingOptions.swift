import SwiftUI

struct FundingOptions: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            DisplayText(
                NSLocalizedString("lightning__funding__title", comment: ""),
                accentColor: .purpleAccent
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            BodyMText(NSLocalizedString("lightning__funding__text", comment: ""))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                NavigationLink(destination: Text("TODO")) {
                    RectangleButton(
                        icon: Image("transfer-purple"),
                        title: NSLocalizedString("lightning__funding__button1", comment: ""),
                        isDisabled: wallet.totalOnchainSats == 0 || app.isGeoBlocked
                    )
                }
                .disabled(wallet.totalOnchainSats == 0 || app.isGeoBlocked)

                NavigationLink(destination: Text("TODO")) {
                    RectangleButton(
                        icon: Image("qr-purple"),
                        title: NSLocalizedString("lightning__funding__button2", comment: ""),
                        isDisabled: app.isGeoBlocked
                    )
                }
                .disabled(app.isGeoBlocked)

                NavigationLink(destination: Text("TODO")) {
                    RectangleButton(
                        icon: Image("share-purple"),
                        title: NSLocalizedString("lightning__funding__button3", comment: "")
                    )
                }
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        FundingOptions()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
