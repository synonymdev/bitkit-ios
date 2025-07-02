import SwiftUI

struct SendUtxoSelectionView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("wallet__send_amount"), showBackButton: true)

            ScrollView {
                Text("TODO")
            }

            Spacer()

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                //TODO:
            }
            .padding(.vertical, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendAmountView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                        .environmentObject(CurrencyViewModel())
                        .environmentObject(SettingsViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
