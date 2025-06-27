import SwiftUI

struct BackupPassphrase: View {
    @Binding var navigationPath: [BackupRoute]
    let mnemonic: [String]
    let passphrase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("security__pass_your"))

            VStack(spacing: 0) {
                BodyMText(localizedString("security__pass_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(localizedString("security__pass"), textColor: .textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BodyMSBText(passphrase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    Spacer()
                }
                .padding(32)
                .frame(maxHeight: .infinity)
                .background(Color.white10)
                .cornerRadius(16)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .privacySensitive()
                .frame(maxWidth: .infinity)

                BodySText(localizedString("security__pass_never_share"), accentColor: .brandAccent)

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: localizedString("common__continue"),
                    ) {
                        navigationPath.append(.confirmMnemonic(mnemonic: mnemonic, passphrase: passphrase))
                    }
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
