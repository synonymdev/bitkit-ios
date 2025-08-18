import SwiftUI

struct BackupIntroView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Binding var navigationPath: [BackupRoute]

    var body: some View {
        let text = wallet.totalBalanceSats > 0 ? t("security__backup_funds") : t("security__backup_funds_no")

        VStack(alignment: .leading, spacing: 0) {
            SheetIntro(
                navTitle: t("security__backup_wallet"),
                title: t("security__backup_title"),
                description: text,
                image: "safe",
                continueText: t("security__backup_button"),
                cancelText: t("common__later"),
                accentColor: .blueAccent,
                testID: "BackupIntroView",
                onCancel: {
                    app.ignoreBackup()
                    sheets.hideSheet()
                },
                onContinue: {
                    navigationPath.append(.mnemonic)
                }
            )
        }
    }
}
