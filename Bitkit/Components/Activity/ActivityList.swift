import SwiftUI
import BitkitCore

struct ActivityList: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @State private var isHorizontalSwipe = false

    let viewType: ActivityViewType

    enum ActivityViewType {
        case all
        case lightning
        case onchain
    }

    var body: some View {
        let activities = getActivities()
        let groupedItems = activity.groupActivities(activities)

        if !groupedItems.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedItems, id: \.self) { groupItem in
                    switch groupItem {
                    case .header(let title):
                        CaptionText(title)
                            .textCase(.uppercase)
                            .padding(.top)

                    case .activity(let item):
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item)
                        }
                        .padding(.vertical)
                        .disabled(isHorizontalSwipe)

                        // Add divider if not the last item in the group
                        if let nextIndex = activity.groupedActivities.firstIndex(of: groupItem),
                            nextIndex + 1 < activity.groupedActivities.count,
                            case .activity = activity.groupedActivities[nextIndex + 1]
                        {
                            Divider()
                        }
                    }
                }
            }
        } else {
            BodyMText(localizedString("wallet__activity_no"))
                .padding()
        }
    }

    private func getActivities() -> [Activity] {
        switch viewType {
        case .all:
            return activity.filteredActivities ?? []
        case .lightning:
            return activity.lightningActivities ?? []
        case .onchain:
            return activity.onchainActivities ?? []
        }
    }
}
