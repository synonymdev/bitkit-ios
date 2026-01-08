import BitkitCore
import SwiftUI

struct SweepFeeRateView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject private var viewModel: SweepViewModel

    @State private var isLoading = true

    private var estimatedTxVbytes: UInt64 {
        viewModel.transactionPreview?.estimatedVsize ?? 0
    }

    private func getFee(for speed: TransactionSpeed) -> UInt64 {
        let feeRate: UInt32
        switch speed {
        case let .custom(rate):
            feeRate = rate
        default:
            guard let rates = viewModel.feeRates else { return 0 }
            feeRate = speed.getFeeRate(from: rates)
        }
        return UInt64(feeRate) * estimatedTxVbytes
    }

    private func getAmountAfterFee(for speed: TransactionSpeed) -> UInt64 {
        let fee = getFee(for: speed)
        let total = viewModel.totalBalance
        return total > fee ? total - fee : 0
    }

    private func isDisabled(for speed: TransactionSpeed) -> Bool {
        let fee = getFee(for: speed)
        let totalBalance = viewModel.totalBalance
        // Disable if fee would consume entire balance (leave at least some dust)
        return fee >= totalBalance
    }

    private func selectFee(_ speed: TransactionSpeed) {
        Task {
            await viewModel.setFeeRate(speed: speed)
            navigation.navigateBack()
        }
    }

    private var currentCustomFeeRate: UInt32 {
        if case let .custom(rate) = viewModel.selectedSpeed {
            return rate
        }
        return viewModel.selectedFeeRate
    }

    private var isCustomSelected: Bool {
        if case .custom = viewModel.selectedSpeed {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("wallet__send_fee_speed"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__send_fee_and_speed"))
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                        Spacer()
                    }
                    .padding(.top, 32)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            FeeItem(
                                speed: .fast,
                                amount: getFee(for: .fast),
                                isSelected: viewModel.selectedSpeed == .fast,
                                isDisabled: isDisabled(for: .fast)
                            ) {
                                selectFee(.fast)
                            }

                            FeeItem(
                                speed: .normal,
                                amount: getFee(for: .normal),
                                isSelected: viewModel.selectedSpeed == .normal,
                                isDisabled: isDisabled(for: .normal)
                            ) {
                                selectFee(.normal)
                            }

                            FeeItem(
                                speed: .slow,
                                amount: getFee(for: .slow),
                                isSelected: viewModel.selectedSpeed == .slow,
                                isDisabled: isDisabled(for: .slow)
                            ) {
                                selectFee(.slow)
                            }

                            // Custom fee option
                            FeeItem(
                                speed: .custom(satsPerVByte: currentCustomFeeRate),
                                amount: getFee(for: .custom(satsPerVByte: currentCustomFeeRate)),
                                isSelected: isCustomSelected,
                                isDisabled: false
                            ) {
                                navigation.navigate(.sweepFeeCustom)
                            }
                        }
                    }
                }

                Spacer()

                CustomButton(title: t("common__continue")) {
                    navigation.navigateBack()
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
        .task {
            await loadFeeEstimates()
        }
    }

    private func loadFeeEstimates() async {
        isLoading = true
        await viewModel.loadFeeEstimates()
        isLoading = false
    }
}
