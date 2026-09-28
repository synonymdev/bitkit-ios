import PhotosUI
import SwiftUI

struct SendOptionsView: View {
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var scanner: ScannerManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    @State private var selectedItem: PhotosPickerItem?

    private var scanScope: ScanHandlingScope {
        hwSend.isActive ? .onchainPayments : .unrestricted
    }

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_bitcoin"))

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 8) {
                    Scanner(
                        onScan: { uri in
                            await scanner.handleSendScan(uri, scope: scanScope) { route in
                                if let route {
                                    handleRoute(route)
                                }
                            }
                        },
                        onImageSelection: { item in
                            await scanner.handleImageSelection(
                                item,
                                context: .send,
                                scope: scanScope
                            ) { route in
                                if let route {
                                    handleRoute(route)
                                }
                            }
                        }
                    )

                    RectangleButton(
                        icon: "users",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_contact"),
                        testID: "RecipientContact"
                    ) {
                        handleContact()
                    }

                    RectangleButton(
                        icon: "clipboard",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_invoice"),
                        testID: "RecipientInvoice"
                    ) {
                        handlePaste()
                    }

                    RectangleButton(
                        icon: "pencil",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_manual"),
                        testID: "RecipientManual"
                    ) {
                        app.resetManualEntryInput()
                        navigationPath.append(.manual)
                    }
                }
            }
        }
        .sheetBackground()
        .padding(.horizontal, 16)
        .onAppear {
            wallet.syncState()
            scanner.configure(
                app: app,
                contactsManager: contactsManager,
                currency: currency,
                settings: settings,
                navigation: navigation,
                pubkyProfile: pubkyProfile,
                sheets: sheets,
                wallet: wallet,
                hwWalletManager: hwWalletManager
            )
        }
    }

    func handlePaste() {
        guard let uri = UIPasteboard.general.string else {
            app.toast(
                type: .warning,
                title: t("wallet__send_clipboard_empty_title"),
                description: t("wallet__send_clipboard_empty_text")
            )
            return
        }

        Task {
            await scanner.handleSendScan(uri, scope: scanScope) { route in
                if let route {
                    handleRoute(route)
                }
            }
        }
    }

    func handleContact() {
        navigationPath.append(isPaykitUIActive ? .contact : .comingSoon)
    }

    private func handleRoute(_ route: SendRoute) {
        navigationPath.append(route)
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendOptionsView(navigationPath: .constant([]), hwSend: HwSendCoordinator())
                        .environmentObject(AppViewModel())
                        .environmentObject(ContactsManager())
                        .environmentObject(CurrencyViewModel())
                        .environmentObject(NavigationViewModel())
                        .environmentObject(PubkyProfileManager())
                        .environmentObject(ScannerManager())
                        .environmentObject(SettingsViewModel.shared)
                        .environmentObject(SheetViewModel())
                        .environmentObject(WalletViewModel())
                        .environment(HwWalletManager())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
