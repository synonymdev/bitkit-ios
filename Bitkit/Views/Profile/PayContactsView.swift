import SwiftUI

struct PayContactsView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    @State private var enablePayments = true

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__pay_contacts_nav_title"))
                .padding(.horizontal, 16)

            Spacer()

            Image("coin-stack")
                .resizable()
                .scaledToFit()
                .frame(width: 279)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(
                    t("profile__pay_contacts_title"),
                    accentColor: .pubkyGreen
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

                BodyMText(t("profile__pay_contacts_description"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Spacer()

            Toggle(isOn: $enablePayments) {
                BodyMText(t("profile__pay_contacts_toggle"), textColor: .white)
            }
            .tint(.pubkyGreen)
            .accessibilityIdentifier("PayContactsToggle")
            .padding(.horizontal, 32)

            CustomButton(title: t("common__continue")) {
                navigation.path = [.profile]
            }
            .accessibilityIdentifier("PayContactsContinue")
            .padding(.top, 16)
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
