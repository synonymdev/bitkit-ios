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
        guard let createdAt = request.createdAt else { return senderName }
        return "\(senderName) - \(Self.dateFormatter.string(from: createdAt))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    BodyMSBText(request.note ?? t("wallet__payment_request"))
                        .lineLimit(1)
                    CaptionText(subtitle, textColor: .white64)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                MoneyCell(sats: Int(clamping: request.amountSats), prefix: "")
            }
            .padding(16)

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
                CustomDivider()
                HStack(spacing: 12) {
                    CustomButton(
                        title: t("wallet__payment_request_dismiss"),
                        variant: .secondary,
                        size: .small,
                        icon: Image("x-mark").resizable().frame(width: 16, height: 16),
                        isDisabled: isActionDisabled,
                        isLoading: isRejecting
                    ) {
                        guard !isRejecting else { return }
                        isRejecting = true
                        await onReject?()
                        isRejecting = false
                    }
                    .frame(maxWidth: .infinity)

                    CustomButton(
                        title: t("common__pay"),
                        size: .small,
                        icon: Image("coins").resizable().frame(width: 16, height: 16),
                        isDisabled: isActionDisabled || isRejecting
                    ) {
                        onPay?()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
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
        .accessibilityIdentifier("PaymentRequestRow-\(request.paymentRequestId)")
    }

    @ViewBuilder
    private var avatar: some View {
        if let contact {
            PubkyContactAvatar(contact: contact, size: 40)
        } else {
            ContactAvatarLetter(source: request.counterparty, size: 40)
        }
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
                        ForEach(paymentRequests.pendingRequests.prefix(3)) { request in
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
                        navigation.navigate(.paymentRequests)
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
            onPay: {
                sheets.hideSheetBeforePerforming(reason: "Paying payment request") {
                    _ = paymentRequests.requestPresentation(request)
                }
            },
            onReject: {
                await reject(request)
            }
        )
    }

    private func reject(_ request: PaykitPaymentRequest) async {
        do {
            try await paymentRequests.reject(request)
        } catch {
            app.toast(error)
        }
    }
}

struct PaymentRequestsView: View {
    private struct HistorySection: Identifiable {
        let title: String
        let requests: [PaykitPaymentRequest]

        var id: String {
            title
        }
    }

    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__payment_requests"))

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if paymentRequests.historyRequests.isEmpty {
                        emptyState
                    } else {
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
                                PaymentRequestCard(request: request, subtitleOverride: historyDate(for: request), isHighlighted: false)
                            }
                        }
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 120)
            }

            if !paymentRequests.eligibleTargets.isEmpty {
                CustomButton(title: t("wallet__payment_request_request_payment")) {
                    let draft = PaykitPaymentRequestDraft(amountSats: 0, note: "", expiresAt: .now)
                    sheets.showSheet(.receive, data: ReceiveConfig(view: .paymentRequestDetails(draft)))
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("PaymentRequestRequestPayment")
            }
        }
        .padding(.horizontal, 16)
        .background(Color.black)
        .navigationBarHidden(true)
        .accessibilityIdentifier("PaymentRequestsScreen")
        .task {
            await paymentRequests.refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image("bell")
                .resizable()
                .scaledToFit()
                .foregroundColor(.white32)
                .frame(width: 48, height: 48)
            BodyMText(t("wallet__payment_requests_empty"), textColor: .white64)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var activeRequests: [PaykitPaymentRequest] {
        paymentRequests.historyRequests.filter {
            $0.lifecycleState == .proposed && !$0.isExpired(at: Date())
        }
    }

    private var historicalRequests: [PaykitPaymentRequest] {
        paymentRequests.historyRequests.filter { request in
            !activeRequests.contains { $0.id == request.id }
        }
    }

    private var historySections: [HistorySection] {
        let calendar = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: historicalRequests) { request in
            request.createdAt.map { calendar.dateInterval(of: .month, for: $0)?.start ?? .distantPast } ?? .distantPast
        }
        return groups.keys.sorted(by: >).map { month in
            let title = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
                ? t("wallet__activity_group_month")
                : Self.monthFormatter.string(from: month)
            return HistorySection(title: title, requests: groups[month, default: []])
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
            return t("wallet__payment_request_status_accepted")
        case .rejected:
            return t("wallet__payment_request_status_rejected")
        case .canceled:
            return t("wallet__payment_request_status_canceled")
        case .proofSubmitted:
            return t("wallet__payment_request_status_proof_submitted")
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
                subtitleOverride: activeDate(for: request),
                isActionDisabled: paymentRequests.requestedPresentationId == request.id,
                onPay: { _ = paymentRequests.requestPresentation(request) },
                onReject: { await reject(request) }
            )
        } else if request.direction == .outgoing {
            PaymentRequestCard(
                request: request,
                subtitleOverride: t(
                    "wallet__payment_request_waiting_for_recipient",
                    variables: ["name": displayName(for: request)]
                ),
                isHighlighted: false
            )
        } else {
            PaymentRequestCard(request: request, status: status(for: request))
        }
    }

    private func activeDate(for request: PaykitPaymentRequest) -> String {
        guard let createdAt = request.createdAt else { return status(for: request) }
        return Self.dateTimeFormatter.string(from: createdAt)
    }

    private func historyDate(for request: PaykitPaymentRequest) -> String {
        guard let createdAt = request.createdAt else { return status(for: request) }
        return Self.dateFormatter.string(from: createdAt)
    }

    private func displayName(for request: PaykitPaymentRequest) -> String {
        guard let contact = contactsManager.contacts.first(where: {
            PubkyPublicKeyFormat.matches($0.publicKey, request.counterparty)
        }) else {
            return PubkyPublicKeyFormat.displayTruncated(request.counterparty)
        }
        return contact.displayName
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMdHm")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    private func reject(_ request: PaykitPaymentRequest) async {
        do {
            try await paymentRequests.reject(request)
        } catch {
            app.toast(error)
        }
    }
}
