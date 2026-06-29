import SwiftUI

struct TrezorAccountTypeSelector: View {
    @Binding var selection: TrezorAccountTypeSelection
    var title: String = "Account Type"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(title)

            SegmentedControl(selectedTab: $selection, tabs: TrezorAccountTypeSelection.allCases)

            FootnoteText(selection.subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("TrezorAccountTypeSelector")
    }
}
