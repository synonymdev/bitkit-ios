import SwiftUI

struct RenameHardwareWalletConfig {
    let walletId: String
    let currentName: String
}

struct RenameHardwareWalletSheetItem: SheetItem, Equatable {
    let id: SheetID = .renameHardwareWallet
    let size: SheetSize = .small
    let walletId: String
    let currentName: String
}

/// Renames a paired hardware wallet: a single NAME field pre-filled with the current name and a Save
/// button. Persists the custom name via `TrezorManager.renameWallet`, which re-pushes the device
/// snapshot so `HwWallet.name` updates everywhere.
struct RenameHardwareWalletSheet: View {
    @Environment(TrezorManager.self) private var trezorManager
    @EnvironmentObject private var sheets: SheetViewModel

    let config: RenameHardwareWalletSheetItem

    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Sheet(id: .renameHardwareWallet) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("settings__hardware_wallets__rename_title"))

                CaptionMText(t("settings__hardware_wallets__name_label"))
                    .padding(.bottom, 8)

                TextField(
                    config.currentName,
                    text: $name,
                    testIdentifier: "RenameHardwareWalletInput"
                )
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit(save)

                Spacer(minLength: 16)

                CustomButton(
                    title: t("common__save"),
                    isDisabled: trimmedName.isEmpty,
                    shouldExpand: true
                ) {
                    save()
                }
                .buttonBottomPadding(isFocused: isNameFocused)
                .accessibilityIdentifier("RenameHardwareWalletSave")
            }
            .padding(.horizontal, 16)
            .task {
                name = config.currentName
                isNameFocused = true
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        trezorManager.renameWallet(walletId: config.walletId, newName: trimmedName)
        sheets.hideSheet()
    }
}
