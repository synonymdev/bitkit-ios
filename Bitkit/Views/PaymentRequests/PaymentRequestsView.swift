import SwiftUI

struct PaymentRequestsSheetItem: SheetItem {
    let id: SheetID = .paymentRequests
    let size: SheetSize = .large
}

struct PaymentRequestCard: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let request: PaykitPaymentRequest
    var status: String?
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
        guard let createdAt = request.createdAt else { return senderName }
        return "\(senderName) · \(Self.dateFormatter.string(from: createdAt))"
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
                        title: t("wallet__payment_request_reject"),
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
                .stroke(Color.brand50, lineWidth: 1)
        }
        .shadow(color: .brandAccent.opacity(0.18), radius: 12)
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

    private static let dateFormatter = DateFormatterHelpers.formatter(dateStyle: .medium, timeStyle: .short)

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
    @EnvironmentObject private var app: AppViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__payment_requests"), showMenuButton: false)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if paymentRequests.pendingRequests.isEmpty, paymentRequests.sentRequests.isEmpty {
                        emptyState
                    } else {
                        if !paymentRequests.pendingRequests.isEmpty {
                            CaptionMText(t("wallet__payment_requests_incoming"), textColor: .white64)
                            ForEach(paymentRequests.pendingRequests) { request in
                                PaymentRequestCard(
                                    request: request,
                                    isActionDisabled: paymentRequests.requestedPresentationId == request.id,
                                    onPay: { _ = paymentRequests.requestPresentation(request) },
                                    onReject: { await reject(request) }
                                )
                            }
                        }

                        if !paymentRequests.sentRequests.isEmpty {
                            CaptionMText(t("wallet__payment_requests_sent"), textColor: .white64)
                                .padding(.top, 8)
                            ForEach(paymentRequests.sentRequests) { request in
                                PaymentRequestCard(request: request, status: status(for: request))
                            }
                        }
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 120)
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

    private func status(for request: PaykitPaymentRequest) -> String {
        request.deliveryStatus == .sent ? t("wallet__payment_request_waiting") : t("wallet__payment_request_sending")
    }

    private func reject(_ request: PaykitPaymentRequest) async {
        do {
            try await paymentRequests.reject(request)
        } catch {
            app.toast(error)
        }
    }
}
