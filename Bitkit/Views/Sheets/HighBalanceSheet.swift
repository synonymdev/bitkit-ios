import SwiftUI

struct HighBalanceSheetItem: SheetItem {
    let id: SheetID = .highBalance
    let size: SheetSize = .large
}

struct HighBalanceSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    let config: HighBalanceSheetItem

    var body: some View {
        Sheet(id: .highBalance, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: localizedString("other__high_balance__nav_title"))

                VStack(spacing: 0) {
                    Spacer()

                    Image("exclamation-mark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: UIScreen.main.bounds.width * 0.8)
                        .frame(maxHeight: 256)
                        .padding(.bottom, 32)

                    DisplayText(localizedString("other__high_balance__title"), accentColor: .yellowAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    BodyMText(localizedString("other__high_balance__text"), accentFont: Fonts.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: localizedString("other__high_balance__cancel"),
                        variant: .secondary,
                    ) {
                        onLearnMore()
                    }

                    CustomButton(
                        title: localizedString("other__high_balance__continue"),
                    ) {
                        onDismiss()
                    }
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 32)
        }
    }

    private func onDismiss() {
        app.ignoreHighBalance()
        sheets.hideSheet()
    }

    private func onLearnMore() {
        UIApplication.shared.open(URL(string: "https://en.bitcoin.it/wiki/Storing_bitcoins")!)
    }
}
