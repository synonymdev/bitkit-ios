import BitkitCore
import SwiftUI

struct SweepConfirmView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject private var viewModel: SweepViewModel

    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var isLoadingAddress = true

    private var isLoading: Bool {
        isLoadingAddress || viewModel.isPreparingTransaction || viewModel.sweepState.isLoading
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                NavigationBar(title: t("sweep__confirm_title"))
                    .padding(.bottom, 16)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            if case .ready = viewModel.sweepState, !viewModel.isPreparingTransaction {
                                MoneyStack(
                                    sats: Int(viewModel.amountAfterFees),
                                    showSymbol: true,
                                    testIdPrefix: "SweepAmount"
                                )
                            } else {
                                MoneyStack(
                                    sats: Int(viewModel.totalBalance),
                                    showSymbol: true,
                                    testIdPrefix: "SweepAmount"
                                )
                                .opacity(0.5)
                            }
                        }

                        Divider()

                        // Destination section
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("sweep__destination"))

                            if let address = viewModel.destinationAddress {
                                BodySSBText(address.ellipsis(maxLength: 20))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                BodySSBText("...")
                                    .opacity(0.5)
                            }
                        }

                        Divider()

                        // Fee section
                        Button(action: {
                            navigation.navigate(.sweepFeeRate)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 8) {
                                    CaptionMText(t("wallet__send_fee_and_speed"))
                                    HStack(spacing: 0) {
                                        Image(viewModel.selectedSpeed.iconName)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .foregroundColor(viewModel.selectedSpeed.iconColor)
                                            .frame(width: 16, height: 16)
                                            .padding(.trailing, 4)

                                        if viewModel.estimatedFee > 0, !viewModel.isPreparingTransaction {
                                            HStack(spacing: 0) {
                                                BodySSBText("\(viewModel.selectedSpeed.displayTitle) (")
                                                MoneyText(sats: Int(viewModel.estimatedFee), size: .bodySSB, symbol: true, symbolColor: .textPrimary)
                                                BodySSBText(")")
                                            }

                                            Image("pencil")
                                                .foregroundColor(.textPrimary)
                                                .frame(width: 12, height: 12)
                                                .padding(.leading, 6)
                                        } else {
                                            BodySSBText(viewModel.selectedSpeed.displayTitle)
                                        }
                                    }
                                }

                                Spacer()

                                VStack(alignment: .leading, spacing: 8) {
                                    CaptionMText(t("wallet__send_confirming_in"))
                                    HStack(spacing: 0) {
                                        Image("clock")
                                            .foregroundColor(.brandAccent)
                                            .frame(width: 16, height: 16)
                                            .padding(.trailing, 4)

                                        BodySSBText(viewModel.selectedSpeed.displayDescription)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        Divider()

                        // Error display
                        if let error = viewModel.errorMessage {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.redAccent)
                                BodyMText(error)
                                    .foregroundColor(.redAccent)
                            }
                            .padding()
                            .background(Color.redAccent.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }

                Spacer()

                // Bottom button area
                if case .broadcasting = viewModel.sweepState {
                    VStack(spacing: 32) {
                        ActivityIndicator(size: 32)
                        CaptionMText(t("sweep__broadcasting"))
                            .foregroundColor(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else if isLoading {
                    VStack(spacing: 32) {
                        ActivityIndicator(size: 32)
                        CaptionMText(t("sweep__preparing"))
                            .foregroundColor(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else if case .ready = viewModel.sweepState, viewModel.destinationAddress != nil {
                    SwipeButton(title: t("sweep__swipe"), accentColor: .greenAccent) {
                        // Check if authentication is required
                        if settings.requirePinForPayments && settings.pinEnabled {
                            if settings.useBiometrics && BiometricAuth.isAvailable {
                                let result = await BiometricAuth.authenticate()
                                switch result {
                                case .success:
                                    break
                                case .cancelled:
                                    throw CancellationError()
                                case let .failed(message):
                                    biometricErrorMessage = message
                                    showingBiometricError = true
                                    throw CancellationError()
                                }
                            } else {
                                showPinCheck = true
                                let shouldProceed = try await waitForPinCheck()
                                if !shouldProceed {
                                    throw CancellationError()
                                }
                            }
                        }

                        // Broadcast the sweep
                        await viewModel.broadcastSweep()

                        if case let .success(result) = viewModel.sweepState {
                            navigation.navigate(.sweepSuccess(txid: result.txid))
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await loadDestinationAddress()
            do {
                try await viewModel.loadFeeEstimates()
            } catch {
                Logger.error("Failed to load fee estimates: \(error)", context: "SweepConfirmView")
                viewModel.errorMessage = error.localizedDescription
            }
            if let address = viewModel.destinationAddress {
                await viewModel.prepareSweep(destinationAddress: address)
            }
        }
        .onChange(of: viewModel.selectedSpeed) { _ in
            Task {
                if let address = viewModel.destinationAddress {
                    await viewModel.prepareSweep(destinationAddress: address)
                }
            }
        }
        .alert(
            t("security__bio_error_title"),
            isPresented: $showingBiometricError
        ) {
            Button(t("common__ok")) {}
        } message: {
            Text(biometricErrorMessage)
        }
        .navigationDestination(isPresented: $showPinCheck) {
            PinCheckView(
                title: t("security__pin_send_title"),
                explanation: t("security__pin_send"),
                onCancel: {
                    pinCheckContinuation?.resume(returning: false)
                    pinCheckContinuation = nil
                },
                onPinVerified: { _ in
                    pinCheckContinuation?.resume(returning: true)
                    pinCheckContinuation = nil
                }
            )
        }
    }

    private func loadDestinationAddress() async {
        isLoadingAddress = true
        do {
            viewModel.destinationAddress = try await LightningService.shared.newAddress()
        } catch {
            Logger.error("Failed to get destination address: \(error)", context: "SweepConfirmView")
            viewModel.errorMessage = t("sweep__error_destination_address")
        }
        isLoadingAddress = false
    }

    private func waitForPinCheck() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            pinCheckContinuation = continuation
        }
    }
}
