import BitkitCore
import SwiftUI

struct SpendingConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    @State private var isPaying = false
    @State private var hideSwipeButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

            if let order = transfer.uiState.order {
                VStack(spacing: 24) {
                    HStack {
                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__network_fee"),
                            amount: order.networkFeeSat
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__lsp_fee"),
                            amount: order.serviceFeeSat
                        )
                        .frame(maxWidth: .infinity)
                    }

                    HStack {
                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__amount"),
                            amount: order.clientBalanceSat
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__total"),
                            amount: order.feeSat
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 32)
                .padding(.bottom, 16)

                if transfer.uiState.isAdvanced {
                    LightningChannel(
                        capacity: order.lspBalanceSat + order.clientBalanceSat,
                        localBalance: order.clientBalanceSat,
                        remoteBalance: order.lspBalanceSat,
                        status: .open,
                        showLabels: true
                    )
                    .padding(.bottom, 16)
                }

                HStack(spacing: 16) {
                    CustomButton(title: t("common__learn_more"), size: .small) {
                        navigation.navigate(.transferLearnMore(order: order))
                    }

                    if transfer.uiState.isAdvanced {
                        CustomButton(title: t("lightning__spending_confirm__default"), size: .small) {
                            transfer.onDefaultClick()
                        }
                    } else {
                        CustomButton(title: t("common__advanced"), size: .small) {
                            navigation.navigate(.spendingAdvanced(order: order))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                if !hideSwipeButton {
                    SwipeButton(
                        title: t("lightning__transfer__swipe"),
                        accentColor: .purpleAccent
                    ) {
                        isPaying = true
                        do {
                            try await transfer.payOrder(order: order, speed: .fast)

                            try await Task.sleep(nanoseconds: 1_000_000_000)

                            navigation.navigate(.settingUp)

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                hideSwipeButton = true
                            }
                        } catch {
                            app.toast(error)
                            isPaying = false
                        }
                        isPaying = false
                    }
                    .disabled(isPaying)
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

private struct SpendingDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            BodySText(label, textColor: .textSecondary)
            Spacer()
            BodySText(value)
        }
    }
}

#Preview {
    NavigationStack {
        SpendingConfirm()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    vm.onOrderCreated(order: IBtOrder.mock())
                    return vm
                }()
            )
    }
    .preferredColorScheme(.dark)
}
