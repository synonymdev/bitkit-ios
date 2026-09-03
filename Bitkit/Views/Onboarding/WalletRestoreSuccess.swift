import SwiftUI

struct WalletRestoreSuccess: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var tagManager: TagManager
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(t("onboarding__restore_success_header"), accentColor: .greenAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(t("onboarding__restore_success_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("check")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            CustomButton(title: t("onboarding__get_started")) {
                Haptics.play(.light)

                suggestionsManager.reloadDismissed()
                tagManager.reloadLastUsedTags()

                // Mark backup as verified since user just restored with their phrase
                app.backupVerified = true
                wallet.isRestoringWallet = false

                let settings = SettingsViewModel.shared

                // Suppress "Received" sheets for historical txs replayed during the post-restore sync.
                // Cleared on the first post-restore on-chain syncCompleted, which marks them seen. #588
                settings.pendingRestoreActivitySeen = true

                // Skip pruning if backup had explicit monitored address types
                if !settings.restoredMonitoredTypesFromBackup {
                    settings.pendingRestoreAddressTypePrune = true
                }
            }
            .accessibilityIdentifier("GetStartedButton")
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}
