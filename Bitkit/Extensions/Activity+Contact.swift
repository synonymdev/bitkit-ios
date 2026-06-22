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
