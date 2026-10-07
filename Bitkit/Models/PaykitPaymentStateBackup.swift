import CryptoKit
import Foundation
import Paykit

struct PaykitPaymentStateBackup: Codable {
    let subscriptions: [String: Subscription]
    let pendingProofs: [Proof]
    var activeOnchainAttempt: ActiveOnchainAttempt? = nil
    var acceptedOneTimeRequests: [String: [RequestID]]? = nil

    struct RequestID: Codable {
        let paymentRequestId: String
        let counterparty: String
        let billingPeriodStartsAt: String?

        init(_ id: PaykitPaymentRequest.ID, billingPeriod: PaykitBillingPeriod?) {
            paymentRequestId = id.paymentRequestId
            counterparty = id.counterparty
            billingPeriodStartsAt = billingPeriod?.sdkValue.startsAt ?? id.billingPeriodStartsAt.map { PaykitPreciseInstant(date: $0).timestamp }
        }

        func restored(billingPeriod: PaykitBillingPeriod?) -> PaykitPaymentRequest.ID {
            PaykitPaymentRequest.ID(
                paymentRequestId: paymentRequestId,
                counterparty: counterparty,
                billingPeriodStartsAt: billingPeriod?.startsAt
            )
        }
    }

    struct Subscription: Codable {
        struct Acceptance: Codable {
            let id: PaykitSubscription.ID
            let acceptedAt: String
        }

        let acceptances: [Acceptance]
        let presentedProposalIds: Set<PaykitSubscription.ID>

        init(_ state: PaykitSubscriptionState) {
            acceptances = state.acceptedAt.map { Acceptance(id: $0.key, acceptedAt: $0.value.timestamp) }
            presentedProposalIds = state.presentedProposalIds
        }

        func restored() throws -> PaykitSubscriptionState {
            var acceptedAt: [PaykitSubscription.ID: PaykitPreciseInstant] = [:]
            for acceptance in acceptances {
                acceptedAt[acceptance.id] = try parseTimestamp(acceptance.acceptedAt)
            }
            return PaykitSubscriptionState(
                acceptedAt: acceptedAt,
                presentedProposalIds: presentedProposalIds
            )
        }
    }

    struct Proof: Codable {
        struct Period: Codable {
            let startsAt: String
            let endsAt: String
        }

        let identity: String
        let requestId: RequestID
        let paymentAppId: String
        let paymentEndpointIdentifier: String
        let kind: PaykitPaymentProofKind
        let paymentStarted: Bool
        let paymentIdentifier: String?
        let proofData: String?
        let billingPeriod: Period?
        let onchainAddress: String?
        let onchainAmountSats: UInt64?
        let onchainWalletId: String?
        let hardwareSignedTransaction: String?
        let hardwareMiningFeeSats: UInt64?
        let hardwareFeeRate: UInt64?
        let hardwareTotalSpent: UInt64?
        let hardwareDispatchAttempted: Bool?
        let privatePaymentListVersion: UInt64?
        let onchainMatchingTransactionIdsBeforeAttempt: Set<String>
        let onchainAcceptanceVerified: Bool?

        init(_ proof: PendingPaykitPaymentProof) {
            identity = proof.identity
            requestId = RequestID(proof.requestId, billingPeriod: proof.billingPeriod)
            paymentAppId = proof.paymentAppId
            paymentEndpointIdentifier = proof.paymentEndpointIdentifier
            kind = proof.kind
            paymentStarted = proof.paymentStarted
            paymentIdentifier = proof.paymentIdentifier
            proofData = proof.proofData
            billingPeriod = proof.billingPeriod.map { Period(startsAt: $0.sdkValue.startsAt, endsAt: $0.sdkValue.endsAt) }
            onchainAddress = proof.onchainAddress
            onchainAmountSats = proof.onchainAmountSats
            onchainWalletId = proof.onchainWalletId
            hardwareSignedTransaction = proof.hardwareSignedTransaction
            hardwareMiningFeeSats = proof.hardwareMiningFeeSats
            hardwareFeeRate = proof.hardwareFeeRate
            hardwareTotalSpent = proof.hardwareTotalSpent
            hardwareDispatchAttempted = proof.hardwareDispatchAttempted
            privatePaymentListVersion = proof.privatePaymentListVersion
            onchainMatchingTransactionIdsBeforeAttempt = proof.onchainMatchingTransactionIdsBeforeAttempt ?? []
            onchainAcceptanceVerified = proof.onchainAcceptanceVerified
        }

        func restored() throws -> PendingPaykitPaymentProof {
            let period = try billingPeriod.map { value in
                guard let period = PaykitBillingPeriod(sdkPeriod: BillingPeriod(startsAt: value.startsAt, endsAt: value.endsAt)) else {
                    throw invalidBackup("Invalid Paykit billing period")
                }
                return period
            }
            var proof = PendingPaykitPaymentProof(
                identity: identity,
                requestId: requestId.restored(billingPeriod: period),
                paymentAppId: paymentAppId,
                paymentEndpointIdentifier: paymentEndpointIdentifier,
                kind: kind,
                billingPeriod: period,
                paymentStarted: paymentStarted,
                paymentIdentifier: paymentIdentifier,
                proofData: proofData,
                onchainAddress: onchainAddress,
                onchainAmountSats: onchainAmountSats,
                onchainWalletId: onchainWalletId,
                onchainMatchingTransactionIdsBeforeAttempt: onchainMatchingTransactionIdsBeforeAttempt,
                onchainAcceptanceVerified: onchainAcceptanceVerified
            )
            if let hardwareSignedTransaction {
                guard kind == .onchain, paymentStarted, let walletId = onchainWalletId, walletId != WalletScope.default,
                      try SignedTransactionId.fromHex(hardwareSignedTransaction) == paymentIdentifier
                else { throw invalidBackup("Invalid hardware payment receipt") }
                proof.hardwareSignedTransaction = hardwareSignedTransaction
                proof.hardwareMiningFeeSats = hardwareMiningFeeSats
                proof.hardwareFeeRate = hardwareFeeRate
                proof.hardwareTotalSpent = hardwareTotalSpent
                proof.hardwareDispatchAttempted = hardwareDispatchAttempted
            }
            proof.privatePaymentListVersion = privatePaymentListVersion
            return proof
        }
    }

    /// Shared v1 wire object; unsigned values are decimal strings on both platforms.
    struct ActiveOnchainAttempt: Codable {
        struct Wallet: Codable, Equatable {
            let kind: String
            let network: String
            let binding: String
            let sourceIndex: String

            static func binding(storeId: String) -> String {
                SHA256.hash(data: Data(storeId.utf8)).map { String(format: "%02x", $0) }.joined()
            }

            static func backupNamespace(index: Int) async throws -> Wallet {
                let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: index)
                return Wallet(kind: "software", network: Env.networkName, binding: binding(storeId: storeId), sourceIndex: String(index))
            }

            var originalWalletId: String? {
                guard let index = Int(sourceIndex), index >= 0, index <= Int(Int32.max), String(index) == sourceIndex else { return nil }
                return "node:\(network):\(WalletScope.default):\(index)"
            }
        }

        struct Input: Codable { let txid: String; let vout: String }
        struct Followup: Codable {
            let feeSats: String
            let tags: [String]
            let contact: String?
            let createdAtMillis: String
            let channelId: String?
        }

        struct Transfer: Codable {
            let txTotalSats: String
            let preTransferOnchainSats: String
            let originalOrderClientBalanceSats: String
            let originalOrderFeeSats: String
        }

        let version: Int
        let wallet: Wallet
        let attemptId: String
        let requestId: RequestID?
        let orderId: String?
        let payerIdentity: String?
        let address: String
        let amountSats: String
        let isMaxAmount: Bool
        let status: String
        let txid: String?
        let rejectionReason: String?
        let originalInputs: [Input]?
        let candidateTxids: [String]
        let feeRateSatsPerVByte: String
        let candidateFeeRates: [String: String]?
        let followup: Followup?
        let transfer: Transfer?

        init(_ attempt: OnchainSendAttempt, wallet: Wallet) throws {
            guard attempt.walletId == wallet.originalWalletId else { throw invalidBackup("On-chain attempt belongs to another backup wallet") }
            version = 1
            self.wallet = wallet
            attemptId = attempt.id.uuidString.lowercased()
            requestId = attempt.requestId.map { RequestID($0, billingPeriod: nil) }
            orderId = attempt.orderId
            payerIdentity = attempt.recoveryContext?.paymentIdentity
            address = attempt.address
            amountSats = String(attempt.amountSats)
            isMaxAmount = attempt.isMaxAmount
            status = attempt.status.rawValue
            txid = attempt.txid?.lowercased()
            rejectionReason = attempt.rejectionReason
            originalInputs = attempt.recoveryContext.flatMap { recovery in
                recovery.inputs.isEmpty ? nil : recovery.inputs.map { Input(txid: $0.txid.lowercased(), vout: String($0.vout)) }
            }
            candidateTxids = attempt.recoveryContext?.candidateTxids.map { $0.lowercased() } ?? []
            let receiptCandidates = Set(candidateTxids)
            if let rates = attempt.recoveryContext?.candidateFeeRates {
                guard rates.allSatisfy({ $0.key.count == 64 && $0.key.allSatisfy { "0123456789abcdef".contains($0) } &&
                        receiptCandidates.contains($0.key) && $0.value > 0
                }) else {
                    throw invalidBackup("Invalid candidate fee rate association")
                }
                candidateFeeRates = rates.mapValues { String($0) }
            } else {
                candidateFeeRates = nil
            }
            feeRateSatsPerVByte = String(attempt.recoveryContext?.satsPerVbyte ?? attempt.followupContext?.feeRate ?? 0)
            guard attempt.followupContext?.createdAt.multipliedReportingOverflow(by: 1000).overflow != true else {
                throw invalidBackup("Invalid local follow-up timestamp")
            }
            followup = attempt.followupContext.map {
                Followup(
                    feeSats: String($0.feeSats),
                    tags: $0.tags,
                    contact: $0.contact,
                    createdAtMillis: String($0.backupCreatedAtMillis ?? $0.createdAt.multipliedReportingOverflow(by: 1000).partialValue),
                    channelId: $0.channelId
                )
            }
            transfer = try attempt.transferContext.map {
                guard let fee = $0.originalOrderFeeSats else { throw invalidBackup("Missing original order fee") }
                return Transfer(txTotalSats: String($0.txTotalSats), preTransferOnchainSats: String($0.preTransferOnchainSats),
                                originalOrderClientBalanceSats: String($0.clientBalanceSats), originalOrderFeeSats: String(fee))
            }
        }

        func restored(wallet destination: Wallet, proofs: [PendingPaykitPaymentProof]) throws -> (OnchainSendAttempt, [PendingPaykitPaymentProof]) {
            guard version == 1, wallet.kind == "software", destination.kind == "software",
                  ["bitcoin", "testnet", "signet", "regtest"].contains(wallet.network),
                  wallet.network == destination.network, wallet.binding == destination.binding, validTxid(wallet.binding),
                  wallet.originalWalletId != nil, let destinationWalletId = destination.originalWalletId,
                  let id = UUID(uuidString: attemptId), id.uuidString.lowercased() == attemptId,
                  let state = OnchainSendAttempt.Status(rawValue: status), !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  requestId == nil || orderId == nil
            else { throw invalidBackup("On-chain backup wallet or operation mismatch") }
            let amount: UInt64 = try number(amountSats)
            guard amount > 0 else { throw invalidBackup("Invalid on-chain backup amount") }
            let rate: UInt32 = try number(feeRateSatsPerVByte)
            let inputs = try originalInputs.map { values in
                try values.map { input -> OnchainSendInput in
                    guard validTxid(input.txid) else { throw invalidBackup("Invalid original input") }
                    return try OnchainSendInput(txid: input.txid, vout: number(input.vout))
                }
            }
            guard candidateTxids.allSatisfy(validTxid), Set(candidateTxids).count == candidateTxids.count,
                  inputs == nil ? candidateTxids.isEmpty && txid == nil && state == .pending :
                  inputs?.isEmpty == false && Set(inputs ?? []).count == inputs?.count && !candidateTxids.isEmpty &&
                  txid.map(candidateTxids.contains) == true && rate > 0,
                  state != .accepted || txid != nil
            else { throw invalidBackup("Invalid on-chain prepared receipt") }
            let rates = try candidateFeeRates.map { values in
                try values.mapValues { value -> UInt32 in
                    let rate: UInt32 = try number(value)
                    guard rate > 0 else { throw invalidBackup("Invalid candidate fee rate") }
                    return rate
                }
            }
            guard rates?.keys.allSatisfy({ validTxid($0) && candidateTxids.contains($0) }) != false else {
                throw invalidBackup("Candidate fee does not belong to this operation")
            }
            let restoredRequest = try requestId.map { value in
                let date = try value.billingPeriodStartsAt.map { try parseTimestamp($0).date }
                return PaykitPaymentRequest.ID(paymentRequestId: value.paymentRequestId, counterparty: value.counterparty,
                                               billingPeriodStartsAt: date)
            }
            let restoredProofs = proofs
            if let restoredRequest {
                guard let payerIdentity, PubkyPublicKeyFormat.normalized(payerIdentity) == payerIdentity,
                      restoredProofs.contains(where: {
                          PubkyPublicKeyFormat.matches($0.identity, payerIdentity) && $0.requestId == restoredRequest &&
                              $0.kind == .onchain && $0.paymentStarted && ($0.onchainWalletId == nil || $0.onchainWalletId == WalletScope.default) &&
                              $0.onchainAddress == address && $0.onchainAmountSats == amount &&
                              ($0.paymentIdentifier == nil || candidateTxids.contains($0.paymentIdentifier?.lowercased() ?? "")) &&
                              ($0.proofData == nil || candidateTxids.contains($0.proofData?.lowercased() ?? "")) &&
                              ($0.onchainAcceptanceVerified != true || $0.paymentIdentifier == txid && $0.proofData == txid && state == .accepted)
                      })
                else { throw invalidBackup("Original on-chain proof association is missing") }
                // The validated active wallet supplies indexed association; proof keeps its software scope.
            }
            let context = try followup.map { value -> OnchainSendFollowupContext in
                let milliseconds: UInt64 = try number(value.createdAtMillis)
                return try OnchainSendFollowupContext(feeSats: number(value.feeSats), feeRate: rate, tags: value.tags,
                                                      contact: value.contact, createdAt: milliseconds / 1000, backupCreatedAtMillis: milliseconds,
                                                      channelId: value.channelId)
            }
            let orderContext = try transfer.map { value -> OnchainSendTransferContext in
                guard orderId != nil else { throw invalidBackup("Original transfer context mismatch") }
                return try OnchainSendTransferContext(clientBalanceSats: number(value.originalOrderClientBalanceSats),
                                                      txTotalSats: number(value.txTotalSats),
                                                      preTransferOnchainSats: number(value.preTransferOnchainSats),
                                                      originalOrderFeeSats: number(value.originalOrderFeeSats))
            }
            guard orderId == nil || orderContext != nil else { throw invalidBackup("Missing original transfer context") }
            let attempt = OnchainSendAttempt(id: id, walletId: destinationWalletId, requestId: restoredRequest, orderId: orderId,
                                             address: address, amountSats: amount, isMaxAmount: isMaxAmount, status: state, txid: txid,
                                             rejectionReason: rejectionReason, localFollowupComplete: false,
                                             followupContext: context, transferContext: orderContext,
                                             recoveryContext: OnchainSendRecoveryContext(inputs: inputs ?? [], satsPerVbyte: rate,
                                                                                         paymentIdentity: payerIdentity,
                                                                                         candidateTxids: candidateTxids, candidateFeeRates: rates))
            return (attempt, restoredProofs)
        }

        private func validTxid(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }

        private func number<T: FixedWidthInteger & UnsignedInteger>(_ value: String) throws -> T {
            guard let parsed = T(value), String(parsed) == value else { throw invalidBackup("Invalid unsigned on-chain backup value") }
            return parsed
        }
    }

    private static func parseTimestamp(_ value: String) throws -> PaykitPreciseInstant {
        guard let instant = PaykitPreciseInstant(timestamp: value) else {
            throw invalidBackup("Invalid Paykit timestamp")
        }
        return instant
    }

    private static func invalidBackup(_ message: String) -> NSError {
        NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
