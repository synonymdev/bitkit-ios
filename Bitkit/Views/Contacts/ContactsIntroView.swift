import SwiftUI

struct ContactsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__nav_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("group")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 8) {
                    DisplayText(
                        t("contacts__intro_title"),
                        accentColor: .pubkyGreen
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                    BodyMText(t("contacts__intro_description"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
                    .frame(height: 24)

                CustomButton(title: t("common__continue")) {
                    app.hasSeenContactsIntro = true
                    if pubkyProfile.isAuthenticated {
                        navigation.navigate(.contacts)
                    } else if app.hasSeenProfileIntro {
                        navigation.navigate(.pubkyRingAuth)
                    } else {
                        navigation.navigate(.profileIntro)
                    }
                }
                .accessibilityIdentifier("ContactsIntroContinue")
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        ContactsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .preferredColorScheme(.dark)
    }
}
