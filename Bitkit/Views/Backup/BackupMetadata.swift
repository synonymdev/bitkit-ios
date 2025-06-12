import SwiftUI

struct BackupMetadata: View {
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_data_header"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(localizedString("security__mnemonic_data_text"))

                Spacer()

                Image("card")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                // TODO: Add actual last backup time
                BodySText(localizedString("security__mnemonic_latest_backup", variables: ["time": "12/06/2025 12:00"]))
                    .padding(.bottom, 16)

                CustomButton(title: localizedString("common__ok")) {
                    sheets.hideSheet()
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
