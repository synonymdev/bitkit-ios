import BitkitCore
import SwiftUI

struct ActivityLatest: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    private var shouldShowBanner: Bool {
        wallet.balanceInTransferToSavings > 0 || wallet.balanceInTransferToSpending > 0
    }

    private var bannerType: ActivityBannerType {
        if wallet.balanceInTransferToSpending > 0 {
            return .spending
        } else {
            return .savings
        }
    }

    /// Calculate remaining duration for force close transfers
    private var remainingDuration: String? {
        guard let claimableAtHeight = wallet.forceCloseClaimableAtHeight,
              wallet.currentBlockHeight > 0
        else {
            return nil
        }
        let blocksRemaining = BlockTimeHelpers.blocksRemaining(until: claimableAtHeight, currentHeight: wallet.currentBlockHeight)
        guard blocksRemaining > 0 else { return nil }
        return BlockTimeHelpers.getDurationForBlocks(blocksRemaining)
    }

    /// Three or four vertical slots (by screen size) shared by: transfer banner, widgets onboarding
    /// and activity items; only the item count shrinks so the total stays within the cap.
    private var maxActivityItemsOnHome: Int {
        let slotCapacity = UIScreen.main.isSmall ? 3 : 4
        var nonItemSlots = 0
        if shouldShowBanner { nonItemSlots += 1 }
        if settings.showWidgets, !app.hasDismissedWidgetsOnboardingHint { nonItemSlots += 1 }
        return max(0, slotCapacity - nonItemSlots)
    }

    private var displayedActivities: [Activity]? {
        guard let items = activity.latestActivities, !items.isEmpty else { return nil }
        return Array(items.prefix(maxActivityItemsOnHome))
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowBanner {
                ActivityBanner(type: bannerType, remainingDuration: remainingDuration)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }

            if let rows = displayedActivities {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(zip(rows.indices, rows)), id: \.1) { index, item in
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item, feeEstimates: feeEstimatesManager.estimates)
                        }
                        .accessibilityIdentifier("ActivityShort-\(index)")
                    }
                }

                CustomButton(title: t("common__show_all"), variant: .tertiary) {
                    navigation.navigate(.activityList)
                }
                .accessibilityIdentifier("ActivityShowAll")
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shouldShowBanner)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: maxActivityItemsOnHome)
        .task {
            await feeEstimatesManager.getEstimates(refresh: false)
        }
    }
}
