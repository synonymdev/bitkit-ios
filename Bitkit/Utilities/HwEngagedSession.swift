import Foundation

/// Closes a hardware wallet's device session without waiting for it: the next connect to that
/// device waits for the release instead. Implemented by `HwWalletManager`.
@MainActor
protocol HwSessionReleasing: AnyObject {
    func scheduleStaleSessionCleanup(walletId: String)
}

extension HwWalletManager: HwSessionReleasing {}

/// The hardware wallet whose device a screen engaged by verifying an address or entering a
/// passphrase. Only that session is released on the way out: showing a watch-only address never
/// opens one, and dropping a live session there would ask for a passphrase again on the next send.
///
/// The session stays engaged after the work ends, so leaving after a verification still releases
/// it: a device keeps its session open until something closes it.
@MainActor
final class HwEngagedSession {
    private(set) var walletId: String?
    private var runningWorkCount = 0

    var isWorking: Bool {
        runningWorkCount > 0
    }

    /// Runs device work for `walletId`, engaging its session from the moment the work starts.
    func perform(walletId: String, _ work: () async throws -> Void) async rethrows {
        self.walletId = walletId
        runningWorkCount += 1
        defer { runningWorkCount -= 1 }
        try await work()
    }

    /// Releases the engaged session, if any, when the screen, the hardware tab or the passphrase
    /// prompt is left.
    func release(through releaser: HwSessionReleasing) {
        guard let walletId else { return }
        self.walletId = nil
        releaser.scheduleStaleSessionCleanup(walletId: walletId)
    }

    /// The wallet or address on screen changed. Work still running was for one no longer shown, so
    /// the session it engaged is released; a session whose work already finished stays engaged until
    /// the screen is left.
    func invalidate(through releaser: HwSessionReleasing) {
        guard isWorking else { return }
        release(through: releaser)
    }
}
