import SwiftUI

struct FundingOptionsView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @State private var showNoFundsAlert = false
    @State private var showFundTransfer = false

    var body: some View {
        VStack {
            DisplayText(
                NSLocalizedString("lightning__funding__title", comment: ""),
                accentColor: .purpleAccent
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            BodyMText(NSLocalizedString(app.isGeoBlocked == true ? "lightning__funding__text_blocked" : "lightning__funding__text", comment: ""))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                Button(action: {
                    if wallet.totalOnchainSats == 0 {
                        showNoFundsAlert = true
                    } else if app.isGeoBlocked != true {
                        showFundTransfer = true
                    }
                }) {
                    RectangleButton(
                        icon: Image("transfer-purple"),
                        title: NSLocalizedString("lightning__funding__button1", comment: ""),
                        isDisabled: wallet.totalOnchainSats == 0 || app.isGeoBlocked == true
                    )
                }
                .alert(
                    NSLocalizedString("lightning__no_funds__title", comment: ""),
                    isPresented: $showNoFundsAlert
                ) {
                    Button(NSLocalizedString("common__ok", comment: ""), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("lightning__no_funds__description", comment: ""))
                }
                .background(
                    NavigationLink(
                        destination: SpendingIntroView(),
                        isActive: $showFundTransfer
                    ) { EmptyView() }
                )

                NavigationLink(destination: FundReceiveView()) {
                    RectangleButton(
                        icon: Image("qr-purple"),
                        title: NSLocalizedString("lightning__funding__button2", comment: ""),
                        isDisabled: app.isGeoBlocked == true
                    )
                }
                .disabled(app.isGeoBlocked == true)

                NavigationLink(destination: FundCustomView()) {
                    RectangleButton(
                        icon: Image("share-purple"),
                        title: NSLocalizedString("lightning__funding__button3", comment: "")
                    )
                }
            }

            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showTransferToSpendingSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
        .task {
            await app.checkGeoStatus()
        }
    }
}

#Preview("Default - No Balance") {
    NavigationView {
        FundingOptionsView()
            .environmentObject({
                let wallet = WalletViewModel()
                wallet.totalOnchainSats = 0
                return wallet
            }())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}

#Preview("Geoblocked") {
    NavigationView {
        FundingOptionsView()
            .environmentObject({
                let wallet = WalletViewModel()
                wallet.totalOnchainSats = 100_000
                return wallet
            }())
            .environmentObject({
                let app = AppViewModel()
                app.isGeoBlocked = true
                return app
            }())
            .preferredColorScheme(.dark)
    }
}

#Preview("Has Balance and not geoblocked") {
    NavigationView {
        FundingOptionsView()
            .environmentObject({
                let wallet = WalletViewModel()
                wallet.totalOnchainSats = 100_000
                return wallet
            }())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
