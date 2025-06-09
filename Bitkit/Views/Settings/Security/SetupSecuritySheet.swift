import SwiftUI

struct SetupSecuritySheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var pinEnabled: Bool = false
    @State private var useBiometrics: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if settings.pinEnabled && settings.useBiometrics {
                    //Replace current view with this so they can't go back in navigation stack
                    SecuritySetupSuccess()
                } else if pinEnabled {
                    // PIN is enabled but biometrics is not - show biometrics setup
                    SetupBiometricsView()
                } else {
                    // PIN is not enabled - show intro to start setup
                    SecuritySetupIntro()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .onAppear {
                pinEnabled = settings.pinEnabled
                useBiometrics = settings.useBiometrics
            }
        }
    }
}

#Preview {
    SetupSecuritySheet()
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel())
}
