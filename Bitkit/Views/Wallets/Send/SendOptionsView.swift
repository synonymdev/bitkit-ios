import PhotosUI
import SwiftUI

struct SendOptionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var scanner: ScannerManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_bitcoin"))

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 8) {
                    Scanner(
                        onScan: { uri in
                            await scanner.handleSendScan(uri) { route in
                                if let route {
                                    navigationPath.append(route)
                                }
                            }
                        },
                        onImageSelection: { item in
                            await scanner.handleImageSelection(item, context: .send) { route in
                                if let route {
                                    navigationPath.append(route)
                                }
                            }
                        }
                    )

                    RectangleButton(
                        icon: "users",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_contact"),
                        isDisabled: true,
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
                currency: currency,
                settings: settings
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
            await scanner.handleSendScan(uri) { route in
                if let route {
                    navigationPath.append(route)
                }
            }
        }
    }

    func handleContact() {
        // TODO: implement contacts
        // navigationPath.append(.contact)
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendOptionsView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
