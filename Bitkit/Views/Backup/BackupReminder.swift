import SwiftUI

struct BackupReminder: View {
    @Binding var navigationPath: [BackupRoute]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("security__mnemonic_keep_header"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(t("security__mnemonic_keep_text"), accentColor: .textPrimary, accentFont: Fonts.bold)

                Spacer()

                Image("exclamation-mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                CustomButton(
                    title: t("common__ok")
                ) {
                    navigationPath.append(.success)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
