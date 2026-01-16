import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

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
}
