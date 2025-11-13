import SwiftUI

struct ForceTransferSheetItem: SheetItem {
    let id: SheetID = .forceTransfer
    let size: SheetSize = .large
}

struct ForceTransferSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var transfer: TransferViewModel
    let config: ForceTransferSheetItem

    @State private var isLoading = false

    var body: some View {
        Sheet(id: .forceTransfer, data: config) {
            SheetIntro(
                navTitle: t("lightning__force_nav_title"),
                title: t("lightning__force_title"),
                description: t("lightning__force_text"),
                image: "exclamation-mark",
                continueText: t("lightning__force_button"),
                cancelText: t("common__cancel"),
                accentColor: .yellowAccent,
                accentFont: Fonts.bold,
                testID: "ForceTransferSheet",
                onCancel: onCancel,
                onContinue: onForceTransfer
            )
        }
    }

    private func onCancel() {
        sheets.hideSheet()
    }

    private func onForceTransfer() {
        isLoading = true

        Task { @MainActor in
            do {
                try await transfer.forceCloseChannel()
                sheets.hideSheet()
                app.toast(
                    type: .success,
                    title: t("lightning__force_init_title"),
                    description: t("lightning__force_init_msg")
                )
            } catch {
                Logger.error("Force transfer failed", context: error.localizedDescription)
                app.toast(
                    type: .error,
                    title: t("lightning__force_failed_title"),
                    description: t("lightning__force_failed_msg")
                )
            }
            isLoading = false
        }
    }
}
