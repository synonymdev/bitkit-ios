import SwiftUI

struct ActivityLatest: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
        VStack(spacing: 0) {
            CaptionMText(t("wallet__activity"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
                .padding(.top, 32)

            if let items = activity.latestActivities {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item)
                        }

                        if item != items.last {
                            Divider()
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
                        CustomButton(title: t("wallet__activity_show_all"), variant: .tertiary) {
                            navigation.navigate(.activityList)
                        }
                    }
                }
            } else {
                EmptyView()
            }
        }
    }
}
