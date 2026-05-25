import SwiftUI

struct Header: View {
    @Environment(CalculatorInputManager.self) private var calculatorInput

    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    /// When true, shows the widget edit button (only on the widgets tab).
    var showWidgetEditButton: Bool = false
    /// Binding to widgets edit state; used when showWidgetEditButton is true.
    @Binding var isEditingWidgets: Bool

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    init(showWidgetEditButton: Bool = false, isEditingWidgets: Binding<Bool> = .constant(false)) {
        self.showWidgetEditButton = showWidgetEditButton
        _isEditingWidgets = isEditingWidgets
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if isPaykitUIActive {
                profileButton
            }

            Spacer()

            HStack(alignment: .center, spacing: 8) {
                AppStatus(
                    testID: "HeaderAppStatus",
                    onPress: {
                        if dismissCalculatorIfNeeded() { return }
                        navigation.navigate(.appStatus)
                    }
                )

                if showWidgetEditButton {
                    Button(action: {
                        if dismissCalculatorIfNeeded() { return }
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
                    if dismissCalculatorIfNeeded() { return }

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

    private var profileButton: some View {
        Button {
            if dismissCalculatorIfNeeded() { return }

            if pubkyProfile.isAuthenticated || pubkyProfile.cachedName != nil {
                navigation.navigate(.profile)
            } else if pubkyProfile.initializationErrorMessage != nil {
                navigation.navigate(.profile)
            } else if !pubkyProfile.isInitialized {
                // Still initializing — don't navigate to choice screen yet
                return
            } else if app.hasSeenProfileIntro {
                navigation.navigate(.pubkyChoice)
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
        .accessibilityLabel(pubkyProfile.displayName ?? t("profile__nav_title"))
        .accessibilityIdentifier("ProfileButton")
    }

    private func dismissCalculatorIfNeeded() -> Bool {
        guard calculatorInput.isPresented else { return false }
        calculatorInput.dismiss()
        return true
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
