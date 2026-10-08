import BitkitCore
import SwiftUI

struct UsdtSupportActions: View {
    let details: String
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 16) {
            CustomButton(title: t("wallet__send_error_support"), variant: .secondary) {
                sheets.hideSheet()
                navigation.navigate(.reportIssue(ReportIssuePrefill(message: details)))
            }
            .accessibilityIdentifier("UsdtContactSupport")
            CustomButton(title: t("usdt__copy_details"), variant: .secondary) {
                UIPasteboard.general.string = details
                app.toast(type: .success, title: t("common__copied"))
            }
            .accessibilityIdentifier("UsdtCopyDetails")
        }
    }
}

extension UsdtTransfer {
    @MainActor var supportDetails: String {
        var lines = [
            "Asset: USDT",
            "Bridge: \(orchestra == nil ? "USDT0" : "Orchestra")",
            "Source network: Arbitrum One",
            "Recipient network: \(destination.label)",
            "Status: \(status)",
        ]
        if let reference = orchestra?.quoteId { lines.append("Bridge reference: \(reference)") }
        if let txHash { lines.append("Source transaction: \(txHash)") }
        if let bridgeGuid { lines.append("LayerZero message: \(bridgeGuid)") }
        if let hash = orchestra?.destinationTx { lines.append("Destination transaction: \(hash)") }
        if let hash = orchestra?.refundTx { lines.append("Refund transaction: \(hash)") }
        return lines.joined(separator: "\n")
    }
}

extension UsdtDepositDetail {
    var supportDetails: String {
        var lines = [
            "Asset: \(deposit.asset)",
            "Bridge: Orchestra",
            "Source network: \(deposit.network)",
            "Recipient network: Arbitrum One",
            "Deposit reference: \(deposit.id)",
            "Status: \(order?.status ?? deposit.status)",
            "Source transaction: \(deposit.sourceTx)",
        ]
        if let statusCode { lines.append("Status code: \(statusCode)") }
        if let hash = order?.destinationTx { lines.append("Destination transaction: \(hash)") }
        if let hash = order?.refundTx ?? deposit.refundTx { lines.append("Refund transaction: \(hash)") }
        return lines.joined(separator: "\n")
    }
}
