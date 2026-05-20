import BitkitCore
import SwiftUI

struct ContactActivityView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var feeEstimatesManager: FeeEstimatesManager

    let publicKey: String

    @State private var activities: [Activity] = []
    @State private var isLoading = true
    @State private var hasError = false
    @State private var contactName = ""

    private var groupedActivities: [ActivityGroupItem] {
        activityList.groupActivities(activities)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: contactName.isEmpty ? t("wallet__activity") : contactName)
                .padding(.horizontal, 16)

            if isLoading {
                loadingContent
            } else if hasError {
                errorContent
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
            await loadActivities(showLoading: true)
        }
        .onReceive(activityList.activitiesChangedPublisher) { _ in
            Task {
                await loadActivities(showLoading: activities.isEmpty)
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
                                contact: activityContact,
                                showContactAvatar: false
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

    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("wallet__activity_no"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("contacts__error_loading"))
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

    private var activityContact: PubkyContact {
        PubkyContact(
            publicKey: publicKey,
            profile: PubkyProfile(
                publicKey: publicKey,
                name: contactDisplayName,
                bio: "",
                imageUrl: nil,
                links: [],
                status: nil
            )
        )
    }

    private func resolveContactName() {
        contactName = contactsManager.contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, publicKey) })?.displayName ?? ""
    }

    private func loadActivities(showLoading: Bool) async {
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }

        do {
            activities = try await activityList.contactActivities(publicKey: publicKey)
            hasError = false
        } catch {
            Logger.error(error, context: "ContactActivityView")
            if showLoading || activities.isEmpty {
                activities = []
                hasError = true
            } else {
                hasError = false
            }
            app.toast(type: .error, title: t("contacts__error_loading"), description: error.localizedDescription)
        }
    }
}
