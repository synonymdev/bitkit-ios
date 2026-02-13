import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    /// When true, shows the widget edit button (only on the widgets tab).
    var showWidgetEditButton: Bool = false
    /// Binding to widgets edit state; used when showWidgetEditButton is true.
    @Binding var isEditingWidgets: Bool

    init(showWidgetEditButton: Bool = false, isEditingWidgets: Binding<Bool> = .constant(false)) {
        self.showWidgetEditButton = showWidgetEditButton
        _isEditingWidgets = isEditingWidgets
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Button {
            //     if app.hasSeenProfileIntro {
            //         navigation.navigate(.profile)
            //     } else {
            //         navigation.navigate(.profileIntro)
            //     }
            // } label: {
            //     HStack(alignment: .center, spacing: 16) {
            //         Image(systemName: "person.circle.fill")
            //             .resizable()
            //             .font(.title2)
            //             .foregroundColor(.gray1)
            //             .frame(width: 32, height: 32)

            //         TitleText(t("slashtags__your_name_capital"))
            //     }
            // }

            Spacer()

            HStack(alignment: .center, spacing: 8) {
                AppStatus(
                    testID: "HeaderAppStatus",
                    onPress: {
                        navigation.navigate(.appStatus)
                    }
                )

                if showWidgetEditButton {
                    Button(action: {
                        isEditingWidgets.toggle()
                    }) {
                        Image(isEditingWidgets ? "check-mark" : "pencil")
                            .resizable()
                            .foregroundColor(.textPrimary)
                            .frame(width: 24, height: 24)
                            .frame(width: 32, height: 32)
                            .padding(.leading, 16)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("HeaderWidgetEdit")
                }

                Button {
                    withAnimation {
                        app.showDrawer = true
                    }
                } label: {
                    Image("burger")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("HeaderMenu")
            }
        }
        .frame(height: 48)
        .zIndex(.infinity)
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }
}
