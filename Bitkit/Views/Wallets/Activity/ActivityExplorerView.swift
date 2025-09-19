import BitkitCore
import Foundation
import LDKNode
import SwiftUI

struct ActivityExplorerView: View {
    let item: Activity
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    @State private var txDetails: TxDetails?

    private var onchain: OnchainActivity? {
        guard case let .onchain(activity) = item else { return nil }
        return activity
    }

    private var lightning: LightningActivity? {
        guard case let .lightning(activity) = item else { return nil }
        return activity
    }

    private var paymentHash: String? {
        guard case let .lightning(activity) = item else { return nil }
        return activity.id
    }

    private func getBlockExplorerUrl(txId: String) -> URL? {
        let baseUrl =
            switch Env.network {
            case .testnet: "https://mempool.space/testnet"
            case .bitcoin, .regtest, .signet: "https://mempool.space"
            }
        return URL(string: "\(baseUrl)/tx/\(txId)")
    }

    private func loadTransactionDetails() async {
        guard let onchain else { return }

        do {
            let details = try await AddressChecker.getTransaction(txid: onchain.txId)
            await MainActor.run {
                txDetails = details
            }
        } catch {
            await MainActor.run {}
        }
    }

    private var amountPrefix: String {
        switch item {
        case let .lightning(activity):
            return activity.txType == .sent ? "-" : "+"
        case let .onchain(activity):
            return activity.txType == .sent ? "-" : "+"
        }
    }

    private var activity: (timestamp: UInt64, fee: UInt64?, value: UInt64, txType: PaymentType) {
        switch item {
        case let .lightning(activity):
            return (activity.timestamp, activity.fee, activity.value, activity.txType)
        case let .onchain(activity):
            return (activity.timestamp, activity.fee, activity.value, activity.txType)
        }
    }

    private var amount: Int {
        if activity.txType == .sent {
            return Int(activity.value + (activity.fee ?? 0))
        } else {
            return Int(activity.value)
        }
    }

    private struct InfoSection: View {
        let title: String
        let content: String
        @EnvironmentObject var app: AppViewModel

        var body: some View {
            Button {
                UIPasteboard.general.string = content
                app.toast(type: .success, title: t("common__copied"), description: content)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(title)
                        .textCase(.uppercase)
                        .padding(.bottom, 8)
                    BodySSBText(content)
                        .padding(.bottom, 16)

                    Divider()
                        .padding(.bottom, 16)
                }
            }
            .buttonStyle(.plain)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("wallet__activity_bitcoin_received"))
                .padding(.bottom, 16)

            HStack(alignment: .bottom) {
                MoneyStack(sats: amount, prefix: amountPrefix, showSymbol: false)
                Spacer()
                ActivityIcon(activity: item, size: 48)
            }
            .padding(.bottom, 16)

            if let onchain {
                InfoSection(
                    title: t("wallet__activity_tx_id"),
                    content: onchain.txId,
                )

                if let txDetails {
                    CaptionText("Inputs (\(txDetails.vin.count))")
                        .textCase(.uppercase)
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(txDetails.vin.enumerated()), id: \.offset) { _, input in
                            let txId = input.txid ?? ""
                            let vout = input.vout ?? 0
                            BodySSBText("\(txId):\(vout)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Divider()
                        .padding(.vertical, 16)

                    CaptionText("OUTPUTS (\(txDetails.vout.count))")
                        .textCase(.uppercase)
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(txDetails.vout.enumerated()), id: \.offset) { _, output in
                            BodySSBText(output.scriptpubkey_address ?? "")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.bottom, 16)
                }

                Divider()
                    .padding(.bottom, 16)
            } else if let lightning {
                if let preimage = lightning.preimage {
                    InfoSection(
                        title: t("wallet__activity_preimage"),
                        content: preimage,
                    )
                }

                if let paymentHash {
                    InfoSection(
                        title: t("wallet__activity_payment_hash"),
                        content: paymentHash,
                    )
                }

                InfoSection(
                    title: t("wallet__activity_invoice"),
                    content: lightning.invoice,
                )
            }

            Spacer()

            if onchain != nil {
                CustomButton(title: t("wallet__activity_explorer"), shouldExpand: true) {
                    if let onchain,
                       let url = getBlockExplorerUrl(txId: onchain.txId)
                    {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            if onchain != nil {
                await loadTransactionDetails()
            }
        }
    }
}

struct ActivityExplorer_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ActivityExplorerView(
                item: .lightning(
                    LightningActivity(
                        id: "test-lightning-1",
                        txType: .received,
                        status: .succeeded,
                        value: 50000,
                        fee: 1,
                        invoice:
                        "lnbc500n1p3hk3hgpp5ygx8cnfds9x49rp2mwxhcqpvdp4xys5pcxg95tyc2mrqz8dskvvsdq5g9kxy7fqd9h8vmmfvdjscqzpgxqyz5vqsp5usyc4l9c2y2funvqp0gsq3u7yws2h0pjkm984dlv6rvhtevk4ms9qyyssqzpvy9gyzjc0xsmp9gk4w2rlp3ezs5f3k2cxqzfmjh8mcst8zps4stu8qf0egyn7vgx8k9dvrbr7znlkc9s67x8j88t0y4mu5m7c4kcpj8wcr3",
                        message: "Test payment",
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        preimage: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
            .previewDisplayName("Lightning Payment")

            ActivityExplorerView(
                item: .onchain(
                    OnchainActivity(
                        id: "test-onchain-1",
                        txType: .received,
                        txId: "9c60a69005cbdb7323f8f0551d5c6f79a8c9c27c32475e4a0ad4a47d305c629d",
                        value: 100_000,
                        fee: 500,
                        feeRate: 8,
                        address: "bcrt1q3mwmz23he496...7jzn2kwhqyxa",
                        confirmed: true,
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        isBoosted: false,
                        isTransfer: false,
                        doesExist: true,
                        confirmTimestamp: nil,
                        channelId: nil,
                        transferTxId: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
            .previewDisplayName("Onchain Payment")
        }
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
    }
}
