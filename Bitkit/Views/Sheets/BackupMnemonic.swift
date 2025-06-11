import SwiftUI

struct BackupMnemonicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__mnemonic_your"))

            BodyMText(localizedString("security__mnemonic_write"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
            }
            .background(Color.red)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxHeight: .infinity)

            BodySText(localizedString("security__mnemonic_never_share"), accentColor: .brandAccent)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                CustomButton(
                    title: localizedString("common__continue"),
                    destination: BackupMnemonicView()
                )
            }
            .padding(.top, 32)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 32)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
