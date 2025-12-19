import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                if app.hasSeenProfileIntro {
                    navigation.navigate(.profile)
                } else {
                    navigation.navigate(.profileIntro)
                }
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    // Avatar - show profile image if available, otherwise default icon
                    if !app.profileAvatarUrl.isEmpty, let url = URL(string: app.profileAvatarUrl) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .resizable()
                                .foregroundColor(.gray1)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else if !app.profileName.isEmpty {
                        // Show initial if we have a name but no avatar
                        ZStack {
                            Circle()
                                .fill(Color.brandAccent.opacity(0.2))
                            Text(String(app.profileName.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.brandAccent)
                        }
                        .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .font(.title2)
                            .foregroundColor(.gray1)
                            .frame(width: 32, height: 32)
                    }

                    TitleText(app.displayName)
                }
            }

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
