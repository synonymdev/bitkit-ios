import SwiftUI

// MARK: - Sheet Item

struct IncomingPaymentSheetItem: SheetItem {
    let id: SheetID = .incomingPayment
    let size: SheetSize = .large
    let paymentInfo: IncomingPaymentInfo
}

// MARK: - Sheet Wrapper

struct IncomingPaymentSheet: View {
    let config: IncomingPaymentSheetItem

    var body: some View {
        Sheet(item: config) {
            IncomingPaymentView(paymentInfo: config.paymentInfo)
        }
    }
}

// MARK: - Main View

/// Shows progress while completing an incoming Lightning payment.
/// Triggered when user opens app from payment notification.
struct IncomingPaymentView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var pushManager: PushNotificationManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    let paymentInfo: IncomingPaymentInfo

    @State private var state: IncomingState = .connecting

    enum IncomingState {
        case connecting
        case completing
        case completed(sats: UInt64)
        case expired
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            stateContent

            Spacer()

            actionButton
        }
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await processPayment()
        }
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .connecting:
            loadingContent(
                title: tTodo("Connecting"),
                subtitle: tTodo("Connecting to Lightning network...")
            )

        case .completing:
            loadingContent(
                title: tTodo("Receiving"),
                subtitle: tTodo("Completing payment...")
            )

        case let .completed(sats):
            successContent(sats: sats)

        case .expired:
            errorContent(
                icon: "exclamationmark.triangle",
                iconColor: .orange,
                title: tTodo("Payment Expired"),
                subtitle: tTodo("Ask sender to retry")
            )

        case let .failed(message):
            errorContent(
                icon: "xmark.circle",
                iconColor: .red,
                title: tTodo("Processing Failed"),
                subtitle: message
            )
        }
    }

    private func loadingContent(title: String, subtitle: String) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.purpleAccent)

            VStack(spacing: 8) {
                DisplayText(title, accentColor: .purpleAccent)
                    .multilineTextAlignment(.center)

                BodyMText(subtitle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    private func successContent(sats: UInt64) -> some View {
        VStack(spacing: 24) {
            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)

            VStack(spacing: 8) {
                DisplayText(tTodo("Payment Received"), accentColor: .purpleAccent)
                    .multilineTextAlignment(.center)

                BodyMText(tTodo("Received \(sats.formatted()) sats"))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    private func errorContent(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(iconColor)

            VStack(spacing: 8) {
                DisplayText(title)
                    .multilineTextAlignment(.center)

                BodyMText(subtitle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .connecting, .completing:
            // No button while processing
            EmptyView()

        case .completed:
            CustomButton(title: localizedRandom("common__ok_random")) {
                sheets.hideSheet()
            }

        case .expired:
            CustomButton(title: tTodo("Close")) {
                sheets.hideSheet()
            }

        case .failed:
            VStack(spacing: 12) {
                CustomButton(title: tTodo("Retry")) {
                    Task {
                        await processPayment()
                    }
                }

                CustomButton(title: tTodo("Close"), style: .outline) {
                    sheets.hideSheet()
                }
            }
        }
    }

    // MARK: - Payment Processing

    private func processPayment() async {
        // Check expiry first
        guard !paymentInfo.isExpired else {
            state = .expired
            pushManager.clearPendingPayment()
            return
        }

        state = .connecting

        // Process via manager (starts node, connects peer, etc.)
        await pushManager.processIncomingPayment(paymentInfo, walletViewModel: wallet)

        // Wait for completion signal with timeout (30s)
        state = .completing
        for _ in 0 ..< 60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if pushManager.pendingPaymentInfo == nil {
                let sats = (paymentInfo.amountMsat ?? 0) / 1000
                state = .completed(sats: sats)
                Haptics.notify(.success)
                return
            }
        }

        state = .failed(tTodo("Payment processing timed out"))
    }
}

// MARK: - Previews

#Preview("Connecting") {
    IncomingPaymentSheet(
        config: IncomingPaymentSheetItem(
            paymentInfo: IncomingPaymentInfo(
                paymentType: .incomingHtlc,
                amountMsat: 100_000_000
            )
        )
    )
    .environmentObject(AppViewModel())
    .environmentObject(PushNotificationManager.shared)
    .environmentObject(SheetViewModel())
    .environmentObject(WalletViewModel())
    .preferredColorScheme(.dark)
}
