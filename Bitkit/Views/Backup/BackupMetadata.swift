import SwiftUI

struct BackupMetadata: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var lastBackupTime: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("security__mnemonic_data_header"), showBackButton: true)

            VStack(spacing: 0) {
                BodyMText(t("security__mnemonic_data_text"))

                Spacer()

                Image("card")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                if let lastBackupTime {
                    BodySText(
                        t("security__mnemonic_latest_backup", variables: ["time": lastBackupTime]),
                        textColor: .textPrimary,
                        accentFont: Fonts.bold
                    )
                    .padding(.bottom, 16)
                }

                CustomButton(title: t("common__ok")) {
                    sheets.hideSheet()
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadLastBackupTime()
        }
    }

    private func loadLastBackupTime() async {
        if let timestamp = BackupService.shared.getLatestBackupTime() {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.locale = Locale.current
            lastBackupTime = formatter.string(from: date)
        }
    }
}
