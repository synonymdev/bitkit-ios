import SwiftUI

struct SavingsAvailabilityView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(localizedString("lightning__availability__title"), accentColor: .brandAccent)

            BodyMText(localizedString("lightning__availability__text"), accentFont: Fonts.bold)
                .padding(.top, 16)

            Spacer()

            ZStack {
                Image("exclamation-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: localizedString("common__cancel"), variant: .secondary) {
                    navigation.reset()
                }

                CustomButton(title: localizedString("common__continue")) {
                    navigation.navigate(.savingsConfirm)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
