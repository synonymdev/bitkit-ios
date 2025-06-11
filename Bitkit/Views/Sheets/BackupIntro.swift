import SwiftUI

struct BackupIntroView: View {
    @EnvironmentObject private var sheets: SheetViewModel
    let config: BackupSheetItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__backup_wallet"))

            Spacer()

            Image("safe")
                .resizable()
                .scaledToFit()
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxHeight: 256)

            DisplayText(localizedString("security__backup_title"), accentColor: .blueAccent)
                .frame(maxWidth: .infinity, alignment: .leading)

            BodyMText(localizedString("security__backup_funds"))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 16) {
                CustomButton(
                    title: localizedString("common__later"),
                    variant: .secondary,
                ) {
                    sheets.hideSheet()
                }

                CustomButton(
                    title: localizedString("security__backup_button"),
                    destination: BackupMnemonicView()
                )
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 32)
    }
}
