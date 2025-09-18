import SwiftUI

struct AppStatus: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var wallet: WalletViewModel

    let showText: Bool
    let showReady: Bool
    let showColor: Bool
    let testID: String
    let onPress: (() -> Void)?

    @State private var rotationAngle: Double = 0
    @State private var opacity: Double = 1

    init(
        showText: Bool = false,
        showReady: Bool = false,
        showColor: Bool = true,
        testID: String,
        onPress: (() -> Void)? = nil
    ) {
        self.showText = showText
        self.showReady = showReady
        self.showColor = showColor
        self.testID = testID
        self.onPress = onPress
    }

    var body: some View {
        Button(action: {
            onPress?()
        }) {
            HStack(spacing: 8) {
                statusIcon

                if showText {
                    BodyMSBText(t("wallet__drawer__status"), textColor: .black)
                }
            }
        }
        .frame(minWidth: 32, minHeight: 32)
        .accessibilityIdentifier(testID)
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            startAnimations()
        }
        .onChange(of: appStatus) { _ in
            startAnimations()
        }
    }

    // MARK: - Computed Properties

    private var appStatus: HealthStatus {
        // During initialization, return 'ready' instead of error
        if !app.appStatusInitialized {
            return .ready
        }

        return AppStatusHelper.combinedAppStatus(from: wallet, network: network)
    }

    private var statusColor: Color {
        if !showColor {
            return .black
        }

        return appStatus.iconColor
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch appStatus {
        case .ready:
            if showReady {
                Image("power")
                    .resizable()
                    .foregroundColor(statusColor)
                    .frame(width: 24, height: 24)
            }
        case .pending:
            Image("arrows-clockwise")
                .resizable()
                .foregroundColor(statusColor)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotationAngle))
        case .error:
            Image("warning")
                .resizable()
                .foregroundColor(statusColor)
                .frame(width: 24, height: 24)
                .opacity(opacity)
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        switch appStatus {
        case .ready:
            stopAnimations()
        case .pending:
            startRotationAnimation()
        case .error:
            startFadeAnimation()
        }
    }

    private func startRotationAnimation() {
        // Reset rotation to 0 first
        rotationAngle = 0

        // First half turn with easing (0 to 180 degrees)
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.8)) {
            rotationAngle = 180
        }

        // Second half turn with different timing (180 to 360 degrees)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.2)) {
                rotationAngle = 360
            }

            // Reset and repeat the sequence
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                rotationAngle = 0
                startRotationAnimation()
            }
        }
    }

    private func startFadeAnimation() {
        withAnimation(
            .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
        ) {
            opacity = opacity == 1 ? 0.3 : 1
        }
    }

    private func stopAnimations() {
        withAnimation(.easeInOut(duration: 0.3)) {
            rotationAngle = 0
            opacity = 1
        }
    }
}
