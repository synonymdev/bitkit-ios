import BitkitCore
import PhotosUI
import SwiftUI

struct UsdtSendView: View {
    var onDetails: (String) -> Void
    var initialRecipient = ""
    var initialAmount = ""
    var embedded = false
    var sendPayment: ((UsdtQuote) async throws -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var amount = ""
    @State private var destination: UsdtDestination = .arbitrum
    @State private var destinations = Env.usdtDestinations
    @State private var quote: UsdtQuote?
    @State private var editingRecipient = false
    @State private var editingAmount = false
    @State private var busy = false
    @State private var error: String?
    @State private var pin = false
    @State private var submitted = false
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
        sendPayment: ((UsdtQuote) async throws -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onDetails = onDetails
        self.initialRecipient = initialRecipient
        self.initialAmount = initialAmount
        self.embedded = embedded
        self.sendPayment = sendPayment
        self.onBack = onBack
        self.onClose = onClose
        _recipient = State(initialValue: initialRecipient)
        _amount = State(initialValue: initialAmount)
        _editingAmount = State(initialValue: !initialRecipient.isEmpty)
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
        if quote != nil { return t("wallet__send_review") }
        return t(editingAmount ? "usdt__amount" : "usdt__send_title")
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .task {
            if !embedded {
                do { destinations = try await usdt.sendDestinations() }
                catch { Logger.warn("Could not load USDT bridge destinations", context: "UsdtSendView") }
            }
            guard !initialRecipient.isEmpty, quote == nil else { return }
            busy = true
            defer { busy = false }
            do { quote = try await usdt.quote(recipient: recipient, amount: amount, destination: destination) }
            catch { self.error = UsdtWalletManager.message(for: error) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, showBackButton: !submitted, onBack: goBack).disabled(busy)
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
                PaymentCelebration(isOnchain: true, isReceived: false, confettiColor: .greenAccent)
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
                busy = false
            }
            while !Task.isCancelled, [.pending, .bridging, .bridgeNeedsAttention].contains(submittedStatus) {
                await usdt.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
            await PaykitUsdtPaymentService.shared.reconcile(wallet: usdt)
        }
        .onAppear { usdt.isSendPresented = true }
        .onDisappear { usdt.isSendPresented = false }
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
        SendSectionView(t("usdt__destination")) {
            if !embedded, destinations.count > 1 {
                Menu {
                    ForEach(destinations, id: \.self) { item in
                        Button(item.label) {
                            guard destination != item else { return }
                            destination = item
                            recipient = ""
                            amount = ""
                            quote = nil
                            error = nil
                        }
                    }
                } label: {
                    NumberPadActionButton(text: destination.label, color: .greenAccent, variant: .secondary) {}
                }
                .accessibilityIdentifier("UsdtNetwork")
            } else {
                BodySSBText(destination.label)
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("UsdtNetwork")
            }
        }
    }

    private var recipientContent: some View {
        VStack(spacing: 8) {
            networkSelector.padding(.bottom, 8)
            Scanner(onScan: { payload in if let value = payload.string { useRecipient(value) } }, onImageSelection: readImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RectangleButton(
                icon: "clipboard", iconColor: .greenAccent, title: t("common__paste"), testID: "UsdtPaste"
            ) {
                if let value = UIPasteboard.general.string, !value.isEmpty { useRecipient(value) }
                else { error = t("wallet__send_clipboard_empty_text") }
            }
            RectangleButton(
                icon: "pencil", iconColor: .greenAccent, title: t("wallet__recipient_manual"), testID: "UsdtManual"
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
            CaptionMText("USDT · " + destination.label).padding(.bottom, 8)
            NumberPadAmountText(value: amount.isEmpty ? "0" : amount, symbol: "₮")
                .accessibilityIdentifier("UsdtAmount")
            Spacer(minLength: 16)
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError").padding(.bottom, 16)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    CaptionMText(t("usdt__balance"))
                    BodySSBText((settings.hideBalance ? " • • • • •" : usdt.balance.map { usdtFormatAmount(amount: $0) } ?? "—") + " USDT")
                }
                Spacer()
                NumberPadActionButton(text: "USDT", color: .greenAccent, variant: .secondary, disabled: true) {}
            }
            .padding(.bottom, 12)
            CustomDivider()
            NumberPad(type: .decimal, isDisabled: busy || embedded, onDeleteLongPress: { amount = "" }, onPress: enterAmount)
            CustomButton(title: t("common__continue"), isDisabled: busy || amount.isEmpty, isLoading: busy) {
                guard !busy, quote == nil else { return }
                busy = true
                error = nil
                defer { busy = false }
                do {
                    quote = try await usdt.quote(recipient: recipient, amount: amount, destination: destination)
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), network: quote.destination.label)
                        .contentShape(Rectangle()).onTapGesture { if !busy { goBack() } }
                        .padding(.bottom, 32)
                    if showDetails {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 16) {
                                SendSectionView(t("wallet__send_from")) {
                                    NumberPadActionButton(text: "USDT", color: .greenAccent, variant: .secondary, disabled: true) {}
                                }
                                SendSectionView(t("usdt__destination")) { BodySSBText(quote.destination.label).frame(height: 28) }
                            }
                            SendSectionView(t("wallet__send_to")) { BodySSBText(quote.recipient).textSelection(.enabled) }
                            if let provider = quote.bridgeProvider {
                                SendSectionView(t("usdt__bridge_provider")) { BodySSBText(provider == .orchestra ? "Orchestra" : "USDT0") }
                            }
                        }
                    } else {
                        PaymentReviewIllustration(swipeProgress: swipeProgress, maximumHeight: 220)
                    }
                }
            }
            if quote.destination != .arbitrum {
                SendSectionView(t(quote.bridgeProvider == .orchestra ? "usdt__expected_amount" : "usdt__recipient_gets")) {
                    BodySSBText(usdtFormatAmount(amount: quote.receivedAmount) + " USDT")
                }.padding(.top, 16)
                if quote.bridgeProvider == .orchestra {
                    SendSectionView(t("usdt__bridge_deducted_fee")) {
                        BodySSBText(usdtFormatAmount(amount: quote.amount - min(quote.amount, quote.receivedAmount)) + " USDT")
                    }.padding(.top, 16)
                }
            }
            SendSectionView(t("usdt__maximum_fee")) {
                BodySSBText(usdtFormatAmount(amount: quote.maximumFee) + " USDT")
            }
            .padding(.top, 16)
            if quote.destination != .arbitrum {
                SendSectionView(t("usdt__maximum_total")) { BodySSBText(usdtFormatAmount(amount: quote.amount + quote.maximumFee) + " USDT") }
                    .padding(.top, 16)
            }
            BodySText(t(quote.bridgeProvider == .orchestra ? "usdt__bridge_estimate_note" : "usdt__fee_note"), textColor: .textSecondary).padding(
                .top,
                12
            )
            if let error { BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtError") }
            CustomButton(
                title: t(showDetails ? "common__hide_details" : "common__show_details"), size: .small,
                icon: Image(showDetails ? "eye-slash" : "coins").foregroundColor(.greenAccent), background: Color(hex: 0x151515)
            ) { showDetails.toggle() }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .accessibilityIdentifier("UsdtReviewDetails")
            SwipeButton(
                title: t("wallet__send_swipe"), accentColor: .greenAccent, isDisabled: busy, isLoading: busy, swipeProgress: $swipeProgress
            ) {
                await confirmPayment()
                if !submitted { throw CancellationError() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("UsdtConfirm")
        }
    }

    private var submittedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let quote {
                UsdtAmountHeader(amount: usdtFormatAmount(amount: quote.amount), network: quote.destination.label).padding(.bottom, 32)
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
            guard request.chainId == nil || destination == .arbitrum else { throw UsdtError.WrongNetwork }
            recipient = request.recipient
            amount = request.amount.map { usdtFormatAmount(amount: $0) } ?? ""
        } catch { self.error = UsdtWalletManager.message(for: error); return }
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

    private func enterAmount(_ key: String) {
        guard !busy else { return }
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
