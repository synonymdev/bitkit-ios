import BitkitCore
import PhotosUI
import SwiftUI

struct UsdtSendView: View {
    var onDetails: (String) -> Void
    var initialRecipient = ""
    var initialAmount = ""
    var embedded = false
    var paymentContext: ContactPaymentContext?
    var sendPayment: ((UsdtQuote) async throws -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var amount = ""
    @State private var destination: UsdtDestination = .arbitrum
    @State private var destinations = Env.usdtDestinations
    @State private var quote: UsdtQuote?
    @State private var maximumQuote: UsdtQuote?
    @State private var preparingMaximum = false
    @State private var editingRecipient = false
    @State private var editingAmount = false
    @State private var busy = false
    @State private var error: String?
    @State private var pin = false
    @State private var submitted = false
    @State private var paymentComplete = false
    @State private var showDetails = false
    @State private var warning: String?
    @State private var confirmedWarnings: Set<String> = []
    @State private var swipeProgress: CGFloat = 0
    @FocusState private var recipientFocused: Bool

    init(
        onDetails: @escaping (String) -> Void,
        initialRecipient: String = "",
        initialAmount: String = "",
        embedded: Bool = false,
        paymentContext: ContactPaymentContext? = nil,
        sendPayment: ((UsdtQuote) async throws -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onDetails = onDetails
        self.initialRecipient = initialRecipient
        self.initialAmount = initialAmount
        self.embedded = embedded
        self.paymentContext = paymentContext
        self.sendPayment = sendPayment
        self.onBack = onBack
        self.onClose = onClose
        _recipient = State(initialValue: initialRecipient)
        _amount = State(initialValue: initialAmount)
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
        if submitted, !busy {
            if submittedStatus == .confirmed { return t("usdt__payment_sent") }
            if submittedStatus == .bridgeRefunded { return t("usdt__deposit_refunded") }
            if bridgeNeedsAttention { return t("usdt__bridge_attention") }
            return t(submissionFailed ? "wallet__send_error_tx_failed" : "usdt__submitted")
        }
        if quote != nil { return t(paymentRequest == nil ? "wallet__send_review" : "wallet__payment_request") }
        return t(editingAmount ? "usdt__amount" : "usdt__send_title")
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .onAppear { usdt.isSendPresented = true }
        .onDisappear { usdt.isSendPresented = false }
        .task {
            if !embedded {
                do { destinations = try await usdt.sendDestinations() }
                catch { Logger.warn("Could not load USDT bridge destinations", context: "UsdtSendView") }
            }
            guard !initialRecipient.isEmpty, !initialAmount.isEmpty, quote == nil else { return }
            busy = true
            defer { busy = false }
            do { quote = try await usdt.quote(recipient: recipient, amount: amount, destination: destination) }
            catch { self.error = UsdtWalletManager.message(for: error) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, showBackButton: !submitted,
                        action: paymentContext == nil ? nil : AnyView(SendContactHeaderAvatar(publicKey: paymentContext?.publicKey)), onBack: goBack)
                .disabled(busy)
            if submitted, !busy { submittedContent }
            else if let quote { confirmation(quote) }
            else if editingAmount { amountContent }
            else if editingRecipient { manualContent }
            else { recipientContent }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if submitted, !busy, submittedStatus == .confirmed {
                PaymentCelebration(isOnchain: true, isReceived: false, confettiColor: .usdtAccent)
            }
        }
        .sheetBackground()
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $pin) {
            SendPinScreen(onCancel: { pin = false }, onPinVerified: {
                pin = false
                Task { await send() }
            })
        }
        .task(id: "\(scenePhase == .active)-\(submitted)") {
            guard scenePhase == .active, submitted else { return }
            if busy, let quote {
                if quote.destination == .arbitrum { await usdt.waitForTransfer(quote.id) }
                if submittedStatus == .confirmed {
                    paymentComplete = true
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                busy = false
            }
            while !Task.isCancelled, [.pending, .bridging, .bridgeNeedsAttention].contains(submittedStatus) {
                await usdt.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt)
        }
        .interactiveDismissDisabled(busy || pin)
        .alert(t("common__are_you_sure"), isPresented: Binding(
            get: { warning != nil },
            set: { if !$0 { warning = nil } }
        ), presenting: warning) { warning in
            Button(t("common__cancel"), role: .cancel) { self.warning = nil }
            Button(t("wallet__send_yes")) {
                confirmedWarnings.insert(warning)
                self.warning = nil
                Task { await confirmPayment() }
            }
        } message: { warning in
            Text(t(warning))
        }
    }

    private var networkSelector: some View {
        SendSectionView(t("usdt__network")) { networkButton }
    }

    private var networkButton: some View {
        Menu {
            ForEach(destinations, id: \.self) { item in
                Button(item.label) {
                    guard destination != item else { return }
                    destination = item
                    maximumQuote = nil
                    quote = nil
                    error = nil
                    if !recipient.isEmpty, (try? usdtValidateRecipient(value: recipient, destination: item)) == nil {
                        editingAmount = false
                        editingRecipient = true
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image("usdt-network").resizable().scaledToFit().frame(width: 16, height: 16).foregroundColor(.usdtAccent)
                CaptionBText(destination.label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Color.white06, in: Capsule())
            .overlay(Capsule().stroke(Color.white10, lineWidth: 1))
        }
        .disabled(embedded || destinations.count < 2 || busy)
        .accessibilityIdentifier("UsdtNetwork")
    }

    private var recipientContent: some View {
        VStack(spacing: 8) {
            networkSelector.padding(.bottom, 8)
            Scanner(onScan: { payload in if let value = payload.string { useRecipient(value) } }, onImageSelection: readImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RectangleButton(
                icon: "clipboard", iconColor: .usdtAccent, title: t("common__paste"), testID: "UsdtPaste"
            ) {
                if let value = UIPasteboard.general.string, !value.isEmpty { useRecipient(value) }
                else { error = t("wallet__send_clipboard_empty_text") }
            }
            RectangleButton(
                icon: "pencil", iconColor: .usdtAccent, title: t("wallet__recipient_manual"), testID: "UsdtManual"
            ) { editingRecipient = true }
            if let error { BodySText(error, textColor: .brandAccent) }
            BodySText(t("usdt__network_warning"), textColor: .textSecondary).padding(.top, 8)
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
    }

    private var amountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount)
                .accessibilityIdentifier("UsdtAmount")
                .padding(.bottom, 32)
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError").padding(.bottom, 16)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__send_available"))
                    BodySSBText(settings.hideBalance ? " • • • • •" : "$ " + (usdt.balance.map { usdtOverviewAmount($0) } ?? "—"))
                }
                Spacer()
                NumberPadActionButton(text: "USDT", color: .usdtAccent, variant: .secondary, disabled: true) {}
                if !embedded {
                    NumberPadActionButton(text: t("common__max"), color: .usdtAccent, disabled: busy,
                                          isLoading: preparingMaximum)
                    {
                        Task { await useMaximum() }
                    }
                    .accessibilityIdentifier("UsdtMax")
                    networkButton
                }
            }
            .padding(.bottom, 16)
            CustomDivider()
            NumberPad(type: .decimal, isDisabled: busy || embedded, onDeleteLongPress: { amount = ""; maximumQuote = nil }, onPress: enterAmount)
                .frame(maxHeight: .infinity)
            CustomButton(title: t("common__continue"), isDisabled: busy || amount.isEmpty, isLoading: busy && !preparingMaximum) {
                guard !busy, quote == nil else { return }
                busy = true
                error = nil
                defer { busy = false }
                do {
                    if let maximumQuote {
                        let fresh = maximumQuote.expiresAt > UInt64(Date().timeIntervalSince1970) + 5
                        let prepared: UsdtQuote = if fresh { maximumQuote }
                        else { try await usdt.quoteMaximum(recipient: recipient, destination: destination) }
                        quote = prepared
                        amount = usdtFormatAmount(amount: prepared.amount)
                    } else {
                        quote = try await usdt.quote(recipient: recipient, amount: amount, destination: destination)
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

    private func confirmation(_ quote: UsdtQuote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), displayAmount: usdtOverviewAmount(quote.amount))
                            .contentShape(Rectangle()).onTapGesture { if !busy { goBack() } }
                            .padding(.bottom, 32)
                        if showDetails {
                            quoteDetails(quote)
                            if let requestNote { PaymentRequestInvoiceNote(note: requestNote).padding(.top, 16) }
                        } else {
                            if paymentRequest != nil {
                                PaymentRequestSummary(contactName: contactName, note: requestNote).padding(.bottom, 16)
                            }
                            Spacer(minLength: 0)
                            PaymentReviewIllustration(swipeProgress: swipeProgress, maximumHeight: 192)
                                .padding(.top, 16).frame(height: 256)
                        }
                        if quote.destination != .arbitrum { bridgeCosts(quote).padding(.top, 16) }
                        if let error { BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError") }
                        CustomButton(
                            title: t(showDetails ? "common__hide_details" : "common__show_details"), size: .small,
                            icon: Image(showDetails ? "eye-slash" : "speed-normal").resizable().frame(width: 16, height: 16)
                                .foregroundColor(.usdtAccent), background: Color.white06
                        ) { showDetails.toggle() }
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                            .accessibilityIdentifier("UsdtReviewDetails")
                        if showDetails { Spacer(minLength: 0) }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
            if showDetails {
                CaptionText(t(quote.bridgeProvider == .orchestra ? "usdt__bridge_estimate_note" : "usdt__fee_note"))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 24)
            }
            SwipeButton(
                title: t("wallet__send_swipe"), accentColor: .usdtAccent, isDisabled: busy,
                isLoading: busy, isComplete: paymentComplete, swipeProgress: $swipeProgress
            ) {
                await confirmPayment()
                if !submitted { throw CancellationError() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("UsdtConfirm")
        }
    }

    private func quoteDetails(_ quote: UsdtQuote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("usdt__pay_from")) {
                    NumberPadActionButton(text: "USDT", color: .usdtAccent, variant: .secondary, disabled: true) {}
                }
                UsdtDetailCell(title: t("usdt__network"), value: quote.destination.label, icon: "usdt-network")
            }
            HStack(alignment: .top, spacing: 16) {
                UsdtDetailCell(title: t("wallet__activity_payment"), value: usdtOverviewAmount(quote.amount), icon: "user")
                UsdtDetailCell(title: t("wallet__activity_fee"), value: usdtOverviewAmount(quote.maximumFee), icon: "speed-normal")
            }
            if paymentContext != nil {
                SendSectionView(t("wallet__payment_request_contact")) {
                    HStack(spacing: 4) {
                        if let contact { PubkyContactAvatar(contact: contact, size: 20) }
                        BodySSBText(contactName).lineLimit(1)
                    }
                }
            }
            SendSectionView(t("wallet__activity_address")) {
                BodySSBText(quote.recipient).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let provider = quote.bridgeProvider {
                SendSectionView(t("usdt__bridge_provider")) { BodySSBText(provider == .orchestra ? "Orchestra" : "USDT0") }
            }
        }
    }

    private func bridgeCosts(_ quote: UsdtQuote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SendSectionView(t(quote.bridgeProvider == .orchestra ? "usdt__expected_amount" : "usdt__recipient_gets")) {
                BodySSBText(usdtFormatAmount(amount: quote.receivedAmount) + " USDT")
            }
            if quote.bridgeProvider == .orchestra {
                SendSectionView(t("usdt__bridge_deducted_fee")) {
                    BodySSBText(usdtFormatAmount(amount: quote.amount - min(quote.amount, quote.receivedAmount)) + " USDT")
                }
            }
            SendSectionView(t("usdt__maximum_total")) { BodySSBText(usdtFormatAmount(amount: quote.amount + quote.maximumFee) + " USDT") }
        }
    }

    private var submittedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let quote {
                UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), displayAmount: usdtOverviewAmount(quote.amount))
                    .padding(.bottom, 32)
            }
            if submittedStatus == .bridgeRefunded {
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
                CustomButton(title: t("wallet__send_details"), variant: .secondary, isDisabled: quote == nil, shouldExpand: true) {
                    if let quote { onDetails(quote.id) }
                }
                CustomButton(title: t("common__close"), shouldExpand: true) {
                    if let onClose { onClose() } else { dismiss() }
                }
            }
        }
    }

    private func useRecipient(_ value: String) {
        guard !editingAmount, quote == nil, !submitted else { return }
        do {
            let request: UsdtPaymentRequest = if value.contains(":") { try usdtParsePaymentRequest(value: value) }
            else { try UsdtPaymentRequest(recipient: usdtValidateRecipient(value: value, destination: destination), amount: nil, chainId: nil) }
            if request.chainId != nil { destination = .arbitrum }
            recipient = request.recipient
            if let requestedAmount = request.amount { amount = usdtFormatAmount(amount: requestedAmount) }
        } catch { self.error = UsdtWalletManager.message(for: error); return }
        maximumQuote = nil
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
        if let onBack { onBack(); return }
        if quote != nil { quote = nil }
        else if editingAmount { editingAmount = false; editingRecipient = true }
        else if editingRecipient { editingRecipient = false }
        else { dismiss() }
        error = nil
    }

    private func useMaximum() async {
        guard !busy, !embedded else { return }
        busy = true
        preparingMaximum = true
        error = nil
        defer { busy = false; preparingMaximum = false }
        do {
            let prepared = try await usdt.quoteMaximum(recipient: recipient, destination: destination)
            maximumQuote = prepared
            amount = usdtFormatAmount(amount: prepared.amount)
        } catch is CancellationError {
        } catch { self.error = UsdtWalletManager.message(for: error) }
    }

    private func enterAmount(_ key: String) {
        guard !busy else { return }
        maximumQuote = nil
        amount = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
    }

    private func confirmPayment() async {
        guard let quote, !busy, !submitted else { return }
        var warnings: [String] = []
        if let balance = usdt.balance, quote.amount > balance / 2 { warnings.append("wallet__send_dialog2") }
        if settings.warnWhenSendingOver100, quote.amount > 100_000_000 { warnings.append("wallet__send_dialog1") }
        if quote.maximumFee > 10_000_000 { warnings.append("wallet__send_dialog4") }
        if quote.maximumFee > quote.amount / 2 { warnings.append("wallet__send_dialog3") }
        if let next = warnings.first(where: { !confirmedWarnings.contains($0) }) {
            warning = next
            return
        }
        await authenticateAndSend()
    }

    private func authenticateAndSend() async {
        guard !busy else { return }
        if settings.requirePinForPayments && settings.pinEnabled {
            guard settings.useBiometrics && BiometricAuth.isAvailable else {
                pin = true
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
        defer { if !submitted { busy = false } }
        do {
            if let sendPayment { try await sendPayment(quote) }
            else { try await usdt.send(quote) }
            submitted = true
            Task { await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt) }
        } catch is CancellationError {} catch {
            self.error = UsdtWalletManager.message(for: error)
            self.quote = nil
            Logger.warn("Failed to send USDT: \(UsdtWalletManager.message(for: error))", context: "UsdtSendView")
        }
    }
}
