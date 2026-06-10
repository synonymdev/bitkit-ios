import BitkitCore
import Foundation
import LDKNode
import SwiftUI

/// View model for loading channel details and finding their linked Blocktank orders
@MainActor
class ChannelDetailsViewModel: ObservableObject {
    static let shared = ChannelDetailsViewModel()

    @Published var foundChannel: ChannelDisplayable? = nil
    @Published var linkedOrder: IBtOrder? = nil
    @Published var isLoading = false
    @Published var error: Error? = nil

    private let coreService: CoreService
    private let transferStorage: TransferStorage

    /// Private initializer for the singleton instance
    private init(coreService: CoreService = .shared, transferStorage: TransferStorage = .shared) {
        self.coreService = coreService
        self.transferStorage = transferStorage
    }

    // MARK: - Display values

    /// Whether `linkedOrder` confidently belongs to `foundChannel`, i.e. it was matched by a
    /// channel-unique key (funding transaction, user channel id, or short channel id) rather than
    /// the loose counterparty-pubkey fallback in `findLinkedOrder`. Only then is it safe to borrow
    /// the order's short channel id, which could otherwise belong to another channel the user has
    /// open with the same LSP.
    private var isLinkedOrderConfident: Bool {
        guard let order = linkedOrder, let channel = foundChannel else { return false }

        if let fundingTxid = channel.displayedFundingTxoTxid, !fundingTxid.isEmpty,
           order.channel?.fundingTx.id == fundingTxid
        {
            return true
        }

        if let openChannel = channel as? ChannelDetails {
            if order.id == openChannel.userChannelId {
                return true
            }
            if let scid = openChannel.shortChannelId, order.channel?.shortChannelId == String(scid) {
                return true
            }
        }

        return false
    }

    /// Funding outpoint for display, taken from the channel's own LDK or stored values.
    /// A single source so the funding txid and channel point always agree.
    private var fundingOutpoint: (txid: String, vout: UInt64)? {
        guard let txid = foundChannel?.displayedFundingTxoTxid, !txid.isEmpty,
              let vout = foundChannel?.fundingTxoVout
        else {
            return nil
        }
        return (txid, UInt64(vout))
    }

    /// Funding transaction id (`funding_txid`) for display.
    var displayFundingTxid: String? {
        fundingOutpoint?.txid
    }

    /// Funding outpoint (`funding_txid:vout`) for display.
    var displayChannelPoint: String? {
        guard let outpoint = fundingOutpoint else { return nil }
        return "\(outpoint.txid):\(outpoint.vout)"
    }

    /// Short channel id for display, formatted as `block x tx x output`. Uses the channel's own
    /// scid (open channels) and, for closed channels (which are not stored with one), the scid from
    /// a confidently linked Blocktank order. Hidden otherwise rather than showing a guessed value.
    var displayShortChannelId: String? {
        let linkedOrderScid = isLinkedOrderConfident ? linkedOrder?.channel?.shortChannelId : nil
        return resolveDisplayShortChannelId(channelScid: foundChannel?.shortChannelIdValue, linkedOrderScid: linkedOrderScid)
    }

    /// Find a channel by ID, checking open channels, pending channels, pending orders, then closed channels
    func findChannel(channelId: String, wallet: WalletViewModel) async {
        // Clear any previously found channel and order to avoid returning stale data
        foundChannel = nil
        linkedOrder = nil
        isLoading = true
        error = nil

        guard !channelId.isEmpty else {
            isLoading = false
            return
        }

        // First check if channel is already in open channels
        if let channels = wallet.channels,
           let openChannel = channels.first(where: { $0.channelId.description == channelId })
        {
            foundChannel = openChannel
            linkedOrder = await findLinkedOrder(for: openChannel)
            isLoading = false
            return
        }

        // Check pending connections (pending channels + fake channels from pending orders)
        let pending = await pendingConnections(wallet: wallet)
        if let pendingChannel = pending.first(where: { $0.channelId.description == channelId }) {
            foundChannel = pendingChannel
            linkedOrder = await findLinkedOrder(for: pendingChannel)
            isLoading = false
            return
        }

        // Load closed channels if not found in open, pending channels, or pending orders
        do {
            let closedChannels = try await coreService.activity.closedChannels()
            if let closedChannel = closedChannels.first(where: { $0.channelId == channelId }) {
                foundChannel = closedChannel
                linkedOrder = await findLinkedOrder(for: closedChannel)
            } else {
                foundChannel = nil
                linkedOrder = nil
            }
        } catch {
            Logger.warn("Failed to load closed channels: \(error)")
            self.error = error
            foundChannel = nil
            linkedOrder = nil
        }

        isLoading = false
    }

    /// Find the linked Blocktank order for a channel (works for both open and closed channels)
    func findLinkedOrder(for channel: ChannelDisplayable) async -> IBtOrder? {
        guard let orders = try? await coreService.blocktank.orders(refresh: false) else { return nil }

        // For open channels, try matching by userChannelId first (which is set to order.id for Blocktank orders)
        if let openChannel = channel as? ChannelDetails {
            if let order = orders.first(where: { $0.id == openChannel.userChannelId }) {
                return order
            }

            // Match by short channel ID (only available for open channels)
            if let shortChannelId = openChannel.shortChannelId {
                let shortChannelIdString = String(shortChannelId)
                if let order = orders.first(where: { order in
                    order.channel?.shortChannelId == shortChannelIdString
                }) {
                    return order
                }
            }
        }

        // Match by funding transaction (works for both open and closed channels)
        if let fundingTxId = channel.displayedFundingTxoTxid {
            if let order = orders.first(where: { order in
                order.channel?.fundingTx.id == fundingTxId
            }) {
                return order
            }
        }

        // Match by counterparty node ID (less reliable, could match multiple)
        let counterpartyNodeIdString = channel.counterpartyNodeIdString
        if let order = orders.first(where: { order in
            guard let orderChannel = order.channel else { return false }
            return orderChannel.clientNodePubkey == counterpartyNodeIdString ||
                orderChannel.lspNodePubkey == counterpartyNodeIdString
        }) {
            return order
        }

        return nil
    }

    /// Get pending connections (pending channels + fake channels from pending orders)
    func pendingConnections(wallet: WalletViewModel) async -> [ChannelDetails] {
        var connections: [ChannelDetails] = []

        // Add actual pending channels
        if let channels = wallet.channels {
            connections.append(contentsOf: channels.filter { !$0.isChannelReady })
        }

        // Only show pending orders that have been paid (aligns with Android/RN behavior)
        let paidOrderIds: Set<String> = {
            guard let activeTransfers = try? transferStorage.getActiveTransfers() else {
                return []
            }
            return Set(
                activeTransfers
                    .filter { $0.type.isToSpending() }
                    .compactMap(\.lspOrderId)
            )
        }()

        if paidOrderIds.isEmpty {
            return connections
        }

        // Create fake channels from pending orders
        guard let orders = try? await coreService.blocktank.orders(refresh: true) else {
            return connections
        }

        let pendingOrders = Self.pendingOrders(
            orders: orders,
            paidOrderIds: paidOrderIds
        )

        for order in pendingOrders {
            let fakeChannel = createFakeChannel(from: order)
            connections.append(fakeChannel)
        }

        return connections
    }

    static func pendingOrders(orders: [IBtOrder], paidOrderIds: Set<String>) -> [IBtOrder] {
        orders.filter { order in
            paidOrderIds.contains(order.id) && (order.state2 == .created || order.state2 == .paid)
        }
    }

    /// Creates a fake channel from a Blocktank order for UI display purposes
    private func createFakeChannel(from order: IBtOrder) -> ChannelDetails {
        return ChannelDetails(
            channelId: order.id,
            counterpartyNodeId: order.lspNode?.pubkey ?? "",
            fundingTxo: OutPoint(txid: Txid(order.channel?.fundingTx.id ?? ""), vout: UInt32(order.channel?.fundingTx.vout ?? 0)),
            shortChannelId: order.channel?.shortChannelId.flatMap(UInt64.init),
            outboundScidAlias: nil,
            inboundScidAlias: nil,
            channelValueSats: order.lspBalanceSat + order.clientBalanceSat,
            unspendablePunishmentReserve: 1000,
            userChannelId: order.id,
            feerateSatPer1000Weight: 2500,
            outboundCapacityMsat: order.clientBalanceSat * 1000,
            inboundCapacityMsat: order.lspBalanceSat * 1000,
            confirmationsRequired: nil,
            confirmations: 0,
            isOutbound: false,
            isChannelReady: false,
            isUsable: false,
            isAnnounced: false,
            cltvExpiryDelta: 144,
            counterpartyUnspendablePunishmentReserve: 1000,
            counterpartyOutboundHtlcMinimumMsat: 1000,
            counterpartyOutboundHtlcMaximumMsat: 99_000_000,
            counterpartyForwardingInfoFeeBaseMsat: 1000,
            counterpartyForwardingInfoFeeProportionalMillionths: 100,
            counterpartyForwardingInfoCltvExpiryDelta: 144,
            nextOutboundHtlcLimitMsat: order.clientBalanceSat * 1000,
            nextOutboundHtlcMinimumMsat: 1000,
            forceCloseSpendDelay: nil,
            inboundHtlcMinimumMsat: 1000,
            inboundHtlcMaximumMsat: order.lspBalanceSat * 1000,
            config: .init(
                forwardingFeeProportionalMillionths: 0,
                forwardingFeeBaseMsat: 0,
                cltvExpiryDelta: 0,
                maxDustHtlcExposure: .feeRateMultiplier(multiplier: 0),
                forceCloseAvoidanceMaxFeeSatoshis: 0,
                acceptUnderpayingHtlcs: true
            ),
            claimableOnCloseSats: order.lspBalanceSat + order.clientBalanceSat
        )
    }
}
