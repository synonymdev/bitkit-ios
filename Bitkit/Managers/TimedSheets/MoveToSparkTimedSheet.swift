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
        // E2E runs open new channels and do not expect the move offer covering Home; the journey covers the sheet.
        guard !Env.isE2E, !app.hasSeenMoveToSparkIntro else { return false }
        let spark = SparkManager.shared
        return MoveToSparkMath.canMove(channels: wallet.channels, isSparkUsable: MoveToSparkMath.isSparkUsable(spark))
    }

    func onShown() {
        Task { @MainActor in
            app.hasSeenMoveToSparkIntro = true
        }
    }

    func onDismissed() {}
}
