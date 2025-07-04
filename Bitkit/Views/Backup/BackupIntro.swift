import SwiftUI

struct BackupIntroView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Binding var navigationPath: [BackupRoute]

    var body: some View {
        let text = wallet.totalBalanceSats > 0 ? localizedString("security__backup_funds") : localizedString("security__backup_funds_no")

        VStack(alignment: .leading, spacing: 0) {
            SheetIntro(
                navTitle: localizedString("security__backup_wallet"),
                title: localizedString("security__backup_title"),
                description: text,
                image: "safe",
                continueText: localizedString("security__backup_button"),
                cancelText: localizedString("common__later"),
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
