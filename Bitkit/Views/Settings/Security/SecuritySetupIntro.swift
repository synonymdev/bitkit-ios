import SwiftUI

struct SecuritySetupIntro: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 24) {
            // Shield illustration
            Image("shield")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaledToFit()
                .frame(maxWidth: 300, maxHeight: 300)

            // Title and description
            VStack(spacing: 8) {
                DisplayText(
                    NSLocalizedString("security__pin_security_title", comment: ""),
                    textColor: .textPrimary,
                    accentColor: .greenAccent,
                )

                BodyMText(
                    NSLocalizedString("security__pin_security_text", comment: ""),
                    textColor: .textSecondary,
                )
                .multilineTextAlignment(.center)
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: NSLocalizedString("common__later", comment: "Later button"),
                    variant: .secondary
                ) {
                    sheets.hideSheet()
                }

                CustomButton(
                    title: NSLocalizedString("security__pin_security_button", comment: ""),
                    variant: .primary,
                    destination: ChoosePinView()
                )
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(NSLocalizedString("security__pin_security_header", comment: ""))
    }
}

#Preview {
    SecuritySetupIntro()
        .environmentObject(AppViewModel())
        .environmentObject(SheetViewModel())
}
