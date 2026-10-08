import SwiftUI

struct PaymentRequestInvoiceNote: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(t("wallet__activity_invoice_note"))
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                ZigzagDivider()

                TitleText(note, textColor: .primary)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white10)
                    .accessibilityIdentifier("PaymentRequestInvoiceNote")
            }
        }
    }
}
