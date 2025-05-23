import Foundation
import LDKNode
import SwiftUI

struct ActivityExplorerView: View {
    let item: Activity
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @Environment(\.presentationMode) var presentationMode

    private var onchain: OnchainActivity? {
        guard case .onchain(let activity) = item else { return nil }
        return activity
    }

    private var lightning: LightningActivity? {
        guard case .lightning(let activity) = item else { return nil }
        return activity
    }

    private var paymentHash: String? {
        guard case .lightning(let activity) = item else { return nil }
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

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case .lightning(let activity):
            BalanceHeaderView(sats: Int(activity.value), sign: activity.txType == .sent ? "-" : "+", showBitcoinSymbol: false)
        case .onchain(let activity):
            BalanceHeaderView(sats: Int(activity.value), sign: activity.txType == .sent ? "-" : "+", showBitcoinSymbol: false)
        }
    }

    @ViewBuilder
    private var activityTypeIcon: some View {
        ActivityIcon(activity: item, size: 48)
    }

    private struct InfoSection: View {
        let title: String
        let content: String
        @EnvironmentObject var app: AppViewModel

        var body: some View {
            Button {
                UIPasteboard.general.string = content
                app.toast(type: .success, title: localizedString("common__copied"), description: content)
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
            HStack(alignment: .bottom) {
                amountView
                Spacer()
                activityTypeIcon
            }
            .padding(.vertical)
            .padding(.bottom, 16)

            if let onchain = onchain {
                InfoSection(
                    title: localizedString("wallet__activity_tx_id"),
                    content: onchain.txId,
                )

                InfoSection(
                    title: "INPUT",
                    content: "\(onchain.txId):0",
                )

                CaptionText("OUTPUTS (2)")
                    .textCase(.uppercase)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0 ..< 2, id: \.self) { i in
                        BodySSBText("bcrt1q...output\(i)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.bottom, 16)

                Divider()
                    .padding(.bottom, 16)
            } else if let lightning = lightning {
                if let preimage = lightning.preimage {
                    InfoSection(
                        title: localizedString("wallet__activity_preimage"),
                        content: preimage,
                    )
                }

                if let paymentHash = paymentHash {
                    InfoSection(
                        title: localizedString("wallet__activity_payment_hash"),
                        content: paymentHash,
                    )
                }

                InfoSection(
                    title: localizedString("wallet__activity_invoice"),
                    content: lightning.invoice,
                )
            }

            Spacer()

            if onchain != nil {
                CustomButton(title: "Open Block Explorer", shouldExpand: true) {
                    if let onchain = onchain,
                        let url = getBlockExplorerUrl(txId: onchain.txId)
                    {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .navigationTitle(localizedString("wallet__activity_bitcoin_received"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
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
                        value: 50_000,
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
