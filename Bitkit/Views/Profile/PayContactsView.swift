import SwiftUI

struct PayContactsView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__pay_contacts_nav_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("coin-stack")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 279)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    DisplayText(
                        t("profile__pay_contacts_title"),
                        accentColor: .pubkyGreen
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                    BodyMText(t("profile__pay_contacts_description"), textColor: .white64)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 16)

            // Profile setup has already turned on contact payments, so this step only explains them.
            CustomButton(title: t("common__continue")) {
                navigation.path = [.profile]
            }
            .accessibilityIdentifier("PayContactsContinue")
            .padding(.top, 32)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        PayContactsView()
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
