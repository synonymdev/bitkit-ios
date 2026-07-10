import BitkitCore
import LDKNode

/// The default address type funds are sourced from when transferring from a hardware wallet to
/// spending. v1 funds from the native-segwit account only; multi-address-type spend is out of scope.
let hwFundingDefaultAddressType: AddressScriptType = .nativeSegwit

/// A paired hardware wallet's account used to fund a transfer, resolved from the stored account
/// xpub and the watch-only balance for that address type.
struct HwFundingAccount: Equatable {
    let xpub: String
    let addressType: AddressScriptType
    let balanceSats: UInt64

    /// bitkit-core account type for composing/watching this account.
    var accountType: AccountType {
        addressType.accountType
    }
}

/// A composed (but not yet signed) hardware-wallet funding payment, produced before prompting for
/// the on-device signature so exact fees are known up front.
struct HwFundingTransaction: Equatable {
    /// Base64-encoded PSBT ready for on-device signing.
    let psbt: String
    let miningFeeSats: UInt64
    let feeRate: Float
    /// Total value spent (payment + fee, excluding change), from the composer.
    let totalSpent: UInt64
    let satsPerVByte: UInt64
}

/// A signed (but not yet broadcast) hardware-wallet funding payment. Carries the fee metadata from
/// the composed payment so the broadcast result can be built without re-reading it.
struct HwFundingSignedTx: Equatable {
    /// Signed raw transaction hex, ready to broadcast.
    let serializedTx: String
    let miningFeeSats: UInt64
    let feeRate: Float
    let totalSpent: UInt64
    let txId: String

    init(
        serializedTx: String,
        miningFeeSats: UInt64,
        feeRate: Float,
        totalSpent: UInt64,
        txId: String = "txid"
    ) {
        self.serializedTx = serializedTx
        self.miningFeeSats = miningFeeSats
        self.feeRate = feeRate
        self.totalSpent = totalSpent
        self.txId = txId
    }
}

/// The result of signing a composed funding payment on the device and broadcasting it.
struct HwFundingBroadcastResult: Equatable {
    let txId: String
    let miningFeeSats: UInt64
    let feeRate: UInt64
    let totalSpent: UInt64
}
