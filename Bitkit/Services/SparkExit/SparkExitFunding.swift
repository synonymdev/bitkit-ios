import BitkitCore
import BreezSdkSpark
import CryptoKit
import Foundation
import LDKNode

/// The key that pays a Spark exit's CPFP fees. It derives from the wallet seed on an account no wallet of Bitkit's
/// derives, so ldk-node never spends the funding UTXO or the CPFP change chained back to it.
enum SparkExitFundingKey {
    static let account: UInt32 = 7797

    struct Derived {
        let address: String
        /// Compressed public key, hex, as `CpfpInput.p2wpkh` takes it.
        let pubkey: String
        let secretKey: Data
    }

    enum KeyError: Error, Equatable {
        case invalidWif
    }

    static func path(index: UInt32, network: BitkitCore.Network) -> String {
        let coin = network == .bitcoin ? 0 : 1
        return "m/84'/\(coin)'/\(account)'/0/\(index)"
    }

    static func derive(index: UInt32, mnemonic: String, passphrase: String?, network: BitkitCore.Network) throws -> Derived {
        let path = path(index: index, network: network)
        let address = try deriveBitcoinAddress(mnemonicPhrase: mnemonic, derivationPathStr: path, network: network, bip39Passphrase: passphrase)
        let wif = try derivePrivateKey(mnemonicPhrase: mnemonic, derivationPathStr: path, network: network, bip39Passphrase: passphrase)
        return try Derived(address: address.address, pubkey: address.publicKey, secretKey: secretKey(fromWif: wif))
    }

    /// The 32-byte secret of a compressed-key WIF: base58check, version byte first, `0x01` compression flag last.
    static func secretKey(fromWif wif: String) throws -> Data {
        guard let decoded = Base58.decode(wif), decoded.count == 38 else { throw KeyError.invalidWif }
        let payload = decoded.prefix(34)
        let checksum = Data(SHA256.hash(data: Data(SHA256.hash(data: payload)))).prefix(4)
        guard Data(decoded.suffix(4)) == checksum, decoded[decoded.startIndex + 33] == 0x01 else { throw KeyError.invalidWif }
        return Data(payload.dropFirst().prefix(32))
    }
}

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func decode(_ string: String) -> Data? {
        var bytes: [UInt8] = []
        for character in string {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for i in bytes.indices.reversed() {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let leadingZeros = string.prefix { $0 == "1" }.count
        return Data(repeating: 0, count: leadingZeros) + Data(bytes)
    }
}

/// What an exit costs and returns, from a `prepareRecoverFunds` quote.
struct SparkExitQuote: Equatable {
    let prepared: PrepareRecoverFundsResponse

    /// The value of the leaves the exit takes on-chain.
    var exitSats: UInt64 {
        prepared.recoverableValueSats
    }

    var networkFeeSats: UInt64 {
        prepared.totalFeeSats
    }

    /// What savings gains overall: the exited value less every fee, those paid from the fee funding included.
    var receiveSats: UInt64 {
        exitSats.saturatingSub(networkFeeSats)
    }

    /// The on-chain payment that funds the CPFP fees, or 0 when every leaf is recovered cooperatively.
    var fundingSats: UInt64 {
        prepared.funding?.singleUtxoSats ?? 0
    }

    /// What the sweep and the cooperative recoveries pay to savings: `receiveSats` plus the fee funding the exit
    /// did not spend, which the sweep returns.
    var incomingSats: UInt64 {
        receiveSats + fundingSats
    }

    var leftBehindSats: UInt64 {
        prepared.skipped.reduce(0) { $0 + $1.valueSats }
    }

    var leafIds: [String] {
        prepared.leaves.map(\.leafId)
    }

    /// Breez's rule: only exit when the value is more than its fees.
    var isWorthExiting: Bool {
        !prepared.leaves.isEmpty && exitSats > networkFeeSats
    }
}

enum SparkExitMath {
    /// The countdown target: the latest block at which a timelocked step of the exit can confirm.
    static func claimableAtHeight(_ recovery: RecoverFundsResponse) -> UInt32? {
        recovery.transactions.compactMap { tx -> UInt32? in
            if case let .waitingForTimelock(height) = tx.status {
                return height
            }
            return nil
        }.max()
    }

    /// The steps already in a block, for progress.
    static func confirmedCount(_ recovery: RecoverFundsResponse) -> Int {
        recovery.transactions.filter {
            if case .confirmed = $0.status {
                return true
            }
            return false
        }.count
    }

    /// A confirmed UTXO at the funding address that covers `requiredSats`, the largest first.
    static func fundingUtxo(_ utxos: [EsploraUtxo], requiredSats: UInt64) -> EsploraUtxo? {
        utxos.filter { $0.status.confirmed && $0.value >= requiredSats }.max { $0.value < $1.value }
    }

    /// About how long until `height`: 10-minute blocks, and Spark's regtest mines one every ~30 seconds.
    static func secondsUntil(height: UInt32, tip: UInt32, network: LDKNode.Network) -> TimeInterval {
        let blockSeconds: TimeInterval = network == .regtest ? 30 : 600
        return TimeInterval(BlockTimeHelpers.blocksRemaining(until: height, currentHeight: tip)) * blockSeconds
    }

    /// When to remind the user to open Bitkit while steps wait to be published: well inside the ~50 blocks after
    /// which the operators may publish their own version of a matured step.
    static func reminderSeconds(network: LDKNode.Network) -> TimeInterval {
        network == .regtest ? 10 * 60 : 4 * 60 * 60
    }

    /// Savings can pay the fee funding when its spendable balance covers the funding and the payment's own fee.
    static func canFundFromSavings(spendableSats: UInt64, fundingSats: UInt64, paymentFeeSats: UInt64) -> Bool {
        fundingSats > 0 && spendableSats >= fundingSats.saturatingAdd(paymentFeeSats)
    }
}
