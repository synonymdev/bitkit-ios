import SwiftUI

/// Placeholder — final implementation lands in step 5 (unified preview with size carousel).
struct WidgetPreviewSheetView: View {
    let type: WidgetType
    @Binding var navigationPath: [WidgetsRoute]

    var body: some View {
        VStack(spacing: 16) {
            SheetHeader(title: t("widgets__\(type.rawValue)__name"), showBackButton: true)

            Spacer()
            BodyMText("Preview placeholder for \(type.rawValue)", textColor: .textSecondary)
            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}
