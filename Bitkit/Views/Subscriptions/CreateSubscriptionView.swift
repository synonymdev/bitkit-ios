import PhotosUI
import SwiftUI

struct CreateSubscriptionView: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    @Binding var draft: PaykitSubscriptionDraft
    let onEditAmount: () -> Void
    let onChooseRecipient: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var iconImage: UIImage?
    @State private var isLoadingIcon = false
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__create_subscription"))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    amount
                    frequency
                    name
                    description
                    customIcon
                }
                .padding(.bottom, 24)
            }

            CustomButton(
                title: t("subscriptions__choose_recipient"),
                icon: Image("user-plus").resizable().frame(width: 16, height: 16),
                isDisabled: draft.amountSats == 0 ||
                    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    isLoadingIcon
            ) {
                onChooseRecipient()
            }
            .buttonBottomPadding(isFocused: isDescriptionFocused)
            .accessibilityIdentifier("SubscriptionChooseRecipient")
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .onChange(of: draft.name) { _, value in
            if value.count > 256 {
                draft.name = String(value.prefix(256))
            }
        }
        .onChange(of: draft.description) { _, value in
            if value.count > 1024 {
                draft.description = String(value.prefix(1024))
            }
        }
        .onChange(of: selectedPhotoItem) { _, item in
            Task { await loadIcon(item) }
        }
        .accessibilityIdentifier("CreateSubscription")
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(currency.convert(sats: draft.amountSats)?.formatted ?? "", textColor: .white64)
            Button(action: onEditAmount) {
                HStack(spacing: 8) {
                    MoneyText(
                        sats: Int(clamping: draft.amountSats),
                        unitType: .primary,
                        size: .display,
                        symbol: true,
                        color: .textPrimary,
                        symbolColor: .textSecondary
                    )
                    Image("pencil")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SubscriptionEditAmount")
        }
    }

    private var frequency: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("subscriptions__frequency").localizedUppercase, textColor: .white64)
            HStack(spacing: 8) {
                ForEach(SubscriptionFrequencyOption.allCases) { option in
                    Button {
                        draft.frequency = option.unit
                    } label: {
                        VStack(spacing: 8) {
                            CaptionBText(option.description, textColor: draft.frequency == option.unit ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                            Rectangle()
                                .fill(draft.frequency == option.unit ? Color.white : Color.white16)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SubscriptionFrequency-\(option.rawValue)")
                }
            }
        }
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("subscriptions__name").localizedUppercase, textColor: .white64)
            TextField(
                t("subscriptions__name_placeholder"),
                text: $draft.name,
                testIdentifier: "SubscriptionName"
            )
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("subscriptions__description").localizedUppercase, textColor: .white64)
            NoteTextEditor(
                text: $draft.description,
                placeholder: t("subscriptions__description_placeholder"),
                testIdentifier: "SubscriptionDescription",
                isFocused: $isDescriptionFocused
            )
        }
    }

    private var customIcon: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("subscriptions__custom_icon").localizedUppercase, textColor: .white64)
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 16) {
                    Group {
                        if let iconImage {
                            Image(uiImage: iconImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image("house")
                                .resizable()
                                .scaledToFit()
                                .padding(10)
                                .foregroundColor(.purpleAccent)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .background(Color.white08)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        BodyMSBText(t("subscriptions__custom_icon"))
                        CaptionText(t("subscriptions__custom_icon_description"), textColor: .white64)
                    }
                    Spacer()
                    Image("chevron")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.white64)
                }
                .padding(16)
                .background(Color.gray6)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityIdentifier("SubscriptionIconPicker")
        }
    }

    private func loadIcon(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingIcon = true
        defer {
            isLoadingIcon = false
            selectedPhotoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        iconImage = image
        draft.iconData = data
    }
}

struct SubscriptionAmountView: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    let initialAmountSats: UInt64
    let onBack: () -> Void
    let onContinue: (UInt64) -> Void

    @State private var amountViewModel = AmountInputViewModel()

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__payment_request_amount"), showBackButton: true, onBack: onBack)
            NumberPadTextField(
                viewModel: amountViewModel,
                showEditButton: false,
                isFocused: true,
                testIdentifier: "SubscriptionAmountField"
            )
            Spacer()
            NumberPad(
                type: amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }
            CustomButton(title: t("common__continue"), isDisabled: amountViewModel.amountSats == 0) {
                onContinue(amountViewModel.amountSats)
            }
            .accessibilityIdentifier("SubscriptionAmountContinue")
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .task {
            amountViewModel.updateFromSats(initialAmountSats, currency: currency)
        }
        .accessibilityIdentifier("SubscriptionAmount")
    }
}

struct SubscriptionRecipientView: View {
    @EnvironmentObject private var app: AppViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    @Binding var draft: PaykitSubscriptionDraft
    @Binding var selectedTarget: PaykitPaymentRequestTarget?
    let onBack: () -> Void
    let onSent: (PaykitSubscription) -> Void

    var body: some View {
        PaykitRecipientPicker(
            selectedTarget: selectedTarget,
            onSelect: { selectedTarget = $0 },
            accessibilityIdentifier: "SubscriptionRecipient",
            testIdentifierPrefix: "Subscription"
        ) {
            SheetHeader(
                title: t("subscriptions__choose_recipient"),
                showBackButton: true,
                action: AnyView(expirationMenu),
                onBack: onBack
            )
        } footer: {
            CustomButton(
                title: t("subscriptions__propose_subscription"),
                icon: Image("airplane").resizable().frame(width: 16, height: 16),
                isDisabled: selectedTarget == nil,
                isLoading: paymentRequests.isCreatingRequest
            ) {
                await propose()
            }
            .padding(.bottom, 16)
            .accessibilityIdentifier("SubscriptionPropose")
        }
        .interactiveDismissDisabled(paymentRequests.isCreatingRequest)
    }

    private var expirationMenu: some View {
        Menu {
            ForEach(PaymentRequestExpiration.allCases) { expiration in
                Button(expiration.description) {
                    draft.expiresAt = expiration.date(from: Date())
                }
            }
        } label: {
            Image("timer")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.textPrimary)
        }
        .accessibilityLabel(t("wallet__payment_request_expires"))
        .accessibilityIdentifier("SubscriptionExpiration")
    }

    private func propose() async {
        guard let selectedTarget else { return }
        do {
            let subscription = try await paymentRequests.proposeSubscription(draft, to: selectedTarget)
            guard paymentRequests.subscriptions.contains(where: { $0.id == subscription.id }) else { return }
            onSent(subscription)
        } catch {
            app.toast(error)
        }
    }
}

struct SubscriptionProposalSentView: View {
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var sheets: SheetViewModel

    let subscription: PaykitSubscription

    private var contact: PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, subscription.counterparty) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__payment_request_sent_title"))
            Spacer(minLength: 8)
            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            DisplayText(t("subscriptions__proposal_sent_headline"), accentColor: .purpleAccent)
                .padding(.bottom, 8)
            BodyMText(
                subscription.deliveryStatus == .sent
                    ? t("subscriptions__proposal_sent_description")
                    : t("subscriptions__proposal_queued_description"),
                textColor: .white64
            )
            .padding(.bottom, 16)
            if let contact {
                PubkyContactRow(contact: contact, verticalPadding: 16) {}
                    .allowsHitTesting(false)
            }
            SubscriptionRow(subscription: subscription, now: Date())
                .padding(.top, 8)
            Spacer(minLength: 24)
            CustomButton(title: t("common__ok")) {
                sheets.hideSheet(reason: "Subscription proposal created")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .accessibilityIdentifier("SubscriptionProposalSent")
    }
}

private enum SubscriptionFrequencyOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case day
    case week
    case month
    case year

    var id: String {
        rawValue
    }

    var unit: PaykitSubscriptionRecurrence.Unit {
        switch self {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    var description: String {
        switch self {
        case .day: t("subscriptions__daily")
        case .week: t("subscriptions__weekly")
        case .month: t("subscriptions__monthly")
        case .year: t("subscriptions__yearly")
        }
    }
}
