import SwiftUI

struct BackupSuccess: View {
    @EnvironmentObject private var app: AppViewModel
    @Binding var navigationPath: [BackupRoute]

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

                CustomButton(
                    title: localizedString("common__ok"),
                ) {
                    app.backupVerified = true
                    navigationPath.append(.devices)
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
