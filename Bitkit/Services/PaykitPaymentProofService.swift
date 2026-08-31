import CryptoKit
import Foundation
import LDKNode
import Paykit

enum PaykitPaymentProofKind: String, Codable {
    case lightning = "bitcoin-bolt11-preimage"
    case onchain = "bitcoin-onchain-txid"
}

struct PendingPaykitPaymentProof: Codable, Equatable {
    let identity: String
    let requestId: PaykitPaymentRequest.ID
    let paymentEndpointIdentifier: String
    let kind: PaykitPaymentProofKind
    var paymentIdentifier: String?
    var proofData: String?
}

protocol PaykitPaymentProofStoring: Sendable {
    func load() async throws -> [PendingPaykitPaymentProof]
    func save(_ proofs: [PendingPaykitPaymentProof]) async throws
}

struct PaykitPaymentProofStore: PaykitPaymentProofStoring {
    private struct State: Codable {
        var proofs: [PendingPaykitPaymentProof]
    }

    func load() async throws -> [PendingPaykitPaymentProof] {
        guard let data = try Keychain.load(key: .paykitPendingPaymentProofs) else { return [] }
        do {
            return try JSONDecoder().decode(State.self, from: data).proofs
        } catch {
            Logger.warn("Discarding invalid pending Paykit payment proof state: \(error)", context: "PaykitPaymentProof")
            try? Keychain.delete(key: .paykitPendingPaymentProofs)
            return []
        }
    }

    func save(_ proofs: [PendingPaykitPaymentProof]) async throws {
        guard !proofs.isEmpty else {
            try Keychain.delete(key: .paykitPendingPaymentProofs)
            return
        }
        try Keychain.upsert(
            key: .paykitPendingPaymentProofs,
            data: JSONEncoder().encode(State(proofs: proofs))
        )
    }
}

protocol PaykitPaymentProofSdkHandling: Sendable {
    func identityStatus() async throws -> Paykit.IdentityStatus?
    func paymentRequests() async throws -> [Paykit.PaymentRequestRecord]
    func processPendingPrivateMessages() async throws -> [Paykit.OutboundPrivateCounterpartySendReport]
    func submitPaymentProof(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        proof: Paykit.PaymentProofSubmission
    ) async throws -> Paykit.PaymentRequestRecord
}

extension PaykitSdkService: PaykitPaymentProofSdkHandling {}

enum PaykitLightningPaymentProofStatus: Equatable {
    case pending
    case succeeded(preimage: String?)
    case failed
    case unknown
}

protocol PaykitLightningPaymentProofLookingUp: Sendable {
    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus
}

struct PaykitLightningPaymentProofLookup: PaykitLightningPaymentProofLookingUp {
    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus {
        guard let payment = await LightningService.shared.listPayments()?.first(where: {
            $0.id.caseInsensitiveCompare(paymentHash) == .orderedSame
        }), payment.direction == .outbound else {
            return .unknown
        }

        switch payment.status {
        case .pending:
            return .pending
        case .failed:
            return .failed
        case .succeeded:
            guard case let .bolt11(_, preimage, _, _, _) = payment.kind else { return .unknown }
            return .succeeded(preimage: preimage)
        }
    }
}

actor PaykitPaymentProofService {
    static let shared = PaykitPaymentProofService()

    private let sdk: any PaykitPaymentProofSdkHandling
    private let store: any PaykitPaymentProofStoring
    private let lightningPaymentLookup: any PaykitLightningPaymentProofLookingUp
    private let logInfo: @Sendable (String) -> Void
    private let logWarning: @Sendable (String) -> Void

    init(
        sdk: any PaykitPaymentProofSdkHandling = PaykitSdkService.shared,
        store: any PaykitPaymentProofStoring = PaykitPaymentProofStore(),
        lightningPaymentLookup: any PaykitLightningPaymentProofLookingUp = PaykitLightningPaymentProofLookup(),
        logInfo: @escaping @Sendable (String) -> Void = {
            Logger.info($0, context: "PaykitPaymentProof")
        },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentProof")
        }
    ) {
        self.sdk = sdk
        self.store = store
        self.lightningPaymentLookup = lightningPaymentLookup
        self.logInfo = logInfo
        self.logWarning = logWarning
    }

    func prepare(
        request: PaykitPaymentRequest,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind
    ) async throws {
        let proof = try await pendingProof(
            request: request,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: kind
        )

        var pendingProofs = try await loadProofs()
        pendingProofs.removeAll {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) &&
                $0.requestId == request.id &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
        pendingProofs.append(proof)
        try await persist(pendingProofs)
    }

    private func pendingProof(
        request: PaykitPaymentRequest,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind
    ) async throws -> PendingPaykitPaymentProof {
        guard request.acceptedPaymentEndpointIdentifiers.contains(paymentEndpointIdentifier),
              Self.endpoint(paymentEndpointIdentifier, supports: kind),
              let identityStatus = try await sdk.identityStatus(),
              identityStatus.liveSessionAvailable,
              let publicKey = identityStatus.publicKey,
              let identity = PubkyPublicKeyFormat.normalized(publicKey)
        else {
            throw PaykitPaymentRequestError.requestUnavailable
        }

        return PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: kind,
            paymentIdentifier: nil,
            proofData: nil
        )
    }

    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws {
        guard Self.isHex(paymentHash, byteCount: 32) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }

        var pendingProofs = try await loadProofs()
        guard let index = pendingProofs.lastIndex(where: {
            $0.requestId == request.id &&
                $0.kind == .lightning &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        pendingProofs[index].paymentIdentifier = paymentHash.lowercased()
        try await persist(pendingProofs)
    }

    func completeLightningPayment(paymentHash: String, preimage: String?) async {
        guard let preimage,
              Self.preimage(preimage, matchesPaymentHash: paymentHash)
        else {
            if preimage != nil {
                logWarning("Ignored a Paykit Lightning proof whose preimage did not match its payment hash")
            }
            return
        }

        do {
            var pendingProofs = try await loadProofs()
            let indexes = pendingProofs.indices.filter {
                pendingProofs[$0].kind == .lightning &&
                    pendingProofs[$0].paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame
            }
            guard !indexes.isEmpty else { return }
            for index in indexes {
                pendingProofs[index].proofData = preimage.lowercased()
            }
            let completedProofs = indexes.map { pendingProofs[$0] }
            await persistAndSubmit(completedProofs, allProofs: pendingProofs)
        } catch {
            logWarning("Failed to complete a Paykit Lightning payment proof: \(error)")
        }
    }

    func completeOnchainPayment(
        _ request: PaykitPaymentRequest,
        txid: String,
        paymentEndpointIdentifier: String
    ) async {
        guard Self.isHex(txid, byteCount: 32) else {
            logWarning("Ignored a Paykit on-chain proof with an invalid transaction id")
            return
        }

        do {
            var pendingProofs = try await loadProofs()
            guard let index = pendingProofs.lastIndex(where: {
                $0.requestId == request.id &&
                    $0.kind == .onchain &&
                    $0.paymentIdentifier == nil &&
                    $0.proofData == nil
            }) else { return }
            pendingProofs[index].paymentIdentifier = txid.lowercased()
            pendingProofs[index].proofData = txid.lowercased()
            await persistAndSubmit([pendingProofs[index]], allProofs: pendingProofs)
        } catch {
            logWarning("Failed to load a Paykit on-chain payment proof; attempting immediate delivery: \(error)")
            do {
                var proof = try await pendingProof(
                    request: request,
                    paymentEndpointIdentifier: paymentEndpointIdentifier,
                    kind: .onchain
                )
                proof.paymentIdentifier = txid.lowercased()
                proof.proofData = txid.lowercased()
                await submit(proof)
            } catch {
                logWarning("Failed to complete a Paykit on-chain payment proof: \(error)")
            }
        }
    }

    func failLightningPayment(paymentHash: String) async {
        await removeProofs {
            $0.kind == .lightning && $0.paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame
        }
    }

    func cancelPreparation(_ request: PaykitPaymentRequest) async {
        await removeProofs {
            $0.requestId == request.id &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
    }

    func reconcile() async {
        do {
            let pendingProofs = try await loadProofs()
            guard !pendingProofs.isEmpty else { return }
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  let publicKey = identityStatus.publicKey,
                  let identity = PubkyPublicKeyFormat.normalized(publicKey)
            else { return }

            let identityProofs = pendingProofs.filter {
                PubkyPublicKeyFormat.matches($0.identity, identity)
            }
            for proof in identityProofs {
                if proof.proofData != nil {
                    await submit(proof)
                    continue
                }
                guard proof.kind == PaykitPaymentProofKind.lightning, let paymentHash = proof.paymentIdentifier else { continue }
                switch await lightningPaymentLookup.status(paymentHash: paymentHash) {
                case .pending, .unknown:
                    continue
                case .failed:
                    await failLightningPayment(paymentHash: paymentHash)
                case let .succeeded(preimage):
                    await completeLightningPayment(paymentHash: paymentHash, preimage: preimage)
                }
            }
        } catch {
            logWarning("Failed to reconcile pending Paykit payment proofs: \(error)")
        }
    }

    private func submit(_ pendingProof: PendingPaykitPaymentProof) async {
        guard let proofData = pendingProof.proofData else { return }
        do {
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  PubkyPublicKeyFormat.matches(identityStatus.publicKey, pendingProof.identity)
            else { return }

            let records = try await sdk.paymentRequests()
            guard let request = records.first(where: {
                $0.paymentRequestId == pendingProof.requestId.paymentRequestId &&
                    PubkyPublicKeyFormat.matches($0.counterparty, pendingProof.requestId.counterparty) &&
                    $0.counterpartyReceiverPath == pendingProof.requestId.counterpartyReceiverPath
            }) else { return }

            let proofText = try Self.proofText(kind: pendingProof.kind, data: proofData)
            let isAlreadyQueued = request.paymentProofs.contains(where: {
                $0.billingPeriod == nil &&
                    $0.paymentEndpointIdentifier == pendingProof.paymentEndpointIdentifier &&
                    Self.proofValues($0.proof.exportText()) == Self.proofValues(proofText)
            })

            if !isAlreadyQueued {
                _ = try await sdk.submitPaymentProof(
                    counterparty: pendingProof.requestId.counterparty,
                    counterpartyReceiverPath: pendingProof.requestId.counterpartyReceiverPath,
                    paymentRequestId: pendingProof.requestId.paymentRequestId,
                    proof: Paykit.PaymentProofSubmission(
                        billingPeriod: nil,
                        paymentEndpointIdentifier: pendingProof.paymentEndpointIdentifier,
                        proof: Paykit.PrivateJsonObject(text: proofText)
                    )
                )
                logInfo("Queued a Paykit payment proof for private delivery")
                do {
                    _ = try await sdk.processPendingPrivateMessages()
                } catch {
                    logWarning("Paykit payment proof remains queued for private delivery: \(error)")
                }
            }
            await removeRequestProofs(pendingProof)
        } catch {
            logWarning("Failed to queue a Paykit payment proof: \(error)")
        }
    }

    private func loadProofs() async throws -> [PendingPaykitPaymentProof] {
        try await store.load()
    }

    private func persist(_ proofs: [PendingPaykitPaymentProof]) async throws {
        try await store.save(proofs)
    }

    private func persistAndSubmit(
        _ completedProofs: [PendingPaykitPaymentProof],
        allProofs: [PendingPaykitPaymentProof]
    ) async {
        do {
            try await persist(allProofs)
        } catch {
            logWarning("Failed to persist a completed Paykit payment proof; attempting immediate delivery: \(error)")
        }
        for proof in completedProofs {
            await submit(proof)
        }
    }

    private func removeRequestProofs(_ proof: PendingPaykitPaymentProof) async {
        await removeProofs {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) && $0.requestId == proof.requestId
        }
    }

    private func removeProofs(where shouldRemove: (PendingPaykitPaymentProof) -> Bool) async {
        do {
            let pendingProofs = try await loadProofs()
            let remainingProofs = pendingProofs.filter { !shouldRemove($0) }
            guard remainingProofs != pendingProofs else { return }
            try await persist(remainingProofs)
        } catch {
            logWarning("Failed to clear a pending Paykit payment proof: \(error)")
        }
    }

    private static func endpoint(_ identifier: String, supports kind: PaykitPaymentProofKind) -> Bool {
        guard let methodId = PublicPaykitService.MethodId(rawValue: identifier) else { return false }
        switch kind {
        case .lightning:
            return methodId == .bitcoinLightningBolt11 || methodId == .bitcoinLightningLnurl
        case .onchain:
            return methodId.onchainNetwork != nil
        }
    }

    private static func preimage(_ preimage: String, matchesPaymentHash paymentHash: String) -> Bool {
        guard let bytes = data(hex: preimage), bytes.count == 32 else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            .caseInsensitiveCompare(paymentHash) == .orderedSame
    }

    private static func isHex(_ value: String, byteCount: Int) -> Bool {
        data(hex: value)?.count == byteCount
    }

    private static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    private static func proofText(kind: PaykitPaymentProofKind, data: String) throws -> String {
        let encoded = try JSONSerialization.data(
            withJSONObject: ["data": data, "type": kind.rawValue],
            options: [.sortedKeys]
        )
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func proofValues(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return values
    }
}
