import BitkitCore
import BreezSdkSpark
import SwiftUI

/// The dollar balance held on Spark, separate from the Arbitrum USDT wallet: its activity, receive QR and send flow.
struct SparkUsdWalletScreen: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(UsdtWalletManager.self) private var usdt
    @State private var page: SparkUsdPage?
    @State private var initialRecipient: String
    private let spark = SparkManager.shared

    init(initialRecipient: String = "") {
        _initialRecipient = State(initialValue: initialRecipient)
        _page = State(initialValue: initialRecipient.isEmpty ? nil : .send)
    }

    var body: some View {
        ZStack(alignment: .top) {
            UsdtCoinIllustration()
                .scaleEffect(x: -1, y: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: 97, y: 4)
                .allowsHitTesting(false)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    UsdtAmountHeader(
                        amount: spark.usd.map { usdtFormatAmount(amount: $0.balance) } ?? "—",
                        displayAmount: spark.usd.map { usdtOverviewAmount($0.balance) }, hideBalance: settings.hideBalance
                    )
                    .balanceVisibilityToggle()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SparkUsdBalance")
                    HStack(spacing: 8) {
                        CustomButton(title: t("usdt__convert_spark"), variant: .secondary, size: .small) { page = .convert }
                            .accessibilityIdentifier("SparkUsdConvert")
                        if bridgeAddress != nil {
                            CustomButton(title: t("usdt__bridge_spark"), variant: .secondary, size: .small) { page = .bridge }
                                .accessibilityIdentifier("SparkUsdBridge")
                        }
                    }
                    .fixedSize()
                    activityList
                }
            }
            .contentMargins(.top, ScreenLayout.topPaddingWithoutSafeArea)
            .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .refreshable { await spark.refreshState() }
            VStack {
                Spacer()
                HStack(spacing: 0) {
                    TabBarButton(title: t("wallet__send"), icon: "arrow-up", variant: .left) {
                        initialRecipient = ""
                        page = .send
                    }
                    .accessibilityIdentifier("Send")
                    TabBarButton(title: t("wallet__receive"), icon: "arrow-down", variant: .right) { page = .receive }
                        .accessibilityIdentifier("Receive")
                }
                .overlay { ScanButton { sheets.showSheet(.scanner) } }
            }
            .bottomSafeAreaPadding()
            NavigationBar(title: (spark.usd?.ticker ?? "USDT") + " · " + t("lightning__spark"), icon: "tether-circle")
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .task { await spark.refreshState() }
        .sheet(item: $page) { page in
            Sheet(id: .send, data: SendSheetItem()) {
                switch page {
                case .receive: SparkUsdReceiveView()
                case .send: SparkUsdSendView(initialRecipient: initialRecipient)
                case .convert: SparkUsdConvertView(bridgeAddress: nil)
                case .bridge: SparkUsdConvertView(bridgeAddress: bridgeAddress)
                }
            }
        }
    }

    /// Bitkit's own Arbitrum USDT address, the bridge's destination; Orchestra only runs on mainnet.
    private var bridgeAddress: String? {
        Env.isSparkBridgeAvailable && !usdt.address.isEmpty ? usdt.address : nil
    }

    private var activityList: some View {
        let transfers = spark.usd?.transfers ?? []
        return LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(transfers.enumerated()), id: \.element.id) { index, transfer in
                let header = transfer.groupTitle
                if index == 0 || transfers[index - 1].groupTitle != header {
                    CaptionMText(header).padding(.top, index == 0 ? 0 : 16)
                }
                NavigationLink(value: Route.sparkUsdActivity(transferId: transfer.id)) {
                    SparkUsdActivityRow(transfer: transfer, hideBalance: settings.hideBalance)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SparkUsdActivity-\(index)")
            }
        }
    }
}

enum SparkUsdPage: String, Identifiable {
    case receive
    case send
    case convert
    case bridge

    var id: String {
        rawValue
    }
}

/// Home tile for the dollar balance on Spark, next to the Arbitrum USDT one.
struct SparkUsdWalletBalance: View {
    @EnvironmentObject private var settings: SettingsViewModel
    let usd: SparkUsdState

    var body: some View {
        WalletBalanceContent {
            HStack(spacing: 4) {
                CaptionMText(usd.ticker, kerning: 1)
                CaptionMText(t("lightning__spark"), textColor: .textSecondary, kerning: 1)
            }
        } icon: {
            Image("tether-circle").resizable().frame(width: 24, height: 24)
        } amount: {
            BodyMSBText(settings.hideBalance ? " • • • • •" : "$ " + usdtOverviewAmount(usd.balance), kerning: 0, lineHeight: 22)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct SparkUsdActivityRow: View {
    let transfer: SparkUsdTransfer
    let hideBalance: Bool

    var body: some View {
        ActivityRowContainer {
            ActivityRowContent(title: transfer.title, subtitle: DateFormatterHelpers.getActivityItemDate(transfer.timestamp)) {
                CircularIcon(icon: transfer.statusIcon, iconColor: transfer.iconColor, backgroundColor: transfer.iconColor.opacity(0.16), size: 40)
            } amount: {
                VStack(alignment: .trailing, spacing: 2) {
                    BodyMSBText(
                        "<accent>\(transfer.isIncoming ? "+" : "−")</accent> " + (hideBalance ? " • • • • •" : usdtOverviewAmount(transfer.amount)),
                        accentColor: .textSecondary
                    )
                    .lineLimit(1).minimumScaleFactor(0.7)
                    CaptionBText(hideBalance ? "• • • • •" : "$ " + usdtOverviewAmount(transfer.amount), textColor: .textSecondary)
                }
            }
        }
    }
}

extension SparkUsdTransfer {
    var groupTitle: String {
        DateFormatterHelpers.getActivityGroupHeader(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    var title: String {
        switch (status, kind) {
        case (.failed, _): t("usdt__failed")
        case (.pending, _): t("usdt__pending")
        case (_, .toUsd): t("usdt__activity_to_usd_spark")
        case (_, .toBtc): t("usdt__activity_to_btc_spark")
        case (_, .toArbitrum): t("usdt__activity_bridge_spark")
        default: t(isIncoming ? "usdt__received" : "usdt__sent")
        }
    }

    var statusLabel: String {
        switch status {
        case .failed: t("usdt__failed")
        case .pending: t("usdt__pending")
        case .completed: t("usdt__confirmed")
        }
    }

    var statusIcon: String {
        switch (status, kind) {
        case (.failed, _): "x-circle"
        case (.pending, _): "hourglass-simple"
        case (_, .toUsd), (_, .toBtc), (_, .toArbitrum): "transfer"
        default: isIncoming ? "arrow-down" : "arrow-up"
        }
    }

    var iconColor: Color {
        switch status {
        case .failed: .redAccent
        case .pending: .yellowAccent
        case .completed: .usdtAccent
        }
    }
}

struct SparkUsdReceiveView: View {
    @State private var request: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: t("usdt__receive_title"), showBackButton: false, topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8)
            if let request {
                // Bech32 is case-insensitive, and uppercase fits QR's denser alphanumeric mode, so the code scans easier.
                QrArea(uri: request.uppercased(), imageAsset: "tether-circle", accentColor: .usdtAccent, copyValue: request,
                       shareText: request, copyMessage: t("usdt__receive_copied_spark"))
                    .accessibilityIdentifier("SparkUsdReceiveQr")
            } else if let error {
                BodySText(error, textColor: .brandAccent)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            BodySText(t("usdt__receive_network", variables: ["network": t("lightning__spark")]), textColor: .textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray7)
        .task {
            do {
                request = try await SparkManager.shared.createUsdRequest()
            } catch {
                self.error = t("usdt__error_network")
                Logger.warn("Failed to create Spark dollar request: \(error)", context: "SparkUsdReceiveView")
            }
        }
        .task {
            // Syncs while the QR is open, so an incoming payment shows within seconds.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await SparkManager.shared.syncNow()
            }
        }
    }
}

struct SparkUsdSendView: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipientInput: String
    @State private var recipient: SparkUsdRecipient?
    @State private var amount = ""
    @State private var reviewing = false
    @State private var busy = false
    @State private var submitted = false
    @State private var sentTransferId: String?
    @EnvironmentObject private var navigation: NavigationViewModel
    @State private var error: String?
    @State private var pin = false
    @State private var pinContinuation: CheckedContinuation<Bool, Never>?
    @State private var swipeProgress: CGFloat = 0
    @FocusState private var recipientFocused: Bool
    private let spark = SparkManager.shared

    init(initialRecipient: String = "") {
        _recipientInput = State(initialValue: initialRecipient)
    }

    private var amountUnits: UInt64? {
        guard let units = try? usdtParseAmount(value: amount), units > 0 else { return nil }
        return units
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, showBackButton: !submitted, topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8, onBack: goBack)
                .disabled(busy)
            if submitted {
                submittedContent
            } else if reviewing {
                reviewContent
            } else if recipient != nil {
                amountContent
            } else {
                recipientContent
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray7)
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $pin) {
            SendPinScreen(onCancel: { resolvePin(false) }, onPinVerified: { resolvePin(true) })
        }
        .interactiveDismissDisabled(busy || pin)
        .task {
            if !recipientInput.isEmpty, recipient == nil {
                await useRecipient()
            }
        }
    }

    private var title: String {
        if submitted {
            return t("usdt__sent_title_spark")
        }
        if reviewing {
            return t("wallet__send_review")
        }
        if recipient != nil {
            return t("usdt__amount")
        }
        return t("usdt__send_title_spark")
    }

    private var recipientContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__send_to"))
            PaymentAddressInput(
                text: $recipientInput,
                isFocused: $recipientFocused,
                placeholder: t("usdt__address"),
                testIdentifier: "SparkUsdRecipient"
            )
            errorText
            Spacer(minLength: 16)
            CustomButton(title: t("common__continue"), isDisabled: recipientInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         isLoading: busy)
            {
                await useRecipient()
            }
            .buttonBottomPadding(isFocused: recipientFocused)
            .accessibilityIdentifier("SparkUsdRecipientContinue")
        }
        .onChange(of: recipientInput) { _, _ in error = nil }
    }

    private var amountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount).accessibilityIdentifier("SparkUsdAmount")
            Spacer()
            errorText.padding(.bottom, 16)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    CaptionMText(t("wallet__send_available"), kerning: 1, lineHeight: 18)
                    BodySSBText(
                        settings.hideBalance ? " • • • • •" : "<accent>$</accent> " + (spark.usd.map { usdtOverviewAmount($0.balance) } ?? "—"),
                        accentColor: .textSecondary,
                        kerning: 0,
                        lineHeight: 20
                    )
                }
                Spacer(minLength: 8)
                NumberPadActionButton(text: t("common__max"), titleKerning: 1, titleLineHeight: 18, color: .usdtAccent) {
                    if let balance = spark.usd?.balance {
                        amount = usdtFormatAmount(amount: balance)
                    }
                }
                .accessibilityIdentifier("SparkUsdMax")
            }
            .padding(.bottom, 16)
            CustomDivider()
            NumberPad(type: .decimal, onDeleteLongPress: { amount = "" }) { key in
                amount = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
                error = nil
            }
            CustomButton(title: t("common__continue"), isDisabled: amount.isEmpty, titleKerning: 0, titleLineHeight: 20) { review() }
                .accessibilityIdentifier("SparkUsdReview")
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsdtAmountHeader(amount: usdtFormatAmount(amount: amountUnits ?? 0), displayAmount: usdtOverviewAmount(amountUnits ?? 0))
            CaptionMText(t("wallet__send_to")).padding(.top, 24).padding(.bottom, 8)
            BodySSBText(recipient?.request ?? "", kerning: 0).lineLimit(2).accessibilityIdentifier("SparkUsdReviewRecipient")
            Spacer()
            errorText.padding(.bottom, 16)
            SwipeButton(title: t("wallet__send_swipe"), accentColor: .usdtAccent, isDisabled: busy, isLoading: busy, isSubmitted: submitted,
                        swipeProgress: $swipeProgress)
            {
                try await authenticateAndSend()
                if !submitted {
                    throw CancellationError()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SparkUsdConfirm")
        }
    }

    private var submittedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsdtAmountHeader(amount: usdtFormatAmount(amount: amountUnits ?? 0), displayAmount: usdtOverviewAmount(amountUnits ?? 0))
            Spacer()
            HStack(spacing: 16) {
                if let sentTransferId {
                    CustomButton(title: t("wallet__send_details"), variant: .secondary) {
                        dismiss()
                        navigation.navigate(.sparkUsdActivity(transferId: sentTransferId))
                    }
                    .accessibilityIdentifier("SparkUsdSendDetails")
                }
                CustomButton(title: t("common__close")) { dismiss() }
                    .accessibilityIdentifier("SparkUsdDone")
            }
        }
        .background {
            PaymentCelebration(isOnchain: true, isReceived: false, confettiColor: .usdtAccent, isUsdt: true)
        }
        .accessibilityIdentifier("SparkUsdSendSuccess")
    }

    @ViewBuilder
    private var errorText: some View {
        if let error {
            BodySText(error, textColor: .brandAccent).accessibilityIdentifier("SparkUsdError")
        }
    }

    private func useRecipient() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let parsed = try await spark.parseUsdRecipient(recipientInput)
            recipient = parsed
            if let fixed = parsed.amount {
                amount = usdtFormatAmount(amount: fixed)
                reviewing = true
            }
        } catch SparkUsdError.unsupportedRecipient {
            error = t("usdt__error_address_spark")
        } catch {
            self.error = t("usdt__error_network")
            Logger.warn("Failed to read Spark dollar recipient: \(error)", context: "SparkUsdSendView")
        }
    }

    private func review() {
        guard let units = amountUnits else {
            error = t("usdt__error_amount")
            return
        }
        guard units <= spark.usd?.balance ?? 0 else {
            error = t("usdt__error_balance_spark")
            return
        }
        error = nil
        reviewing = true
    }

    private func goBack() {
        if reviewing, recipient?.amount == nil {
            reviewing = false
        } else if recipient != nil {
            recipient = nil
            reviewing = false
        } else {
            dismiss()
        }
    }

    private func authenticateAndSend() async throws {
        if settings.requirePinForPayments && settings.pinEnabled {
            if settings.useBiometrics && BiometricAuth.isAvailable {
                switch await BiometricAuth.authenticate() {
                case .success: break
                case .cancelled: throw CancellationError()
                case let .failed(message):
                    error = message
                    throw CancellationError()
                }
            } else {
                let verified = await withCheckedContinuation { continuation in
                    pinContinuation = continuation
                    pin = true
                }
                guard verified else { throw CancellationError() }
            }
        }
        await send()
    }

    private func resolvePin(_ verified: Bool) {
        pinContinuation?.resume(returning: verified)
        pinContinuation = nil
        pin = false
    }

    private func send() async {
        guard let recipient, let units = amountUnits, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            sentTransferId = try await spark.sendUsd(request: recipient.request, amount: units, isAmountFixed: recipient.amount != nil)
            submitted = true
        } catch {
            self.error = t("usdt__send_failed_description")
            Logger.error("Failed to send Spark dollar payment: \(error)", context: "SparkUsdSendView")
        }
    }
}

/// Converts between bitcoin and the dollar token within the wallet, or bridges dollars to Bitkit's Arbitrum USDT wallet
/// when `bridgeAddress` is set.
struct SparkUsdConvertView: View {
    let bridgeAddress: String?
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var toUsd = true
    @State private var amount = ""
    @State private var quote: SparkUsdQuote?
    @State private var busy = false
    @State private var completed = false
    @State private var error: String?
    @State private var swipeProgress: CGFloat = 0
    private let spark = SparkManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: t(bridgeAddress == nil ? "usdt__convert_spark" : "usdt__bridge_spark"),
                showBackButton: quote != nil && !completed,
                topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8,
                onBack: { quote = nil }
            )
            .disabled(busy)
            if let quote {
                quoteContent(quote)
            } else {
                amountContent
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray7)
        .navigationBarHidden(true)
        .interactiveDismissDisabled(busy)
    }

    private var amountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridgeAddress == nil {
                HStack(spacing: 8) {
                    NumberPadActionButton(
                        text: t("usdt__convert_to_usd_spark"), titleKerning: 1, titleLineHeight: 18,
                        color: toUsd ? .usdtAccent : .textSecondary
                    ) { toUsd = true; error = nil }
                        .accessibilityIdentifier("SparkUsdConvertToUsd")
                    NumberPadActionButton(
                        text: t("usdt__convert_to_btc_spark"), titleKerning: 1, titleLineHeight: 18,
                        color: toUsd ? .textSecondary : .usdtAccent
                    ) { toUsd = false; error = nil }
                        .accessibilityIdentifier("SparkUsdConvertToBtc")
                }
                .padding(.bottom, 16)
            } else {
                BodySText(t("usdt__bridge_note_spark"), textColor: .textSecondary).padding(.bottom, 16)
            }
            UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount).accessibilityIdentifier("SparkUsdConvertAmount")
            Spacer()
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("SparkUsdError").padding(.bottom, 16)
            }
            CustomDivider()
            NumberPad(type: .decimal, onDeleteLongPress: { amount = "" }) { key in
                amount = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
                error = nil
            }
            CustomButton(title: t("common__continue"), isDisabled: amount.isEmpty, isLoading: busy, titleKerning: 0, titleLineHeight: 20) {
                await requestQuote()
            }
            .accessibilityIdentifier("SparkUsdQuote")
        }
    }

    private func quoteContent(_ quote: SparkUsdQuote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            quoteRow(t("usdt__convert_pay_spark"), Self.display(quote.pay, isSats: quote.kind == .toUsd))
            quoteRow(t("usdt__convert_receive_spark"), Self.display(quote.receive, isSats: quote.kind == .toBtc))
            quoteRow(t("usdt__convert_fee_spark"), Self.display(quote.fee, isSats: false))
            Spacer()
            if let error {
                BodySText(error, textColor: .brandAccent).accessibilityIdentifier("SparkUsdError").padding(.bottom, 16)
            }
            if completed {
                CustomButton(title: t("common__close")) { dismiss() }
                    .accessibilityIdentifier("SparkUsdDone")
            } else {
                SwipeButton(title: t("other__swipe"), accentColor: .usdtAccent, isDisabled: busy, isLoading: busy, isSubmitted: completed,
                            swipeProgress: $swipeProgress)
                {
                    try await run(quote)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SparkUsdConfirmQuote")
            }
        }
    }

    private func quoteRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                CaptionMText(label)
                Spacer()
                BodySSBText(value, kerning: 0)
            }
            .padding(.vertical, 12)
            CustomDivider()
        }
    }

    private static func conversionError(_ error: Error) -> String {
        if let sdkError = error as? SdkError, case .InsufficientFunds = sdkError {
            return t("other__pay_insufficient_spending")
        }
        if "\(error)".localizedCaseInsensitiveContains("insufficient") {
            return t("other__pay_insufficient_spending")
        }
        return t("usdt__convert_failed_spark")
    }

    private static func display(_ value: UInt64, isSats: Bool) -> String {
        isSats ? "₿ " + value.formatted() : "$ " + usdtOverviewAmount(value)
    }

    private func requestQuote() async {
        guard let units = try? usdtParseAmount(value: amount), units > 0 else {
            error = t("usdt__error_amount")
            return
        }
        if bridgeAddress != nil || !toUsd, units > spark.usd?.balance ?? 0 {
            error = t("usdt__error_balance_spark")
            return
        }
        if bridgeAddress == nil, toUsd, spark.balanceSats == 0 {
            error = t("other__pay_insufficient_spending")
            return
        }
        busy = true
        defer { busy = false }
        do {
            let quoted = if let bridgeAddress {
                try await spark.quoteArbitrumBridge(arbitrumAddress: bridgeAddress, amount: units)
            } else {
                try await spark.quoteConversion(toUsd: toUsd, amount: units)
            }
            guard quoted.kind != .toUsd || quoted.pay <= spark.balanceSats else {
                error = t("other__pay_insufficient_spending")
                return
            }
            quote = quoted
            error = nil
        } catch {
            self.error = Self.conversionError(error)
            Logger.warn("Failed to quote Spark dollar conversion: \(error)", context: "SparkUsdConvertView")
        }
    }

    private func run(_ quote: SparkUsdQuote) async throws {
        busy = true
        defer { busy = false }
        do {
            try await spark.execute(quote)
            completed = true
        } catch {
            self.error = Self.conversionError(error)
            Logger.error("Failed to run Spark dollar conversion: \(error)", context: "SparkUsdConvertView")
            throw error
        }
    }
}
