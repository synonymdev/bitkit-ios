import SwiftUI

struct SendEnterManuallyView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var sheets: SheetViewModel

    @Binding var navigationPath: [SendRoute]
    @FocusState private var isTextEditorFocused: Bool

    private var manualEntryBinding: Binding<String> {
        Binding(
            get: { app.manualEntryInput },
            set: { newValue in
                app.manualEntryInput = newValue
                app.validateManualEntryInput(
                    newValue,
                    savingsBalanceSats: wallet.spendableOnchainBalanceSats,
                    spendingBalanceSats: wallet.maxSendLightningSats
                )
            }
        )
    }

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_bitcoin"), showBackButton: true)

            CaptionMText(t("wallet__send_to"))
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .topLeading) {
                if app.manualEntryInput.isEmpty {
                    TitleText(t("wallet__send_address_placeholder"), textColor: .textSecondary)
                        .padding(20)
                }

                TextEditor(text: manualEntryBinding)
                    .focused($isTextEditorFocused)
                    .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                    .padding(20)
                    .frame(maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .font(.custom(Fonts.bold, size: 22))
                    .foregroundColor(.textPrimary)
                    .accentColor(.brandAccent)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .dismissKeyboardOnReturn(text: manualEntryBinding, isFocused: $isTextEditorFocused)
                    .accessibilityValue(app.manualEntryInput)
                    .accessibilityIdentifier("RecipientInput")
            }
            .background(Color.white06)
            .cornerRadius(8)

            Spacer(minLength: 16)

            CustomButton(title: "Continue", isDisabled: !app.isManualEntryInputValid) {
                await handleContinue()
            }
            .buttonBottomPadding(isFocused: isTextEditorFocused)
            .accessibilityIdentifier("AddressContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isTextEditorFocused = true
        }
    }

    func handleContinue() async {
        let uri = app.normalizeManualEntry(app.manualEntryInput).removingLightningSchemes()

        guard !uri.isEmpty, app.isManualEntryInputValid else { return }

        if let route = resolvePubkyRoute(
            input: uri,
            ownPublicKey: pubkyProfile.publicKey,
            contacts: contactsManager.contacts
        ) {
            sheets.hideSheetIfActive(.send, reason: "Manual pubky entry routed to contacts")
            navigation.navigate(route)
            return
        }

        do {
            wallet.resetSendState(speed: settings.defaultTransactionSpeed)

            do {
                try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
            } catch {
                Logger.error("Failed to set default fee rate: \(error)")
            }

            try await app.handleScannedData(uri)

            if let route = PaymentNavigationHelper.appropriateSendRoute(
                app: app,
                currency: currency,
                settings: settings
            ) {
                navigationPath.append(route)
            }
        } catch {
            Logger.error(error, context: "Failed to read data from clipboard")
            app.toast(error)
        }
    }
}

#Preview {
    SendEnterManuallyView(navigationPath: .constant([]))
        .environmentObject(AppViewModel())
        .environmentObject(WalletViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(ContactsManager())
        .environmentObject(NavigationViewModel())
        .environmentObject(PubkyProfileManager())
        .environmentObject(SheetViewModel())
        .preferredColorScheme(.dark)
}
