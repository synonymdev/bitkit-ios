//
//  ActivityRow.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

private struct TransactionStatusText: View {
    let txType: PaymentType
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?

    init(txType: PaymentType, activity: Activity) {
        self.txType = txType
        switch activity {
        case .lightning(let ln):
            self.isLightning = true
            self.status = ln.status
            self.confirmed = nil
        case .onchain(let onchain):
            self.isLightning = false
            self.status = nil
            self.confirmed = onchain.confirmed
        }
    }

    var body: some View {
        if isLightning {
            lightningStatus
        } else {
            onchainStatus
        }
    }

    @ViewBuilder
    private var lightningStatus: some View {
        if txType == .sent {
            switch status {
            case .failed:
                BodyMSBText(localizedString("wallet__activity_failed"), textColor: .textPrimary)
            case .pending:
                BodyMSBText(localizedString("wallet__activity_pending"), textColor: .textPrimary)
            case .succeeded:
                BodyMSBText(localizedString("wallet__activity_sent"), textColor: .textPrimary)
            case .none:
                EmptyView()
            }
        } else {
            switch status {
            case .failed:
                BodyMSBText(localizedString("wallet__activity_failed"), textColor: .textPrimary)
            case .pending:
                BodyMSBText(localizedString("wallet__activity_pending"), textColor: .textPrimary)
            case .succeeded:
                BodyMSBText(localizedString("wallet__activity_received"), textColor: .textPrimary)
            case .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var onchainStatus: some View {
        if txType == .sent {
            BodyMSBText(localizedString("wallet__activity_sent"), textColor: .textPrimary)
        } else {
            BodyMSBText(localizedString("wallet__activity_received"), textColor: .textPrimary)
        }
    }
}

struct ActivityRow: View {
    let item: Activity
    @EnvironmentObject var currency: CurrencyViewModel

    private var formattedTime: String {
        let timestamp: TimeInterval
        switch item {
        case .lightning(let activity):
            timestamp = TimeInterval(activity.timestamp)
        case .onchain(let activity):
            timestamp = TimeInterval(activity.timestamp)
        }

        return DateFormatterHelpers.formatActivityTime(UInt64(timestamp))
    }

    private var amountPrefix: String {
        switch item {
        case .lightning(let activity):
            return activity.txType == .sent ? "-" : "+"
        case .onchain(let activity):
            return activity.txType == .sent ? "-" : "+"
        }
    }

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case .lightning(let activity):
            MoneyCell(sats: Int(activity.value), prefix: amountPrefix)
        case .onchain(let activity):
            MoneyCell(sats: Int(activity.value), prefix: amountPrefix)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                switch item {
                case .lightning(let activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
                case .onchain(let activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
                }

                // Show message if available, otherwise show time
                switch item {
                case .lightning(let activity):
                    if !activity.message.isEmpty {
                        CaptionBText(activity.message)
                    } else {
                        CaptionBText(formattedTime)
                    }
                case .onchain(_):
                    CaptionBText(formattedTime)
                }
            }

            Spacer()
            amountView
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    var icon: some View {
        ActivityIcon(activity: item, size: 32)
    }
}
