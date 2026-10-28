import BitkitCore
import PhotosUI
import SwiftUI

struct UsdtSendView: View {
    var onDetails: (String) -> Void
    var initialRecipient = ""
    var initialAmount = ""
    var embedded = false
    /// Shown inside the send sheet's navigation stack: back from the amount step returns to the address step.
    var hosted = false
    var paymentContext: ContactPaymentContext?
    var quotePayment: ((String, String, UsdtDestination) async throws -> UsdtQuote)?
    var authenticatePayment: (() async -> Bool)?
    var sendPayment: ((UsdtQuote) async throws -> Void)?
    var fundingSourceButton: AnyView?
    var onReviewChange: ((Bool) -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNetworks = false
    @State private var recipient = ""
    @State private var amount = ""
    @State private var destination: UsdtDestination = .arbitrum
    @State private var destinations = Env.usdtDestinations
    @State private var quote: UsdtQuote?
    @State private var maximumQuote: UsdtQuote?
    @State private var preparedQuote: UsdtPreparedQuote?
    @State private var isMaximumAmount = false
    @State private var preparingMaximum = false
    @State private var editingRecipient = false
    @State private var editingAmount = false
    @State private var busy = false
    @State private var error: String?
    @State private var pin = false
    @State private var submitted = false
    @State private var hasStartedInitialPayment = false
    @State private var automaticPayment = false
    @State private var paymentComplete = false
    @State private var showDetails = false
    @State private var showFullRecipient = false
    @State private var warning: String?
    @State private var confirmedWarnings: Set<String> = []
    @State private var warningContinuation: CheckedContinuation<Bool, Never>?
    @State private var pinContinuation: CheckedContinuation<Bool, Never>?
    @State private var swipeProgress: CGFloat = 0
    @FocusState private var recipientFocused: Bool

    init(
        onDetails: @escaping (String) -> Void,
        initialRecipient: String = "",
        initialAmount: String = "",
        embedded: Bool = false,
        hosted: Bool = false,
        paymentContext: ContactPaymentContext? = nil,
        quotePayment: ((String, String, UsdtDestination) async throws -> UsdtQuote)? = nil,
        authenticatePayment: (() async -> Bool)? = nil,
        sendPayment: ((UsdtQuote) async throws -> Void)? = nil,
        fundingSourceButton: AnyView? = nil,
        onReviewChange: ((Bool) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onDetails = onDetails
        self.initialRecipient = initialRecipient
        self.initialAmount = initialAmount
        self.embedded = embedded
        self.hosted = hosted
        self.paymentContext = paymentContext
        self.quotePayment = quotePayment
        self.authenticatePayment = authenticatePayment
        self.sendPayment = sendPayment
        self.fundingSourceButton = fundingSourceButton
        self.onReviewChange = onReviewChange
        self.onBack = onBack
        self.onClose = onClose
        _recipient = State(initialValue: initialRecipient)
        _amount = State(initialValue: (try? usdtParseAmount(value: initialAmount)) == 0 ? "" : initialAmount)
        _editingAmount = State(initialValue: !initialRecipient.isEmpty)
    }

    private var paymentRequest: PaykitPaymentRequest? {
        paymentContext?.incomingPaymentRequest
    }

    private var requestNote: String? {
        guard let note = paymentRequest?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    private var contact: PubkyContact? {
        guard let key = paymentContext?.publicKey else { return nil }
        return contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, key) }
    }

    private var contactName: String {
        contact?.displayName ?? PubkyPublicKeyFormat.displayTruncated(paymentContext?.publicKey ?? "")
    }

    private var submittedStatus: UsdtTransferStatus? {
        usdt.transfers.first { $0.id == quote?.id }?.status
    }

    private var submissionFailed: Bool {
        submittedStatus == .failed || submittedStatus == .replaced
    }

    private var bridgeNeedsAttention: Bool {
        submittedStatus == .bridgeNeedsAttention || submittedStatus == .bridgeFailed
    }

    private var title: String {
        if showingNetworks {
            return t("usdt__receive_network_title")
        }
        if submitted, !busy {
            if submittedStatus == .confirmed {
                return t("usdt__payment_sent")
            }
            if error != nil {
                return t("wallet__payment_request_expired")
            }
            if submittedStatus == .bridgeRefunded {
                return t("usdt__deposit_refunded")
            }
            if bridgeNeedsAttention {
                return t("usdt__bridge_attention")
            }
            return t(submissionFailed ? "wallet__send_error_tx_failed" : "usdt__submitted")
        }
        if quote != nil || paymentRequest != nil {
            return t(paymentRequest == nil ? "wallet__send_review" : "wallet__payment_request")
        }
        return t(editingAmount ? "usdt__amount" : "usdt__send_title")
    }

    private var isReviewingPayment: Bool {
        paymentContext != nil && settings.isUsdtEnabled && quote != nil && !submitted
    }

    var body: some View {
        Group {
            if !settings.isUsdtEnabled, !submitted {
                UsdtIntroContent(isEnablePrompt: true, onDecline: {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }, onEnable: { settings.usdtPreference = .enabled })
            } else if paymentContext?.isInitialSubscriptionPayment == true, submitted, !busy, submittedStatus == .confirmed {
                SubscriptionSuccessView(paymentProofKind: .usdt) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .navigationBarHidden(true)
                .allowSwipeBack(false)
            } else if embedded || hosted {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task(id: "\(scenePhase == .active)-\(submitted)") {
            guard scenePhase == .active, submitted else { return }
            if busy, let quote {
                if quote.destination == .arbitrum {
                    await usdt.waitForTransfer(quote.id)
                }
                if submittedStatus == .confirmed {
                    Task { await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt) }
                    paymentComplete = true
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                busy = false
            }
            while !Task.isCancelled, [.pending, .bridging, .bridgeNeedsAttention].contains(submittedStatus) {
                await usdt.refresh()
                guard [.pending, .bridging, .bridgeNeedsAttention].contains(submittedStatus) else { break }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt)
        }
        .overlay {
            if automaticPayment, busy {
                InitialSubscriptionPaymentProgress()
            }
        }
        .preference(key: SheetBackgroundPreferenceKey.self, value: .gray7)
        .onAppear { usdt.isSendPresented = true }
        .onDisappear {
            usdt.isSendPresented = false
            preparedQuote = nil
            resolveWarning(proceed: false)
        }
        .onChange(of: isReviewingPayment, initial: true) { _, reviewing in
            onReviewChange?(reviewing)
        }
        .task(id: settings.isUsdtEnabled) {
            if !embedded {
                do { destinations = try await usdt.sendDestinations() }
                catch { Logger.warn("Could not load USDT bridge destinations", context: "UsdtSendView") }
            }
            guard !Task.isCancelled, settings.isUsdtEnabled, !busy, !submitted, quote == nil, maximumQuote == nil,
                  editingAmount, !showingNetworks,
                  !initialRecipient.isEmpty, recipient == initialRecipient, amount == initialAmount, destination == .arbitrum,
                  (try? parsePaykitAmountInput(asset: .usdt, value: amount)) != nil else { return }
            automaticPayment = !hasStartedInitialPayment && paymentContext?.initialUsdtSubscriptionPayment()?.amount.value == amount
            hasStartedInitialPayment = true
            busy = true
            do { quote = try await prepareQuote() }
            catch { self.error = UsdtWalletManager.message(for: error) }
            busy = false
            if automaticPayment, !Task.isCancelled, quote != nil {
                // PIN navigation can cancel the view task while authorization is awaiting its result.
                Task { @MainActor in try? await confirmPayment() }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, showBackButton: !submitted,
                        action: paymentContext == nil ? nil : AnyView(SendContactHeaderAvatar(publicKey: paymentContext?.publicKey)),
                        topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8, onBack: goBack)
                .disabled(busy)
            if showingNetworks {
                networkPicker
            } else if submitted, !busy {
                submittedContent
            } else if let quote {
                confirmation(quote)
            } else if paymentRequest != nil {
                preparingConfirmation
            } else if editingAmount {
                amountContent
            } else if editingRecipient {
                manualContent
            } else {
                recipientContent
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if submitted, !busy, submittedStatus == .confirmed {
                PaymentCelebration(isOnchain: true, isReceived: false, confettiColor: .usdtAccent, isUsdt: true)
            }
        }
        .background(Color.gray7)
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $pin) {
            SendPinScreen(onCancel: { resolvePin(verified: false) }, onPinVerified: { resolvePin(verified: true) })
        }
        .onChange(of: pin) { _, isShown in
            if !isShown {
                resolvePin(verified: false)
            }
        }
        .interactiveDismissDisabled(busy || pin)
        .alert(t("common__are_you_sure"), isPresented: .constant(warning != nil), presenting: warning) { _ in
            Button(t("common__cancel"), role: .cancel) { resolveWarning(proceed: false) }
            Button(t("wallet__send_yes")) { resolveWarning(proceed: true) }
        } message: { warning in
            Text(t(warning))
        }
    }

    private var networkSelector: some View {
        SendSectionView(t("usdt__network")) { networkButton }
    }

    private var networkButton: some View {
        Button { recipientFocused = false; showingNetworks = true } label: {
            HStack(spacing: 8) {
                Image("usdt-network").resizable().scaledToFit().frame(width: 16, height: 16).foregroundColor(.usdtAccent)
                CaptionBText(destination.label, kerning: 0, lineHeight: 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 28)
            .background(Color.white01, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white16, lineWidth: 1))
        }
        .disabled(embedded || destinations.count < 2 || busy)
        .accessibilityIdentifier("UsdtNetwork")
    }

    private var networkPicker: some View {
        UsdtNetworkPicker(note: t("usdt__send_network_note")) {
            ForEach(destinations, id: \.self) { item in
                UsdtNetworkRow(title: item.label, selected: destination == item, identifier: "UsdtNetwork-\(item.label)") {
                    showingNetworks = false
                    guard destination != item else { return }
                    destination = item
                    if isMaximumAmount {
                        amount = ""
                    }
                    isMaximumAmount = false
                    maximumQuote = nil
                    quote = nil
                    error = nil
                    if !recipient.isEmpty, (try? usdtValidateRecipient(value: recipient, destination: item)) == nil {
                        editingAmount = false
                        editingRecipient = true
                    }
                }
            }
        }
    }

    private var recipientContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 8) {
                    networkSelector.padding(.bottom, 8)
                    Scanner(
                        accentColor: .usdtAccent,
                        permissionDescription: t("usdt__camera_permission"),
                        onScan: {
                            payload in if let value = payload.string {
                                useRecipient(value)
                            }
                        },
                        onImageSelection: readImage
                    )
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                    RectangleButton(
                        icon: "clipboard", iconColor: .usdtAccent, title: t("common__paste"), testID: "UsdtPaste"
                    ) {
                        if let value = UIPasteboard.general.string, !value.isEmpty {
                            _ = ClipboardPromptHistory().recordInspection(
                                changeCount: UIPasteboard.general.changeCount,
                                supportedValue: value.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            useRecipient(value)
                        } else {
                            error = t("wallet__send_clipboard_empty_text")
                        }
                    }
                    RectangleButton(
                        icon: "pencil", iconColor: .usdtAccent, title: t("wallet__recipient_manual"), testID: "UsdtManual"
                    ) { editingRecipient = true }
                    if let error {
                        BodySText(error, textColor: .brandAccent)
                    }
                    BodySText(t("usdt__network_warning"), textColor: .textSecondary).padding(.top, 8)
                }
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    private var manualContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            networkSelector.padding(.bottom, 8)
            CaptionMText(t("wallet__send_to"))
            PaymentAddressInput(
                text: $recipient, isFocused: $recipientFocused,
                placeholder: t("usdt__address"), testIdentifier: "UsdtRecipient"
            )
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError")
            }
            Spacer(minLength: 16)
            CustomButton(title: t("common__continue"), isDisabled: recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                useRecipient(recipient)
            }
            .buttonBottomPadding(isFocused: recipientFocused)
            .accessibilityIdentifier("UsdtRecipientContinue")
        }
        .task { recipientFocused = true }
        .onChange(of: recipient) { _, _ in error = nil }
    }

    private var amountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount)
                .accessibilityIdentifier("UsdtAmount")
            Spacer()
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError").padding(.bottom, 16)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom) {
                    availableBalance
                    Spacer(minLength: 8)
                    amountActions
                }
                VStack(alignment: .leading, spacing: 16) {
                    availableBalance
                    HStack {
                        Spacer(minLength: 0)
                        amountActions
                    }
                }
            }
            .padding(.bottom, 16)
            CustomDivider()
            NumberPad(
                type: .decimal,
                isDisabled: busy || embedded,
                onDeleteLongPress: { amount = ""; maximumQuote = nil; isMaximumAmount = false; error = nil },
                onPress: enterAmount
            )
            CustomButton(title: t("common__continue"), isDisabled: busy || (try? parsePaykitAmountInput(asset: .usdt, value: amount)) == nil,
                         isLoading: busy && !preparingMaximum, titleKerning: 0, titleLineHeight: 20)
            {
                guard !busy, quote == nil else { return }
                automaticPayment = false
                busy = true
                error = nil
                defer { busy = false }
                do {
                    if let maximumQuote {
                        let fresh = maximumQuote.expiresAt > UInt64(Date().timeIntervalSince1970) + 5
                        let prepared: UsdtQuote = if fresh {
                            maximumQuote
                        } else {
                            try await usdt.quoteMaximum(recipient: recipient, destination: destination)
                        }
                        quote = prepared
                        amount = usdtFormatAmount(amount: prepared.amount)
                    } else {
                        quote = try await prepareQuote()
                    }
                    showDetails = false
                    confirmedWarnings = []
                } catch is CancellationError {
                } catch {
                    self.error = UsdtWalletManager.message(for: error)
                    Logger.warn("Failed to quote USDT: \(UsdtWalletManager.message(for: error))", context: "UsdtSendView")
                }
            }
            .accessibilityIdentifier("UsdtReview")
        }
    }

    private var availableBalance: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionMText(t("wallet__send_available"), kerning: 1, lineHeight: 18)
            BodySSBText(settings.hideBalance ? " • • • • •" : "<accent>$</accent> " + (usdt.balance.map { usdtOverviewAmount($0) } ?? "—"),
                        accentColor: .textSecondary, kerning: 0, lineHeight: 20)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var amountActions: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(text: "USDT", titleKerning: 1, titleLineHeight: 18, color: .usdtAccent, variant: .secondary, disabled: true) {}
            if !embedded {
                NumberPadActionButton(text: t("common__max"), titleKerning: 1, titleLineHeight: 18, color: .usdtAccent, disabled: busy,
                                      isLoading: preparingMaximum)
                {
                    Task { await useMaximum() }
                }
                .accessibilityIdentifier("UsdtMax")
                networkButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var reviewDetailsButton: some View {
        CustomButton(
            title: t(showDetails ? "common__hide_details" : "common__show_details"), size: .small,
            icon: Image(showDetails ? "eye-slash" : "currency-dollar").resizable().frame(width: 16, height: 16)
                .foregroundColor(.usdtAccent), background: Color.white06, showsHighlightShadow: false, titleKerning: 0, titleLineHeight: 13
        ) { showDetails.toggle() }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("UsdtReviewDetails")
    }

    private var preparingConfirmation: some View {
        VStack(alignment: .leading, spacing: 24) {
            UsdtAmountHeader(amount: amount)
            if paymentContext?.endpoints.count ?? 0 > 1, let fundingSourceButton {
                fundingSourceButton.disabled(busy || submitted).frame(maxWidth: .infinity, alignment: .trailing)
            }
            PaymentRequestSummary(contactName: contactName, note: requestNote, accentColor: .usdtAccent)
            PaymentReviewIllustration(imageSize: 329, isPaymentRequest: true).frame(maxHeight: 256)
            Spacer(minLength: 0)
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError")
                CustomButton(title: t("common__try_again"), size: .small, isDisabled: busy) {
                    busy = true
                    defer { busy = false }
                    do { quote = try await prepareQuote(); self.error = nil }
                    catch { self.error = UsdtWalletManager.message(for: error) }
                }
            }
            SwipeButton(title: t("wallet__send_swipe"), accentColor: .usdtAccent, isDisabled: true, isLoading: busy) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UsdtConfirmLoading")
    }

    func confirmation(_ quote: UsdtQuote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), displayAmount: usdtExactAmount(quote.amount))
                            .contentShape(Rectangle()).onTapGesture(perform: goBack)
                            .allowsHitTesting(!busy && !embedded)
                        if !showDetails, paymentContext?.endpoints.count ?? 0 > 1, let fundingSourceButton {
                            fundingSourceButton.disabled(busy || submitted)
                                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 16)
                        }
                        Spacer().frame(height: 24)
                        if showDetails {
                            quoteDetails(quote)
                            if let requestNote {
                                PaymentRequestInvoiceNote(note: requestNote).padding(.top, 16)
                            }
                        } else {
                            if paymentRequest != nil {
                                PaymentRequestSummary(contactName: contactName, note: requestNote, accentColor: .usdtAccent).padding(.bottom, 16)
                            }
                            Spacer(minLength: 0)
                            PaymentReviewIllustration(
                                swipeProgress: busy || paymentComplete ? 1 : swipeProgress,
                                imageSize: 329,
                                isPaymentRequest: paymentRequest != nil
                            )
                            .padding(.top, 16).frame(height: 256)
                        }
                        if let error {
                            BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError")
                        }
                        reviewDetailsButton.padding(.vertical, 24)
                        if showDetails {
                            Spacer(minLength: 0)
                            BodySText(t("usdt__fee_note"), textColor: .textSecondary, kerning: 0, lineHeight: 20)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 24)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .id(showDetails)
            }
            SwipeButton(
                title: t("wallet__send_swipe"), accentColor: .usdtAccent, isDisabled: busy,
                isLoading: busy, isSubmitted: submitted, isComplete: paymentComplete, swipeProgress: $swipeProgress
            ) {
                automaticPayment = false
                try await confirmPayment()
                if !submitted {
                    throw CancellationError()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("UsdtConfirm")
        }
    }

    func quoteDetails(_ quote: UsdtQuote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("usdt__pay_from"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                    if let fundingSourceButton {
                        fundingSourceButton.disabled(busy || submitted)
                    } else {
                        NumberPadActionButton(
                            text: "USDT",
                            titleKerning: 1,
                            titleLineHeight: 18,
                            color: .usdtAccent,
                            variant: .secondary,
                            disabled: true
                        ) {}
                    }
                }
                UsdtDetailCell(title: t("usdt__network"), value: UsdtDestination.arbitrum.label, icon: "usdt-network", minimumValueHeight: 28)
            }
            HStack(alignment: .top, spacing: 16) {
                UsdtDetailCell(title: t("wallet__activity_payment"), value: usdtExactAmount(quote.amount), icon: "user")
                UsdtDetailCell(title: t("wallet__activity_fee"), value: usdtExactAmount(quote.maximumFee), icon: "speed-normal")
            }
            if quote.destination != .arbitrum {
                HStack(alignment: .top, spacing: 16) {
                    UsdtDetailCell(title: t("usdt__recipient_gets"),
                                   value: (quote.bridgeProvider == .orchestra ? "±" : "") + usdtExactAmount(quote.receivedAmount),
                                   icon: "arrow-down-right")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("UsdtRecipientAmount")
                    UsdtDetailCell(
                        title: t("usdt__maximum_total"),
                        value: usdtExactAmount(quote.amount + quote.maximumFee),
                        icon: "arrow-up-right"
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("UsdtMaximumTotal")
                }
            }
            if paymentContext != nil {
                SendSectionView(t(paymentRequest?.isMerchantRequest == true ? "wallet__send_to" : "wallet__payment_request_contact")) {
                    HStack(spacing: 4) {
                        if let contact {
                            PubkyContactAvatar(contact: contact, size: 20)
                        }
                        BodySSBText(contactName).lineLimit(1)
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("wallet__activity_address"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18,
                                alignDividerToBottom: true)
                {
                    BodySSBText(quote.recipient, kerning: 0, lineHeight: 20)
                        .lineLimit(showFullRecipient ? nil : 1).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        .onTapGesture { showFullRecipient.toggle() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(t(showFullRecipient ? "common__hide_details" : "common__show_details"))
                        .accessibilityIdentifier("UsdtReviewAddress")
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if quote.destination != .arbitrum {
                    UsdtDetailCell(title: t("usdt__recipient_network"), value: quote.destination.label, icon: "usdt-network",
                                   alignDividerToBottom: true)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var submittedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let quote {
                UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), displayAmount: usdtOverviewAmount(quote.amount))
                    .padding(.bottom, 32)
            }
            if let error {
                BodyMText(error, textColor: .textSecondary)
            } else if submittedStatus == .bridgeRefunded {
                BodyMText(t("usdt__bridge_refunded_description"), textColor: .textSecondary)
            } else if submittedStatus != .confirmed {
                BodyMText(t(bridgeNeedsAttention ? "usdt__bridge_attention" : submissionFailed ? "usdt__send_failed_description"
                              : quote?.destination == .arbitrum ? "usdt__submitted_description" : "usdt__bridge_submitted_description"),
                textColor: .textSecondary)
            }
            Spacer(minLength: 16)
            if submittedStatus == .confirmed {
                Image("check").resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("UsdtSendSuccess")
            } else if !submissionFailed, !bridgeNeedsAttention, submittedStatus != .bridgeRefunded {
                HourglassLoadingView()
            }
            Spacer(minLength: 16)
            HStack(spacing: 16) {
                CustomButton(title: t("wallet__send_details"), variant: .secondary, isDisabled: quote == nil, shouldExpand: true,
                             titleKerning: 0, titleLineHeight: 20)
                {
                    if let quote {
                        onDetails(quote.id)
                    }
                }
                CustomButton(title: t("common__close"), shouldExpand: true, titleKerning: 0, titleLineHeight: 20) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
            }
        }
    }

    private func useRecipient(_ value: String) {
        guard !editingAmount, quote == nil, !submitted else { return }
        do {
            let request: UsdtPaymentRequest = if value.contains(":") {
                try usdtParsePaymentRequest(value: value)
            } else {
                try UsdtPaymentRequest(recipient: usdtValidateRecipient(value: value, destination: destination), amount: nil, chainId: nil)
            }
            if request.chainId != nil {
                destination = .arbitrum
            }
            recipient = request.recipient
            if let requestedAmount = request.amount {
                amount = requestedAmount == 0 ? "" : usdtFormatAmount(amount: requestedAmount)
            }
        } catch { self.error = UsdtWalletManager.message(for: error); return }
        maximumQuote = nil
        isMaximumAmount = false
        recipientFocused = false
        editingAmount = true
        error = nil
    }

    private func readImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            let payload = try await QRCodeImageDecoder.decode(item)
            guard let value = payload.string else { throw QRCodeImageDecoderError.noQRCode }
            useRecipient(value)
        } catch is CancellationError {
        } catch QRCodeImageDecoderError.invalidImage {
            error = t("other__qr_error_load_image")
        } catch {
            self.error = t("other__qr_error_process_image")
        }
    }

    private func goBack() {
        guard !busy else { return }
        if showingNetworks {
            showingNetworks = false; return
        }
        if let onBack, embedded || (hosted && quote == nil) {
            onBack(); return
        }
        if quote != nil {
            quote = nil
        } else if editingAmount {
            editingAmount = false; editingRecipient = true
        } else if editingRecipient {
            editingRecipient = false
        } else {
            dismiss()
        }
        error = nil
    }

    private func prepareQuote() async throws -> UsdtQuote {
        if let preparedQuote, preparedQuote.matches(recipient: recipient, amount: amount, destination: destination, sender: usdt.address) {
            return preparedQuote.quote
        }
        preparedQuote = nil
        let sender = usdt.address
        let result: UsdtQuote = if let quotePayment {
            try await quotePayment(recipient, amount, destination)
        } else {
            try await usdt.quote(recipient: recipient, amount: amount, destination: destination)
        }
        preparedQuote = UsdtPreparedQuote(quote: result, amount: amount, sender: sender)
        return result
    }

    private func useMaximum() async {
        guard !busy, !embedded else { return }
        busy = true
        preparingMaximum = true
        preparedQuote = nil
        error = nil
        defer { busy = false; preparingMaximum = false }
        do {
            let prepared = try await usdt.quoteMaximum(recipient: recipient, destination: destination)
            maximumQuote = prepared
            isMaximumAmount = true
            amount = usdtFormatAmount(amount: prepared.amount)
        } catch is CancellationError {
        } catch { self.error = UsdtWalletManager.message(for: error) }
    }

    private func enterAmount(_ key: String) {
        guard !busy else { return }
        let updated = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
        guard updated != amount else { return }
        maximumQuote = nil
        isMaximumAmount = false
        amount = updated
        error = nil
    }

    private func confirmPayment() async throws {
        guard let quote, !busy, !submitted else { return }
        var warnings: [String] = []
        if let balance = usdt.balance, quote.amount > balance / 2 {
            warnings.append("wallet__send_dialog2_usdt")
        }
        if settings.warnWhenSendingOver100, quote.amount > 100_000_000 {
            warnings.append("wallet__send_dialog1")
        }
        if quote.totalCost > 10_000_000 {
            warnings.append("wallet__send_dialog4")
        }
        if quote.totalCost > quote.amount / 2 {
            warnings.append("wallet__send_dialog3")
        }
        // The swipe stays completed while each warning or the PIN is open; cancelling one resets it.
        for next in warnings where !confirmedWarnings.contains(next) {
            let proceed = await withCheckedContinuation { continuation in
                warningContinuation = continuation
                warning = next
            }
            guard proceed else { throw CancellationError() }
            confirmedWarnings.insert(next)
        }
        try await authenticateAndSend()
    }

    private func resolveWarning(proceed: Bool) {
        warningContinuation?.resume(returning: proceed)
        warningContinuation = nil
        warning = nil
    }

    private func resolvePin(verified: Bool) {
        pinContinuation?.resume(returning: verified)
        pinContinuation = nil
        pin = false
    }

    private func authenticateAndSend() async throws {
        guard !busy else { return }
        if let authenticatePayment {
            busy = true
            let authorized = await authenticatePayment()
            busy = false
            if authorized, !Task.isCancelled {
                await send()
            }
            return
        }
        if settings.requirePinForPayments && settings.pinEnabled {
            guard settings.useBiometrics && BiometricAuth.isAvailable else {
                let verified = await withCheckedContinuation { continuation in
                    pinContinuation = continuation
                    pin = true
                }
                guard verified else { throw CancellationError() }
                await send()
                return
            }
            busy = true
            let result = await BiometricAuth.authenticate()
            busy = false
            switch result {
            case .success: await send()
            case .cancelled: break
            case let .failed(message): error = message
            }
        } else {
            await send()
        }
    }

    private func send() async {
        guard let quote, !busy else { return }
        let paymentActivity = PaykitPaymentActivity.shared.begin()
        defer { PaykitPaymentActivity.shared.end(paymentActivity) }
        busy = true
        error = nil
        maximumQuote = nil
        preparedQuote = nil
        defer {
            if !submitted {
                busy = false
            }
        }
        do {
            if let sendPayment {
                try await sendPayment(quote)
            } else {
                try await usdt.send(quote)
            }
            submitted = true
            Task { await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt) }
        } catch is CancellationError {} catch {
            if usdt.transfers.contains(where: { $0.id == quote.id }) {
                submitted = true
                if case UsdtError.SubmissionDeadlineExpired = error {
                    self.error = UsdtWalletManager.message(for: error)
                }
            } else {
                self.error = if error is UsdtError {
                    UsdtWalletManager.message(for: error)
                } else {
                    (error as? LocalizedError)?.errorDescription ?? UsdtWalletManager.message(for: error)
                }
                self.quote = nil
            }
            Logger.warn("Failed to send USDT: \(UsdtWalletManager.message(for: error))", context: "UsdtSendView")
        }
    }
}
