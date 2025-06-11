import SwiftUI

struct SecurityConfig {
    let showLaterButton: Bool

    init(showLaterButton: Bool = false) {
        self.showLaterButton = showLaterButton
    }
}

struct SecuritySheetItem: SheetItem {
    let id: SheetID = .security
    let showLaterButton: Bool
    let size: SheetSize = .medium

    static let withLaterButton = SecuritySheetItem(showLaterButton: true)
    static let withoutLaterButton = SecuritySheetItem(showLaterButton: false)
}

struct SetupSecuritySheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    let config: SecuritySheetItem
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
                        sheets.hideSheet()
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
        .presentationDetents([.height(config.size.height)])
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled)
        .presentationCompactAdaptation(.none)
        .interactiveDismissDisabled(false)
        .presentationCornerRadius(32)
    }
}

#Preview {
    SetupSecuritySheet(config: .withLaterButton)
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel())
}
