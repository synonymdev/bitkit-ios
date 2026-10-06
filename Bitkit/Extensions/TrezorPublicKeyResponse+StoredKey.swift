import BitkitCore

extension TrezorPublicKeyResponse {
    /// Account key to persist on a known device for `addressType`.
    ///
    /// Since bitkit-core 0.7.0 `xpub` is always a normalized `xpub`/`tpub`, while known devices
    /// paired on earlier versions stored the firmware's SLIP-132 form (`ypub`/`zpub`/`upub`/`vpub`)
    /// for BIP-49/BIP-84. Those strings feed `walletKey`, entry matching and `deriveWalletId`, so
    /// they must stay byte-identical: SegWit types keep `xpubSegwit`, Legacy and Taproot keep `xpub`
    /// (Taproot `xpubSegwit` can be a descriptor). See bitkit-core `src/modules/trezor/README.md`,
    /// "Migrating to trezor-connect-rs 10.0.0 (Core 0.7.0)".
    func storedAccountKey(for addressType: AddressScriptType) -> String {
        switch addressType {
        case .nestedSegwit, .nativeSegwit:
            return xpubSegwit ?? xpub
        case .legacy, .taproot:
            return xpub
        }
    }
}
