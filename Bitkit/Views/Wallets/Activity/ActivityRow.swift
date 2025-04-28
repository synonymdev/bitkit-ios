//
//  ActivityRow.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

private struct AmountDisplayView: View {
    let converted: ConvertedAmount
    let prefix: String
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if currency.primaryDisplay == .bitcoin {
                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                HStack(spacing: 1) {
                    BodyMSBText(prefix, textColor: .textSecondary)
                    BodyMSBText(btcComponents.value)
                }

                CaptionBText("\(converted.symbol) \(converted.formatted)")
            } else {
                HStack(spacing: 1) {
                    BodyMSBText(prefix, textColor: .textSecondary)
                    BodyMSBText(converted.symbol, textColor: .textSecondary)
                    BodyMSBText(" \(converted.formatted)")
                }

                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                CaptionBText(btcComponents.value)
            }
        }
    }
}

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

        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar.current

        // Check if the activity is from today
        if calendar.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            return timeFormatter.string(from: date)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            return dateFormatter.string(from: date)
        }
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
            if let converted = currency.convert(sats: UInt64(activity.value)) {
                AmountDisplayView(converted: converted, prefix: amountPrefix)
            }
        case .onchain(let activity):
            if let converted = currency.convert(sats: UInt64(activity.value)) {
                AmountDisplayView(converted: converted, prefix: amountPrefix)
            }
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
                case .onchain(let activity):
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
