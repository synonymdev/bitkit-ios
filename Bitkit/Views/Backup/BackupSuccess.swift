import SwiftUI

struct BackupSuccess: View {
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_result_header"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(localizedString("security__mnemonic_result_text"), accentColor: .textPrimary, accentFont: Fonts.bold)

                Spacer()

                Image("check")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                // TODO: dispatch(verifyBackup());
                CustomButton(
                    title: localizedString("common__ok"),
                    destination: BackupDevices()
                )
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
