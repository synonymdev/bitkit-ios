import Lottie
import SwiftUI

struct SubscriptionSheetItem: SheetItem {
    enum Route: Hashable {
        case review(PaykitSubscription)
        case success
        case details(PaykitSubscription)
        case cancel(PaykitSubscription)
        case payment(SendRoute)
    }

    let route: Route
    let id: SheetID = .subscription
    let size: SheetSize = .large
}

struct SubscriptionsView: View {
    private enum Tab: String, CustomStringConvertible {
        case overview
        case payments

        var description: String {
            switch self {
            case .overview: t("subscriptions__overview")
            case .payments: t("subscriptions__payments")
            }
        }
    }

    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    @State private var selectedTab = Tab.overview
    @State private var now = Date()
    private let showPayments: Bool

    init(showPayments: Bool = false) {
        self.showPayments = showPayments
        _selectedTab = State(initialValue: showPayments ? .payments : .overview)
    }

    private var proposals: [PaykitSubscription] {
        paymentRequests.subscriptions.filter { $0.isProposalVisible(at: now) }
    }

    private var active: [PaykitSubscription] {
        paymentRequests.subscriptions.filter { $0.isActive(at: now) }
    }

    private var expired: [PaykitSubscription] {
        paymentRequests.subscriptions.filter {
            $0.isExpired(at: now) && $0.wasAccepted
        }
    }

    private var hasVisibleSubscriptions: Bool {
        !proposals.isEmpty || !active.isEmpty || !expired.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("subscriptions__title"))
            SegmentedControl(
                selectedTab: $selectedTab,
                tabItems: [
                    TabItem(.overview),
                    TabItem(.payments, badge: paymentRequests.pendingRequests.count),
                ]
            )

            if selectedTab == .payments {
                PaymentRequestsView()
            } else if !hasVisibleSubscriptions {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        metrics
                        section(t("subscriptions__proposals"), subscriptions: proposals)
                        section(t("subscriptions__active"), subscriptions: active)
                        section(t("subscriptions__expired"), subscriptions: expired)
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 120)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Color.black)
        .navigationBarHidden(true)
        .accessibilityIdentifier("SubscriptionsScreen")
        .task {
            await paymentRequests.refresh()
        }
        .onChange(of: showPayments, initial: true) { _, showPayments in
            selectedTab = showPayments ? .payments : .overview
        }
        .task(id: nextTransitionDate) {
            guard let nextTransitionDate else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, nextTransitionDate.timeIntervalSince(now))))
            } catch {
                return
            }
            now = Date()
        }
    }

    private var nextTransitionDate: Date? {
        subscriptionNextTransitionDate(subscriptions: paymentRequests.subscriptions, now: now)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Image("subscription-clock")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer()

            DisplayText(t("subscriptions__empty_headline"), accentColor: .purpleAccent)
            Spacer().frame(height: 12)
            BodyMText(t("subscriptions__empty_description"), textColor: .white64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            SubscriptionMetric(title: t("subscriptions__monthly_cost"), icon: "calendar") {
                MoneyText(
                    sats: monthlyCostSats,
                    unitType: .primary,
                    size: .bodyMSB,
                    prefix: "",
                    color: .textPrimary,
                    symbolColor: .textSecondary
                )
            }
            Rectangle()
                .fill(Color.white16)
                .frame(width: 1, height: 50)
            SubscriptionMetric(title: t("subscriptions__active"), icon: "arrows-clockwise") {
                BodyMSBText("\(active.count)")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, subscriptions: [PaykitSubscription]) -> some View {
        if !subscriptions.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                CaptionMText(title.localizedUppercase, textColor: .white64)
                ForEach(subscriptions) { subscription in
                    Button {
                        if subscription.isProposalVisible(at: now) {
                            paymentRequests.requestSubscriptionPresentation(subscription)
                            sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: .review(subscription)))
                        } else {
                            navigation.navigate(.subscriptionDetail(subscription.id))
                        }
                    } label: {
                        SubscriptionRow(subscription: subscription, now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var monthlyCostSats: Int {
        subscriptionMonthlyCostSats(subscriptions: paymentRequests.subscriptions, now: now)
    }
}

func subscriptionMonthlyCostSats(subscriptions: [PaykitSubscription], now: Date) -> Int {
    let annualPeriods: (PaykitSubscriptionRecurrence.Unit) -> Decimal = { unit in
        switch unit {
        case .minute: 525_600
        case .hour: 8760
        case .day: 365
        case .week: 52
        case .month: 12
        case .year: 1
        }
    }
    let maximum = NSDecimalNumber(value: Int.max)
    return subscriptions.filter { $0.isActive(at: now) }.reduce(into: 0) { total, subscription in
        var monthlyCost = Decimal(subscription.amountSats) * annualPeriods(subscription.recurrence.unit)
            / Decimal(subscription.recurrence.every) / 12
        var roundedMonthlyCost = Decimal()
        NSDecimalRound(&roundedMonthlyCost, &monthlyCost, 0, .plain)
        let number = NSDecimalNumber(decimal: roundedMonthlyCost)
        total = total.saturatingAdd(number.compare(maximum) == .orderedDescending ? .max : number.intValue)
    }
}

func subscriptionNextTransitionDate(
    subscriptions: [PaykitSubscription],
    now: Date
) -> Date? {
    let activeSubscriptions = subscriptions.filter { $0.isActive(at: now) }
    var dates = subscriptions.flatMap {
        [$0.recurrence.startsAt, $0.proposalExpiresAt, $0.recurrence.endsAt].compactMap { $0 }
    }
    dates += activeSubscriptions.compactMap { $0.recurrence.nextPeriod(after: now)?.startsAt }
    return dates.filter { $0 > now }.min()
}

private struct SubscriptionMetric<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionMText(title.localizedUppercase, textColor: .white64)
            HStack(spacing: 8) {
                Image(icon)
                    .resizable()
                    .foregroundColor(.purpleAccent)
                    .frame(width: 24, height: 24)
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SubscriptionRow: View {
    let subscription: PaykitSubscription
    let now: Date

    var body: some View {
        HStack(spacing: 16) {
            SubscriptionAvatar(subscription: subscription, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(subscription.note ?? t("subscriptions__subscription"))
                    .lineLimit(1)
                CaptionText(subscription.rowSubtitle(at: now), textColor: .white64)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            MoneyCell(sats: Int(clamping: subscription.amountSats), prefix: "")
        }
        .padding(16)
        .background(Color.gray6)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(subscription.isExpired(at: now) ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityIdentifier(
            "SubscriptionRow-\(subscription.paymentRequestId)-\(subscription.counterparty)-\(subscription.counterpartyReceiverPath)"
        )
    }
}

struct SubscriptionAvatar: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let subscription: PaykitSubscription
    let size: CGFloat

    private var contact: PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, subscription.counterparty) }
    }

    var body: some View {
        if let contact {
            PubkyContactAvatar(contact: contact, size: size)
        } else {
            ContactAvatarLetter(source: subscription.counterparty, size: size)
        }
    }
}

struct SubscriptionDetailView: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let id: PaykitSubscription.ID
    @State private var now = Date()

    private var subscription: PaykitSubscription? {
        paymentRequests.subscriptions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: subscription?.note ?? t("subscriptions__subscription"))

            if let subscription {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        VStack(alignment: .leading, spacing: 16) {
                            CaptionMText(subscription.recurrence.cadenceLabel.localizedUppercase, textColor: .white64)
                            HStack(spacing: 16) {
                                MoneyText(
                                    sats: Int(clamping: subscription.amountSats),
                                    unitType: .primary,
                                    size: .display,
                                    symbol: true,
                                    color: .textPrimary,
                                    symbolColor: .textSecondary
                                )
                                Spacer()
                                SubscriptionAvatar(subscription: subscription, size: 48)
                            }
                        }

                        details(subscription)
                        payments(subscription)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                    .opacity(subscription.isExpired(at: now) ? 0.5 : 1)
                }

                footer(subscription)
            } else {
                Spacer()
                BodyMText(t("subscriptions__unavailable"), textColor: .white64)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .background(Color.black)
        .navigationBarHidden(true)
        .task(id: nextTransitionDate) {
            guard let nextTransitionDate else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, nextTransitionDate.timeIntervalSince(now))))
            } catch {
                return
            }
            now = Date()
        }
    }

    private func details(_ subscription: PaykitSubscription) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            LabeledDetailCell(
                title: t("subscriptions__subscription"),
                value: subscription.note ?? t("subscriptions__subscription"),
                icon: "cube"
            )
            LabeledDetailCell(title: t("subscriptions__frequency"), value: subscription.recurrence.frequencyValue, icon: "arrows-clockwise")
            LabeledDetailCell(
                title: t("subscriptions__status"),
                value: subscription.isActive(at: now) ? t("subscriptions__active") : t("subscriptions__expired"),
                icon: "check-mark"
            )
            if subscription.isActive(at: now) || subscription.recurrence.endsAt != nil {
                LabeledDetailCell(
                    title: timingTitle(subscription),
                    value: renewalText(subscription),
                    icon: "calendar"
                )
            }
        }
    }

    @ViewBuilder
    private func footer(_ subscription: PaykitSubscription) -> some View {
        let hasMoreInfo = subscription.metadata.description != nil || !subscription.metadata.benefits.isEmpty
        let canCancel = subscription.isActive(at: now) && subscription.recurrence.endsAt == nil
        if hasMoreInfo || canCancel {
            HStack(spacing: 16) {
                if hasMoreInfo {
                    CustomButton(title: t("subscriptions__more_info"), variant: .secondary) {
                        sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: .details(subscription)))
                    }
                }
                if canCancel {
                    CustomButton(
                        title: t("subscriptions__cancel"),
                        icon: Image("x-mark").resizable().frame(width: 16, height: 16)
                    ) {
                        sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: .cancel(subscription)))
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func payments(_ subscription: PaykitSubscription) -> some View {
        let payments = paymentRequests.historyRequests.filter {
            $0.belongs(to: subscription)
        }
        if !payments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CaptionMText(t("subscriptions__payments").localizedUppercase, textColor: .white64)
                ForEach(payments) { payment in
                    PaymentRequestCard(
                        request: payment,
                        subtitleOverride: payment.createdAt.map(Self.dateFormatter.string),
                        isHighlighted: false,
                        paymentDirection: .incoming
                    )
                }
            }
        }
    }

    private func renewalText(_ subscription: PaykitSubscription) -> String {
        guard subscription.isActive(at: now) else {
            return subscription.recurrence.endsAt.map(Self.dateFormatter.string) ?? t("subscriptions__expired")
        }
        let date = subscription.recurrence.endsAt ?? subscription.recurrence.nextPeriod(after: now)?.startsAt
        return date.map(Self.dateFormatter.string) ?? t("subscriptions__ongoing")
    }

    private func timingTitle(_ subscription: PaykitSubscription) -> String {
        guard subscription.isActive(at: now) else { return t("subscriptions__expired") }
        return subscription.recurrence.endsAt == nil ? t("subscriptions__renews") : t("subscriptions__expires")
    }

    private var nextTransitionDate: Date? {
        guard let subscription else { return nil }
        return [
            subscription.recurrence.startsAt,
            subscription.recurrence.endsAt,
            subscription.isActive(at: now) ? subscription.recurrence.nextPeriod(after: now)?.startsAt : nil,
        ]
        .compactMap { $0 }
        .filter { $0 > now }
        .min()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
        return formatter
    }()
}

struct SubscriptionSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests
    @Environment(HwWalletManager.self) private var hwWalletManager

    let config: SubscriptionSheetItem

    @State private var route: SubscriptionSheetItem.Route
    @State private var previousRoute: SubscriptionSheetItem.Route?
    @State private var now = Date()
    @State private var isAccepting = false

    init(config: SubscriptionSheetItem) {
        self.config = config
        _route = State(initialValue: config.route)
        _previousRoute = State(initialValue: nil)
    }

    var body: some View {
        Sheet(id: .subscription, data: config) {
            switch route {
            case let .review(subscription):
                review(subscription)
            case .success:
                success()
            case let .details(subscription):
                moreInfo(subscription)
            case let .cancel(subscription):
                cancel(subscription)
            case let .payment(sendRoute):
                SendSheet(config: SendSheetItem(initialRoute: sendRoute), isEmbedded: true)
            }
        }
        .task {
            if case let .review(subscription) = route {
                now = Date()
                paymentRequests.markSubscriptionProposalPresented(subscription)
            }
        }
        .onChange(of: route) { _, route in
            guard case let .review(subscription) = route else { return }
            now = Date()
            paymentRequests.markSubscriptionProposalPresented(subscription)
        }
        .onChange(of: paymentRequests.subscriptions) {
            guard !isAccepting,
                  !paymentRequests.isProcessingSubscription,
                  case let .review(subscription) = route,
                  !paymentRequests.subscriptions.contains(where: {
                      $0.id == subscription.id && $0.isProposalVisible(at: Date())
                  })
            else { return }
            sheets.hideSheetIfActive(.subscription, reason: "Subscription proposal is no longer available")
        }
        .task(id: reviewTransitionDate) {
            guard let reviewTransitionDate else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, reviewTransitionDate.timeIntervalSinceNow)))
            } catch {
                return
            }
            now = Date()
        }
        .interactiveDismissDisabled(isAccepting)
    }

    private func review(_ subscription: PaykitSubscription) -> some View {
        let payOnAcceptance = subscription.paymentDueOnAcceptance(at: now) != nil
        return VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__review_and_subscribe"))
            SubscriptionAmountHeader(subscription: subscription)
            SubscriptionProviderCard(subscription: subscription) {
                guard !isAccepting else { return }
                previousRoute = route
                route = .details(subscription)
            }
            .allowsHitTesting(!isAccepting)

            if !subscription.recurrence.unit.isSupported {
                BodyMText(t("subscriptions__unsupported_description"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            } else if subscription.acceptedPaymentEndpointIdentifiers.isEmpty {
                BodyMText(t("subscriptions__unsupported_payment_description"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }

            Spacer()
            Image("subscription-clock")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .accessibilityHidden(true)
            Spacer()

            if subscription.isProposalActionable(at: now) {
                SwipeButton(
                    title: payOnAcceptance
                        ? t("subscriptions__swipe_to_subscribe_and_pay")
                        : t("subscriptions__swipe_to_subscribe"),
                    accentColor: .purpleAccent,
                    isLoading: isAccepting || paymentRequests.isProcessingSubscription
                ) {
                    do {
                        try await accept(subscription)
                    } catch {
                        app.toast(error)
                        throw error
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func success() -> some View {
        SubscriptionSuccessView {
            sheets.hideSheet(reason: "Subscription success closed")
        }
    }

    @MainActor
    private func accept(_ subscription: PaykitSubscription) async throws {
        guard !isAccepting else { throw PaykitPaymentRequestError.operationInProgress }
        isAccepting = true
        defer { isAccepting = false }

        guard let dueRequest = try await paymentRequests.accept(subscription) else {
            guard paymentRequests.subscriptions.contains(where: {
                $0.id == subscription.id && $0.lifecycleState == .activeRecurring
            }) else {
                throw PaykitPaymentRequestError.requestUnavailable
            }
            route = .success
            return
        }

        guard sheets.activeSheetConfiguration?.id == .subscription else { return }

        let resolution: PublicPaykitPaymentLaunchResult
        do {
            resolution = try await PrivatePaykitService.shared.beginPaymentRequestWaitingForUpdatedList(dueRequest)
        } catch {
            try showInitialPaymentFailure(dueRequest, error: error)
            return
        }
        guard case let .opened(paymentTarget, privatePaymentContext) = resolution else {
            try showInitialPaymentFailure(dueRequest, error: PaykitPaymentRequestError.requestUnavailable)
            return
        }
        guard sheets.activeSheetConfiguration?.id == .subscription else { return }

        let context = ContactPaymentContext(
            publicKey: dueRequest.counterparty,
            privatePaymentContext: privatePaymentContext,
            incomingPaymentRequest: dueRequest,
            isInitialSubscriptionPayment: true
        )
        guard app.claimContactPaymentContext(context) else {
            throw PaykitPaymentRequestError.operationInProgress
        }

        do {
            try await app.handleScannedData(
                paymentTarget,
                claimedContactPaymentContext: context,
                alternativeOnchainBalanceSats: hwWalletManager.maximumFundingBalanceSats
            )
        } catch {
            guard sheets.activeSheetConfiguration?.id == .subscription,
                  app.ownsContactPaymentContext(context)
            else {
                if app.ownsContactPaymentContext(context) {
                    app.resetSendState()
                }
                return
            }
            try showInitialPaymentFailure(dueRequest, error: error, context: context)
            return
        }
        guard sheets.activeSheetConfiguration?.id == .subscription,
              app.ownsContactPaymentContext(context)
        else {
            if app.ownsContactPaymentContext(context) {
                app.resetSendState()
            }
            return
        }
        guard app.hasSendPaymentTarget else {
            try showInitialPaymentFailure(
                dueRequest,
                error: PaykitPaymentRequestError.requestUnavailable,
                context: context
            )
            return
        }

        let sendRoute: SendRoute = app.lnurlPayData == nil ? .confirm : .lnurlPayConfirm
        route = .payment(sendRoute)
    }

    @MainActor
    private func showInitialPaymentFailure(
        _ request: PaykitPaymentRequest,
        error: Error,
        context existingContext: ContactPaymentContext? = nil
    ) throws {
        guard sheets.activeSheetConfiguration?.id == .subscription else { return }
        let context = existingContext ?? ContactPaymentContext(
            publicKey: request.counterparty,
            incomingPaymentRequest: request,
            isInitialSubscriptionPayment: true
        )
        guard app.ownsContactPaymentContext(context) || app.claimContactPaymentContext(context) else {
            throw PaykitPaymentRequestError.operationInProgress
        }
        let failure = SendFailureContext(
            error: error,
            retryRoute: .confirm,
            contactPaymentContext: context
        )
        route = .payment(.failure(failure))
    }

    private var reviewTransitionDate: Date? {
        guard case let .review(subscription) = route else { return nil }
        return [subscription.recurrence.startsAt, subscription.proposalExpiresAt, subscription.recurrence.endsAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }

    private func moreInfo(_ subscription: PaykitSubscription) -> some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__details"), showBackButton: true) {
                closeDetails()
            }
            SubscriptionProviderCard(subscription: subscription)
                .padding(.bottom, 24)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let description = subscription.metadata.description {
                        BodySSBText(description)
                    }
                    ForEach(subscription.metadata.benefits.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            BodySSBText("•")
                            BodySSBText(subscription.metadata.benefits[index])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CustomButton(title: t("common__ok")) {
                closeDetails()
            }
        }
        .padding(.horizontal, 16)
    }

    private func closeDetails() {
        if let previousRoute {
            route = previousRoute
            self.previousRoute = nil
        } else {
            sheets.hideSheet(reason: "Subscription details closed")
        }
    }

    private func cancel(_ subscription: PaykitSubscription) -> some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__cancel_subscription"))
            SubscriptionAmountHeader(subscription: subscription)
            SubscriptionProviderCard(subscription: subscription, subtitle: subscription.rowSubtitle(at: now)) {
                previousRoute = route
                route = .details(subscription)
            }

            Spacer()
            Image("cross")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .accessibilityHidden(true)
            Spacer()

            SwipeButton(
                title: t("subscriptions__swipe_to_cancel"),
                accentColor: .redAccent,
                isLoading: paymentRequests.isProcessingSubscription
            ) {
                do {
                    try await paymentRequests.cancel(subscription)
                    sheets.hideSheet(reason: "Subscription canceled")
                } catch {
                    app.toast(error)
                    throw error
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct SubscriptionSuccessView: View {
    private let paymentProofKind: PaykitPaymentProofKind?
    let onClose: () -> Void

    init(paymentProofKind: PaykitPaymentProofKind? = nil, onClose: @escaping () -> Void) {
        self.paymentProofKind = paymentProofKind
        self.onClose = onClose
    }

    private var confettiAnimation: LottieAnimation? {
        let animationName = paymentProofKind == .onchain ? "confetti-orange" : "confetti-purple"
        guard let url = Bundle.main.url(forResource: animationName, withExtension: "json") else { return nil }
        return LottieAnimation.filepath(url.path)
    }

    var body: some View {
        ZStack {
            if let animation = confettiAnimation {
                LottieView(animation: animation)
                    .playing(loopMode: .loop)
                    .scaleEffect(1.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                SheetHeader(title: t("subscriptions__subscribed"))
                Spacer()
                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .accessibilityHidden(true)
                Spacer()
                CustomButton(title: t("common__close"), action: onClose)
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SubscriptionAmountHeader: View {
    let subscription: PaykitSubscription

    var body: some View {
        MoneyStack(sats: Int(clamping: subscription.amountSats), showSymbol: true)
            .padding(.bottom, 20)
    }
}

private struct SubscriptionProviderCard: View {
    let subscription: PaykitSubscription
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            content(showsChevron: false)
        }
    }

    private func content(showsChevron: Bool) -> some View {
        HStack(spacing: 16) {
            SubscriptionAvatar(subscription: subscription, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(subscription.note ?? t("subscriptions__subscription"))
                    .lineLimit(1)
                CaptionText(subtitle ?? subscription.recurrence.subscriptionFrequencyLabel, textColor: .white64)
                    .lineLimit(1)
            }
            Spacer()
            if showsChevron {
                Image("chevron")
                    .resizable()
                    .foregroundColor(.white64)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(showsChevron ? 16 : 0)
        .background(showsChevron ? Color.gray6 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: showsChevron ? 16 : 0))
    }
}

extension PaykitSubscriptionRecurrence {
    var cadenceLabel: String {
        let singular = every == 1
        switch unit {
        case .day:
            return singular ? t("subscriptions__per_day") : t("subscriptions__every_days", variables: ["count": "\(every)"])
        case .week:
            return singular ? t("subscriptions__per_week") : t("subscriptions__every_weeks", variables: ["count": "\(every)"])
        case .month:
            return singular ? t("subscriptions__per_month") : t("subscriptions__every_months", variables: ["count": "\(every)"])
        case .year:
            return singular ? t("subscriptions__per_year") : t("subscriptions__every_years", variables: ["count": "\(every)"])
        case .minute, .hour:
            return t("subscriptions__unsupported_frequency")
        }
    }

    var frequencyValue: String {
        guard every == 1 else { return cadenceLabel }
        switch unit {
        case .day:
            return t("subscriptions__daily")
        case .week:
            return t("subscriptions__weekly")
        case .month:
            return t("subscriptions__monthly")
        case .year:
            return t("subscriptions__yearly")
        case .minute, .hour:
            return t("subscriptions__unsupported_frequency")
        }
    }

    var subscriptionFrequencyLabel: String {
        guard every == 1 else { return cadenceLabel }
        switch unit {
        case .day:
            return t("subscriptions__daily_subscription")
        case .week:
            return t("subscriptions__weekly_subscription")
        case .month:
            return t("subscriptions__monthly_subscription")
        case .year:
            return t("subscriptions__yearly_subscription")
        case .minute, .hour:
            return t("subscriptions__unsupported_frequency")
        }
    }
}

private extension PaykitSubscription {
    func rowSubtitle(at now: Date) -> String {
        if isProposalVisible(at: now) || !recurrence.unit.isSupported {
            return recurrence.subscriptionFrequencyLabel
        }
        if isExpired(at: now) {
            guard let endsAt = recurrence.endsAt else { return t("subscriptions__expired") }
            return t("subscriptions__expires_date", variables: ["date": endsAt.formatted(.dateTime.month(.wide).day())])
        }
        if let endsAt = recurrence.endsAt {
            return t("subscriptions__expires_date", variables: ["date": endsAt.formatted(.dateTime.month(.wide).day())])
        }
        guard let renewal = recurrence.nextPeriod(after: now)?.startsAt else {
            return recurrence.subscriptionFrequencyLabel
        }
        return t("subscriptions__renews_date", variables: ["date": renewal.formatted(.dateTime.month(.wide).day())])
    }
}
