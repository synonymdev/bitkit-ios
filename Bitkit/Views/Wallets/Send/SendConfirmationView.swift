import BitkitCore
import LDKNode
import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activityList: ActivityListViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var tagManager: TagManager
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    let requestPinCheck: () async -> Bool
    let prepareIncomingPaymentRequest: () async throws -> Void
    let routingCacheResetAttempted: Bool

    @State private var showDetails = false
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var transactionFee: Int = 0
    @State private var feeCalculationId = 0
    @State private var currentWarning: WarningType?
    @State private var pendingWarnings: [WarningType] = []
    @State private var warningContinuation: CheckedContinuation<Bool, Error>?
    @State private var swipeProgress: CGFloat = 0
    @State private var hasStartedAutomaticPayment = false

    var accentColor: Color {
        if hwSend.isActive { return .blueAccent }
        return app.selectedWalletToPayFrom == .lightning ? .purpleAccent : .brandAccent
    }

    private var fundingSources: [SendFundingSource] {
        var sources: [SendFundingSource] = []
        if app.scannedLightningInvoice != nil {
            sources.append(.spending)
        }
        if app.scannedOnchainInvoice != nil {
            sources.append(.savings)
            sources.append(contentsOf: hwWalletManager.wallets.compactMap { hardwareWallet in
                guard hardwareWallet.fundingBalanceSats > 0 || hardwareWallet.walletId == hwSend.walletId else {
                    return nil
                }
                return .hardware(walletId: hardwareWallet.walletId)
            })
        }
        return sources
    }

    private var selectedFundingSource: SendFundingSource {
        if let walletId = hwSend.walletId {
            return .hardware(walletId: walletId)
        }
        return app.selectedWalletToPayFrom == .lightning ? .spending : .savings
    }

    private var canSwitchFundingSource: Bool {
        fundingSources.count > 1
    }

    var canSwitchWallet: Bool {
        guard !hwSend.isActive else { return false }
        guard app.scannedOnchainInvoice != nil, app.scannedLightningInvoice != nil else { return false }
        let amount = wallet.sendAmountSats ?? app.scannedOnchainInvoice?.amountSatoshis ?? 0
        return wallet.canSwitchWalletForUnifiedInvoice(amountSats: amount)
    }

    private var hardwareWalletName: String? {
        guard let walletId = hwSend.walletId else { return nil }
        return hwWalletManager.wallets.first(where: { $0.id == walletId })?.name
            ?? t("hardware__device_model_trezor")
    }

    private var isHardwarePreparationLoading: Bool {
        hwSend.isActive && (hwSend.isFundingSourceLoading || hwSend.isPreviewLoading)
    }

    private var isHardwareConfirmationUnavailable: Bool {
        hwSend.isActive && (isHardwarePreparationLoading || hwSend.previewFeeSats == 0)
    }

    private var displayedTransactionFee: Int {
        transactionFee > 0 ? transactionFee : Int(hwSend.previewFeeSats)
    }

    /// `.instant` is only valid when paying from Lightning; align `selectedSpeed` with the current sat/vB on savings.
    private func reconcileInstantSpeedWhenSwitchingToOnChain() async {
        guard wallet.selectedSpeed == .instant else { return }

        await MainActor.run {
            wallet.selectedSpeed = settings.defaultTransactionSpeed
        }
    }

    /// BIP21 flow can land on confirm with `sendAmountSats` unset; set it from the scanned invoices.
    @MainActor
    private func ensureSendAmountFromScannedInvoicesIfNeeded() {
        guard wallet.sendAmountSats == nil || wallet.sendAmountSats == 0 else { return }
        if let invoice = app.scannedOnchainInvoice, invoice.amountSatoshis > 0 {
            wallet.sendAmountSats = invoice.amountSatoshis
        } else if let lightning = app.scannedLightningInvoice, lightning.amountSatoshis > 0 {
            wallet.sendAmountSats = lightning.amountSatoshis
        }
    }

    /// Warning system
    private enum WarningType: String, CaseIterable {
        case amount
        case balance
        case fee
        case feePercentage
        case minimumFee

        var title: String {
            switch self {
            case .minimumFee: return t("wallet__send_dialog5_title")
            default: return t("common__are_you_sure")
            }
        }

        var message: String {
            switch self {
            case .amount: return t("wallet__send_dialog1")
            case .balance: return t("wallet__send_dialog2")
            case .fee: return t("wallet__send_dialog4")
            case .feePercentage: return t("wallet__send_dialog3")
            case .minimumFee: return t("wallet__send_dialog5_description")
            }
        }
    }

    private var canEditAmount: Bool {
        guard app.contactPaymentContext?.incomingPaymentRequest == nil else { return false }
        guard app.selectedWalletToPayFrom == .lightning else { return true }
        guard let invoice = app.scannedLightningInvoice else { return true }

        return invoice.amountSatoshis == 0
    }

    private var contactPaymentContact: PubkyContact? {
        guard let publicKey = app.contactPaymentContext?.publicKey else {
            return nil
        }

        return contactsManager.contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, publicKey) })
    }

    var body: some View {
        ZStack {
            confirmationContent
            if app.contactPaymentContext?.isInitialSubscriptionPayment == true {
                InitialSubscriptionPaymentProgress()
            }
        }
    }

    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: reviewTitle,
                showBackButton: !navigationPath.isEmpty,
                action: AnyView(SendContactHeaderAvatar())
            )

            VStack(alignment: .leading, spacing: 0) {
                if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    MoneyStack(
                        sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                        showSymbol: true,
                        testIdPrefix: "ReviewAmount",
                        onTap: navigateToAmount
                    )
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    MoneyStack(
                        sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                        showSymbol: true,
                        testIdPrefix: "ReviewAmount",
                        onTap: navigateToAmount
                    )
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 44)

            if showDetails {
                if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    onchainView(invoice)
                } else if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    lightningView(invoice)
                }
            } else {
                Image("coin-stack-4")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
                    .rotationEffect(.degrees(swipeProgress * 14))
            }

            Spacer(minLength: 16)

            if !UIScreen.main.isSmall || !showDetails {
                CustomButton(
                    title: showDetails ? t("common__hide_details") : t("common__show_details"),
                    size: .small,
                    icon: Image(showDetails ? "eye-slash" : app.selectedWalletToPayFrom == .lightning ? "bolt-hollow" : "speed-normal")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(accentColor),
                    background: Color(hex: 0x151515)
                ) {
                    showDetails.toggle()
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 62)
                .accessibilityIdentifier("SendConfirmToggleDetails")
            }

            SwipeButton(
                title: app.contactPaymentContext?.isInitialSubscriptionPayment == true
                    ? t("subscriptions__swipe_to_subscribe_and_pay")
                    : t("wallet__send_swipe"),
                accentColor: accentColor,
                isDisabled: isHardwareConfirmationUnavailable,
                isLoading: hasStartedAutomaticPayment,
                swipeProgress: $swipeProgress
            ) {
                try await submitPayment()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            ensureSendAmountFromScannedInvoicesIfNeeded()
            await calculateTransactionFee()
            await calculateRoutingFee()
            await startAutomaticPaymentIfNeeded()
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) {
            Task {
                await calculateTransactionFee()
            }
        }
        .onChange(of: app.selectedWalletToPayFrom) {
            Task {
                if app.selectedWalletToPayFrom == .lightning {
                    await calculateTransactionFee()
                } else {
                    await onSwitchToOnchainWallet()
                }
            }
        }
        .onChange(of: hwSend.walletId) {
            Task { await calculateTransactionFee() }
        }
        .alert(
            t("security__bio_error_title"),
            isPresented: $showingBiometricError
        ) {
            Button(t("common__ok")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
        .alert(
            currentWarning?.title ?? "",
            isPresented: .constant(currentWarning != nil)
        ) {
            Button(t("common__dialog_cancel"), role: .cancel) {
                warningContinuation?.resume(returning: false)
                warningContinuation = nil
                currentWarning = nil
            }
            Button(t("wallet__send_yes")) {
                warningContinuation?.resume(returning: true)
                warningContinuation = nil
                currentWarning = nil
            }
        } message: {
            if let warning = currentWarning {
                Text(warning.message)
            }
        }
    }

    private var reviewTitle: String {
        paykitPaymentReviewTitle(context: app.contactPaymentContext, fallback: t("wallet__send_review"))
    }

    @MainActor
    private func startAutomaticPaymentIfNeeded() async {
        guard app.contactPaymentContext?.isInitialSubscriptionPayment == true,
              !hasStartedAutomaticPayment
        else { return }
        hasStartedAutomaticPayment = true
        do {
            if app.selectedWalletToPayFrom == .onchain,
               wallet.selectedFeeRateSatsPerVByte == nil
            {
                try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
            }
            try await submitPayment()
        } catch is CancellationError {
            navigationPath.append(.failure(SendFailureContext(
                error: CancellationError(),
                retryRoute: .confirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: app.scannedLightningInvoice?.bolt11,
                contactPaymentContext: app.contactPaymentContext
            )))
        } catch {
            navigationPath.append(.failure(SendFailureContext(
                error: error,
                retryRoute: .confirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: app.scannedLightningInvoice?.bolt11,
                contactPaymentContext: app.contactPaymentContext
            )))
        }
    }

    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("wallet__send_from")) {
                    NumberPadActionButton(
                        text: hardwareWalletName ?? t("wallet__savings__title"),
                        imageName: canSwitchFundingSource ? "arrow-up-down" : nil,
                        color: hwSend.isActive ? .blueAccent : .brandAccent,
                        variant: canSwitchFundingSource ? .primary : .secondary,
                        disabled: !canSwitchFundingSource || isHardwarePreparationLoading,
                        isLoading: hwSend.isFundingSourceLoading
                    ) {
                        selectNextFundingSource()
                    }
                    .accessibilityIdentifier("SendConfirmAssetButton")
                }

                if let contact = contactPaymentContact {
                    SendSectionView(t("wallet__send_to")) {
                        contactRecipient(contact)
                    }
                } else {
                    Button {
                        navigateToManual(with: invoice.address)
                    } label: {
                        SendSectionView(t("wallet__send_to")) {
                            BodySSBText(invoice.address.ellipsis(maxLength: 18))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(height: 28)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ReviewUri")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                Button(action: {
                    navigationPath.append(.feeRate)
                }) {
                    SendSectionView(t("wallet__send_fee_and_speed")) {
                        HStack(spacing: 0) {
                            Group {
                                if hwSend.isPreviewLoading {
                                    ActivityIndicator(size: 10, tint: wallet.selectedSpeed.iconColor)
                                } else {
                                    Image(wallet.selectedSpeed.iconName)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .foregroundColor(wallet.selectedSpeed.iconColor)
                                }
                            }
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                            HStack(spacing: 0) {
                                BodySSBText(wallet.selectedSpeed.title)
                                if displayedTransactionFee > 0 {
                                    BodySSBText(" (")
                                    MoneyText(
                                        sats: displayedTransactionFee,
                                        size: .bodySSB,
                                        symbol: true,
                                        symbolColor: .textPrimary
                                    )
                                    BodySSBText(")")
                                }
                            }

                            Image("pencil")
                                .foregroundColor(.textPrimary)
                                .frame(width: 12, height: 12)
                                .padding(.leading, 6)
                        }
                    }
                }
                .disabled(isHardwarePreparationLoading)

                SendSectionView(t("wallet__send_confirming_in")) {
                    HStack(spacing: 0) {
                        Image("clock")
                            .foregroundColor(.brandAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        BodySSBText(
                            TransactionSpeed.getFeeTierLocalized(
                                feeRate: UInt64(wallet.selectedFeeRateSatsPerVByte ?? 0),
                                feeEstimates: feeEstimatesManager.estimates,
                                variant: .range
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SendSectionView(t("wallet__tags")) {
                TagsListView(
                    tags: tagManager.selectedTagsArray,
                    icon: .close,
                    onAddTag: {
                        navigationPath.append(.tag)
                    },
                    onTagDelete: { tag in
                        tagManager.removeTagFromSelection(tag)
                    },
                    addButtonTestId: "TagsAddSend"
                )
            }
        }
    }

    func lightningView(_ invoice: LightningInvoice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SendSectionView(t("wallet__send_from")) {
                    NumberPadActionButton(
                        text: t("wallet__spending__title"),
                        imageName: canSwitchFundingSource ? "arrow-up-down" : nil,
                        color: app.selectedWalletToPayFrom == .lightning ? .purpleAccent : .brandAccent,
                        variant: canSwitchFundingSource ? .primary : .secondary,
                        disabled: !canSwitchFundingSource
                    ) {
                        selectNextFundingSource()
                    }
                    .accessibilityIdentifier("SendConfirmAssetButton")
                }

                Spacer(minLength: 16)

                if let contact = contactPaymentContact {
                    SendSectionView(t("wallet__send_to")) {
                        contactRecipient(contact)
                    }
                } else {
                    Button {
                        navigateToManual(with: invoice.bolt11)
                    } label: {
                        SendSectionView(t("wallet__send_to")) {
                            BodySSBText(invoice.bolt11.ellipsis(maxLength: 18))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(height: 28)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ReviewUri")
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Button(action: {
                    if canSwitchWallet {
                        navigationPath.append(.feeRate)
                    }
                }) {
                    SendSectionView(t("wallet__send_fee_and_speed")) {
                        HStack(spacing: 0) {
                            Image("bolt-hollow")
                                .foregroundColor(.purpleAccent)
                                .frame(width: 16, height: 16)
                                .padding(.trailing, 4)

                            if wallet.routingFeeEstimateSats > 0 {
                                let feeText = "\(t("fee__instant__title")) (±"
                                HStack(spacing: 0) {
                                    BodySSBText(feeText)
                                    MoneyText(
                                        sats: Int(wallet.routingFeeEstimateSats),
                                        size: .bodySSB,
                                        symbol: true,
                                        symbolColor: .textPrimary
                                    )
                                    BodySSBText(")")
                                }
                            } else {
                                BodySSBText(t("fee__instant__title"))
                            }

                            if canSwitchWallet {
                                Image("pencil")
                                    .foregroundColor(.textPrimary)
                                    .frame(width: 12, height: 12)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }

                SendSectionView(t("wallet__send_invoice_expiration")) {
                    HStack(spacing: 4) {
                        Image("timer-alt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)

                        BodySSBText(DateFormatterHelpers.formatInvoiceExpiryRelative(
                            timestampSeconds: invoice.timestampSeconds,
                            expirySeconds: invoice.expirySeconds
                        ))
                    }
                }
            }

            if let description = app.scannedLightningInvoice?.description, !description.isEmpty {
                SendSectionView(t("wallet__note")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        BodySSBText(description)
                            .lineLimit(1)
                            .allowsTightening(false)
                    }
                }
            }

            SendSectionView(t("wallet__tags")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tagManager.selectedTagsArray, id: \.self) { tag in
                            Tag(tag, icon: .close, onDelete: { tagManager.removeTagFromSelection(tag) })
                        }
                        AddTagButton(onPress: { navigationPath.append(.tag) })
                            .accessibilityIdentifier("TagsAddSend")
                    }
                }
            }
        }
    }

    private func selectNextFundingSource() {
        guard canSwitchFundingSource else { return }
        let currentIndex = fundingSources.firstIndex(of: selectedFundingSource)
        let nextIndex = currentIndex.map { ($0 + 1) % fundingSources.count } ?? 0
        selectFundingSource(fundingSources[nextIndex])
    }

    private func selectFundingSource(_ source: SendFundingSource) {
        switch source {
        case .spending:
            hwSend.selectWallet(nil)
            app.selectedWalletToPayFrom = .lightning
        case .savings:
            hwSend.selectWallet(nil)
            app.selectedWalletToPayFrom = .onchain
        case let .hardware(walletId):
            let balance = hwWalletManager.fundingBalance(walletId: walletId)
            let reserve = HwFundingSigner.feeReserve(
                balanceSats: balance,
                satsPerVByte: wallet.selectedFeeRateSatsPerVByte.map(UInt64.init)
            )
            hwSend.selectWallet(
                walletId,
                initialAvailableSats: balance > reserve ? balance - reserve : 0,
                showsLoading: true
            )
            app.selectedWalletToPayFrom = .onchain
        }
    }

    private func submitPayment() async throws {
        // Validate payment and show warnings if needed
        let warnings = await validatePayment()
        if !warnings.isEmpty {
            let shouldProceed = try await showWarnings(warnings)
            if !shouldProceed {
                throw CancellationError()
            }
        }

        if hwSend.isActive {
            do {
                let context = app.contactPaymentContext
                try validateIncomingPaymentRequestContext(context)
                try validateIncomingPaymentRequestAmounts(context)
            } catch {
                Logger.error("Failed to validate hardware payment: \(error)")
                navigationPath.append(.failure(SendFailureContext(
                    error: error,
                    retryRoute: .confirm,
                    routingCacheResetAttempted: routingCacheResetAttempted,
                    paymentRequest: nil
                )))
                return
            }
        }

        // Check if authentication is required for payments
        if settings.requirePinForPayments && settings.pinEnabled {
            if settings.useBiometrics && BiometricAuth.isAvailable {
                let result = await BiometricAuth.authenticate()
                switch result {
                case .success:
                    break
                case .cancelled:
                    throw CancellationError()
                case let .failed(message):
                    biometricErrorMessage = message
                    showingBiometricError = true
                    throw CancellationError()
                }
            } else {
                let shouldProceed = await requestPinCheck()
                guard shouldProceed else {
                    throw CancellationError()
                }
            }
        }

        if hwSend.isActive {
            navigationPath.append(.hardwareSign)
        } else {
            try await performPayment()
        }
    }

    private func contactRecipient(_ contact: PubkyContact) -> some View {
        HStack(spacing: 8) {
            PubkyContactAvatar(contact: contact, size: 24)

            BodySSBText(contact.displayName)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("ReviewContactRecipient")
    }

    private func performPayment() async throws {
        var createdMetadataPaymentId: String? = nil
        let contactPaymentContext = app.contactPaymentContext
        let contactPublicKey = contactPaymentContext?.publicKey
        let incomingPaymentRequest = contactPaymentContext?.incomingPaymentRequest
        var shouldCancelPaymentProof = false
        var preparedPaymentProof: (endpointIdentifier: String, kind: PaykitPaymentProofKind)?
        var onchainPaymentStarted = false

        do {
            try validateIncomingPaymentRequestContext(contactPaymentContext)
            try validateIncomingPaymentRequestAmounts(contactPaymentContext)
            if let incomingPaymentRequest {
                let proof = try paymentProofPreparation()
                try await PaykitPaymentProofService.shared.prepare(
                    request: incomingPaymentRequest,
                    paymentEndpointIdentifier: proof.endpointIdentifier,
                    kind: proof.kind
                )
                preparedPaymentProof = proof
                shouldCancelPaymentProof = true
            }
            try await prepareIncomingPaymentRequest()
            try validateIncomingPaymentRequestContext(contactPaymentContext)

            if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                // Set the amount for other screens
                wallet.sendAmountSats = amount

                // Create pre-activity metadata for tags and activity address
                let paymentHash = invoice.paymentHash.hex
                if let incomingPaymentRequest {
                    try await PaykitPaymentProofService.shared.associateLightningPayment(
                        incomingPaymentRequest,
                        paymentHash: paymentHash
                    )
                }
                createdMetadataPaymentId = paymentHash
                await createPreActivityMetadata(paymentId: paymentHash, paymentHash: paymentHash)

                // Perform the Lightning payment (10s timeout → navigate to pending for hold invoices)
                // For invoices with a built-in amount, pass sats: nil so LDK uses the invoice's
                // native millisatoshi precision instead of our truncated satoshi value.
                let paymentSats: UInt64? = invoice.amountSatoshis == 0 ? amount : nil
                do {
                    try await wallet.sendWithTimeout(
                        bolt11: invoice.bolt11,
                        sats: paymentSats,
                        onTimeout: { timedOutHash in
                            app.addPendingPaymentHash(timedOutHash, contactPaymentContext: contactPaymentContext)
                            navigationPath.append(.pending(paymentHash: timedOutHash, retryRoute: .confirm, paymentRequest: invoice.bolt11))
                        }
                    )
                    shouldCancelPaymentProof = false
                    await syncContactForActivity(paymentId: paymentHash, contactPublicKey: contactPublicKey)
                    Logger.info("Lightning payment successful: \(paymentHash)")
                    navigationPath.append(.success(paymentId: paymentHash))
                } catch is PaymentTimeoutError {
                    // onTimeout callback already navigated to .pending; suppress throw
                    shouldCancelPaymentProof = false
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await PaykitPaymentProofService.shared.failLightningPayment(paymentHash: paymentHash)
                    throw error
                }
            } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                let useMaxAmount = await shouldUseMaxOnchainSend(address: invoice.address, amountSats: amount)
                let txid = try await wallet.send(
                    address: invoice.address,
                    sats: amount,
                    isMaxAmount: useMaxAmount
                ) {
                    if let incomingPaymentRequest {
                        try await PaykitPaymentProofService.shared.markOnchainPaymentStarted(
                            incomingPaymentRequest,
                            address: invoice.address
                        )
                        onchainPaymentStarted = true
                    }
                }
                shouldCancelPaymentProof = false
                if let incomingPaymentRequest, let preparedPaymentProof {
                    await PaykitPaymentProofService.shared.completeOnchainPayment(
                        incomingPaymentRequest,
                        txid: txid,
                        paymentEndpointIdentifier: preparedPaymentProof.endpointIdentifier
                    )
                }

                // Create pre-activity metadata for tags and activity address
                await createPreActivityMetadata(paymentId: txid, address: invoice.address, txId: txid, feeRate: wallet.selectedFeeRateSatsPerVByte)

                // Create sent onchain activity immediately so it appears before LDK event (which can be delayed)
                await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
                    txid: txid,
                    address: invoice.address,
                    amount: amount,
                    fee: UInt64(transactionFee),
                    feeRate: wallet.selectedFeeRateSatsPerVByte ?? 1,
                    contact: contactPublicKey
                )

                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                Logger.info("Onchain send result txid: \(txid)")

                navigationPath.append(.success(paymentId: txid))
            } else {
                throw NSError(
                    domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid payment method or missing invoice data"]
                )
            }
        } catch is CancellationError {
            if shouldCancelPaymentProof, let incomingPaymentRequest {
                await PaykitPaymentProofService.shared.cancelPreparation(incomingPaymentRequest)
            }
            return
        } catch {
            if onchainPaymentStarted, let incomingPaymentRequest {
                if isDefiniteOnchainPreBroadcastFailure(error) {
                    await PaykitPaymentProofService.shared.failOnchainPayment(incomingPaymentRequest)
                    onchainPaymentStarted = false
                } else {
                    shouldCancelPaymentProof = false
                    wallet.sendAmountSats = incomingPaymentRequest.amountSats
                    Logger.warn("On-chain payment outcome is uncertain after broadcast started: \(error)", context: "SendConfirmation")
                    navigationPath.append(.pending(
                        paymentHash: incomingPaymentRequest.paymentRequestId,
                        retryRoute: .confirm,
                        paymentRequest: nil,
                        paykitPaymentRequestId: incomingPaymentRequest.id
                    ))
                    return
                }
            }
            if shouldCancelPaymentProof, let incomingPaymentRequest {
                await PaykitPaymentProofService.shared.cancelPreparation(incomingPaymentRequest)
            }
            Logger.error("Payment failed: \(error)")

            if let paymentId = createdMetadataPaymentId {
                try? await CoreService.shared.activity.deletePreActivityMetadata(paymentId: paymentId)
            }

            navigationPath.append(.failure(SendFailureContext(
                error: error,
                retryRoute: .confirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: app.selectedWalletToPayFrom == .lightning ? app.scannedLightningInvoice?.bolt11 : nil,
                contactPaymentContext: contactPaymentContext
            )))
        }
    }

    private func isDefiniteOnchainPreBroadcastFailure(_ error: Error) -> Bool {
        let underlyingError = (error as? AppError)?.underlyingError ?? error
        if let serviceError = underlyingError as? CustomServiceError {
            switch serviceError {
            case .nodeNotSetup, .nodeNotStarted:
                return true
            default:
                return false
            }
        }
        guard let nodeError = underlyingError as? NodeError else { return false }

        switch nodeError {
        case .NotRunning, .OnchainTxCreationFailed, .OnchainWalletAccountNotRegistered,
             .OnchainTxSigningFailed, .InvalidAddress, .InvalidAmount, .InvalidNetwork,
             .InvalidFeeRate, .InsufficientFunds, .CoinSelectionFailed, .NoSpendableOutputs:
            return true
        default:
            return false
        }
    }

    private func paymentProofPreparation() throws -> (endpointIdentifier: String, kind: PaykitPaymentProofKind) {
        switch app.selectedWalletToPayFrom {
        case .lightning:
            let endpointIdentifier = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
            return (endpointIdentifier, .lightning)
        case .onchain:
            guard let address = app.scannedOnchainInvoice?.address else {
                throw PaykitPaymentRequestError.requestUnavailable
            }
            let endpointIdentifier = PublicPaykitService.onchainMethodId(for: address).rawValue
            return (endpointIdentifier, .onchain)
        }
    }

    private func validateIncomingPaymentRequestContext(_ context: ContactPaymentContext?) throws {
        guard let context, let request = context.incomingPaymentRequest else { return }
        guard !request.isExpired(at: Date()) else { throw PaykitPaymentRequestError.requestExpired }
        guard app.ownsContactPaymentContext(context) else { throw PaykitPaymentRequestError.requestUnavailable }
    }

    private func validateIncomingPaymentRequestAmounts(_ context: ContactPaymentContext?) throws {
        guard let request = context?.incomingPaymentRequest else { return }

        let paymentAmount = switch app.selectedWalletToPayFrom {
        case .lightning:
            wallet.sendAmountSats ?? app.scannedLightningInvoice?.amountSatoshis
        case .onchain:
            wallet.sendAmountSats ?? app.scannedOnchainInvoice?.amountSatoshis
        }

        guard let paymentAmount, request.acceptsPaymentAmount(paymentAmount) else {
            throw PaykitPaymentRequestError.amountMismatch
        }
        guard app.selectedWalletToPayFrom == .lightning else { return }
        guard let invoice = app.scannedLightningInvoice else {
            throw PaykitPaymentRequestError.amountMismatch
        }
        let parsedInvoice = try Bolt11Invoice.fromStr(invoiceStr: invoice.bolt11)
        guard request.acceptsLightningInvoiceAmount(milliSatoshis: parsedInvoice.amountMilliSatoshis())
        else {
            throw PaykitPaymentRequestError.amountMismatch
        }
    }

    private func syncContactForActivity(paymentId: String, contactPublicKey: String?) async {
        guard let contactPublicKey else {
            return
        }

        do {
            app.addPendingContactPaymentContext(paymentId, context: app.contactPaymentContext)
            try await activityList.setContact(contactPublicKey, forPaymentId: paymentId)
            app.consumeContactPaymentContext(forPendingPaymentHash: paymentId)
        } catch {
            Logger.warn("Failed to set contact for activity \(paymentId): \(error)", context: "SendConfirmationView")
        }
    }

    private func validatePayment() async -> [WarningType] {
        var warnings: [WarningType] = []

        let amount: UInt64 = if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
            wallet.sendAmountSats ?? invoice.amountSatoshis
        } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
            wallet.sendAmountSats ?? invoice.amountSatoshis
        } else {
            0
        }

        // Check if amount > 50% of balance
        if app.selectedWalletToPayFrom == .lightning {
            let lightningBalance = wallet.totalLightningSats
            if amount > lightningBalance / 2 {
                warnings.append(.balance)
            }
        } else {
            let onchainBalance = hwSend.isActive ? hwSend.availableSats : UInt64(clamping: wallet.totalOnchainSats)
            if amount > onchainBalance / 2 {
                warnings.append(.balance)
            }
        }

        // Check if amount > $100 and warning is enabled
        if settings.warnWhenSendingOver100 {
            if let usdAmount = currency.convert(sats: amount, to: "USD") {
                if usdAmount.value > 100.0 {
                    warnings.append(.amount)
                }
            }
        }

        // Check if fee > $10 (only for onchain)
        if app.selectedWalletToPayFrom == .onchain {
            if let feeUsd = currency.convert(sats: UInt64(transactionFee), to: "USD") {
                if feeUsd.value > 10.0 {
                    warnings.append(.fee)
                }
            }

            // Check if fee > 50% of send amount
            if transactionFee > 0 && UInt64(transactionFee) > amount / 2 {
                warnings.append(.feePercentage)
            }

            // TODO: add minimum fee warning
            // Check minimum fee warning
            // if let feeRate = wallet.selectedFeeRateSatsPerVByte,
            //    let minimumFee = wallet.minimumFeeRateSatsPerVByte,
            //    feeRate <= minimumFee {
            //     warnings.append(.minimumFee)
            // }
        }

        return warnings
    }

    private func showWarnings(_ warnings: [WarningType]) async throws -> Bool {
        pendingWarnings = warnings

        while !pendingWarnings.isEmpty {
            let warning = pendingWarnings.removeFirst()

            let shouldProceed = try await withCheckedThrowingContinuation { continuation in
                warningContinuation = continuation
                currentWarning = warning
            }

            if !shouldProceed {
                return false
            }
        }

        return true
    }

    private func shouldUseMaxOnchainSend(address: String, amountSats: UInt64, feeRate: UInt32? = nil) async -> Bool {
        guard wallet.isMaxAmountSend else { return false }
        guard let rate = feeRate ?? wallet.selectedFeeRateSatsPerVByte else { return false }

        do {
            let currentMaxSendable = try await wallet.calculateMaxSendableAmount(address: address, satsPerVByte: rate)
            let matchesCurrentMax = amountSats == currentMaxSendable

            if !matchesCurrentMax {
                Logger.warn(
                    "Ignoring stale max on-chain send flag: amount=\(amountSats), currentMaxSendable=\(currentMaxSendable)",
                    context: "SendConfirmationView"
                )
            }

            return matchesCurrentMax
        } catch {
            Logger.error("Failed to verify max on-chain send amount: \(error)", context: "SendConfirmationView")
            return false
        }
    }

    private func createPreActivityMetadata(
        paymentId: String,
        paymentHash: String? = nil,
        address: String? = nil,
        txId: String? = nil,
        feeRate: UInt32? = nil
    ) async {
        let currentTime = UInt64(Date().timeIntervalSince1970)
        let preActivityMetadata = BitkitCore.PreActivityMetadata(
            walletId: WalletScope.default,
            paymentId: paymentId,
            tags: tagManager.selectedTagsArray,
            paymentHash: paymentHash,
            txId: txId,
            address: address,
            isReceive: false,
            feeRate: feeRate.map { UInt64($0) } ?? 0,
            isTransfer: false,
            channelId: nil,
            createdAt: currentTime
        )
        try? await CoreService.shared.activity.addPreActivityMetadata(preActivityMetadata)
    }

    private func navigateToManual(with value: String) {
        guard !value.isEmpty else { return }
        app.manualEntryInput = value
        app.validateManualEntryInput(
            value,
            savingsBalanceSats: wallet.spendableOnchainBalanceSats,
            spendingBalanceSats: wallet.maxSendLightningSats
        )

        if let manualIndex = navigationPath.firstIndex(of: .manual) {
            navigationPath = Array(navigationPath.prefix(manualIndex + 1))
        } else {
            navigationPath = [.manual]
        }
    }

    private func navigateToAmount() {
        guard canEditAmount else { return }

        if let amountIndex = navigationPath.lastIndex(of: .amount) {
            navigationPath = Array(navigationPath.prefix(amountIndex + 1))
        } else {
            if let confirmIndex = navigationPath.lastIndex(of: .confirm) {
                navigationPath = Array(navigationPath.prefix(confirmIndex))
            }
            navigationPath.append(.amount)
        }
    }

    /// After the user chooses savings, prepares on-chain send (amount, fee rate, UTXOs) and refreshes the shown fee.
    private func onSwitchToOnchainWallet() async {
        guard app.selectedWalletToPayFrom == .onchain else { return }

        await reconcileInstantSpeedWhenSwitchingToOnChain()

        if wallet.selectedFeeRateSatsPerVByte == nil {
            do {
                try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
            } catch {
                Logger.error("Failed to set fee rate when switching to on-chain: \(error)")
                await MainActor.run {
                    app.selectedWalletToPayFrom = .lightning
                    app.toast(type: .error, title: t("other__try_again"))
                }
                return
            }
        }

        if settings.coinSelectionMethod == .manual {
            if wallet.selectedUtxos == nil || wallet.selectedUtxos?.isEmpty == true {
                do {
                    try await wallet.loadAvailableUtxos()
                    await MainActor.run {
                        navigationPath.append(.utxoSelection)
                    }
                } catch {
                    Logger.error("Failed to load UTXOs when switching to on-chain: \(error)")
                    await MainActor.run {
                        app.selectedWalletToPayFrom = .lightning
                        app.toast(type: .error, title: t("other__try_again"))
                    }
                }
                return
            }
        } else {
            do {
                try await wallet.setUtxoSelection(coinSelectionAlgorythm: settings.coinSelectionAlgorithm)
            } catch {
                Logger.error("Failed to set UTXO selection when switching to on-chain: \(error)")
                await MainActor.run {
                    app.selectedWalletToPayFrom = .lightning
                    app.toast(
                        type: .error,
                        title: t("other__try_again"),
                        description: error.localizedDescription
                    )
                }
                return
            }
        }

        await calculateTransactionFee()
    }

    @MainActor
    private func calculateTransactionFee() async {
        feeCalculationId += 1
        let requestId = feeCalculationId

        func apply(_ fee: UInt64) {
            guard feeCalculationId == requestId else { return }
            transactionFee = Int(fee)
        }

        guard app.selectedWalletToPayFrom == .onchain else {
            apply(0)
            return
        }

        guard let address = app.scannedOnchainInvoice?.address,
              let amountSats = wallet.sendAmountSats
        else {
            if hwSend.isActive {
                await hwSend.refreshAvailable(
                    manager: hwWalletManager,
                    destinationAddress: "",
                    satsPerVByte: nil
                )
            }
            return
        }

        guard let feeRate = wallet.selectedFeeRateSatsPerVByte else {
            if hwSend.isActive {
                await hwSend.refreshAvailable(
                    manager: hwWalletManager,
                    destinationAddress: address,
                    satsPerVByte: nil
                )
            }
            return
        }

        do {
            if hwSend.isActive {
                if transactionFee == 0, hwSend.previewFeeSats > 0 {
                    apply(hwSend.previewFeeSats)
                }
                guard let fee = try await hwSend.preparePreview(
                    manager: hwWalletManager,
                    address: address,
                    sats: amountSats,
                    satsPerVByte: UInt64(feeRate)
                ) else { return }
                apply(fee)
                return
            }

            if await shouldUseMaxOnchainSend(address: address, amountSats: amountSats, feeRate: feeRate) {
                let sendAllFee = try await wallet.estimateSendAllFee(
                    address: address,
                    satsPerVByte: feeRate
                )
                apply(sendAllFee)
                return
            }

            // Fee for normal send (recipient + change outputs).
            let normalFee = try await wallet.calculateTotalFee(
                address: address,
                amountSats: amountSats,
                satsPerVByte: feeRate,
                utxosToSpend: wallet.selectedUtxos
            )
            apply(normalFee)
        } catch {
            guard feeCalculationId == requestId else { return }
            Logger.error("Failed to calculate actual fee: \(error)")
            transactionFee = 0
            app.toast(type: .error, title: t("other__try_again"))
        }
    }

    @MainActor
    private func calculateRoutingFee() async {
        guard let bolt11 = app.scannedLightningInvoice?.bolt11 else {
            wallet.routingFeeEstimateSats = 0
            return
        }

        if canSwitchWallet || app.selectedWalletToPayFrom == .lightning {
            // For invoices with a built-in amount, pass nil so LDK uses native msat precision
            let amountSats: UInt64? = app.scannedLightningInvoice?.amountSatoshis == 0 ? wallet.sendAmountSats : nil
            await wallet.refreshRoutingFeeEstimate(bolt11: bolt11, amountSats: amountSats)
        } else {
            wallet.routingFeeEstimateSats = 0
        }
    }
}
