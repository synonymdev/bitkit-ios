import SwiftUI

struct SendEnterManuallyView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]
    @State private var text = ""
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_bitcoin"), showBackButton: true)

            CaptionMText(t("wallet__send_to"))
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    TitleText(t("wallet__send_address_placeholder"), textColor: .textSecondary)
                        .padding(20)
                }

                TextEditor(text: $text)
                    .focused($isTextEditorFocused)
                    .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                    .padding(20)
                    .frame(maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .font(.custom(Fonts.bold, size: 22))
                    .foregroundColor(.textPrimary)
                    .accentColor(.brandAccent)
            }
            .background(Color.white06)
            .cornerRadius(8)

            Spacer(minLength: 16)

            CustomButton(title: "Continue", isDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                await handleContinue()
            }
            .buttonBottomPadding(isFocused: isTextEditorFocused)
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
        let uri = text.trimmingCharacters(in: .whitespacesAndNewlines)

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
