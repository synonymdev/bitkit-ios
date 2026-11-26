import SwiftUI

struct SendContactSelectView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    /// The picker visit on top of this send, or nil when the picker is not the top screen.
    /// A contact that resolves after its visit ended opens no payment.
    var currentVisit: () -> Int? = { 0 }
    /// Lets the sheet release the previous pick's context before this pick claims its own.
    var onBeforeClaim: () -> Void = {}
    /// Reports the context this picker claimed, so the sheet can release it when the user comes back.
    var onContextClaimed: (UUID) -> Void = { _ in }
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
                            .disabled(selectedContactKey != nil)
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
        let presentationID = sheets.activeSheetConfiguration?.presentationID
        let visit = currentVisit()
        selectedContactKey = contact.publicKey
        defer { selectedContactKey = nil }

        do {
            let result = try await PrivatePaykitService.shared.beginSavedContactPayment(to: contact.publicKey, wallet: wallet)

            switch result {
            case let .opened(paymentRequest, privatePaymentContext, endpoints):
                _ = await openContactPayment(
                    paymentRequest: paymentRequest,
                    publicKey: contact.publicKey,
                    privatePaymentContext: privatePaymentContext,
                    endpoints: endpoints,
                    presentationID: presentationID,
                    visit: visit
                )
            case .noEndpoint, .notOpened, .privateLinkPending, .waitingForUpdatedPaymentList:
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
            if let description = PaymentNavigationHelper.contactPaymentErrorDescription(error) {
                app.toast(type: .error, title: t("slashtags__error_pay_title"), description: description)
            }
        }
    }

    @MainActor
    private func openContactPayment(
        paymentRequest: String,
        publicKey: String,
        privatePaymentContext: PrivatePaykitPaymentContext?,
        endpoints: [PublicPaykitService.Endpoint],
        presentationID: UUID?,
        visit: Int?
    ) async -> Bool {
        guard let presentationID, sheets.activeSheetConfiguration?.presentationID == presentationID,
              let visit, currentVisit() == visit else { return false }
        let contactPaymentContext = ContactPaymentContext(
            publicKey: publicKey,
            privatePaymentContext: privatePaymentContext,
            endpoints: endpoints
        )
        onBeforeClaim()
        guard app.claimContactPaymentContext(contactPaymentContext) else { return false }
        onContextClaimed(contactPaymentContext.id)

        do {
            try await app.handleScannedData(
                paymentRequest,
                claimedContactPaymentContext: contactPaymentContext,
                scope: hwSend.isActive ? .onchainPayments : .unrestricted,
                alternativeOnchainBalanceSats: hwWalletManager.maximumFundingBalanceSats,
                sendPresentationID: presentationID
            )
        } catch is CancellationError {
            if app.ownsContactPaymentContext(contactPaymentContext) {
                app.resetSendState(ownerID: presentationID)
            }
            return false
        } catch {
            guard app.ownsContactPaymentContext(contactPaymentContext) else { return false }
            app.resetSendState(ownerID: presentationID)
            Logger.warn("Failed to decode contact payment request: \(error)", context: "SendContactSelectView")
            app.toast(
                type: .warning,
                title: t("slashtags__error_pay_title"),
                description: t("slashtags__error_pay_not_opened_msg")
            )
            return false
        }

        guard sheets.activeSheetConfiguration?.presentationID == presentationID,
              app.ownsContactPaymentContext(contactPaymentContext) else { return false }
        guard currentVisit() == visit,
              let route = PaymentNavigationHelper.contactPaymentRoute(app: app, currency: currency, settings: settings)
        else {
            app.resetSendState(ownerID: presentationID)
            return false
        }

        navigationPath.append(route)
        return true
    }
}
