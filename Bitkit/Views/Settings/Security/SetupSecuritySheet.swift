import SwiftUI

struct SetupSecuritySheet: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Main content
                VStack(spacing: 32) {
                    Spacer()

                    // Shield illustration
                    Image("shield")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 300, height: 300)

                    // Title and description
                    VStack(spacing: 8) {
                        DisplayText(
                            NSLocalizedString("security__pin_security_title", comment: "Title for security setup sheet"),
                            textColor: .textPrimary,
                            accentColor: .greenAccent,
                        )

                        BodyMText(
                            NSLocalizedString("security__pin_security_text", comment: "Description for security setup"),
                            textColor: .textSecondary,
                        )
                        .multilineTextAlignment(.center)
                    }

                    Spacer()
                }

                // Buttons
                HStack(spacing: 16) {
                    CustomButton(
                        title: NSLocalizedString("common__later", comment: "Later button"),
                        variant: .secondary
                    ) {
                        app.showSetupSecuritySheet = false
                    }

                    CustomButton(
                        title: NSLocalizedString("security__pin_security_button", comment: "Secure wallet button"),
                        variant: .primary,
                        destination: ChoosePinView()
                    )
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)

            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheetBackground()
            .navigationTitle(NSLocalizedString("security__pin_security_header", comment: "Navigation title for security setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        app.showSetupSecuritySheet = false
                    }) {
                        Image("x-mark")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
}

#Preview {
    SetupSecuritySheet()
        .environmentObject(AppViewModel())
}
