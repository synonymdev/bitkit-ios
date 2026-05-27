import SwiftUI

/// Placeholder — final implementation lands in step 6 (sheet wrapper around existing edit logic).
struct WidgetEditSheetView: View {
    let type: WidgetType
    @Binding var navigationPath: [WidgetsRoute]

    var body: some View {
        VStack(spacing: 16) {
            SheetHeader(title: t("widgets__widget__settings"), showBackButton: true)

            Spacer()
            BodyMText("Edit placeholder for \(type.rawValue)", textColor: .textSecondary)
            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}
