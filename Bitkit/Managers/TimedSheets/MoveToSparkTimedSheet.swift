import Foundation

/// Shown once after the update to users whose channels still hold a balance worth moving to Spark.
struct MoveToSparkTimedSheet: TimedSheetItem {
    let id = SheetID.moveToSpark
    let priority = TimedSheetPriority.critical
    let sheetItem: any SheetItem = MoveToSparkSheetItem()
    let app: AppViewModel
    let wallet: WalletViewModel

    @MainActor
    func shouldShow() async -> Bool {
        guard !app.hasSeenMoveToSparkIntro else { return false }
        let spark = SparkManager.shared
        return MoveToSparkMath.canMove(channels: wallet.channels, isSparkUsable: spark.isReady && !spark.isExiting)
    }

    func onShown() {
        Task { @MainActor in
            app.hasSeenMoveToSparkIntro = true
        }
    }

    func onDismissed() {}
}
