import SwiftUI

struct SendOptionCard: View {
    var title: String
    var action: () -> Void
    var iconName: String
    var testID: String

    var body: some View {
        Button {
            action()
        } label: {
            HStack {
                Image(iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(Color.brandAccent)
                    .frame(width: 32, height: 32)
                    .padding(.trailing, 8)
                BodyMSBText(title)
                Spacer()
            }
            .frame(height: 80)
            .padding(.horizontal, 24)
            .background(Color.white06)
            .cornerRadius(8)
            .accessibilityIdentifier(testID)
        }
    }
}

struct SendOptionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @Binding var navigationPath: [SendRoute]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_bitcoin"))

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__send_to"))
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    SendOptionCard(
                        title: t("wallet__recipient_contact"),
                        action: handleContact,
                        iconName: "users",
                        testID: "RecipientContact"
                    )

                    SendOptionCard(
                        title: t("wallet__recipient_invoice"),
                        action: handlePaste,
                        iconName: "clipboard",
                        testID: "RecipientInvoice"
                    )

                    SendOptionCard(
                        title: t("wallet__recipient_manual"),
                        action: { navigationPath.append(.manual) },
                        iconName: "pencil",
                        testID: "RecipientManual"
                    )

                    SendOptionCard(
                        title: t("wallet__recipient_scan"),
                        action: { navigationPath.append(.scan) },
                        iconName: "scan-brand",
                        testID: "RecipientScan"
                    )
                }

                if !UIScreen.main.isSmall {
                    Spacer(minLength: 0)

                    Image("coin-stack-logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer(minLength: 0)
            }
        }
        .sheetBackground()
        .padding(.horizontal, 16)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            wallet.syncState()
        }
    }

    func handleContact() {
        // TODO: implement contacts
        // navigationPath.append(.contact)
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

        Haptics.play(.pastedFromClipboard)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)

                let route = PaymentNavigationHelper.appropriateSendRoute(
                    app: app,
                    currency: currency,
                    settings: settings
                )
                navigationPath.append(route)
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(error)
            }
        }
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
