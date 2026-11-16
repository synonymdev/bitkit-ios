import Foundation

/// Turns private and public payments on once for Pubky profiles that existed before payments were on by default.
///
/// `AppDataMigrations` queues both steps at upgrade for wallets with a stored Pubky identity. The app runs them in the
/// background once the wallet, node and Pubky session are ready, through the same paths as the Settings toggles, so
/// the access check, app record sync, contact preparation and rollback all apply. A step leaves the queue when it
/// succeeds, when its payments are already on, when the user chose its setting, or, for private payments, when the
/// profile has no private payment access. Any other failure keeps it queued for a later launch.
enum PaykitPaymentsMigration {
    static let privatePendingKey = "paykitPrivatePaymentsMigrationPending"
    static let publicPendingKey = "paykitPublicPaymentsMigrationPending"

    struct Plan: Equatable {
        var enablesPrivate: Bool
        var enablesPublic: Bool

        var isEmpty: Bool {
            !enablesPrivate && !enablesPublic
        }
    }

    /// Each step returns whether its change applied; false means a newer change or session superseded it.
    struct Steps {
        let enablePrivate: @MainActor () async throws -> Bool
        let enablePublic: @MainActor () async throws -> Bool

        @MainActor
        static func live(
            pubkyProfile: PubkyProfileManager,
            contactsManager: ContactsManager,
            wallet: WalletViewModel
        ) -> Steps {
            Steps(
                enablePrivate: {
                    try await ContactPaymentsService.setEnabled(
                        true,
                        pubkyProfile: pubkyProfile,
                        contactsManager: contactsManager,
                        operations: .live(wallet: wallet)
                    )
                },
                enablePublic: {
                    try await ContactPaymentsService.setPublicEnabled(
                        true,
                        pubkyProfile: pubkyProfile,
                        operations: .live(wallet: wallet),
                        recordsChoice: false
                    )
                }
            )
        }
    }

    /// One attempt per app launch, so a failing step waits for the next launch instead of retrying on every foreground.
    @MainActor private static var hasAttemptedThisLaunch = false

    static func queue(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: privatePendingKey)
        defaults.set(true, forKey: publicPendingKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: privatePendingKey)
        defaults.removeObject(forKey: publicPendingKey)
    }

    /// Private payments count as chosen once the user confirmed a preference: turning them off stores the
    /// confirmation with sharing off. Public payments count as chosen once the user used the public toggle.
    static func plan(defaults: UserDefaults = .standard) -> Plan {
        let sharesPrivate = defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
        let chosePrivate = defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey)
        let sharesPublic = defaults.bool(forKey: PublicPaykitService.publishingEnabledKey)
        let chosePublic = defaults.bool(forKey: ContactPaymentsService.publicPreferenceChosenKey)
        return Plan(
            enablesPrivate: defaults.bool(forKey: privatePendingKey) && !sharesPrivate && !chosePrivate,
            enablesPublic: defaults.bool(forKey: publicPendingKey) && !sharesPublic && !chosePublic
        )
    }

    /// Drops queued steps that no longer need to run: their payments are on, or the user chose the setting.
    static func dropSettledSteps(defaults: UserDefaults = .standard) {
        let plan = plan(defaults: defaults)
        if !plan.enablesPrivate {
            defaults.removeObject(forKey: privatePendingKey)
        }
        if !plan.enablesPublic {
            defaults.removeObject(forKey: publicPendingKey)
        }
    }

    /// `isCurrent` must stay true for the whole run: the session, wallet and node it started with are still current
    /// and no wipe or profile deletion started.
    @MainActor
    static func run(
        steps: Steps,
        defaults: UserDefaults = .standard,
        isCurrent: @escaping @MainActor () -> Bool
    ) async {
        guard !hasAttemptedThisLaunch, isCurrent(), !Task.isCancelled else { return }
        dropSettledSteps(defaults: defaults)
        guard !plan(defaults: defaults).isEmpty else { return }
        hasAttemptedThisLaunch = true

        if plan(defaults: defaults).enablesPrivate {
            do {
                if try await steps.enablePrivate(), isCurrent() {
                    defaults.removeObject(forKey: privatePendingKey)
                    Logger.info("Turned private payments on for an existing profile", context: "PaykitPaymentsMigration")
                }
            } catch PrivatePaykitError.privateUnavailable {
                if isCurrent() {
                    defaults.removeObject(forKey: privatePendingKey)
                    Logger.info("Profile has no private payment access; skipping private payments", context: "PaykitPaymentsMigration")
                }
            } catch {
                Logger.warn("Failed to turn private payments on, retrying next launch: \(error)", context: "PaykitPaymentsMigration")
            }
        }

        guard isCurrent(), !Task.isCancelled else { return }
        // The user may have used the public toggle while private payments were being set up.
        dropSettledSteps(defaults: defaults)
        if plan(defaults: defaults).enablesPublic {
            do {
                if try await steps.enablePublic(), isCurrent() {
                    defaults.removeObject(forKey: publicPendingKey)
                    Logger.info("Turned public payments on for an existing profile", context: "PaykitPaymentsMigration")
                }
            } catch {
                Logger.warn("Failed to turn public payments on, retrying next launch: \(error)", context: "PaykitPaymentsMigration")
            }
        }
    }

    @MainActor
    static func resetLaunchAttemptForTesting() {
        hasAttemptedThisLaunch = false
    }
}
