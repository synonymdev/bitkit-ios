import SwiftUI

struct InitialSubscriptionPaymentProgress: View {
    var body: some View {
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
        .sheetBackground()
    }
}

func paykitPaymentReviewTitle(context: ContactPaymentContext?, fallback: String) -> String {
    guard let request = context?.incomingPaymentRequest else { return fallback }
    if context?.isInitialSubscriptionPayment == true {
        return t("subscriptions__review_and_subscribe")
    }
    return request.billingPeriod == nil ? t("wallet__payment_request") : t("subscriptions__subscription")
}
