import SwiftUI

struct BackupIntroView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Binding var navigationPath: [BackupRoute]

    var body: some View {
        let text = wallet.totalBalanceSats > 0 ? localizedString("security__backup_funds") : localizedString("security__backup_funds_no")

        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__backup_wallet"))

            VStack(spacing: 0) {
                Spacer()

                Image("safe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                DisplayText(localizedString("security__backup_title"), accentColor: .blueAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodyMText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: localizedString("common__later"),
                        variant: .secondary,
                    ) {
                        app.ignoreBackup()
                        sheets.hideSheet()
                    }

                    CustomButton(
                        title: localizedString("security__backup_button"),
                    ) {
                        navigationPath.append(.mnemonic)
                    }
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, 16)
    }
}
