import SwiftUI

/// Placeholder — final implementation lands in step 3 (grid of widget tiles).
struct WidgetsListSheetView: View {
    @Binding var navigationPath: [WidgetsRoute]

    var body: some View {
        VStack(spacing: 16) {
            SheetHeader(title: t("widgets__add"))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(WidgetType.allCases.filter { $0 != .suggestions }, id: \.rawValue) { type in
                        Button {
                            navigationPath.append(.preview(type))
                        } label: {
                            HStack {
                                BodyMText(t("widgets__\(type.rawValue)__name"))
                                Spacer()
                                Image("chevron")
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.textSecondary)
                            }
                            .padding()
                            .background(Color.gray6)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarHidden(true)
    }
}
