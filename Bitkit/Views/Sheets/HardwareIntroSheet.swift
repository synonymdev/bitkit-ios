import SwiftUI

struct HardwareIntroSheetItem: SheetItem {
    let id: SheetID = .hardwareIntro
    let size: SheetSize = .large
}

/// Intro sheet opened from the Hardware suggestion card. Mirrors bitkit-android's `HwIntroSheet`:
/// staggered device hero, accent title, copy, and Cancel + (disabled) Continue. Continue is
/// intentionally disabled — the connect flow ships in a later PR.
struct HardwareIntroSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    let config: HardwareIntroSheetItem

    var body: some View {
        Sheet(id: .hardwareIntro, data: config) {
            VStack(spacing: 0) {
                SheetHeader(title: t("hardware__intro_title"))
                    .padding(.horizontal, 16)

                HwDeviceIllustrations()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("hardware__intro_header"), accentColor: .blueAccent)

                    BodyMText(t("hardware__intro_text"))
                        .padding(.top, 8)

                    HStack(spacing: 16) {
                        CustomButton(title: t("common__cancel"), variant: .secondary, shouldExpand: true) {
                            sheets.hideSheet()
                        }
                        .accessibilityIdentifier("HwIntroCancel")

                        CustomButton(title: t("common__continue"), isDisabled: true, shouldExpand: true)
                            .accessibilityIdentifier("HwIntroContinue")
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 32)
            }
            .accessibilityIdentifier("HwIntroSheet")
        }
    }
}
