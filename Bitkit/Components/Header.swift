import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            profileButton

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                AppStatus(
                    testID: "HeaderAppStatus",
                    onPress: {
                        navigation.navigate(.appStatus)
                    }
                )

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
                        .padding(.leading, 16)
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
        .accessibilityLabel(pubkyProfile.displayName ?? t("profile__nav_title"))
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
