import BitkitCore
import SwiftUI

struct ActivityList: View {
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject var activity: ActivityListViewModel

    let viewType: ActivityViewType

    enum ActivityViewType {
        case all
        case lightning
        case onchain
    }

    var body: some View {
        let activities = getActivities()
        let rows = WalletActivity.grouped(WalletActivity.merged(activities, filteredUsdt))
        if !rows.isEmpty {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(rows.enumerated()), id: \.element) { index, item in
                    switch item {
                    case let .header(title):
                        CaptionMText(title).frame(height: 34, alignment: .bottom)
                    case let .activity(activity):
                        WalletActivityRow(item: activity).accessibilityIdentifier("Activity-\(index)")
                    }
                }
            }
        } else {
            BodyMText(t("wallet__activity_no")).padding()
        }
    }

    private var filteredUsdt: [UsdtTransfer] {
        guard viewType == .all, activity.selectedTags.isEmpty else { return [] }
        return usdt.transfers.filter { transfer in
            let matchesTab: Bool = switch activity.selectedTab {
            case .all: true
            case .sent: !transfer.isIncoming
            case .received: transfer.isIncoming
            case .other: false
            }
            let date = Date(timeIntervalSince1970: TimeInterval(transfer.timestamp))
            let start = activity.startDate.map { Calendar.current.startOfDay(for: $0) }
            let end = activity.endDate.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }
            let search = activity.searchText
            return matchesTab && (start.map { date >= $0 } ?? true) && (end.map { date < $0 } ?? true) &&
                (search.isEmpty || transfer.recipient.localizedCaseInsensitiveContains(search) ||
                    transfer.txHash?.localizedCaseInsensitiveContains(search) == true || "USDT".localizedCaseInsensitiveContains(search))
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
