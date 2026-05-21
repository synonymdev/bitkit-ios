import SwiftUI

struct SendContactSelectView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]
    @State private var selectedContactKey: String?

    private var contacts: [PubkyContact] {
        contactsManager.contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__recipient_contact"), showBackButton: true)

            if contacts.isEmpty {
                Spacer()
                BodyMText(t("slashtags__contacts_no_found"), textColor: .white64)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("contacts__nav_title").localizedUppercase, textColor: .white64)
                            .padding(.bottom, 16)

                        CustomDivider()

                        ForEach(contacts) { contact in
                            PubkyContactRow(
                                contact: contact,
                                verticalPadding: 24,
                                isLoading: selectedContactKey == contact.publicKey
                            ) {
                                Task {
                                    await pay(contact)
                                }
                            }
                            .accessibilityIdentifier("SendContact-\(contact.publicKey)")
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func pay(_ contact: PubkyContact) async {
        guard selectedContactKey == nil else { return }
        selectedContactKey = contact.publicKey
        defer { selectedContactKey = nil }

        do {
            let result = try await PrivatePaykitService.shared.beginSavedContactPayment(to: contact.publicKey, wallet: wallet)

            switch result {
            case let .opened(paymentRequest):
                _ = await openContactPayment(paymentRequest: paymentRequest, publicKey: contact.publicKey)
            case .noEndpoint, .notOpened:
                if let messageKey = result.contactPaymentFailureMessageKey {
                    app.toast(
                        type: .warning,
                        title: t("slashtags__error_pay_title"),
                        description: t(messageKey)
                    )
                }
            }
        } catch {
            Logger.error("Failed to pay contact \(PubkyPublicKeyFormat.redacted(contact.publicKey)): \(error)", context: "SendContactSelectView")
            app.toast(type: .error, title: t("slashtags__error_pay_title"), description: error.localizedDescription)
        }
    }

    @MainActor
    private func openContactPayment(paymentRequest: String, publicKey: String) async -> Bool {
        do {
            try await app.handleScannedData(paymentRequest)
        } catch {
            Logger.warn("Failed to decode contact payment request: \(error)", context: "SendContactSelectView")
            app.toast(
                type: .warning,
                title: t("slashtags__error_pay_title"),
                description: t("slashtags__error_pay_not_opened_msg")
            )
            return false
        }

        guard let route = PaymentNavigationHelper.contactPaymentRoute(app: app, currency: currency, settings: settings) else {
            return false
        }

        app.contactPaymentContext = ContactPaymentContext(publicKey: publicKey)
        navigationPath.append(route)
        return true
    }
}
