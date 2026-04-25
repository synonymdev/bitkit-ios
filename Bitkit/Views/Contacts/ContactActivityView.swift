import BitkitCore
import SwiftUI

struct ContactActivityView: View {
    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var feeEstimatesManager: FeeEstimatesManager

    let publicKey: String

    @State private var activities: [Activity] = []
    @State private var isLoading = true
    @State private var contactName = ""

    private var groupedActivities: [ActivityGroupItem] {
        activityList.groupActivities(activities)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("wallet__activity"))
                .padding(.horizontal, 16)

            if isLoading {
                loadingContent
            } else if groupedActivities.isEmpty {
                emptyContent
            } else {
                activityContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            resolveContactName()
            await loadActivities()
        }
        .onReceive(CoreService.shared.activity.activitiesChangedPublisher) { _ in
            Task {
                await loadActivities()
            }
        }
        .onReceive(contactsManager.$contacts) { _ in
            resolveContactName()
        }
    }

    private var activityContent: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(zip(groupedActivities.indices, groupedActivities)), id: \.1) { index, groupItem in
                    switch groupItem {
                    case let .header(title):
                        CaptionMText(title)
                            .frame(height: 34, alignment: .bottom)

                    case let .activity(activity):
                        NavigationLink(value: Route.activityDetail(activity)) {
                            ActivityRow(
                                item: activity,
                                feeEstimates: feeEstimatesManager.estimates,
                                titleOverride: activityTitle(activity)
                            )
                        }
                        .accessibilityIdentifier("ContactActivity-\(index)")
                    }
                }
            }
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
    }

    @ViewBuilder
    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("wallet__activity_no"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contactDisplayName: String {
        if !contactName.isEmpty {
            return contactName
        }

        return publicKey.ellipsis(maxLength: 18)
    }

    private func resolveContactName() {
        contactName = contactsManager.contacts.first(where: { $0.publicKey == publicKey })?.profile.name ?? ""
    }

    private func activityTitle(_ activity: Activity) -> String {
        let txType: PaymentType = switch activity {
        case let .lightning(lightningActivity):
            lightningActivity.txType
        case let .onchain(onchainActivity):
            onchainActivity.txType
        }

        switch txType {
        case .sent:
            return t("contacts__activity_sent_to", variables: ["name": contactDisplayName])
        case .received:
            return t("contacts__activity_received_from", variables: ["name": contactDisplayName])
        }
    }

    private func loadActivities() async {
        isLoading = true
        defer { isLoading = false }

        do {
            activities = try await CoreService.shared.activity.get(contact: publicKey, sortDirection: .desc)
        } catch {
            Logger.error(error, context: "ContactActivityView")
            activities = []
        }
    }
}
