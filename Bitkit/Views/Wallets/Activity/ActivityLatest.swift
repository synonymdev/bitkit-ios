import SwiftUI

struct ActivityLatest: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
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

    var body: some View {
        VStack(spacing: 0) {
            CaptionMText(t("wallet__activity"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            if shouldShowBanner {
                ActivityBanner(type: bannerType)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }

            if let items = activity.latestActivities {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(zip(items.indices, items)), id: \.1) { index, item in
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item, feeEstimates: activity.feeEstimates)
                        }
                        .accessibilityIdentifier("ActivityShort-\(index)")
                    }
                }

                if items.isEmpty {
                    Button(
                        action: {
                            sheets.showSheet(.receive)
                        },
                        label: {
                            EmptyActivityRow()
                        }
                    )
                } else {
                    CustomButton(title: tTodo("Show All"), variant: .tertiary) {
                        navigation.navigate(.activityList)
                    }
                    .accessibilityIdentifier("ActivityShowAll")
                }
            } else {
                EmptyView()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shouldShowBanner)
    }
}
