import SwiftUI

struct ActivityLatest: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            CaptionMText(t("wallet__activity"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            if let items = activity.latestActivities {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item, feeEstimates: activity.feeEstimates)
                        }
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
                }
            } else {
                EmptyView()
            }
        }
    }
}
