import SwiftUI

struct MoveToSparkSheetItem: SheetItem {
    let id: SheetID = .moveToSpark
    let size: SheetSize = .large
}

/// Tells channel holders that Blocktank closes its channels and that moving the balance to Spark costs least.
struct MoveToSparkSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    let config: MoveToSparkSheetItem

    var body: some View {
        Sheet(id: .moveToSpark, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("lightning__move_to_spark__nav_title"))
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 32) {
                            Image("lightning")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 256, height: 256)
                                .frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                DisplayText(t("lightning__move_to_spark__intro_title"), accentColor: .purpleAccent)
                                BodyMText(t("lightning__move_to_spark__intro_text"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(minHeight: geometry.size.height, alignment: .bottom)
                    }
                }
                let buttonLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 16))
                    : AnyLayout(HStackLayout(spacing: 16))
                buttonLayout {
                    CustomButton(title: t("common__later"), variant: .secondary, shouldExpand: true) {
                        sheets.hideSheet()
                    }
                    .accessibilityIdentifier("MoveToSparkIntroLater")
                    CustomButton(title: t("lightning__move_to_spark__nav_title"), shouldExpand: true) {
                        sheets.hideSheet()
                        navigation.navigate(.moveToSpark)
                    }
                    .accessibilityIdentifier("MoveToSparkIntroMove")
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("MoveToSparkIntro")
        }
    }
}
