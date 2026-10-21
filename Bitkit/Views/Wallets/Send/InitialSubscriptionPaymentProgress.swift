import SwiftUI

struct InitialSubscriptionPaymentProgress: View {
    @EnvironmentObject private var app: AppViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    private var subscription: PaykitSubscription? {
        guard let request = app.contactPaymentContext?.incomingPaymentRequest else { return nil }
        return paymentRequests.subscriptions.first {
            $0.paymentRequestId == request.paymentRequestId && $0.counterparty == request.counterparty
        }
    }

    var body: some View {
        Group {
            if let subscription {
                SubscriptionReviewContent(subscription: subscription, isPaying: true)
            } else {
                progressIndicator
            }
        }
        .sheetBackground()
    }

    private var progressIndicator: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: t("subscriptions__review_and_subscribe"),
                action: AnyView(SendContactHeaderAvatar())
            )
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .purpleAccent))
                .scaleEffect(1.25)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

func paykitPaymentReviewTitle(context: ContactPaymentContext?, fallback: String) -> String {
    guard let request = context?.incomingPaymentRequest else { return fallback }
    if context?.isInitialSubscriptionPayment == true {
        return t("subscriptions__review_and_subscribe")
    }
    return request.billingPeriod == nil ? t("wallet__payment_request") : t("subscriptions__subscription")
}
