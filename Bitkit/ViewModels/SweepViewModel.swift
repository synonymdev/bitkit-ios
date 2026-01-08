import BitkitCore
import Foundation
import SwiftUI

/// Manages sweep transaction state and operations
@MainActor
class SweepViewModel: ObservableObject {
    // MARK: - Published State

    /// Current state of the sweep check
    @Published var checkState: CheckState = .idle

    /// Sweepable balances from external wallets
    @Published var sweepableBalances: SweepableBalances?

    /// Transaction preview after preparation
    @Published var transactionPreview: SweepTransactionPreview?

    /// Selected fee rate in sats/vbyte
    @Published var selectedFeeRate: UInt32 = 1

    /// Available fee rates
    @Published var feeRates: FeeRates?

    /// Selected transaction speed
    @Published var selectedSpeed: TransactionSpeed = .normal

    /// Error message to display
    @Published var errorMessage: String?

    /// Result after broadcast
    @Published var sweepResult: SweepResult?

    /// Destination address for the sweep
    @Published var destinationAddress: String?

    /// Whether a transaction is currently being prepared
    @Published var isPreparingTransaction = false

    // MARK: - Types

    enum CheckState {
        case idle
        case checking
        case found(balance: UInt64)
        case noFunds
        case error(String)
    }

    enum SweepState {
        case idle
        case preparing
        case ready
        case broadcasting
        case success(SweepResult)
        case error(String)

        var isLoading: Bool {
            switch self {
            case .idle, .preparing:
                return true
            default:
                return false
            }
        }
    }

    @Published var sweepState: SweepState = .idle

    // MARK: - Private Properties

    private let walletIndex: Int

    // MARK: - Computed Properties

    var totalBalance: UInt64 {
        sweepableBalances?.totalBalance ?? 0
    }

    var hasBalance: Bool {
        totalBalance > 0
    }

    var estimatedFee: UInt64 {
        transactionPreview?.estimatedFee ?? 0
    }

    var amountAfterFees: UInt64 {
        transactionPreview?.amountAfterFees ?? 0
    }

    var utxosCount: UInt32 {
        sweepableBalances?.totalUtxosCount ?? 0
    }

    // MARK: - Initialization

    init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex
    }

    // MARK: - Public Methods

    /// Check for sweepable balances from external addresses
    func checkBalance() async {
        checkState = .checking
        errorMessage = nil

        do {
            let mnemonic = try getMnemonic()
            let passphrase = try getPassphrase()
            let electrumUrl = Self.getElectrumUrl()
            let network = Env.bitkitCoreNetwork

            let balances = try await BitkitCore.checkSweepableBalances(
                mnemonicPhrase: mnemonic,
                network: network,
                bip39Passphrase: passphrase,
                electrumUrl: electrumUrl
            )

            sweepableBalances = balances

            if balances.totalBalance > 0 {
                checkState = .found(balance: balances.totalBalance)
            } else {
                checkState = .noFunds
            }
        } catch {
            Logger.error("Failed to check sweepable balance: \(error)", context: "SweepViewModel")
            checkState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Prepare the sweep transaction
    func prepareSweep(destinationAddress: String) async {
        self.destinationAddress = destinationAddress
        sweepState = .preparing
        isPreparingTransaction = true
        errorMessage = nil

        do {
            let mnemonic = try getMnemonic()
            let passphrase = try getPassphrase()
            let electrumUrl = Self.getElectrumUrl()
            let network = Env.bitkitCoreNetwork

            let preview = try await BitkitCore.prepareSweepTransaction(
                mnemonicPhrase: mnemonic,
                network: network,
                bip39Passphrase: passphrase,
                electrumUrl: electrumUrl,
                destinationAddress: destinationAddress,
                feeRateSatsPerVbyte: selectedFeeRate
            )

            transactionPreview = preview
            sweepState = .ready
        } catch {
            Logger.error("Failed to prepare sweep: \(error)", context: "SweepViewModel")
            sweepState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }

        isPreparingTransaction = false
    }

    /// Broadcast the sweep transaction
    func broadcastSweep() async {
        guard let preview = transactionPreview else {
            sweepState = .error("No transaction prepared")
            return
        }

        sweepState = .broadcasting
        errorMessage = nil

        do {
            let mnemonic = try getMnemonic()
            let passphrase = try getPassphrase()
            let electrumUrl = Self.getElectrumUrl()
            let network = Env.bitkitCoreNetwork

            let result = try await BitkitCore.broadcastSweepTransaction(
                psbt: preview.psbt,
                mnemonicPhrase: mnemonic,
                network: network,
                bip39Passphrase: passphrase,
                electrumUrl: electrumUrl
            )

            sweepResult = result
            sweepState = .success(result)
        } catch {
            Logger.error("Failed to broadcast sweep: \(error)", context: "SweepViewModel")
            sweepState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Set fee rate based on selected speed
    func setFeeRate(speed: TransactionSpeed) async {
        selectedSpeed = speed

        switch speed {
        case let .custom(rate):
            selectedFeeRate = rate
        default:
            if let rates = feeRates {
                selectedFeeRate = speed.getFeeRate(from: rates)
            }
        }
    }

    /// Load current fee estimates
    func loadFeeEstimates() async throws {
        var rates = try? await CoreService.shared.blocktank.fees(refresh: true)

        if rates == nil {
            Logger.warn("Failed to fetch fresh fee rate, using cached rate.", context: "SweepViewModel")
            rates = try await CoreService.shared.blocktank.fees(refresh: false)
        }

        guard let rates else {
            throw AppError(message: "Fee rates unavailable", debugMessage: nil)
        }

        feeRates = rates
        selectedFeeRate = selectedSpeed.getFeeRate(from: rates)
    }

    /// Reset the view model state
    func reset() {
        checkState = .idle
        sweepState = .idle
        isPreparingTransaction = false
        sweepableBalances = nil
        transactionPreview = nil
        sweepResult = nil
        errorMessage = nil
        selectedFeeRate = 1
        selectedSpeed = .normal
        destinationAddress = nil
    }

    // MARK: - Private Methods

    private func getMnemonic() throws -> String {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw NSError(
                domain: "SweepViewModel",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Mnemonic not found"]
            )
        }
        return mnemonic
    }

    private func getPassphrase() throws -> String? {
        try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
    }

    private static func getElectrumUrl() -> String {
        let configService = ElectrumConfigService()
        let server = configService.getCurrentServer()
        return server.fullUrl.isEmpty ? Env.electrumServerUrl : server.fullUrl
    }

    // MARK: - Static Methods

    /// Check for sweepable funds after migration and return true if funds were found
    static func checkForSweepableFundsAfterMigration(walletIndex: Int = 0) async -> Bool {
        do {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
                Logger.debug("No mnemonic found for sweep check", context: "SweepViewModel")
                return false
            }

            let passphrase = try? Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
            let electrumUrl = Self.getElectrumUrl()
            let network = Env.bitkitCoreNetwork

            let balances = try await BitkitCore.checkSweepableBalances(
                mnemonicPhrase: mnemonic,
                network: network,
                bip39Passphrase: passphrase,
                electrumUrl: electrumUrl
            )

            if balances.totalBalance > 0 {
                Logger.info("Found \(balances.totalBalance) sats to sweep after migration", context: "SweepViewModel")
                return true
            }

            Logger.debug("No sweepable funds found after migration", context: "SweepViewModel")
            return false
        } catch {
            Logger.error("Failed to check sweepable funds after migration: \(error)", context: "SweepViewModel")
            return false
        }
    }
}
