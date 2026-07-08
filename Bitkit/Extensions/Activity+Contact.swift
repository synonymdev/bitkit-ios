import BitkitCore

extension Activity {
    /// bitkit-core wallet id scoping this activity (`"bitkit"` for the normal wallet, a derived
    /// id for watch-only hardware wallets — see `HwWalletId`).
    var walletId: String {
        switch self {
        case let .lightning(lightning):
            return lightning.walletId
        case let .onchain(onchain):
            return onchain.walletId
        }
    }

    /// Whether this activity belongs to a watch-only hardware wallet (not the normal Bitkit wallet).
    // TODO: Used as an interim feature gate (see ActivityItemView.isHardwareActivity). The
    // wallet-id shorthand holds only while CoreService activity mutations are default-scoped;
    // replace with a real capability check when wallet_id mutation support lands.
    var isHardwareWallet: Bool {
        walletId != WalletScope.default
    }

    func contact(in contacts: [PubkyContact]) -> PubkyContact? {
        guard let contactPublicKey else { return nil }
        return contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, contactPublicKey) })
    }

    func isReplacedSentTransaction(txIdsInBoostTxIds: Set<String>) -> Bool {
        guard case let .onchain(onchain) = self else { return false }
        return !onchain.doesExist && onchain.txType == .sent && txIdsInBoostTxIds.contains(onchain.txId)
    }

    private var contactPublicKey: String? {
        switch self {
        case let .lightning(lightning):
            return lightning.contact

        case let .onchain(onchain):
            return onchain.contact
        }
    }
}

extension [Activity] {
    /// Drop hardware-wallet on-chain rows whose tx already exists as a main-wallet activity, so a
    /// transfer shows a single (main-wallet) row in the merged home / All Activity lists. The HW row
    /// still appears on the hardware wallet detail screen (which fetches scoped to the device).
    func withoutHardwareDuplicates() -> [Activity] {
        let localTxIds = Set(compactMap { activity -> String? in
            guard !activity.isHardwareWallet, case let .onchain(onchain) = activity else { return nil }
            return onchain.txId
        })
        return filter { activity in
            guard activity.isHardwareWallet, case let .onchain(onchain) = activity else { return true }
            return !localTxIds.contains(onchain.txId)
        }
    }
}
