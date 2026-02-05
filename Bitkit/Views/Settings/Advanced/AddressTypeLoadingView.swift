import SwiftUI

/// Loading view shown during address type or monitoring changes
struct AddressTypeLoadingView: View {
    let targetAddressType: AddressScriptType?
    let isMonitoringChange: Bool

    private var navTitle: String {
        isMonitoringChange ? "Address Monitoring" : "Address Type"
    }

    private var headline: String {
        if let addressType = targetAddressType, !isMonitoringChange {
            return "Switching to <accent>\(addressType.localizedTitle)</accent>"
        }
        return "Updating Wallet"
    }

    private var description: String {
        "Please wait while the wallet restarts..."
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: navTitle, showBackButton: false, showMenuButton: false)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("wallet")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 14) {
                    DisplayText(headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    BodyMText(description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ActivityIndicator(size: 32)
                    .padding(.top, 32)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .accessibilityIdentifier("AddressTypeLoadingView")
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

#Preview {
    AddressTypeLoadingView(
        targetAddressType: .taproot,
        isMonitoringChange: false
    )
    .preferredColorScheme(.dark)
}
