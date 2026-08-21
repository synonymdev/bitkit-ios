import SwiftUI

/// Confirms removing a paired hardware wallet, offering to carry its name and tags in the backup so
/// re-pairing the device restores them. Shared by the wallet screen and the hardware wallet settings.
///
/// A card rather than a native `.alert`, which cannot hold the switch. Ports bitkit-android's
/// `RemoveHwWalletDialog`.
struct RemoveHwWalletDialog: View {
    let walletName: String
    @Binding var keepBackupData: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                SubtitleText(t("hardware__remove_dialog_title", variables: ["name": walletName]))
                    .padding(.bottom, 8)

                BodyMText(t("hardware__remove_dialog_text"))
                    .padding(.bottom, 16)

                keepBackupDataRow
                    .padding(.bottom, 24)

                HStack(spacing: 16) {
                    CustomButton(title: t("common__dialog_cancel"), variant: .secondary, shouldExpand: true) {
                        onDismiss()
                    }
                    .accessibilityIdentifier("DialogCancel")

                    CustomButton(title: t("common__remove"), shouldExpand: true) {
                        onConfirm()
                    }
                    .accessibilityIdentifier("DialogConfirm")
                }
            }
            .padding(24)
            .background(Color.gray6)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 32)
            .frame(maxWidth: 400)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RemoveHwWalletDialog")
    }

    private var keepBackupDataRow: some View {
        HStack(spacing: 16) {
            BodyMSBText(t("hardware__remove_dialog_keep"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $keepBackupData)
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                .labelsHidden()
                .accessibilityLabel(t("hardware__remove_dialog_keep"))
                .accessibilityIdentifier("HwRemoveKeepBackupToggle")
        }
        .contentShape(Rectangle())
        .onTapGesture { keepBackupData.toggle() }
    }
}

extension RemoveHwWalletDialog {
    /// Message for a failed removal. An unreadable tag read leaves the wallet untouched, so it names
    /// the way through instead of asking for a retry that would repeat the same failure.
    static func errorDescription(for error: Error) -> String {
        if let removalError = error as? HwWalletRemovalError, removalError == .backupDataUnreadable {
            return t("hardware__remove_keep_error")
        }
        return t("hardware__remove_error")
    }
}

extension View {
    /// Overlays `RemoveHwWalletDialog` while `walletName` is non-nil. Nil dismisses it, so the caller
    /// keeps the wallet being removed in one piece of state rather than two that can disagree.
    func removeHwWalletDialog(
        walletName: String?,
        keepBackupData: Binding<Bool>,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        overlay {
            if let walletName {
                RemoveHwWalletDialog(
                    walletName: walletName,
                    keepBackupData: keepBackupData,
                    onConfirm: onConfirm,
                    onDismiss: onDismiss
                )
            }
        }
    }
}

#Preview {
    Color.black
        .removeHwWalletDialog(
            walletName: "Trezor Safe 3",
            keepBackupData: .constant(true),
            onConfirm: {},
            onDismiss: {}
        )
        .preferredColorScheme(.dark)
}
