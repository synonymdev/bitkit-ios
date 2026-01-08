import SwiftUI

struct SweepFeeCustomView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject private var viewModel: SweepViewModel

    @State private var feeRate: UInt32 = 1
    @State private var transactionFee: UInt64 = 0

    private let minFee: UInt32 = 1
    private let maxFee: UInt32 = 999

    private var isValid: Bool {
        feeRate >= minFee && feeRate <= maxFee
    }

    private var estimatedTxVbytes: UInt64 {
        viewModel.transactionPreview?.estimatedVsize ?? 0
    }

    private var totalFeeText: String {
        let fee = UInt64(feeRate) * estimatedTxVbytes
        return "\(fee) sats total fee"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("wallet__send_fee_custom"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("common__sat_vbyte"))
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)

                HStack {
                    MoneyText(sats: Int(feeRate), symbol: true, color: feeRate == 0 ? .textSecondary : .textPrimary)
                }
                .padding(.bottom, 16)
                .padding(.horizontal, 16)

                if isValid {
                    BodyMText(totalFeeText)
                        .padding(.bottom, 32)
                        .padding(.horizontal, 16)
                }

                Spacer()

                NumberPad { key in
                    handleNumberPadInput(key)
                }
                .padding(.horizontal, 16)

                CustomButton(title: t("common__continue")) {
                    onContinue()
                }
                .disabled(!isValid)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
        .task {
            initializeFromCurrentFee()
        }
    }

    private func initializeFromCurrentFee() {
        // Get current custom rate if set, otherwise use default
        if case let .custom(rate) = viewModel.selectedSpeed {
            feeRate = rate
        } else if let rates = viewModel.feeRates {
            feeRate = viewModel.selectedSpeed.getFeeRate(from: rates)
        } else {
            feeRate = viewModel.selectedFeeRate
        }
    }

    private func handleNumberPadInput(_ key: String) {
        let current = String(feeRate)

        if key == "delete" {
            if current.count > 1 {
                let newString = String(current.dropLast())
                feeRate = UInt32(newString) ?? 0
            } else {
                feeRate = 0
            }
        } else {
            let newString: String = if current == "0" {
                key
            } else {
                current + key
            }

            // Limit to 3 digits (max 999 sat/vB)
            if newString.count <= 3, let newRate = UInt32(newString) {
                feeRate = newRate
            }
        }
    }

    private func onContinue() {
        guard isValid else { return }

        Task {
            await viewModel.setFeeRate(speed: .custom(satsPerVByte: feeRate))
            viewModel.selectedFeeRate = feeRate
            navigation.navigateBack()
        }
    }
}
