import BitkitCore
import Combine
import Foundation
import LDKNode
import SwiftUI

struct ActivityExplorerView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    @State private var item: Activity
    @State private var txDetails: BitkitCore.TransactionDetails?
    @State private var boostTxDoesExist: [String: Bool] = [:] // Maps boostTxId -> doesExist

    init(item: Activity) {
        _item = State(initialValue: item)
    }

    private var activityId: String {
        switch item {
        case let .lightning(activity):
            return activity.id
        case let .onchain(activity):
            return activity.id
        }
    }

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
        return URL(string: "\(Env.blockExplorerUrl)/tx/\(txId)")
    }

    private func loadTransactionDetails() async {
        guard let onchain else { return }

        do {
            let details = try await CoreService.shared.activity.getTransactionDetails(txid: onchain.txId)
            await MainActor.run {
                txDetails = details
            }
        } catch {
            Logger.error("Failed to load transaction details for \(onchain.txId): \(error)", context: "ActivityExplorerView")
        }
    }

    private func loadBoostTxDoesExist() async {
        guard let onchain else { return }

        let doesExistMap = await CoreService.shared.activity.getBoostTxDoesExist(boostTxIds: onchain.boostTxIds)
        await MainActor.run {
            boostTxDoesExist = doesExistMap
        }
    }

    private func refreshActivity() async {
        do {
            if let updatedActivity = try await CoreService.shared.activity.getActivity(id: activityId) {
                await MainActor.run {
                    item = updatedActivity
                }
                if case let .onchain(onchainActivity) = updatedActivity, !onchainActivity.boostTxIds.isEmpty {
                    await loadBoostTxDoesExist()
                }
            }
        } catch {
            Logger.error(error, context: "Failed to refresh activity \(activityId) in ActivityExplorerView")
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
        let testId: String?
        @EnvironmentObject var app: AppViewModel

        init(title: String, content: String, testId: String? = nil) {
            self.title = title
            self.content = content
            self.testId = testId
        }

        var body: some View {
            Button {
                UIPasteboard.general.string = content
                app.toast(type: .success, title: t("common__copied"), description: content)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(title)
                        .padding(.bottom, 8)
                    BodySSBText(content)
                        .padding(.bottom, 16)

                    Divider()
                        .padding(.bottom, 16)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifierIfPresent(testId)
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
                    .offset(y: 5) // Align arrow with bottom of money stack
            }
            .padding(.bottom, 32)

            if let onchain {
                InfoSection(
                    title: t("wallet__activity_tx_id"),
                    content: onchain.txId,
                    testId: "TXID"
                )

                if let txDetails {
                    CaptionMText(tPlural("wallet__activity_input", arguments: ["count": txDetails.inputs.count]))
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(txDetails.inputs.enumerated()), id: \.offset) { _, input in
                            let txId = input.txid
                            let vout = Int(input.vout)
                            BodySSBText("\(txId):\(vout)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Divider()
                        .padding(.vertical, 16)

                    CaptionMText(tPlural("wallet__activity_output", arguments: ["count": txDetails.outputs.count]))
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(txDetails.outputs.indices, id: \.self) { i in
                            BodySSBText(txDetails.outputs[i].scriptpubkeyAddress ?? "")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.bottom, 16)
                }

                if !onchain.boostTxIds.isEmpty {
                    Divider()
                        .padding(.bottom, 16)
                    ForEach(Array(onchain.boostTxIds.enumerated()), id: \.offset) { index, boostTxId in
                        let isRBF = onchain.txType == .sent || !(boostTxDoesExist[boostTxId] ?? true)
                        InfoSection(
                            title: t(isRBF ? "wallet__activity_boosted_rbf" : "wallet__activity_boosted_cpfp", variables: ["num": String(index + 1)]),
                            content: boostTxId,
                            testId: isRBF ? "RBFBoosted" : "CPFPBoosted"
                        )
                    }
                }
            } else if let lightning {
                if let preimage = lightning.preimage {
                    InfoSection(
                        title: t("wallet__activity_preimage"),
                        content: preimage
                    )
                }

                if let paymentHash {
                    InfoSection(
                        title: t("wallet__activity_payment_hash"),
                        content: paymentHash
                    )
                }

                InfoSection(
                    title: t("wallet__activity_invoice"),
                    content: lightning.invoice
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
        .onReceive(CoreService.shared.activity.activitiesChangedPublisher) { _ in
            Task {
                await refreshActivity()
            }
        }
        .task {
            guard let onchain else { return }
            await loadTransactionDetails()
            if !onchain.boostTxIds.isEmpty {
                await loadBoostTxDoesExist()
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
                        updatedAt: nil,
                        seenAt: nil
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
                        boostTxIds: [],
                        isTransfer: false,
                        doesExist: true,
                        confirmTimestamp: nil,
                        channelId: nil,
                        transferTxId: nil,
                        createdAt: nil,
                        updatedAt: nil,
                        seenAt: nil
                    )
                )
            )
            .previewDisplayName("Onchain Payment")
        }
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(CurrencyViewModel())
        .preferredColorScheme(.dark)
    }
}
