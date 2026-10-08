import SwiftUI

struct PaymentRequestSummary: View {
    let contactName: String
    let note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SendSectionView(t("wallet__send_from")) {
                paymentRequestSummaryValue(
                    contactName,
                    icon: "user",
                    accessibilityIdentifier: "PaymentRequestFrom"
                )
            }

            SendSectionView(t("wallet__payment_request_for")) {
                paymentRequestSummaryValue(
                    note ?? t("wallet__payment_request_for_not_specified"),
                    icon: "note",
                    textColor: note == nil ? .textSecondary : .textPrimary,
                    accessibilityIdentifier: "PaymentRequestFor"
                )
            }
        }
    }

    private func paymentRequestSummaryValue(
        _ text: String,
        icon: String,
        textColor: Color = .textPrimary,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: 4) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .foregroundColor(.white)
                .frame(width: 16, height: 16)

            BodySSBText(text, textColor: textColor)
                .lineLimit(1)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
