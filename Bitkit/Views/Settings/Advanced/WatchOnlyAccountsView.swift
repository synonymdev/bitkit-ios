import SwiftUI

struct WatchOnlyAccountsView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var manager = WatchOnlyAccountManager.shared
    @State private var nameDrafts: [UUID: String] = [:]
    @State private var updatingAccountId: UUID?

    private var visibleAccounts: [WatchOnlyAccountRecord] {
        manager.accounts(for: LightningService.shared.currentWalletIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("watch_only_accounts__title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    BodyMText(t("watch_only_accounts__description"), textColor: .white64)
                        .lineSpacing(4)

                    if visibleAccounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleAccounts) { account in
                            accountCard(account)
                        }
                    }
                }
                .padding(16)
                .bottomSafeAreaPadding()
            }
        }
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            manager.reload()
            nameDrafts = Dictionary(uniqueKeysWithValues: visibleAccounts.map { ($0.id, $0.name) })
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            TitleText(t("watch_only_accounts__empty_title"))
            BodySText(t("watch_only_accounts__empty_description"), textColor: .white64)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Color.gray6)
        .cornerRadius(16)
        .accessibilityIdentifier("WatchOnlyAccountsEmpty")
    }

    private func accountCard(_ account: WatchOnlyAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BodyMSBText(account.name)
                    CaptionText(account.derivationPath, textColor: .white64)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { account.isTrackingEnabled },
                        set: { enabled in
                            Task { await updateTracking(account: account, enabled: enabled) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                .disabled(updatingAccountId != nil)
                .accessibilityLabel(t("watch_only_accounts__tracking"))
                .accessibilityIdentifier("WatchOnlyAccountTracking_\(account.accountIndex)")
            }

            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("watch_only_accounts__name"), textColor: .white64)
                TextField(
                    t("watch_only_accounts__name_placeholder"),
                    text: Binding(
                        get: { nameDrafts[account.id] ?? account.name },
                        set: { nameDrafts[account.id] = $0 }
                    ),
                    testIdentifier: "WatchOnlyAccountName_\(account.accountIndex)",
                    submitLabel: .done
                )
                .onSubmit { saveName(account) }
            }

            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("watch_only_accounts__xpub"), textColor: .white64)
                BodySText(account.xpub, textColor: .white64)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("WatchOnlyAccountXpub_\(account.accountIndex)")
            }

            HStack(spacing: 12) {
                CustomButton(title: t("watch_only_accounts__save_name"), variant: .secondary) {
                    saveName(account)
                }
                .accessibilityIdentifier("WatchOnlyAccountSaveName_\(account.accountIndex)")

                CustomButton(title: t("watch_only_accounts__copy_xpub"), variant: .secondary) {
                    UIPasteboard.general.string = account.xpub
                    app.toast(type: .success, title: t("common__copied"))
                }
                .accessibilityIdentifier("WatchOnlyAccountCopyXpub_\(account.accountIndex)")
            }

            if account.setupState == .pendingDelivery {
                CaptionText(t("watch_only_accounts__pending_delivery"), textColor: .yellow)
                    .accessibilityIdentifier("WatchOnlyAccountPending_\(account.accountIndex)")
            }
        }
        .padding(20)
        .background(Color.gray6)
        .cornerRadius(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WatchOnlyAccount_\(account.accountIndex)")
    }

    @MainActor
    private func saveName(_ account: WatchOnlyAccountRecord) {
        do {
            try manager.rename(id: account.id, name: nameDrafts[account.id] ?? account.name)
            app.toast(type: .success, title: t("watch_only_accounts__name_saved"))
        } catch {
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }
    }

    @MainActor
    private func updateTracking(account: WatchOnlyAccountRecord, enabled: Bool) async {
        let previousValue = account.isTrackingEnabled
        updatingAccountId = account.id

        do {
            try manager.setTrackingEnabled(id: account.id, enabled: enabled)
            try await wallet.reloadWatchOnlyAccountTracking()
            app.toast(
                type: .success,
                title: enabled ? t("watch_only_accounts__tracking_enabled") : t("watch_only_accounts__tracking_disabled")
            )
        } catch {
            try? manager.setTrackingEnabled(id: account.id, enabled: previousValue)
            try? await wallet.reloadWatchOnlyAccountTracking()
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }

        updatingAccountId = nil
    }
}

#Preview {
    NavigationStack {
        WatchOnlyAccountsView()
            .environmentObject(AppViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
