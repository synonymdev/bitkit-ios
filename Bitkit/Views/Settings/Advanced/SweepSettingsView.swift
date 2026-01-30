import BitkitCore
import Lottie
import SwiftUI

struct SweepSettingsView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject private var viewModel: SweepViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navigationTitle)
                .padding(.bottom, 30)

            switch viewModel.checkState {
            case .idle, .checking:
                loadingView
            case .found:
                foundFundsView
            case .noFunds:
                noFundsView
            case let .error(message):
                errorView(message: message)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .task {
            viewModel.reset()
            await viewModel.checkBalance()
        }
    }

    private var navigationTitle: String {
        switch viewModel.checkState {
        case .found:
            return t("sweep__found_title")
        case .noFunds:
            return t("sweep__no_funds_title")
        default:
            return t("sweep__title")
        }
    }

    // MARK: - Loading View

    @ViewBuilder
    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(t("sweep__loading_description"))
                .foregroundColor(.textSecondary)

            Spacer()

            // Magnifying glass image
            Image("magnifying-glass-illustration")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 311, height: 311)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            // Loading indicator
            VStack(spacing: 32) {
                ActivityIndicator(size: 32)

                CaptionMText(t("sweep__looking_for_funds"))
                    .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Found Funds View

    @ViewBuilder
    private var foundFundsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(t("sweep__found_description"))
                .foregroundColor(.textSecondary)
                .padding(.bottom, 24)

            CaptionMText(t("sweep__funds_found"))
                .foregroundColor(.textSecondary)
                .padding(.bottom, 16)

            if let balances = viewModel.sweepableBalances {
                VStack(alignment: .leading, spacing: 0) {
                    if balances.legacyBalance > 0 {
                        fundRow(
                            title: "Legacy (P2PKH)",
                            utxoCount: balances.legacyUtxosCount,
                            balance: balances.legacyBalance
                        )
                    }
                    if balances.p2shBalance > 0 {
                        fundRow(
                            title: "SegWit (P2SH)",
                            utxoCount: balances.p2shUtxosCount,
                            balance: balances.p2shBalance
                        )
                    }
                    if balances.taprootBalance > 0 {
                        fundRow(
                            title: "Taproot (P2TR)",
                            utxoCount: balances.taprootUtxosCount,
                            balance: balances.taprootBalance
                        )
                    }

                    // Total row
                    HStack {
                        TitleText(t("common__total"))
                        Spacer()
                        MoneyText(sats: Int(balances.totalBalance), size: .title, symbol: true, symbolColor: .textPrimary)
                    }
                    .padding(.top, 16)
                }
            }

            Spacer()

            CustomButton(title: t("sweep__sweep_to_wallet")) {
                navigation.navigate(.sweepConfirm)
            }
            .accessibilityIdentifier("SweepToWalletButton")
        }
    }

    @ViewBuilder
    private func fundRow(title: String, utxoCount: UInt32, balance: UInt64) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(title), \(utxoCount) UTXO\(utxoCount == 1 ? "" : "s")")
                    .font(Fonts.semiBold(size: 13))
                    .foregroundColor(.textPrimary)
                Spacer()
                MoneyText(sats: Int(balance), size: .captionB, symbol: true, symbolColor: .textPrimary)
            }
            .padding(.vertical, 16)

            Divider()
                .background(Color.gray5)
        }
    }

    // MARK: - No Funds View

    @ViewBuilder
    private var noFundsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(t("sweep__no_funds_description"))
                .foregroundColor(.textSecondary)

            Spacer()

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 311, height: 311)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            CustomButton(title: t("common__ok")) {
                navigation.navigateBack()
            }
        }
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(.redAccent)

            VStack(spacing: 8) {
                BodyMSBText(t("sweep__error_title"))
                BodyMText(message)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            CustomButton(title: t("common__retry")) {
                Task { await viewModel.checkBalance() }
            }
        }
    }
}
