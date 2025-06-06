import SwiftUI

struct SetupBiometricsView: View {
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                BodyMText(NSLocalizedString("security__bio_ask", comment: ""), textAlignment: .left)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 32)
            .padding(.bottom, 48)

            Spacer()

            // Setup button
            VStack(spacing: 16) {
                Button(action: {
                    // TODO: Implement biometric setup logic
                    dismiss()
                }) {
                    Text(NSLocalizedString("security__bio_use", comment: ""))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.brandAccent)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)

                Button(action: {
                    // Skip biometric setup
                    dismiss()
                }) {
                    Text(NSLocalizedString("common__skip", comment: ""))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(NSLocalizedString("security__bio", comment: ""))
    }
}

#Preview {
    SetupBiometricsView()
        .environmentObject(AppViewModel())
}
