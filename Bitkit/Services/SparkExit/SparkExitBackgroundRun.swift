import BreezSdkSpark
import Foundation
import os

/// One background run of an exit, from a cold launch with no UI: loads the record, sends what is ready from the
/// stored, already signed transactions without the SDK, then starts the Spark SDK only (never the node) and ticks
/// again with it, which checks the exit against the chain, signs a build or rebuild, and broadcasts. The driver
/// saves the record before and after each broadcast, so a run that expires mid-step leaves a whole record and the
/// next run carries on from it: a step that does not fit one run (connect and sign, say) finishes in the next.
struct SparkExitBackgroundRun {
    enum Step: String, CaseIterable {
        case load, keyless, connect, check, sign, broadcast, total
    }

    struct Outcome {
        var record: SparkExitRecord?
        var isConnected = false
        var seconds: [Step: TimeInterval] = [:]
    }

    let load: () throws -> SparkExitRecord?
    /// A driver over the given SDK, or over none for the keyless pass. The run times its SDK and broadcast calls.
    let makeDriver: (_ chain: SparkExitChain, _ recovering: SparkExitRecovering?) -> SparkExitDriver
    let chain: SparkExitChain
    /// The SDK when it is already connected, so the keyless pass is skipped.
    let connected: SparkExitRecovering?
    /// Starts the Spark SDK only; nil when it does not connect within the given seconds.
    let connect: (_ timeout: TimeInterval) async -> SparkExitRecovering?
    /// When the run must have saved and returned; the OS ends a refresh after about 30 seconds.
    let deadline: Date
    var now: () -> Date = Date.init

    /// Time kept back from the connect for the SDK tick and the final save.
    static let reserveSeconds: TimeInterval = 8

    func run() async -> Outcome {
        let started = now()
        var outcome = await steps()
        outcome.seconds[.total] = now().timeIntervalSince(started)
        return outcome
    }

    private func steps() async -> Outcome {
        let timings = SparkExitTimings()
        var outcome = Outcome()
        let loadStarted = now()
        do {
            outcome.record = try load()
        } catch {
            Logger.error("Spark exit background run could not read the record: \(error)", context: "SparkExitBackgroundRun")
        }
        timings.add(.load, now().timeIntervalSince(loadStarted))
        guard var record = outcome.record, record.isActive else {
            outcome.seconds = timings.seconds
            return outcome
        }
        let chain = TimedSparkExitChain(base: chain, timings: timings)

        var recovering = connected
        if recovering == nil {
            let keylessStarted = now()
            if let ticked = try? await makeDriver(chain, nil).tick(record) {
                record = ticked
            }
            timings.add(.keyless, now().timeIntervalSince(keylessStarted))

            let budget = deadline.timeIntervalSince(now()) - Self.reserveSeconds
            if !Task.isCancelled, budget > 0 {
                let connectStarted = now()
                recovering = await connect(budget)
                timings.add(.connect, now().timeIntervalSince(connectStarted))
            }
        }
        if let recovering, !Task.isCancelled {
            outcome.isConnected = true
            do {
                record = try await makeDriver(chain, TimedSparkExitRecovering(base: recovering, timings: timings)).tick(record)
            } catch {
                Logger.error("Spark exit background tick failed: \(error)", context: "SparkExitBackgroundRun")
            }
        }
        outcome.record = record
        outcome.seconds = timings.seconds
        return outcome
    }
}

/// Wall time per step of a background run, also marked as signpost intervals for Instruments.
final class SparkExitTimings: @unchecked Sendable {
    static let signposter = OSSignposter(subsystem: "to.bitkit", category: "SparkExitBackground")
    private let lock = NSLock()
    private var values: [SparkExitBackgroundRun.Step: TimeInterval] = [:]

    var seconds: [SparkExitBackgroundRun.Step: TimeInterval] {
        lock.withLock { values }
    }

    func add(_ step: SparkExitBackgroundRun.Step, _ seconds: TimeInterval) {
        lock.withLock { values[step, default: 0] += seconds }
    }

    func time<T>(_ step: SparkExitBackgroundRun.Step, _ body: () async throws -> T) async rethrows -> T {
        let state = Self.signposter.beginInterval("step", "\(step.rawValue)")
        let started = Date()
        defer {
            add(step, Date().timeIntervalSince(started))
            Self.signposter.endInterval("step", state)
        }
        return try await body()
    }
}

private struct TimedSparkExitRecovering: SparkExitRecovering {
    let base: SparkExitRecovering
    let timings: SparkExitTimings

    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse {
        try await timings.time(.sign) { try await base.prepare(request) }
    }

    func recover(_ request: RecoverFundsRequest, signer: CpfpSigner?) async throws -> RecoverFundsResponse {
        try await timings.time(.sign) { try await base.recover(request, signer: signer) }
    }

    func check(_ recovery: RecoverFundsResponse) async throws -> CheckRecoverFundsResponse {
        try await timings.time(.check) { try await base.check(recovery) }
    }
}

private struct TimedSparkExitChain: SparkExitChain {
    let base: SparkExitChain
    let timings: SparkExitTimings

    func tipHeight() async throws -> UInt32 {
        try await base.tipHeight()
    }

    func utxos(address: String) async throws -> [EsploraUtxo] {
        try await base.utxos(address: address)
    }

    func txStatus(txid: String) async throws -> EsploraTxStatus {
        try await base.txStatus(txid: txid)
    }

    func broadcast(_ tx: RecoveryTransaction) async -> SparkExitBroadcastOutcome {
        await timings.time(.broadcast) { await base.broadcast(tx) }
    }
}
