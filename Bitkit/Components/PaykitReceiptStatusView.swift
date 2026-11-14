import SwiftUI

/// The Paykit receipt line of a received payment, with a retry when it failed.
struct PaykitReceiptStatusView: View {
    let status: PaykitReceiptStatus
    let onRetry: () -> Void

    private var text: String {
        switch status {
        case .sending: t("wallet__receipt_sending")
        case .sent: t("wallet__receipt_sent")
        case .failed: t("wallet__receipt_failed")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            CaptionBText(text, textColor: status == .failed ? .redAccent : .white64)
                .lineLimit(1)
                .accessibilityIdentifier("PaykitReceiptStatus")
            if status == .failed {
                Button(action: onRetry) {
                    CaptionBText(t("common__retry"), textColor: .brandAccent)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("PaykitReceiptRetry")
            }
        }
    }
}

/// Shows the receipt line for a received payment, keyed by its hash, txid or USDT transfer id, once there is one.
struct PaykitReceiptStatusLine: View {
    let paymentId: String

    var body: some View {
        if let status = PaykitReceiptService.shared.statuses[paymentId.lowercased()] {
            PaykitReceiptStatusView(status: status) {
                Task { await PaykitReceiptService.shared.retry(paymentId: paymentId) }
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        PaykitReceiptStatusView(status: .sending) {}
        PaykitReceiptStatusView(status: .sent) {}
        PaykitReceiptStatusView(status: .failed) {}
    }
    .padding()
    .background(Color.black)
}
