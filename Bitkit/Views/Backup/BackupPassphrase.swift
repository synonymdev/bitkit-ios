import SwiftUI

struct BackupPassphrase: View {
    @Binding var navigationPath: [BackupRoute]
    let mnemonic: [String]
    let passphrase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__pass_your"))

            VStack(spacing: 0) {
                BodyMText(t("security__pass_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(t("security__pass"), textColor: .textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BodyMSBText(passphrase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)

                    Spacer()
                }
                .padding(32)
                .frame(maxHeight: .infinity)
                .background(Color.gray6)
                .cornerRadius(16)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .privacySensitive()
                .frame(maxWidth: .infinity)

                BodySText(
                    t("security__pass_never_share_warning"),
                    accentColor: .brandAccent,
                    accentFont: Fonts.bold
                )

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(title: t("common__continue")) {
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
