import SwiftUI

struct ProfileIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__nav_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("crown")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 8) {
                    DisplayText(
                        t("profile__intro_title"),
                        accentColor: .pubkyGreen
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                    BodyMText(t("profile__intro_description"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
                    .frame(height: 24)

                CustomButton(title: t("common__continue")) {
                    app.hasSeenProfileIntro = true
                    navigation.navigate(.pubkyRingAuth)
                }
                .accessibilityIdentifier("ProfileIntroContinue")
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
        ProfileIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
