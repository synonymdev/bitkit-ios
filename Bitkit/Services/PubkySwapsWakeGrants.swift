import BitkitCore
import Foundation

extension WakeTopics {
    /// A Pubky Swaps provider's wake once a reverse swap's lockup has its confirmations. It names no swap.
    static let swapClaimable = "swap.claimable"
}

/// Where a swap's wake grant is made: the gateway this install registered with, its device secret, and the identity
/// the grant lets the provider wake.
struct SwapWakeGrantTarget: Equatable {
    let gatewayUrl: String
    let deviceSecret: String
    let recipient: String

    /// Only an install the gateway accepted, with notifications on, gets wakes. The grant is for `pk:` when the install
    /// registered one, else `ln:`.
    static func resolve(
        gatewayUrl: String?,
        record: WakeRegistrationRecord,
        credentials: WakeCredentials?,
        notificationsEnabled: Bool
    ) -> SwapWakeGrantTarget? {
        guard notificationsEnabled, let gatewayUrl, let credentials, let device = record.device,
              device.gatewayUrl == gatewayUrl, record.registeredGatewayUrl == gatewayUrl
        else { return nil }
        let identities = device.content.identities
        guard let recipient = identities.first(where: { $0.hasPrefix("pk:") }) ?? identities.first(where: { $0.hasPrefix("ln:") })
        else { return nil }
        return SwapWakeGrantTarget(gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret, recipient: recipient)
    }
}

/// Leaves the device secret out of logs and test failures.
extension SwapWakeGrantTarget: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "SwapWakeGrantTarget(gatewayUrl: \(gatewayUrl), recipient: \(recipient))"
    }

    var debugDescription: String {
        description
    }
}

/// The grant a swap's provider holds, kept to revoke it once the swap ends. Never its token.
struct SwapWakeGrantRecord: Codable, Equatable {
    let grantId: String
    let gatewayUrl: String
}

struct SwapWakeGrantStore {
    static let key = "pubkySwapWakeGrants"

    var defaults: UserDefaults = .standard

    var grants: [String: SwapWakeGrantRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: SwapWakeGrantRecord].self, from: data)) ?? [:]
    }

    func save(_ grant: SwapWakeGrantRecord, for swapId: String) {
        var grants = grants
        grants[swapId] = grant
        write(grants)
    }

    func remove(_ swapId: String) {
        var grants = grants
        grants[swapId] = nil
        write(grants)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func write(_ grants: [String: SwapWakeGrantRecord]) {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Hands each committed swap's provider a wake grant, so it wakes this device once the swap can be claimed, and revokes
/// the grant once the swap ends. Grants are capped per device and per identity, so each lives only as long as its swap.
actor PubkySwapsWakeGrants {
    enum HandOver: Equatable {
        /// The provider sends no wakes.
        case notTaken
        /// Wakes are off, or this install is not registered with the gateway.
        case notRegistered
        case held
        /// The provider already sees the swap as claimable, so it sends no wake.
        case alreadyClaimable
        case failed
    }

    struct Calls {
        var createGrant: @Sendable (_ target: SwapWakeGrantTarget, _ topics: [String], _ expiresInDays: UInt32) async throws -> WakeGrant
        var revokeGrant: @Sendable (_ gatewayUrl: String, _ deviceSecret: String, _ grantId: String) async throws -> Void
        var sendCapability: @Sendable (_ swapId: String, _ gatewayUrl: String, _ token: String, _ expiresAt: UInt64) async throws -> Bool
        var advance: @Sendable (_ swapId: String) async -> Void
    }

    /// Covers a reverse swap's claim window, about a day of blocks. The grant is revoked once the swap ends.
    static let grantDays: UInt32 = 2

    static let shared: PubkySwapsWakeGrants = .init(
        calls: .live,
        target: {
            let notificationsEnabled = await MainActor.run { SettingsViewModel.shared.enableNotifications }
            return try? SwapWakeGrantTarget.resolve(
                gatewayUrl: Env.wakeGatewayUrl,
                record: WakeStorage.loadRegistration(),
                credentials: WakeStorage.loadCredentials(),
                notificationsEnabled: notificationsEnabled
            )
        },
        deviceSecret: { try? WakeStorage.loadCredentials()?.deviceSecret },
        isUnfinished: { await PubkySwapsTracker.shared.unfinishedSwapIds.contains($0) }
    )

    private let store: SwapWakeGrantStore
    private let calls: Calls
    private let target: @Sendable () async -> SwapWakeGrantTarget?
    private let deviceSecret: @Sendable () -> String?
    private let isUnfinished: @Sendable (_ swapId: String) async -> Bool

    init(
        store: SwapWakeGrantStore = SwapWakeGrantStore(),
        calls: Calls,
        target: @escaping @Sendable () async -> SwapWakeGrantTarget?,
        deviceSecret: @escaping @Sendable () -> String?,
        isUnfinished: @escaping @Sendable (_ swapId: String) async -> Bool = { _ in true }
    ) {
        self.store = store
        self.calls = calls
        self.target = target
        self.deviceSecret = deviceSecret
        self.isUnfinished = isUnfinished
    }

    /// Creates a `swap.claimable` grant and hands it to the swap's provider. A failure never fails the swap: without a
    /// wake, the wallet claims when it next runs.
    @discardableResult
    func handOver(swapId: String, providerTakesWake: Bool) async -> HandOver {
        guard providerTakesWake else { return .notTaken }
        guard let target = await target() else { return .notRegistered }
        let grant: WakeGrant
        do {
            grant = try await calls.createGrant(target, [WakeTopics.swapClaimable], Self.grantDays)
        } catch {
            Logger.warn("Failed to create a wake grant for Pubky Swaps route \(swapId): \(error)", context: "PubkySwapsRoute")
            return .failed
        }
        store.save(SwapWakeGrantRecord(grantId: grant.id, gatewayUrl: target.gatewayUrl), for: swapId)
        do {
            let isClaimable = try await calls.sendCapability(swapId, target.gatewayUrl, grant.token, grant.expiresAt)
            guard isClaimable else {
                // A swap that ended meanwhile, as on a failed hold payment, had no grant to revoke then.
                guard await isUnfinished(swapId) else {
                    await revoke(swapId: swapId)
                    return .failed
                }
                Logger.info("Pubky Swaps route \(swapId) wakes this device once it can be claimed", context: "PubkySwapsRoute")
                return .held
            }
            Logger.info("Pubky Swaps route \(swapId) is claimable already", context: "PubkySwapsRoute")
            await revoke(swapId: swapId)
            await calls.advance(swapId)
            return .alreadyClaimable
        } catch {
            Logger.warn("Failed to hand Pubky Swaps route \(swapId) a wake grant: \(error)", context: "PubkySwapsRoute")
            await revoke(swapId: swapId)
            return .failed
        }
    }

    /// Revokes the swap's grant, if it has one, once the swap ends. Best effort: an unrevoked grant expires.
    func revoke(swapId: String) async {
        guard let grant = store.grants[swapId] else { return }
        store.remove(swapId)
        guard let deviceSecret = deviceSecret() else { return }
        do {
            try await calls.revokeGrant(grant.gatewayUrl, deviceSecret, grant.grantId)
        } catch {
            Logger.warn("Failed to revoke the wake grant of Pubky Swaps route \(swapId): \(error)", context: "PubkySwapsRoute")
        }
    }

    func resetForWipe() {
        store.clear()
    }
}

extension PubkySwapsWakeGrants.Calls {
    static let live: PubkySwapsWakeGrants.Calls = .init(
        createGrant: { target, topics, expiresInDays in
            try await ServiceQueue.background(.core, wrapErrors: false) {
                try await wakeCreateGrant(
                    gatewayUrl: target.gatewayUrl,
                    deviceSecret: target.deviceSecret,
                    recipient: target.recipient,
                    topics: topics,
                    perHour: nil,
                    perDay: nil,
                    expiresInDays: expiresInDays
                )
            }
        },
        revokeGrant: { gatewayUrl, deviceSecret, grantId in
            try await ServiceQueue.background(.core, wrapErrors: false) {
                try await wakeRevokeGrant(gatewayUrl: gatewayUrl, deviceSecret: deviceSecret, grantId: grantId)
            }
        },
        sendCapability: { swapId, gatewayUrl, token, expiresAt in
            let (mnemonic, passphrase) = try PubkySwapsRouteService.secrets()
            return try await pubkySwapsSendWakeCapability(
                swapId: swapId,
                gatewayUrl: gatewayUrl,
                token: token,
                expiresAt: expiresAt,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase
            )
        },
        advance: { swapId in
            do {
                let state = try await PubkySwapsRouteService.advance(swapId: swapId)
                Logger.debug("Pubky Swaps route \(swapId): \(state)", context: "PubkySwapsRoute")
            } catch {
                Logger.warn("Failed to advance Pubky Swaps route \(swapId): \(error)", context: "PubkySwapsRoute")
            }
        }
    )
}
