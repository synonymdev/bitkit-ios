import SwiftUI

struct AddTagSheet: View {
    @EnvironmentObject private var app: AppViewModel
    private let coreService: CoreService = .shared
    let activityId: String
    var previewTags: [String]? = nil

    @State private var allTags: [String] = []
    @State private var newTag: String = ""
    @State private var isLoading: Bool = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if !allTags.isEmpty {
                    CaptionText(localizedString("wallet__tags_previously"))
                        .textCase(.uppercase)
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    WrappingHStack(spacing: 8) {
                        ForEach(allTags, id: \.self) { tag in
                            Tag(
                                tag,
                                onPress: {
                                    Task { await appendTagAndClose(tag) }
                                }
                            )
                        }
                    }
                }

                Spacer()

                CaptionText(localizedString("wallet__tags_new"))
                    .textCase(.uppercase)
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                TextField(localizedString("wallet__tags_new_enter"), text: $newTag)
                    .disabled(isLoading)
                    .padding(.top, 8)

                CustomButton(
                    title: localizedString("wallet__tags_add_button"),
                    isDisabled: newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isLoading: isLoading
                ) {
                    Task {
                        await appendTagAndClose(newTag.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal)
            .sheetBackground()
            .navigationTitle(localizedString("wallet__tags_add"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let previewTags = previewTags {
                    allTags = previewTags
                } else {
                    Task { await loadTags() }
                }
            }
        }
    }

    private func loadTags() async {
        do {
            allTags = try await coreService.activity.allPossibleTags()
        } catch {
            app.toast(type: .error, title: "Failed to load tags", description: error.localizedDescription)
        }
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        do {
            try await coreService.activity.appendTag(toActivity: activityId, [tag])
            app.showAddTagSheet = false
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
        isLoading = false
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                AddTagSheet(
                    activityId: "test-activity-id",
                    previewTags: ["Lunch", "Mom", "Dad", "Conference", "Dinner", "Tip", "Friend", "Gift"]
                )
                .environmentObject(AppViewModel())
                .presentationDetents([.height(400)])
            }
        )
        .preferredColorScheme(.dark)
}
