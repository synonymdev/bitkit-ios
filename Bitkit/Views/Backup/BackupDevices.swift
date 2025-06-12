import SwiftUI

struct BackupDevices: View {
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_multiple_header"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(localizedString("security__mnemonic_multiple_text"))

                Spacer()

                Image("phone")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                CustomButton(
                    title: localizedString("common__ok"),
                    destination: BackupMetadata()
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
