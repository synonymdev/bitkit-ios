import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

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
            profileButton

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
                    .accessibilityIdentifier("WidgetsEdit")
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

    @ViewBuilder
    private var profileButton: some View {
        Button {
            if pubkyProfile.isAuthenticated {
                navigation.navigate(.profile)
            } else if app.hasSeenProfileIntro {
                navigation.navigate(.pubkyRingAuth)
            } else {
                navigation.navigate(.profileIntro)
            }
        } label: {
            HStack(alignment: .center, spacing: 16) {
                profileAvatar

                if let name = pubkyProfile.displayName {
                    TitleText(name)
                } else {
                    TitleText(t("slashtags__your_name_capital"))
                }
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let imageUri = pubkyProfile.displayImageUri {
            PubkyImage(uri: imageUri, size: 32)
        } else {
            Circle()
                .fill(Color.gray4)
                .frame(width: 32, height: 32)
                .overlay {
                    Image("user-square")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white32)
                        .frame(width: 16, height: 16)
                }
        }
    }
}
