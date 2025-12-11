import SwiftUI

struct SendEnterManuallyView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]
    @FocusState private var isTextEditorFocused: Bool

    private var manualEntryBinding: Binding<String> {
        Binding(
            get: { app.manualEntryInput },
            set: { newValue in
                app.manualEntryInput = newValue
                Task { await app.validateManualEntryInput(newValue) }
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
        let uri = app.manualEntryInput.filter { !$0.isWhitespace }

        guard !uri.isEmpty, app.isManualEntryInputValid else { return }

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

#Preview {
    SendEnterManuallyView(navigationPath: .constant([]))
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
