import BitkitCore
import Foundation

/// Saves a hardware on-chain send as the user's payment: its tags and contact, and a Sent activity once it may show as sent.
enum HwSendRecord {
    static func save(
        _ result: HwFundingBroadcastResult,
        walletId: String,
        address: String,
        amount: UInt64,
        contactPublicKey: String?,
        tags: [String],
        requestId: PaykitPaymentRequest.ID?,
        proofVerified: Bool
    ) async {
        let metadata = PreActivityMetadata(
            walletId: walletId,
            paymentId: result.txId,
            tags: tags,
            paymentHash: nil,
            txId: result.txId,
            address: address,
            isReceive: false,
            feeRate: result.feeRate,
            isTransfer: false,
            channelId: nil,
            createdAt: UInt64(Date().timeIntervalSince1970)
        )
        try? await CoreService.shared.activity.addPreActivityMetadata(metadata)

        // Retain original metadata for an eventual exact observation. A Shop payment's
        // local Core txid alone must not create a Sent row.
        guard requestId == nil || proofVerified else { return }
        await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
            txid: result.txId,
            address: address,
            amount: amount,
            fee: result.miningFeeSats,
            feeRate: UInt32(clamping: result.feeRate),
            contact: contactPublicKey,
            walletId: walletId
        )
        if !tags.isEmpty {
            try? await CoreService.shared.activity.appendTags(
                toActivity: result.txId,
                tags,
                walletId: walletId
            )
        }

        Logger.info("Hardware onchain send result txid: \(result.txId)")
    }

    /// Records a held send the wallet has seen, with the tags and contact it was held with.
    static func saveSeen(_ held: HwHeldBroadcast) async {
        guard let result = held.result else { return }
        await save(
            result, walletId: held.walletId, address: held.address, amount: held.amountSats,
            contactPublicKey: held.contactPublicKey, tags: held.tags ?? [], requestId: nil, proofVerified: true
        )
    }
}
