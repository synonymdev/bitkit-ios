import SwiftUI

struct ProfileRemovalRecoveryView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var session: SessionManager
    @State private var isWorking = false
    @State private var confirmWipe = false
    @State private var confirmDisconnect = false
    @State private var confirmRemoteRetry = false
    @State private var remoteRetry: PubkyProfileManager.RemoteRemovalConfirmation?
    @State private var disconnectID: UUID?
    @State private var wipeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            NavigationBar(title: t("profile__recovery_title"))
            if pubkyProfile.isDeletingProfile {
                BodyMText(t("profile__recovery_working"))
                ProgressView()
            } else {
                switch pubkyProfile.removalRecovery {
                case let .pending(record) where record.scope == .profile:
                    BodyMText(t("profile__recovery_pending"))
                    if pubkyProfile.canRetryRemoteRemoval(id: record.id) {
                        CustomButton(title: t("common__retry")) {
                            Task { await prepareRetry(id: record.id) }
                        }
                        .accessibilityIdentifier("ProfileRecoveryRetryDisconnect")
                    }
                    CustomButton(title: t("profile__sign_out")) {
                        disconnectID = record.id; confirmDisconnect = true
                    }
                    .accessibilityIdentifier("ProfileRecoveryDisconnect")
                case let .pending(record):
                    BodyMText(t("profile__recovery_wipe"))
                    CustomButton(title: t("security__reset_button_reset")) { wipeID = record.id; confirmWipe = true }
                        .accessibilityIdentifier("ProfileRecoveryWipe")
                case .unavailable:
                    BodyMText(t("profile__recovery_unavailable"))
                    CustomButton(title: t("common__retry")) { pubkyProfile.retryLocalRecoveryRecord() }
                        .accessibilityIdentifier("ProfileRecoveryReadAgain")
                case .ready:
                    EmptyView()
                }
            }
            if isWorking {
                ProgressView()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .disabled(isWorking || pubkyProfile.isDeletingProfile)
        .onDisappear { pubkyProfile.cancelRemoteRemovalRetry(remoteRetry) }
        .alert(t("profile__sign_out_title"), isPresented: $confirmRemoteRetry) {
            Button(t("common__retry"), role: .destructive) {
                if let remoteRetry {
                    Task { await retry(remoteRetry) }
                }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {
                pubkyProfile.cancelRemoteRemovalRetry(remoteRetry)
                remoteRetry = nil
            }
        } message: { Text(t("profile__sign_out_description")) }
        .alert(t("profile__sign_out_title"), isPresented: $confirmDisconnect) {
            Button(t("profile__sign_out"), role: .destructive) {
                if let disconnectID {
                    Task { await disconnect(id: disconnectID) }
                }
            }
            Button(t("common__dialog_cancel"), role: .cancel) { disconnectID = nil }
        } message: { Text(t("profile__recovery_pending")) }
        .alert(t("security__reset_dialog_title"), isPresented: $confirmWipe) {
            Button(t("security__reset_confirm"), role: .destructive) {
                Task { await finishWipe() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: { Text(t("security__reset_dialog_desc")) }
    }

    private func prepareRetry(id: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            remoteRetry = try await pubkyProfile.prepareRemoteRemovalRetry(id: id)
            confirmRemoteRetry = true
        } catch { show(error, expectedID: id, expectedScope: .profile) }
    }

    private func retry(_ confirmation: PubkyProfileManager.RemoteRemovalConfirmation) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let completion = try await pubkyProfile.confirmRemoteRemovalRetry(confirmation)
            if pubkyProfile.ownsRemovalCompletion(completion) {
                navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
            }
        } catch { show(error, expectedID: confirmation.removalID, expectedScope: .profile) }
    }

    private func disconnect(id: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let completion = try await pubkyProfile.finishPendingRemoval(id: id)
            if pubkyProfile.ownsRemovalCompletion(completion) {
                navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
            }
        } catch { show(error, expectedID: id, expectedScope: .profile) }
    }

    private func finishWipe() async {
        guard let wipeID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppReset.wipe(app: app, wallet: wallet, session: session, expectedPendingID: wipeID)
        } catch { show(error, expectedID: wipeID, expectedScope: .walletWipe) }
    }

    private func show(_ error: Error, expectedID: UUID, expectedScope: ProfileRemovalStore.Scope) {
        pubkyProfile.refreshRemovalRecovery()
        guard !Task.isCancelled, pubkyProfile.ownsRecoveryFailure(id: expectedID, scope: expectedScope) else { return }
        app.toast(type: .error, title: t("profile__recovery_title"), description: error.localizedDescription)
    }
}
