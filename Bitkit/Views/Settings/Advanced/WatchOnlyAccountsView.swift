import SwiftUI

struct WatchOnlyAccountsView: View {
    @EnvironmentObject private var app: AppViewModel

    @State private var manager = WatchOnlyAccountManager.shared
    @State private var selectedAccount: WatchOnlyAccountRecord?
    @State private var updatingAccountId: UUID?

    private var visibleAccounts: [WatchOnlyAccountRecord] {
        manager.accounts(for: LightningService.shared.currentWalletIndex)
    }

    private var activeAccounts: [WatchOnlyAccountRecord] {
        visibleAccounts.filter { $0.setupState == .active }
    }

    private var pendingAccounts: [WatchOnlyAccountRecord] {
        visibleAccounts.filter { $0.setupState != .active }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("watch_only_accounts__title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    BodyMText(t("watch_only_accounts__description"), textColor: .white64)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    if visibleAccounts.isEmpty {
                        emptyState
                    } else {
                        if !activeAccounts.isEmpty {
                            SettingsSectionHeader(t("watch_only_accounts__active_section").localizedUppercase)

                            ForEach(activeAccounts) { account in
                                accountSummaryRow(account)

                                SettingsRow(
                                    title: t("watch_only_accounts__tracking"),
                                    rightIcon: nil,
                                    toggle: trackingBinding(for: account),
                                    disabled: updatingAccountId != nil,
                                    testIdentifier: "WatchOnlyAccountTracking_\(account.accountIndex)"
                                )
                            }
                        }

                        if !pendingAccounts.isEmpty {
                            CaptionMText(t("watch_only_accounts__pending_section").localizedUppercase, textColor: .yellow)
                                .frame(height: 50)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, activeAccounts.isEmpty ? 0 : 16)

                            BodySText(t("watch_only_accounts__pending_description"), textColor: .white64)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 8)

                            ForEach(pendingAccounts) { account in
                                accountSummaryRow(account)
                            }
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
            do {
                try await manager.reload()
            } catch {
                app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
            }
        }
        .sheet(item: $selectedAccount) { account in
            WatchOnlyAccountDetailsSheet(account: account) { name in
                try await manager.rename(id: account.id, name: name)
            }
            .environmentObject(app)
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

    private func accountSummaryRow(_ account: WatchOnlyAccountRecord) -> some View {
        Button {
            selectedAccount = account
        } label: {
            SettingsRow(
                title: account.name,
                subtitle: account.derivationPath,
                rightText: account.setupState != .active ? t("watch_only_accounts__setup_not_confirmed") : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("WatchOnlyAccount_\(account.accountIndex)")
    }

    private func trackingBinding(for account: WatchOnlyAccountRecord) -> Binding<Bool> {
        Binding(
            get: {
                manager.accounts.first(where: { $0.id == account.id })?.isTrackingEnabled ?? account.isTrackingEnabled
            },
            set: { enabled in
                Task { await updateTracking(account: account, enabled: enabled) }
            }
        )
    }

    @MainActor
    private func updateTracking(account: WatchOnlyAccountRecord, enabled: Bool) async {
        updatingAccountId = account.id

        do {
            try await manager.setTrackingEnabled(id: account.id, enabled: enabled)
            app.toast(
                type: .success,
                title: enabled ? t("watch_only_accounts__tracking_enabled") : t("watch_only_accounts__tracking_disabled")
            )
        } catch {
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }

        updatingAccountId = nil
    }
}

private struct WatchOnlyAccountDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel

    let account: WatchOnlyAccountRecord
    let onRename: (String) async throws -> Void

    @State private var name: String

    init(account: WatchOnlyAccountRecord, onRename: @escaping (String) async throws -> Void) {
        self.account = account
        self.onRename = onRename
        _name = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("watch_only_accounts__details_title"))

            if account.setupState != .active {
                BodyMText(t("watch_only_accounts__setup_not_finished"), textColor: .yellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("WatchOnlyAccountPending_\(account.accountIndex)")
            }

            CaptionMText(t("watch_only_accounts__name"), textColor: .white64)
                .padding(.bottom, 8)

            TextField(
                t("watch_only_accounts__name_placeholder"),
                text: $name,
                testIdentifier: "WatchOnlyAccountName_\(account.accountIndex)",
                submitLabel: .done
            )
            .onSubmit {
                Task { await saveName() }
            }

            CaptionMText(t("watch_only_accounts__xpub"), textColor: .white64)
                .padding(.top, 24)
                .padding(.bottom, 8)

            BodySText(account.xpub, textColor: .white64)
                .lineLimit(3)
                .truncationMode(.middle)
                .accessibilityIdentifier("WatchOnlyAccountXpub_\(account.accountIndex)")

            Spacer(minLength: 24)

            HStack(spacing: 12) {
                CustomButton(title: t("watch_only_accounts__save_name"), variant: .secondary) {
                    Task { await saveName() }
                }
                .accessibilityIdentifier("WatchOnlyAccountSaveName_\(account.accountIndex)")

                CustomButton(title: t("watch_only_accounts__copy_xpub"), variant: .secondary) {
                    UIPasteboard.general.string = account.xpub
                    app.toast(type: .success, title: t("common__copied"))
                }
                .accessibilityIdentifier("WatchOnlyAccountCopyXpub_\(account.accountIndex)")
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .background(Color.customBlack)
        .presentationDetents([.height(520)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    @MainActor
    private func saveName() async {
        do {
            try await onRename(name)
            app.toast(type: .success, title: t("watch_only_accounts__name_saved"))
            dismiss()
        } catch {
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        WatchOnlyAccountsView()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
