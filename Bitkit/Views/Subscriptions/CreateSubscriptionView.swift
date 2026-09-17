import PhotosUI
import SwiftUI

struct CreateSubscriptionView: View {
    @EnvironmentObject private var app: AppViewModel

    @Binding var draft: PaykitSubscriptionDraft
    let onEditAmount: () -> Void
    let onChooseRecipient: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @FocusState private var isNameFocused: Bool
    @FocusState private var isDescriptionFocused: Bool

    private var isLoadingIcon: Bool {
        selectedPhotoItem != nil
    }

    private var iconImage: UIImage? {
        draft.iconData.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__create_subscription"))

            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {
                            amount
                            frequency
                            name
                            description
                                .id("SubscriptionDescription")
                            customIcon
                        }
                        .padding(.bottom, 24)
                    }
                    .onChange(of: isDescriptionFocused ? geometry.size.height : nil) { _, focusedHeight in
                        if focusedHeight != nil {
                            withAnimation {
                                proxy.scrollTo("SubscriptionDescription", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            CustomButton(
                title: t("subscriptions__choose_recipient"),
                isDisabled: draft.amountSats == 0 ||
                    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    isLoadingIcon
            ) {
                onChooseRecipient()
            }
            .buttonBottomPadding(isFocused: isNameFocused || isDescriptionFocused)
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
        .task(id: selectedPhotoItem) {
            await loadIcon(selectedPhotoItem)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreateSubscription")
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionMText(t("wallet__payment_request_amount").localizedUppercase, textColor: .white64)
            Button(action: onEditAmount) {
                HStack(spacing: 8) {
                    MoneyText(
                        sats: Int(clamping: draft.amountSats),
                        unitType: .primary,
                        size: .display,
                        symbol: true,
                        color: .textPrimary,
                        symbolColor: .textSecondary,
                        fillsWidth: false
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
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
            SegmentedControl(
                selectedTab: Binding(
                    get: { SubscriptionFrequencyOption.allCases.first { $0.unit == draft.frequency } ?? .month },
                    set: { draft.frequency = $0.unit }
                ),
                tabItems: SubscriptionFrequencyOption.allCases.map {
                    TabItem($0, accessibilityIdentifier: "Tab-\($0.rawValue)")
                },
                inactiveColor: .white.opacity(0.5)
            )
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
            .focused($isNameFocused)
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("subscriptions__description").localizedUppercase, textColor: .white64)
            NoteTextEditor(
                text: $draft.description,
                placeholder: t("subscriptions__description_placeholder"),
                testIdentifier: "SubscriptionDescription",
                isFocused: $isDescriptionFocused,
                minHeight: 60,
                maxHeight: 60,
                backgroundColor: .white10
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
                            SubscriptionDefaultIcon(size: 40)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    CaptionBText(t("subscriptions__custom_icon_description"), textColor: .white64)
                    Spacer()
                }
                .padding(16)
                .background(Color.white10)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(isLoadingIcon)
            .accessibilityIdentifier("SubscriptionIconPicker")
        }
    }

    private func loadIcon(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { if selectedPhotoItem == item { selectedPhotoItem = nil } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PaykitPaymentRequestError.requestUnavailable
            }
            try Task.checkCancellation()
            let compressed = try PaykitPaymentRequestService.compressedSubscriptionIcon(data)
            guard selectedPhotoItem == item else { return }
            draft.iconData = compressed
        } catch is CancellationError {
            return
        } catch {
            app.toast(type: .error, title: t("common__error"), description: t("subscriptions__icon_error"))
        }
    }
}

struct SubscriptionAmountView: View {
    let initialAmountSats: UInt64
    let onBack: () -> Void
    let onContinue: (UInt64) -> Void

    var body: some View {
        PaymentRequestAmountView(
            initialDraft: PaykitPaymentRequestDraft(amountSats: initialAmountSats, note: "", expiresAt: .distantFuture),
            target: nil,
            onContinue: { onContinue($0.amountSats) },
            onBack: onBack,
            testIdentifierPrefix: "PaymentRequest"
        )
        .accessibilityElement(children: .contain)
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
            Image("timer-outline")
                .resizable()
                .frame(width: 18, height: 21)
                .frame(width: 24, height: 24, alignment: .top)
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
            SheetHeader(title: t(subscription.deliveryStatus == .sent
                    ? "wallet__payment_request_sent_title"
                    : "subscriptions__proposal_queued_title"))
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Image("check")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 256, height: 256)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        DisplayText(t(subscription.deliveryStatus == .sent
                                ? "subscriptions__proposal_sent_headline"
                                : "subscriptions__proposal_queued_headline"), accentColor: .purpleAccent)
                            .padding(.bottom, 8)
                        BodyMText(
                            subscription.deliveryStatus == .sent
                                ? t("subscriptions__proposal_sent_description")
                                : t("subscriptions__proposal_queued_description"),
                            textColor: .white64
                        )
                        .padding(.bottom, 16)
                        if let contact {
                            PubkyContactRow(contact: contact, verticalPadding: 16, showsDivider: false) {}
                                .padding(.horizontal, 16)
                                .background(Color.gray6)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .allowsHitTesting(false)
                        }
                        SubscriptionRow(
                            subscription: subscription,
                            now: Date(),
                            subtitle: subscription.recurrence.subscriptionFrequencyLabel
                        )
                        .padding(.top, 16)
                        Spacer().frame(height: 24)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
            }
            CustomButton(title: t("common__ok")) {
                sheets.hideSheet(reason: "Subscription proposal created")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .accessibilityIdentifier("SubscriptionProposalSent")
    }
}

private enum SubscriptionFrequencyOption: String, CaseIterable, CustomStringConvertible {
    case day
    case week
    case month
    case year

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
