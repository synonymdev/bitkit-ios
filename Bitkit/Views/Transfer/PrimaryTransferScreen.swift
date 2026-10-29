import SwiftUI

/// Transfer to Spending: moves confirmed savings into the channel with the primary node.
struct PrimaryTransferScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var plan: PrimaryFundingPlan?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var hasPrimaryNode: Bool {
        PrimaryNodeService.shared.primaryNode != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("primary_transfer__title"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                if !hasPrimaryNode {
                    BodyMText(t("primary_node__not_configured"))
                } else if let plan {
                    MoneyStack(sats: Int(plan.amountSats))
                        .padding(.bottom, 32)
                    CaptionMText(t("primary_transfer__fee"))
                        .padding(.bottom, 8)
                    MoneyText(sats: Int(plan.feeSats), size: .bodySSB, testIdentifier: "PrimaryTransferFee")
                        .padding(.bottom, 24)
                    BodyMText(t("primary_transfer__note"))
                } else if !isLoading, errorMessage == nil {
                    BodyMText(t("primary_transfer__nothing"))
                }

                if let errorMessage {
                    BodyMText(errorMessage, textColor: .redAccent)
                        .accessibilityIdentifier("PrimaryTransferError")
                        .padding(.top, 16)
                }

                Spacer()

                if !hasPrimaryNode {
                    CustomButton(title: t("primary_node__title")) {
                        navigation.navigate(.primaryNodeSettings)
                    }
                    .accessibilityIdentifier("PrimaryTransferSetUp")
                } else if plan == nil, errorMessage != nil {
                    CustomButton(title: t("common__retry")) {
                        await load()
                    }
                    .accessibilityIdentifier("PrimaryTransferRetry")
                } else {
                    CustomButton(title: t("primary_transfer__confirm"), isDisabled: plan == nil || isLoading, isLoading: isLoading) {
                        await confirm()
                    }
                    .accessibilityIdentifier("PrimaryTransferConfirm")
                }
            }
            .bottomSafeAreaPadding()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PrimaryTransfer")
        .task {
            await load()
        }
    }

    private func load() async {
        guard hasPrimaryNode else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            plan = try await PrimaryNodeService.shared.fundingPlan()
        } catch {
            errorMessage = error.primaryErrorMessage
        }
    }

    private func confirm() async {
        guard let plan else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await PrimaryNodeService.shared.transferToSpending(plan)
            wallet.syncState()
            app.toast(
                type: .success,
                title: t("primary_transfer__started_title"),
                description: t("primary_transfer__started"),
                accessibilityIdentifier: "PrimaryTransferStartedToast"
            )
            navigation.reset()
        } catch {
            errorMessage = error.primaryErrorMessage
        }
    }
}
