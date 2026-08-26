import SwiftUI

struct PaymentRequestsSheetItem: SheetItem {
    let id: SheetID = .paymentRequests
    let size: SheetSize = .large
}

struct PaymentRequestCard: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let request: PaykitPaymentRequest
    var subtitleOverride: String?
    var status: String?
    var isHighlighted = true
    var isActionDisabled = false
    var paymentDirection: PaykitPaymentRequest.Direction?
    var amountStatus: String?
    var onOpen: (() -> Void)?
    var onPay: (() -> Void)?
    var onReject: (() async -> Void)?

    @State private var isRejecting = false

    private var contact: PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, request.counterparty) }
    }

    private var senderName: String {
        contact?.displayName ?? PubkyPublicKeyFormat.displayTruncated(request.counterparty)
    }

    private var subtitle: String {
        if let subtitleOverride {
            return subtitleOverride
        }

        if let note = request.note, !note.isEmpty {
            return note
        }

        return request.createdAt.map(Self.dateFormatter.string) ?? t("wallet__payment_request")
    }

    private var title: String {
        senderName
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onOpen {
                Button(action: onOpen) {
                    header
                }
                .buttonStyle(.plain)
            } else {
                header
            }

            if let status {
                CustomDivider()
                HStack {
                    CaptionMText(status, textColor: .brandAccent)
                    Spacer()
                    if let expiresAt = request.expiresAt {
                        CaptionText(Self.expirationFormatter.localizedString(for: expiresAt, relativeTo: Date()), textColor: .white64)
                    }
                }
                .padding(16)
            } else if onPay != nil || onReject != nil {
                HStack(spacing: 16) {
                    CustomButton(
                        title: t("wallet__payment_request_dismiss"),
                        variant: .secondary,
                        size: .small,
                        icon: Image("x-mark").resizable().frame(width: 16, height: 16),
                        isDisabled: isActionDisabled,
                        isLoading: isRejecting,
                        shouldExpand: true
                    ) {
                        guard !isRejecting else { return }
                        isRejecting = true
                        await onReject?()
                        isRejecting = false
                    }

                    CustomButton(
                        title: t("common__pay"),
                        size: .small,
                        icon: Image("coins").resizable().frame(width: 16, height: 16),
                        isDisabled: isActionDisabled || isRejecting,
                        shouldExpand: true
                    ) {
                        onPay?()
                    }
                }
                .padding(16)
                .background(Color.gray5)
            }
        }
        .background(Color.gray6)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isHighlighted ? Color.brand50 : Color.clear, lineWidth: 1)
        }
        .shadow(color: isHighlighted ? .brandAccent.opacity(0.16) : .clear, radius: 64)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowAccessibilityIdentifier)
    }

    private var header: some View {
        HStack(spacing: 16) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(title)
                    .lineLimit(1)
                CaptionText(subtitle, textColor: .white64)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let amountStatus {
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(
                        sats: Int(clamping: request.amountSats),
                        unitType: .primary,
                        size: .bodyMSB,
                        prefix: amountPrefix,
                        color: .textPrimary,
                        symbolColor: .textSecondary
                    )
                    CaptionText(amountStatus, textColor: .white64)
                }
            } else {
                MoneyCell(sats: Int(clamping: request.amountSats), prefix: amountPrefix)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let paymentDirection {
            CircularIcon(
                icon: paymentDirection == .incoming ? "arrow-up" : "arrow-down",
                iconColor: .brandAccent,
                backgroundColor: .brand16,
                size: 40
            )
        } else if let contact {
            PubkyContactAvatar(contact: contact, size: 40)
        } else {
            ContactAvatarLetter(source: request.counterparty, size: 40)
        }
    }

    private var amountPrefix: String {
        switch paymentDirection {
        case .incoming: "-"
        case .outgoing: "+"
        case nil: ""
        }
    }

    private var rowAccessibilityIdentifier: String {
        let period = request.billingPeriod.map {
            PaykitSubscriptionTimestamp.string(from: $0.startsAt)
        } ?? "one-time"
        return "PaymentRequestRow-\(request.paymentRequestId)-\(request.counterparty)-\(request.counterpartyReceiverPath)-\(period)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMdHm")
        return formatter
    }()

    private static let expirationFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

struct PaymentRequestsSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let config: PaymentRequestsSheetItem

    var body: some View {
        Sheet(id: .paymentRequests, data: config) {
            VStack(spacing: 0) {
                SheetHeader(title: t("wallet__payment_requests"))

                BodyMText(t("wallet__payment_requests_review"), textColor: .white64)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 16) {
                        ForEach(paymentRequests.pendingRequests.sorted(by: Self.newestFirst).prefix(3)) { request in
                            requestCard(request)
                        }
                    }
                }

                Spacer(minLength: 16)

                HStack(spacing: 16) {
                    CustomButton(title: t("wallet__payment_requests_not_now"), variant: .secondary) {
                        sheets.hideSheet(reason: "Payment requests deferred")
                    }

                    CustomButton(title: t("wallet__payment_requests_see_all")) {
                        sheets.hideSheet(reason: "Opening all payment requests")
                        navigation.navigate(.subscriptions(showPayments: true))
                    }
                    .accessibilityIdentifier("PaymentRequestsSeeAll")
                }
            }
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("PaymentRequestsSheet")
        .onChange(of: paymentRequests.pendingRequests) { _, requests in
            if requests.isEmpty {
                sheets.hideSheetIfActive(.paymentRequests, reason: "No pending payment requests")
            }
        }
    }

    private func requestCard(_ request: PaykitPaymentRequest) -> some View {
        PaymentRequestCard(
            request: request,
            onOpen: {
                sheets.hideSheet(reason: "Opening payment request details")
                navigation.navigate(.paymentRequestDetail(request.id))
            },
            onPay: {
                sheets.hideSheetBeforePerforming(reason: "Paying payment request") {
                    _ = paymentRequests.requestPresentation(request)
                }
            },
            onReject: {
                await dismiss(request)
            }
        )
    }

    private func dismiss(_ request: PaykitPaymentRequest) async {
        do {
            try await paymentRequests.dismiss(request)
        } catch {
            app.toast(error)
        }
    }

    private static func newestFirst(_ lhs: PaykitPaymentRequest, _ rhs: PaykitPaymentRequest) -> Bool {
        (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
}

struct PaymentRequestsView: View {
    private struct HistorySection: Identifiable {
        let title: String
        var requests: [PaykitPaymentRequest]

        var id: String {
            title
        }
    }

    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    var body: some View {
        VStack(spacing: 0) {
            if activeRequests.isEmpty, paymentRequests.historyRequests.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !activeRequests.isEmpty {
                            CaptionMText(t("wallet__payment_requests").localizedUppercase, textColor: .white64)
                            ForEach(activeRequests) { request in
                                activeRequestCard(request)
                            }
                        }

                        ForEach(historySections) { section in
                            CaptionMText(section.title.localizedUppercase, textColor: .white64)
                                .padding(.top, 8)
                            ForEach(section.requests) { request in
                                PaymentRequestCard(
                                    request: request,
                                    subtitleOverride: historyDate(for: request),
                                    isHighlighted: false,
                                    paymentDirection: request.lifecycleState == .proofSubmitted ? request.direction : nil,
                                    onOpen: { navigation.navigate(.paymentRequestDetail(request.id)) }
                                )
                            }
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                }
            }

            if !paymentRequests.eligibleTargets.isEmpty {
                CustomButton(
                    title: activeRequests.isEmpty && paymentRequests.historyRequests.isEmpty
                        ? t("wallet__payment_request_request")
                        : t("wallet__payment_request_request_payment")
                ) {
                    sheets.showSheet(
                        .receive,
                        data: ReceiveConfig(view: .paymentRequestRecipient(ReceiveSheet.defaultPaymentRequestDraft))
                    )
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("PaymentRequestRequestPayment")
            }
        }
        .background(Color.black)
        .navigationBarHidden(true)
        .accessibilityIdentifier("PaymentRequestsScreen")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Image("restore")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer()

            DisplayText(t("wallet__payment_requests_empty_headline"), accentColor: .purpleAccent)
            Spacer().frame(height: 12)
            BodyMText(t("wallet__payment_requests_empty_description"), textColor: .white64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    private var activeRequests: [PaykitPaymentRequest] {
        let pending = paymentRequests.pendingRequests
        let historical = paymentRequests.historyRequests.filter {
            ($0.lifecycleState == .proposed && !$0.isExpired(at: Date()))
                || ($0.direction == .outgoing && $0.lifecycleState == .accepted)
        }
        return (pending + historical).reduce(into: [PaykitPaymentRequest]()) { requests, request in
            if !requests.contains(where: { $0.id == request.id }) {
                requests.append(request)
            }
        }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private var historicalRequests: [PaykitPaymentRequest] {
        paymentRequests.historyRequests.filter { request in
            !activeRequests.contains { $0.id == request.id }
        }
    }

    private var historySections: [HistorySection] {
        historicalRequests
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .reduce(into: [HistorySection]()) { sections, request in
                let title = request.createdAt.map { DateFormatterHelpers.getActivityGroupHeader(for: $0) } ?? t("other__earlier")
                if sections.last?.title == title {
                    sections[sections.count - 1].requests.append(request)
                } else {
                    sections.append(HistorySection(title: title, requests: [request]))
                }
            }
    }

    private func isActionable(_ request: PaykitPaymentRequest) -> Bool {
        paymentRequests.pendingRequests.contains { $0.id == request.id }
    }

    private func status(for request: PaykitPaymentRequest) -> String {
        if request.isExpired(at: Date()), request.lifecycleState == .proposed {
            return t("wallet__payment_request_status_expired")
        }

        switch request.lifecycleState {
        case .proposed:
            if request.direction == .incoming {
                return t("wallet__payment_request_status_unavailable")
            }
            return request.deliveryStatus == .sent
                ? t("wallet__payment_request_waiting")
                : t("wallet__payment_request_sending")
        case .proposalExpired:
            return t("wallet__payment_request_status_expired")
        case .accepted:
            return t("wallet__payment_request_status_pending")
        case .rejected:
            return t("wallet__payment_request_status_rejected")
        case .canceled:
            return t("wallet__payment_request_status_canceled")
        case .proofSubmitted:
            return t("wallet__payment_request_status_paid")
        case .recoveryRequired:
            return t("wallet__payment_request_status_action_required")
        case .invalidConflict, .activeRecurring, .unknown:
            return t("wallet__payment_request_status_unavailable")
        }
    }

    @ViewBuilder
    private func activeRequestCard(_ request: PaykitPaymentRequest) -> some View {
        if isActionable(request) {
            PaymentRequestCard(
                request: request,
                isActionDisabled: paymentRequests.requestedPresentationId == request.id,
                onOpen: { navigation.navigate(.paymentRequestDetail(request.id)) },
                onPay: { _ = paymentRequests.requestPresentation(request) },
                onReject: { await dismiss(request) }
            )
        } else if request.direction == .outgoing {
            PaymentRequestCard(
                request: request,
                isHighlighted: false,
                amountStatus: t("wallet__payment_request_status_pending").localizedLowercase,
                onOpen: { navigation.navigate(.paymentRequestDetail(request.id)) }
            )
        } else {
            PaymentRequestCard(
                request: request,
                status: status(for: request),
                onOpen: { navigation.navigate(.paymentRequestDetail(request.id)) }
            )
        }
    }

    private func historyDate(for request: PaykitPaymentRequest) -> String {
        guard let createdAt = request.createdAt else { return status(for: request) }
        return Self.dateFormatter.string(from: createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()

    private func dismiss(_ request: PaykitPaymentRequest) async {
        do {
            try await paymentRequests.dismiss(request)
        } catch {
            app.toast(error)
        }
    }
}

struct PaymentRequestDetailView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var tagManager: TagManager
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let id: PaykitPaymentRequest.ID
    @State private var showAddTagSheet = false

    private var request: PaykitPaymentRequest? {
        (paymentRequests.pendingRequests + paymentRequests.historyRequests).first { $0.id == id }
    }

    private var contact: PubkyContact? {
        guard let request else { return nil }
        return contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, request.counterparty) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__payment_request"))

            if let request {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        amount(request)
                        details(request)
                        counterparty(request)
                        if isActionable(request) {
                            tags
                        }

                        if let note = request.note, !note.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                CaptionMText(t("wallet__payment_request_note").localizedUppercase, textColor: .white64)
                                VStack(alignment: .leading, spacing: 0) {
                                    ZigzagDivider()
                                    TitleText(note)
                                        .padding(24)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.white10)
                                }
                            }
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                }

                if isActionable(request) {
                    actions(request)
                }
            } else {
                Spacer()
                BodyMText(t("wallet__payment_request_status_unavailable"), textColor: .white64)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .background(Color.black)
        .navigationBarHidden(true)
        .accessibilityIdentifier("PaymentRequestDetailScreen")
        .task {
            tagManager.clearSelectedTags()
        }
        .sheet(isPresented: $showAddTagSheet) {
            AddProfileTagSheet { tag in
                tagManager.addTagToSelection(tag)
            }
        }
    }

    private func amount(_ request: PaykitPaymentRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(currency.convert(sats: request.amountSats)?.formatted ?? "", textColor: .white64)
            HStack(spacing: 16) {
                MoneyText(
                    sats: Int(clamping: request.amountSats),
                    unitType: .primary,
                    size: .display,
                    symbol: false,
                    prefix: request.direction == .incoming ? "-" : "",
                    color: .textPrimary,
                    symbolColor: .textSecondary
                )
                Spacer()
                CircularIcon(
                    icon: request.direction == .incoming ? "arrow-down" : "arrow-up",
                    iconColor: request.direction == .incoming ? .purpleAccent : .brandAccent,
                    backgroundColor: request.direction == .incoming ? .purple16 : .brand16,
                    size: 48
                )
            }
        }
    }

    private func details(_ request: PaykitPaymentRequest) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            LabeledDetailCell(
                title: t("wallet__payment_request_date"),
                value: request.createdAt.map(Self.dateFormatter.string) ?? "–",
                icon: "calendar"
            )
            LabeledDetailCell(
                title: t("wallet__payment_request_time"),
                value: request.createdAt.map(Self.timeFormatter.string) ?? "–",
                icon: "clock"
            )
        }
    }

    private func counterparty(_ request: PaykitPaymentRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionMText(t("wallet__payment_request_contact").localizedUppercase, textColor: .white64)
            HStack(spacing: 16) {
                if let contact {
                    PubkyContactAvatar(contact: contact, size: 48)
                } else {
                    ContactAvatarLetter(source: request.counterparty, size: 48)
                }
                BodyMSBText(contact?.displayName ?? PubkyPublicKeyFormat.displayTruncated(request.counterparty))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.gray6)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            CustomDivider()
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("wallet__tags").localizedUppercase, textColor: .white64)
            TagsListView(
                tags: tagManager.selectedTagsArray,
                icon: .close,
                onAddTag: { showAddTagSheet = true },
                onTagDelete: tagManager.removeTagFromSelection,
                addButtonTestId: "PaymentRequestAddTag"
            )
            .padding(.bottom, 16)
            CustomDivider()
        }
    }

    private func actions(_ request: PaykitPaymentRequest) -> some View {
        HStack(spacing: 16) {
            CustomButton(
                title: t("wallet__payment_request_dismiss"),
                variant: .secondary,
                icon: Image("x-mark").resizable().frame(width: 16, height: 16)
            ) {
                do {
                    try await paymentRequests.dismiss(request)
                    navigation.navigateBack()
                } catch {
                    app.toast(error)
                }
            }

            CustomButton(
                title: t("common__pay"),
                icon: Image("coins").resizable().frame(width: 16, height: 16)
            ) {
                guard paymentRequests.requestPresentation(request) else { return }
                tagManager.preserveSelectedTags(for: request.id)
                navigation.navigateBack()
            }
        }
        .padding(.bottom, 16)
    }

    private func isActionable(_ request: PaykitPaymentRequest) -> Bool {
        paymentRequests.pendingRequests.contains { $0.id == request.id }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()
}
