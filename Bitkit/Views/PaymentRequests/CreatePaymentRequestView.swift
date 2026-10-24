import SwiftUI

enum PaymentRequestExpiration: String, CaseIterable, CustomStringConvertible, Identifiable {
    case hour
    case day
    case week
    case month

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .hour: t("wallet__payment_request_expiry_hour")
        case .day: t("wallet__payment_request_expiry_day")
        case .week: t("wallet__payment_request_expiry_week")
        case .month: t("wallet__payment_request_expiry_month")
        }
    }

    func date(from date: Date) -> Date {
        switch self {
        case .hour: date.addingTimeInterval(60 * 60)
        case .day: date.addingTimeInterval(24 * 60 * 60)
        case .week: date.addingTimeInterval(7 * 24 * 60 * 60)
        case .month: Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(30 * 24 * 60 * 60)
        }
    }

    static func closest(to expiration: Date, from date: Date) -> PaymentRequestExpiration {
        allCases.min {
            abs($0.date(from: date).timeIntervalSince(expiration)) < abs($1.date(from: date).timeIntervalSince(expiration))
        } ?? .week
    }
}

struct RequestOrPayView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests
    @Environment(HwWalletManager.self) private var hwWalletManager

    let publicKey: String
    let onRequest: (PaykitPaymentRequestTarget) -> Void

    @State private var isPayLoading = false
    @State private var payTask: Task<Void, Never>?

    private var target: PaykitPaymentRequestTarget? {
        paymentRequests.eligibleTarget(publicKey: publicKey)
    }

    private var contactName: String {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, publicKey) }?.displayName
            ?? PubkyPublicKeyFormat.displayTruncated(publicKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__payment_request_or_pay"))

            Spacer()

            Image("coin-stack-4")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer()

            DisplayText(t("wallet__payment_request_or_pay_headline"), accentColor: .purpleAccent)
                .padding(.bottom, 8)
            BodyMText(
                t("wallet__payment_request_or_pay_description", variables: ["contact": contactName]),
                textColor: .white64
            )
            .padding(.bottom, 24)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__pay"),
                    variant: .secondary,
                    icon: Image("arrow-up").resizable().frame(width: 16, height: 16),
                    isLoading: isPayLoading
                ) {
                    let task = Task { await payContact() }
                    payTask = task
                    await task.value
                }
                CustomButton(
                    title: t("wallet__payment_request_request"),
                    icon: Image("arrow-down").resizable().frame(width: 16, height: 16),
                    isDisabled: target == nil || isPayLoading
                ) {
                    if let target {
                        onRequest(target)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RequestOrPaySheet")
        .onDisappear {
            payTask?.cancel()
        }
    }

    private func payContact() async {
        isPayLoading = true
        defer { isPayLoading = false }
        await PaymentNavigationHelper.openPrivateContactPayment(
            publicKey: publicKey,
            app: app,
            currency: currency,
            settings: settings,
            wallet: wallet,
            alternativeOnchainBalanceSats: hwWalletManager.maximumFundingBalanceSats
        ) { route in
            sheets.hideSheetBeforePerforming(reason: "Opening contact payment") {
                sheets.showSheet(.send, data: SendConfig(view: route))
            }
        }
    }
}

struct PaymentRequestRecipientView: View {
    let onSelect: (PaykitPaymentRequestTarget) -> Void

    var body: some View {
        PaykitRecipientPicker(
            selectedTarget: nil,
            onSelect: onSelect,
            accessibilityIdentifier: "PaymentRequestRecipient",
            testIdentifierPrefix: "PaymentRequest"
        ) {
            SheetHeader(title: t("wallet__payment_request_choose_recipient"), showBackButton: true)
        } footer: {
            EmptyView()
        }
    }
}

struct PaykitRecipientPicker<Header: View, Footer: View>: View {
    @EnvironmentObject private var contactsManager: ContactsManager
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let selectedTarget: PaykitPaymentRequestTarget?
    let onSelect: (PaykitPaymentRequestTarget) -> Void
    let accessibilityIdentifier: String
    let testIdentifierPrefix: String
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    @State private var recipientQuery = ""

    private var recipientTargets: [PaykitPaymentRequestTarget] {
        paymentRequests.eligibleTargets
            .filter { target in
                let query = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                return query.isEmpty
                    || target.publicKey.localizedCaseInsensitiveContains(query)
                    || displayName(for: target).localizedCaseInsensitiveContains(query)
            }
            .sorted {
                displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header()

            recipientInput
                .padding(.bottom, 32)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("contacts__nav_title").localizedUppercase, textColor: .white64, lineHeight: 18)
                        .padding(.bottom, 16)
                    CustomDivider()
                    if recipientTargets.isEmpty {
                        BodyMText(
                            t(
                                recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "wallet__payment_request_recipient_unavailable"
                                    : "wallet__payment_request_recipient_no_match"
                            ),
                            textColor: .white64
                        )
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .accessibilityIdentifier("\(testIdentifierPrefix)RecipientUnavailable")
                    }
                    ForEach(recipientTargets) { target in
                        recipientRow(target)
                    }
                }
            }

            footer()
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var recipientInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_recipient").localizedUppercase, textColor: .white64, lineHeight: 18)

            HStack(spacing: 8) {
                TextField(
                    t("wallet__payment_request_enter_pubky"),
                    text: $recipientQuery,
                    backgroundColor: .clear,
                    testIdentifier: "\(testIdentifierPrefix)RecipientFilter",
                    contentPadding: 0
                )
                .frame(minHeight: 20)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)

                Button {
                    if let clipboard = UIPasteboard.general.string {
                        recipientQuery = PubkyPublicKeyFormat.bounded(clipboard)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image("clipboard")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        CaptionBText(t("common__paste"), textColor: .textPrimary)
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(testIdentifierPrefix)RecipientPaste")
            }
            .padding(16)
            .background(Color.white10)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func contact(for target: PaykitPaymentRequestTarget) -> PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, target.publicKey) }
    }

    private func displayName(for target: PaykitPaymentRequestTarget) -> String {
        contact(for: target)?.displayName ?? target.publicKey
    }

    @ViewBuilder
    private func recipientRow(_ target: PaykitPaymentRequestTarget) -> some View {
        if let contact = contact(for: target) {
            PubkyContactRow(contact: contact, verticalPadding: 24, isSelected: selectedTarget == target) {
                onSelect(target)
            }
            .accessibilityIdentifier("\(testIdentifierPrefix)Contact\(contact.publicKey)")
        } else {
            Button {
                onSelect(target)
            } label: {
                HStack(spacing: 16) {
                    ContactAvatarLetter(source: target.publicKey, size: 48)
                    BodyMSBText(PubkyPublicKeyFormat.displayTruncated(target.publicKey))
                    Spacer()
                    if selectedTarget == target {
                        Image("check-mark")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.brandAccent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(testIdentifierPrefix)Target-\(target.id)")
            CustomDivider()
        }
    }
}

struct PaymentRequestAmountView: View {
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel

    let initialDraft: PaykitPaymentRequestDraft
    let target: PaykitPaymentRequestTarget?
    let onContinue: (PaykitPaymentRequestDraft) -> Void
    var onBack: (() -> Void)?
    var testIdentifierPrefix = "PaymentRequest"
    var allowedAssets: [PaykitAsset] = [.btc, .usd]

    @State private var amountViewModel = AmountInputViewModel()
    @State private var asset: PaykitAsset = .btc
    @State private var dollarAmount = ""
    @State private var conversionError = false
    @State private var didLoadAmount = false
    @State private var entryConversion = PaykitAmountEntryConversion()

    private var amount: PaykitAmount? {
        asset == .btc ? PaykitAmount(asset: .btc, atomic: amountViewModel.amountSats) : try? parsePaykitAmountInput(asset: .usd, value: dollarAmount)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    SheetHeader(
                        title: t("wallet__payment_request_amount"),
                        showBackButton: true,
                        action: target == nil ? nil : AnyView(targetAvatar),
                        onBack: onBack
                    )

                    ZStack(alignment: .bottomLeading) {
                        NumberPadTextField(viewModel: amountViewModel, showEditButton: false, isFocused: true,
                                           testIdentifier: "\(testIdentifierPrefix)AmountField")
                            .opacity(asset == .btc ? 1 : 0)
                            .accessibilityHidden(asset != .btc)
                        if asset == .usd {
                            NumberPadAmountText(value: dollarAmount.isEmpty ? "0" : dollarAmount, symbol: "$")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("\(testIdentifierPrefix)AmountField")
                        }
                    }

                    Spacer().frame(height: 16)

                    amountControls(showUnit: allowedAssets.contains(.btc))
                        .hidden()
                        .overlay(alignment: .topTrailing) {
                            amountControls(showUnit: asset == .btc)
                        }
                        .padding(.bottom, 16)

                    if conversionError {
                        BodySText(t("wallet__payment_request_rate_unavailable"), textColor: .white64)
                    }
                    CustomDivider()
                        .accessibilityIdentifier("\(testIdentifierPrefix)AmountDivider")
                    Spacer(minLength: 16)
                    NumberPad(
                        type: asset == .usd ? .decimal : amountViewModel.getNumberPadType(currency: currency),
                        errorKey: amountViewModel.errorKey
                    ) { key in
                        entryConversion.reset()
                        if asset == .usd {
                            dollarAmount = NumberPadInputHandler.handleInput(
                                key: key,
                                current: dollarAmount,
                                maxLength: 16,
                                maxDecimals: 2
                            )
                        } else {
                            amountViewModel.handleNumberPadInput(key, currency: currency)
                        }
                    }

                    Spacer(minLength: 24)

                    CustomButton(title: t("common__continue"), isDisabled: !allowedAssets.contains(asset) || (amount?.atomic ?? 0) == 0) {
                        guard allowedAssets.contains(asset), let amount else { return }
                        onContinue(
                            PaykitPaymentRequestDraft(
                                amount: amount, acceptedPaymentEndpointIdentifiers: initialDraft.acceptedPaymentEndpointIdentifiers,
                                note: initialDraft.note,
                                expiresAt: initialDraft.expiresAt
                            )
                        )
                    }
                    .accessibilityIdentifier("\(testIdentifierPrefix)AmountContinue")
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .task {
            guard !didLoadAmount else { return }
            didLoadAmount = true
            asset = initialDraft.amount.asset == .btc ? .btc : .usd
            guard allowedAssets.contains(asset) else {
                asset = allowedAssets.first ?? .btc
                return
            }
            if asset == .btc {
                amountViewModel.updateFromSats(initialDraft.amount.atomic, currency: currency)
            } else {
                dollarAmount = initialDraft.amount.atomic == 0 ? "" : initialDraft.amount.inputValue
            }
        }
    }

    private func amountControls(showUnit: Bool) -> some View {
        HStack {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { amountActions(showUnit: showUnit) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 8) { amountActions(showUnit: showUnit) }
            }
        }
    }

    @ViewBuilder
    private func amountActions(showUnit: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(allowedAssets, id: \.self) { choice in
                NumberPadActionButton(text: choice.rawValue.uppercased(), color: choice == .usd ? .usdtAccent : .brandAccent,
                                      variant: asset == choice ? .primary : .secondary)
                {
                    guard choice != asset else { return }
                    do {
                        let converted = try entryConversion.converted(amount, to: choice, rate: currency.paykitRate, at: Date())
                        if choice == .usd {
                            dollarAmount = converted.atomic == 0 ? "" : converted.inputValue
                        } else {
                            amountViewModel.updateFromSats(converted.atomic, currency: currency)
                        }
                        asset = choice
                        conversionError = false
                    } catch { conversionError = true }
                }
                .accessibilityIdentifier("\(testIdentifierPrefix)Asset-\(choice.rawValue)")
            }
        }
        if showUnit {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down", color: .brandAccent
            ) {
                withAnimation { amountViewModel.togglePrimaryDisplay(currency: currency) }
            }
            .accessibilityIdentifier("\(testIdentifierPrefix)AmountUnit")
        }
    }

    @ViewBuilder
    private var targetAvatar: some View {
        if let target {
            if let contact = contactsManager.contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, target.publicKey) }) {
                PubkyContactAvatar(contact: contact, size: 24)
            } else {
                ContactAvatarLetter(source: target.publicKey, size: 24)
            }
        }
    }
}

struct PaymentRequestDetailsView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let initialDraft: PaykitPaymentRequestDraft
    let target: PaykitPaymentRequestTarget
    let onEditAmount: (PaykitPaymentRequestDraft) -> Void
    let onSent: (PaykitPaymentRequest) -> Void

    @State private var note = ""
    @EnvironmentObject private var wallet: WalletViewModel
    @State private var restrictedEndpoints: [String]?
    @State private var expiration = PaymentRequestExpiration.week
    @FocusState private var isNoteFocused: Bool

    private var contact: PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, target.publicKey) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__payment_request"), showBackButton: true,
                        topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    amount
                    noteInput
                    recipient
                    expirationPicker
                    acceptedMethods
                }
                .padding(.bottom, 24)
            }

            CustomButton(
                title: t("wallet__payment_request_send_request"),
                icon: Image("paper-plane-tilt").resizable().frame(width: 16, height: 16),
                isDisabled: selectedEnabledEndpoints.isEmpty,
                isLoading: paymentRequests.isCreatingRequest,
                titleKerning: 0, titleLineHeight: 20
            ) {
                await sendRequest()
            }
            .buttonBottomPadding(isFocused: isNoteFocused)
            .accessibilityIdentifier("PaymentRequestSend")
        }
        .padding(.horizontal, 16)
        .modifier(SheetBackgroundModifier(base: .gray7, applyGradient: false))
        .preference(key: SheetBackgroundPreferenceKey.self, value: .gray7)
        .navigationBarHidden(true)
        .interactiveDismissDisabled(paymentRequests.isCreatingRequest)
        .task {
            restrictedEndpoints = initialDraft.acceptedPaymentEndpointIdentifiers
            note = initialDraft.note
            if initialDraft.expiresAt > Date() {
                expiration = .closest(to: initialDraft.expiresAt, from: Date())
            }
        }
        .onChange(of: note) { _, value in
            if value.count > 256 {
                note = String(value.prefix(256))
            }
        }
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 16) {
            CaptionMText(t("wallet__payment_request_amount"), textColor: .white64, lineHeight: 18)
            Button { onEditAmount(currentDraft) } label: {
                HStack(spacing: 16) {
                    if initialDraft.amount.asset == .btc {
                        MoneyText(sats: Int(clamping: initialDraft.amount.atomic), unitType: .primary, size: .display,
                                  symbol: true, color: .textPrimary, symbolColor: .textSecondary, fillsWidth: false)
                    } else {
                        PaykitAmountText(amount: initialDraft.amount, size: .display)
                    }
                    Image("pencil").resizable().frame(width: 24, height: 24).foregroundColor(.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("PaymentRequestEditAmount")
        }
    }

    private var enabledEndpoints: [String] {
        PaykitPaymentRequestService.acceptedPaymentEndpointIdentifiers(canReceiveLightning: wallet.hasUsableChannels)
    }

    private var selectedEnabledEndpoints: [String] {
        enabledEndpoints.filter { restrictedEndpoints?.contains($0) ?? true }
    }

    private var acceptedMethods: some View {
        PaykitAcceptedMethods(
            title: t("wallet__payment_request_accepted_methods"), available: enabledEndpoints,
            selected: selectedEnabledEndpoints, identifierPrefix: "PaymentRequest"
        ) { option in
            let endpoints = option.endpoints(in: enabledEndpoints)
            let selected = selectedEnabledEndpoints
            restrictedEndpoints = endpoints.contains(where: selected.contains)
                ? selected.filter { !endpoints.contains($0) }
                : selected + endpoints.filter { !selected.contains($0) }
        }
    }

    private var noteInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__note").localizedUppercase, textColor: .white64, kerning: 1, lineHeight: 18)
            NoteTextEditor(
                text: $note,
                placeholder: t("wallet__receive_note_placeholder"),
                testIdentifier: "PaymentRequestNote",
                isFocused: $isNoteFocused,
                minHeight: 20,
                maxHeight: 20,
                backgroundColor: .white10,
                textKerning: 0.4, textLineHeight: 20
            )
        }
    }

    private var recipient: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_recipient").localizedUppercase, textColor: .white64, lineHeight: 18)
            HStack(spacing: 16) {
                if let contact {
                    PubkyContactAvatar(contact: contact, size: 40)
                } else {
                    ContactAvatarLetter(source: target.publicKey, size: 40)
                }
                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(contact?.displayName ?? PubkyPublicKeyFormat.displayTruncated(target.publicKey),
                                kerning: 0, lineHeight: 22)
                    if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CaptionBText(note, textColor: .white64, kerning: 0, lineHeight: 18)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if initialDraft.amount.asset == .btc {
                    MoneyCell(sats: Int(clamping: initialDraft.amount.atomic), prefix: "")
                } else {
                    PaykitAmountText(amount: initialDraft.amount)
                }
            }
            .padding(16)
            .background(Color.gray6)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var expirationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_expires").localizedUppercase, textColor: .white64, lineHeight: 18)
            SegmentedControl(selectedTab: $expiration, tabs: PaymentRequestExpiration.allCases,
                             inactiveColor: .white.opacity(0.5), labelKerning: 0, labelLineHeight: 18)
        }
    }

    private var currentDraft: PaykitPaymentRequestDraft {
        PaykitPaymentRequestDraft(
            amount: initialDraft.amount, acceptedPaymentEndpointIdentifiers: restrictedEndpoints,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: expiration.date(from: Date())
        )
    }

    private func sendRequest() async {
        do {
            let request = try await paymentRequests.propose(currentDraft, to: target)
            guard paymentRequests.outgoingRequests.contains(where: { $0.id == request.id }) else { return }
            onSent(request)
        } catch {
            app.toast(error)
        }
    }
}

struct PaymentRequestSentView: View {
    @EnvironmentObject private var sheets: SheetViewModel

    let request: PaykitPaymentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t(request.deliveryStatus == .sent
                    ? "wallet__payment_request_sent_title"
                    : "subscriptions__proposal_queued_title"))

            Spacer(minLength: 8)

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            DisplayText(t("wallet__payment_request_sent_headline"), accentColor: .purpleAccent)
                .padding(.bottom, 8)

            BodyMText(description, textColor: .white64)
                .padding(.bottom, 16)

            PaymentRequestCard(
                request: request,
                isHighlighted: false
            )

            Spacer(minLength: 32)

            CustomButton(title: t("common__ok")) {
                sheets.hideSheet(reason: "Payment request created")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .accessibilityIdentifier("PaymentRequestSent")
    }

    private var description: String {
        request.deliveryStatus == .sent
            ? t("wallet__payment_request_sent_description")
            : t("wallet__payment_request_queued_description")
    }
}
