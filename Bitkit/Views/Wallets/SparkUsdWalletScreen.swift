import BitkitCore
import BreezSdkSpark
import SwiftUI

/// The dollar balance held on Spark, separate from the Arbitrum USDT wallet: its activity, receive QR and send flow.
struct SparkUsdWalletScreen: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
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
                }
            }
        }
    }

    private var activityList: some View {
        let transfers = spark.usd?.transfers ?? []
        return LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(transfers.enumerated()), id: \.element.id) { index, transfer in
                let header = transfer.groupTitle
                if index == 0 || transfers[index - 1].groupTitle != header {
                    CaptionMText(header).padding(.top, index == 0 ? 0 : 16)
                }
                SparkUsdActivityRow(transfer: transfer, hideBalance: settings.hideBalance)
                    .accessibilityIdentifier("SparkUsdActivity-\(index)")
            }
        }
    }
}

enum SparkUsdPage: String, Identifiable {
    case receive
    case send

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

private extension SparkUsdTransfer {
    var groupTitle: String {
        DateFormatterHelpers.getActivityGroupHeader(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    var title: String {
        switch status {
        case .failed: t("usdt__failed")
        case .pending: t("usdt__pending")
        case .completed: t(isIncoming ? "usdt__received" : "usdt__sent")
        }
    }

    var statusIcon: String {
        switch status {
        case .failed: "x-circle"
        case .pending: "hourglass-simple"
        case .completed: isIncoming ? "arrow-down" : "arrow-up"
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
                QrArea(uri: request, imageAsset: "tether-circle", accentColor: .usdtAccent, copyValue: request,
                       shareText: request, copyMessage: t("usdt__receive_copied"))
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
            return t("usdt__sent_title")
        }
        if reviewing {
            return t("wallet__send_review")
        }
        if recipient != nil {
            return t("usdt__amount")
        }
        return t("usdt__send_title")
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
            BodySText(t("usdt__submitted_description"), textColor: .textSecondary)
            Spacer()
            CustomButton(title: t("common__close")) { dismiss() }
                .accessibilityIdentifier("SparkUsdDone")
        }
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
            error = t("usdt__error_address")
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
            error = t("usdt__error_balance")
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
            try await spark.sendUsd(request: recipient.request, amount: units)
            submitted = true
        } catch {
            self.error = t("usdt__send_failed_description")
            Logger.error("Failed to send Spark dollar payment: \(error)", context: "SparkUsdSendView")
        }
    }
}
