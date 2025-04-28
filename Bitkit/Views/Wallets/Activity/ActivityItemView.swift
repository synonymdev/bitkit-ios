//
//  ActivityItemView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

struct ActivityItemView: View {
    let item: Activity
    @EnvironmentObject var currency: CurrencyViewModel

    private var isSent: Bool {
        switch item {
        case .lightning(let activity):
            return activity.txType == .sent
        case .onchain(let activity):
            return activity.txType == .sent
        }
    }

    private var isLightning: Bool {
        switch item {
        case .lightning:
            return true
        case .onchain:
            return false
        }
    }

    private var amountPrefix: String {
        isSent ? "-" : "+"
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private var activity: (timestamp: UInt64, fee: UInt64?, value: UInt64) {
        switch item {
        case .lightning(let activity):
            return (activity.timestamp, activity.fee, activity.value)
        case .onchain(let activity):
            return (activity.timestamp, activity.fee, activity.value)
        }
    }

    private var accentColor: Color {
        isLightning ? .purpleAccent : .brandAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                amountView
                Spacer()
                activityTypeIcon
            }
            .padding(.vertical)

            statusSection
            timestampSection
            feeSection
            tagsSection
            note
            buttons

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case .lightning(let activity):
            BalanceHeaderView(sats: Int(activity.value), sign: amountPrefix, showBitcoinSymbol: false)
        case .onchain(let activity):
            BalanceHeaderView(sats: Int(activity.value), sign: amountPrefix, showBitcoinSymbol: false)
        }
    }

    @ViewBuilder
    private var activityTypeIcon: some View {
        ActivityIcon(activity: item, size: 48)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionText(localizedString("wallet__activity_status"))
                .textCase(.uppercase)
                .padding(.bottom, 8)

            HStack(spacing: 4) {
                switch item {
                case .lightning(let activity):
                    switch activity.status {
                    case .pending:
                        Image("hourglass-simple")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(localizedString("wallet__activity_pending"), textColor: .purpleAccent)
                    case .succeeded:
                        Image("bolt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(localizedString("wallet__activity_successful"), textColor: .purpleAccent)
                    case .failed:
                        Image("x-circle")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(localizedString("wallet__activity_failed"), textColor: .purpleAccent)
                    }
                case .onchain(let activity):
                    if activity.confirmed == true {
                        Image("check-circle")
                            .foregroundColor(.greenAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(localizedString("wallet__activity_confirmed"), textColor: .greenAccent)
                    } else {
                        Image("hourglass-simple")
                            .foregroundColor(.brandAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(localizedString("wallet__activity_confirming"), textColor: .brandAccent)
                    }
                }
            }
            .padding(.bottom, 16)

            Divider()
        }
    }

    @ViewBuilder
    private var timestampSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(localizedString("wallet__activity_date"))
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                HStack(spacing: 4) {
                    Image("calendar")
                        .foregroundColor(accentColor)
                        .frame(width: 16, height: 16)
                    BodySSBText(dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(activity.timestamp))))
                }
                .padding(.bottom, 16)

                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                CaptionText(localizedString("wallet__activity_time"))
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                HStack(spacing: 4) {
                    Image("clock")
                        .foregroundColor(accentColor)
                        .frame(width: 16, height: 16)
                    BodySSBText(timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(activity.timestamp))))
                }
                .padding(.bottom, 16)

                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var feeSection: some View {
        if isSent {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(localizedString("wallet__activity_payment"))
                        .textCase(.uppercase)
                        .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        Image("user")
                            .foregroundColor(accentColor)
                            .frame(width: 16, height: 16)
                        BodySSBText("\(activity.value)")
                    }
                    .padding(.bottom, 16)

                    Divider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let fee = activity.fee {
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionText(localizedString("wallet__activity_fee"))
                            .textCase(.uppercase)
                            .padding(.bottom, 8)

                        HStack(spacing: 4) {
                            Image("timer")
                                .foregroundColor(accentColor)
                                .frame(width: 16, height: 16)
                            BodySSBText("\(fee)")
                        }
                        .padding(.bottom, 16)

                        Divider()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionText(localizedString("wallet__tags"))
                .textCase(.uppercase)
                .padding(.bottom, 8)

            HStack(spacing: 4) {
                // TODO: get actual tags
                Tag("test1", onDelete: {})
                Tag("test2", onDelete: {})
                Tag("test3", onDelete: {})
            }
            .padding(.bottom, 16)

            Divider()
        }
    }

    @ViewBuilder
    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionText(localizedString("wallet__activity_invoice_note"))
                .textCase(.uppercase)
                .padding(.bottom, 8)

            if case .lightning(let activity) = item {
                if !activity.message.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ZigzagDivider()

                        TitleText(activity.message, textColor: .primary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        // TODO: add button actions
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                CustomButton(
                    title: localizedString("wallet__activity_assign"), size: .small,
                    icon: Image("user-plus")
                        .foregroundColor(accentColor),
                    shouldExpand: true)

                CustomButton(
                    title: localizedString("wallet__activity_tag"), size: .small,
                    icon: Image("tag")
                        .foregroundColor(accentColor),
                    shouldExpand: true)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 16) {
                CustomButton(
                    title: localizedString("wallet__activity_boost"), size: .small,
                    icon: Image("timer-alt")
                        .foregroundColor(accentColor),
                    shouldExpand: true)

                CustomButton(
                    title: localizedString("wallet__activity_explore"), size: .small,
                    icon: Image("branch")
                        .foregroundColor(accentColor),
                    shouldExpand: true)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ZigzagDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width + 48
                let height: CGFloat = 12
                let zigzagWidth: CGFloat = 24

                path.move(to: CGPoint(x: 0, y: height))

                var x: CGFloat = 0
                var toggle = false

                while x < width {
                    let nextX = min(x + zigzagWidth / 2, width)
                    path.addLine(to: CGPoint(x: nextX, y: toggle ? 0 : height))

                    toggle.toggle()
                    x = nextX
                }
            }
            .fill(Color.white10)
            .offset(x: -24, y: 0)
            .clipShape(Rectangle())
        }
        .frame(height: 12)
    }
}

struct ActivityItemView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Lightning Activity Preview
            ActivityItemView(
                item: .lightning(
                    LightningActivity(
                        id: "test-lightning-1",
                        txType: .sent,
                        status: .succeeded,
                        value: 50000,
                        fee: 1,
                        invoice: "lnbc...",
                        message: "Splitting the lunch bill. Thanks for suggesting that amazing restaurant!",
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        preimage: nil,
                        createdAt: nil,
                        updatedAt: nil
                    ))
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Lightning Payment")

            // Onchain Activity Preview
            ActivityItemView(
                item: .onchain(
                    OnchainActivity(
                        id: "test-onchain-1",
                        txType: .received,
                        txId: "abc123",
                        value: 100000,
                        fee: 500,
                        feeRate: 8,
                        address: "bc1...",
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
                    ))
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Onchain Payment")
        }.preferredColorScheme(.dark)
    }
}
