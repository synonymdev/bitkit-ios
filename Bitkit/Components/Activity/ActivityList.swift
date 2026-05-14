import BitkitCore
import SwiftUI

struct ActivityList: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager

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
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(zip(groupedItems.indices, groupedItems)), id: \.1) { index, groupItem in
                    switch groupItem {
                    case let .header(title):
                        CaptionMText(title)
                            .frame(height: 34, alignment: .bottom)

                    case let .activity(item):
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(
                                item: item,
                                feeEstimates: feeEstimatesManager.estimates,
                                contact: item.contact(in: contactsManager.contacts)
                            )
                        }
                        .accessibilityIdentifier("Activity-\(index)")
                    }
                }
            }
        } else {
            BodyMText(t("wallet__activity_no"))
                .padding()
        }
    }

    private func getActivities() -> [Activity] {
        switch viewType {
        case .all: return activity.filteredActivities ?? []
        case .lightning: return activity.lightningActivities ?? []
        case .onchain: return activity.onchainActivities ?? []
        }
    }
}
