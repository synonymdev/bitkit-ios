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
                    CaptionMText(t("contacts__nav_title").localizedUppercase, textColor: .white64)
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
            CaptionMText(t("wallet__payment_request_recipient").localizedUppercase, textColor: .white64)

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

    @State private var amountViewModel = AmountInputViewModel()
    @State private var asset: PaykitAsset = .btc
    @State private var dollarAmount = ""
    @State private var conversionError = false

    private var amount: PaykitAmount? {
        asset == .btc ? PaykitAmount(asset: .btc, atomic: amountViewModel.amountSats) : try? PaykitAmount(asset: .usd, value: dollarAmount)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: t("wallet__payment_request_amount"),
                showBackButton: true,
                action: target == nil ? nil : AnyView(targetAvatar),
                onBack: onBack
            )

            if asset == .usd {
                NumberPadAmountText(value: dollarAmount.isEmpty ? "0" : dollarAmount, symbol: "$")
                    .accessibilityIdentifier("\(testIdentifierPrefix)AmountField")
            } else {
                NumberPadTextField(viewModel: amountViewModel, showEditButton: false, isFocused: true,
                                   testIdentifier: "\(testIdentifierPrefix)AmountField")
            }

            Spacer()

            HStack {
                Spacer()
                ForEach([PaykitAsset.btc, .usd], id: \.self) { choice in
                    NumberPadActionButton(text: choice.rawValue.uppercased(), color: choice == .usd ? .usdtAccent : .brandAccent,
                                          variant: asset == choice ? .primary : .secondary)
                    {
                        guard choice != asset else { return }
                        do {
                            if let current = amount, current.atomic > 0 {
                                let converted = try current.converted(to: choice, rate: currency.paykitRate, at: Date())
                                if choice == .usd { dollarAmount = converted.value }
                                else { amountViewModel.updateFromSats(converted.atomic, currency: currency) }
                            }
                            asset = choice
                            conversionError = false
                        } catch { conversionError = true }
                    }
                    .accessibilityIdentifier("\(testIdentifierPrefix)Asset-\(choice.rawValue)")
                }
            }
            .padding(.bottom, 12)

            if conversionError {
                BodySText(t("wallet__payment_request_rate_unavailable"), textColor: .white64)
            }
            NumberPad(
                type: asset == .usd ? .decimal : amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey
            ) { key in
                if asset == .usd { dollarAmount = NumberPadInputHandler.handleInput(key: key, current: dollarAmount, maxLength: 16, maxDecimals: 2) }
                else { amountViewModel.handleNumberPadInput(key, currency: currency) }
            }

            CustomButton(title: t("common__continue"), isDisabled: (amount?.atomic ?? 0) == 0) {
                guard let amount else { return }
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
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .task {
            asset = initialDraft.amount.asset == .btc ? .btc : .usd
            if asset == .btc { amountViewModel.updateFromSats(initialDraft.amount.atomic, currency: currency) }
            else { dollarAmount = initialDraft.amount.value }
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
            SheetHeader(title: t("wallet__payment_request"), showBackButton: true)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    amount
                    noteInput
                    recipient
                    acceptedMethods
                    expirationPicker
                }
            }

            CustomButton(
                title: t("wallet__payment_request_send_request"),
                icon: Image("airplane").resizable().frame(width: 16, height: 16),
                isDisabled: (restrictedEndpoints ?? enabledEndpoints).isEmpty,
                isLoading: paymentRequests.isCreatingRequest
            ) {
                await sendRequest()
            }
            .buttonBottomPadding(isFocused: isNoteFocused)
            .accessibilityIdentifier("PaymentRequestSend")
        }
        .padding(.horizontal, 16)
        .sheetBackground()
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
        Button { onEditAmount(currentDraft) } label: {
            HStack(spacing: 8) {
                if initialDraft.amount.asset == .btc {
                    MoneyText(sats: Int(clamping: initialDraft.amount.atomic), unitType: .primary, size: .display,
                              symbol: true, color: .textPrimary, symbolColor: .textSecondary)
                } else { NumberPadAmountText(value: initialDraft.amount.value, symbol: "$") }
                Image("pencil").resizable().frame(width: 24, height: 24).foregroundColor(.textPrimary)
            }
        }.buttonStyle(.plain)
    }

    private var enabledEndpoints: [String] {
        PaykitPaymentRequestService.acceptedPaymentEndpointIdentifiers(canReceiveLightning: wallet.hasUsableChannels)
    }

    private var acceptedMethodGroups: [[PublicPaykitService.MethodId]] {
        let groups: [[PublicPaykitService.MethodId]] = [
            PublicPaykitService.MethodId.onchainPreferenceOrder,
            [.bitcoinLightningBolt11, .bitcoinLightningLnurl],
            [.usdtArbitrum],
        ]
        return groups.map { $0.filter { enabledEndpoints.contains($0.rawValue) } }.filter { !$0.isEmpty }
    }

    private var acceptedMethods: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_accepted_methods"), textColor: .white64)
            HStack {
                ForEach(acceptedMethodGroups, id: \.self) { methods in
                    let endpoints = methods.map(\.rawValue)
                    let usdt = methods.contains(.usdtArbitrum)
                    let lightning = methods.contains(.bitcoinLightningBolt11) || methods.contains(.bitcoinLightningLnurl)
                    let selected = restrictedEndpoints ?? enabledEndpoints
                    let isSelected = endpoints.allSatisfy(selected.contains)
                    NumberPadActionButton(text: usdt ? "USDT" : t(lightning ? "lightning__spending" : "lightning__savings").uppercased(),
                                          color: usdt ? .usdtAccent : lightning ? .purpleAccent : .brandAccent,
                                          variant: isSelected ? .primary : .secondary)
                    {
                        restrictedEndpoints = isSelected
                            ? selected.filter { !endpoints.contains($0) }
                            : selected + endpoints.filter { !selected.contains($0) }
                    }
                    .accessibilityIdentifier("PaymentRequestAccept-\(usdt ? "usdt" : lightning ? "spending" : "savings")")
                }
            }
        }
    }

    private var noteInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__note").localizedUppercase, textColor: .white64)
            NoteTextEditor(
                text: $note,
                placeholder: t("wallet__receive_note_placeholder"),
                testIdentifier: "PaymentRequestNote",
                isFocused: $isNoteFocused
            )
        }
    }

    private var recipient: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_recipient").localizedUppercase, textColor: .white64)
            HStack(spacing: 16) {
                if let contact {
                    PubkyContactAvatar(contact: contact, size: 40)
                } else {
                    ContactAvatarLetter(source: target.publicKey, size: 40)
                }
                VStack(alignment: .leading, spacing: 4) {
                    BodyMSBText(contact?.displayName ?? PubkyPublicKeyFormat.displayTruncated(target.publicKey))
                    if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CaptionText(note, textColor: .white64)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if initialDraft.amount.asset == .btc { MoneyCell(sats: Int(clamping: initialDraft.amount.atomic), prefix: "") }
                else { BodyMSBText("$" + initialDraft.amount.value) }
            }
            .padding(16)
            .background(Color.gray6)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var expirationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__payment_request_expires").localizedUppercase, textColor: .white64)
            SegmentedControl(selectedTab: $expiration, tabs: PaymentRequestExpiration.allCases)
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
