import SwiftUI

struct MoveToSparkSheetItem: SheetItem {
    let id: SheetID = .moveToSpark
    let size: SheetSize = .large
}

/// The Update Spending Balance modal: quotes moving the channels' balance to Spark when it opens, moves it on Update and
/// reports the outcome in place, from Spending Balance Updated to the states that need another step.
struct MoveToSparkSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var transfer: TransferViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @State private var manager = MoveToSparkManager.shared
    let config: MoveToSparkSheetItem

    /// On every state's dismiss button, so tests can close the modal in whichever state it opened.
    private static let dismissId = "UpdateSpendingBalanceDismiss"

    var body: some View {
        Sheet(id: .moveToSpark, data: config) {
            content
                .task {
                    await manager.start(wallet: wallet)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .quoting:
            update(feeSats: nil, isLoading: true)
        case let .confirm(quote, isMoving):
            update(feeSats: quote.feeSats, isLoading: isMoving)
        case let .done(_, _, hasRest):
            done(hasRest: hasRest)
        case .inFlight:
            modal(
                navTitle: t("lightning__move_to_spark__update_nav_title"),
                image: "lightning",
                title: t("lightning__move_to_spark__in_flight_title"),
                text: t("lightning__move_to_spark__in_flight_text"),
                id: "MoveToSparkInFlight"
            ) {
                dismissButton(t("common__ok"))
            }
        case let .tooLarge(amountSats, smallerSats):
            tooLarge(amountSats: amountSats, smallerSats: smallerSats)
        case let .failed(failure):
            failed(failure)
        }
    }

    private func update(feeSats: UInt64?, isLoading: Bool) -> some View {
        let text = t("lightning__move_to_spark__update_text")
        let fee = feeSats.map {
            t("lightning__move_to_spark__update_fee", variables: ["fee": currency.primaryAmountText(sats: $0)])
        }
        return modal(
            navTitle: t("lightning__move_to_spark__update_nav_title"),
            image: "lightning",
            title: t("lightning__move_to_spark__update_title"),
            text: fee.map { "\(text) <accent>\($0)</accent>" } ?? text,
            id: "UpdateSpendingBalance"
        ) {
            CustomButton(title: t("common__later"), variant: .secondary, shouldExpand: true) {
                sheets.hideSheet()
            }
            .accessibilityIdentifier("UpdateSpendingBalanceLater")
            CustomButton(
                title: t("lightning__move_to_spark__update"),
                isDisabled: isLoading,
                isLoading: isLoading,
                shouldExpand: true
            ) {
                await manager.move(wallet: wallet, transfer: transfer)
            }
            .accessibilityIdentifier("UpdateSpendingBalanceUpdate")
        }
    }

    @ViewBuilder
    private func done(hasRest: Bool) -> some View {
        if hasRest {
            modal(
                navTitle: t("lightning__move_to_spark__update_nav_title"),
                image: "check",
                title: t("lightning__move_to_spark__done_title"),
                text: t("lightning__move_to_spark__updated_rest_text"),
                id: "MoveToSparkPartlyMoved"
            ) {
                dismissButton(t("common__later"), variant: .secondary)
                CustomButton(title: t("lightning__move_to_spark__move_rest"), shouldExpand: true) {
                    await manager.quote(wallet: wallet)
                }
                .accessibilityIdentifier("MoveToSparkMoveRest")
            }
        } else {
            modal(
                navTitle: t("lightning__move_to_spark__updated_nav_title"),
                image: "check",
                title: t("lightning__move_to_spark__updated_title"),
                text: t("lightning__move_to_spark__updated_text"),
                id: "SpendingBalanceUpdated"
            ) {
                CustomButton(title: t("common__ok"), shouldExpand: true) {
                    sheets.hideSheet()
                }
                .accessibilityIdentifier("SpendingBalanceUpdatedOk")
            }
        }
    }

    private func tooLarge(amountSats: UInt64, smallerSats: UInt64?) -> some View {
        let next = smallerSats == nil ? t("lightning__move_to_spark__too_large_none") : t("lightning__move_to_spark__too_large_smaller")
        let amount = t(
            "lightning__move_to_spark__too_large_text",
            variables: ["amount": "<accent>\(currency.primaryAmountText(sats: amountSats))</accent>"]
        )
        return modal(
            navTitle: t("lightning__move_to_spark__update_nav_title"),
            image: "exclamation-mark",
            title: t("lightning__move_to_spark__too_large_title"),
            text: "\(amount) \(next)",
            id: "MoveToSparkTooLarge"
        ) {
            if let smallerSats {
                dismissButton(t("common__cancel"), variant: .secondary)
                CustomButton(title: t("lightning__move_to_spark__move_half"), shouldExpand: true) {
                    await manager.quote(wallet: wallet, targetSats: smallerSats)
                }
                .accessibilityIdentifier("MoveToSparkTrySmaller")
            } else {
                dismissButton(t("common__ok"))
            }
        }
    }

    private func failed(_ failure: MoveToSparkFailure) -> some View {
        let text = switch failure {
        case .nothingToMove: t("lightning__move_to_spark__failed_nothing")
        case .sparkUnavailable: t("lightning__move_to_spark__failed_spark")
        case .unknown: t("lightning__move_to_spark__failed_unknown")
        }
        return modal(
            navTitle: t("lightning__move_to_spark__update_nav_title"),
            image: "cross",
            title: t("lightning__move_to_spark__failed_title"),
            text: text,
            id: "MoveToSparkFailed"
        ) {
            if failure == .nothingToMove {
                dismissButton(t("common__ok"))
            } else {
                dismissButton(t("common__cancel"), variant: .secondary)
                CustomButton(title: t("common__try_again"), shouldExpand: true) {
                    await manager.quote(wallet: wallet)
                }
                .accessibilityIdentifier("MoveToSparkRetry")
            }
        }
    }

    private func dismissButton(_ title: String, variant: CustomButton.Variant = .primary) -> some View {
        CustomButton(title: title, variant: variant, shouldExpand: true) {
            sheets.hideSheet()
        }
        .accessibilityIdentifier(Self.dismissId)
    }

    private func modal(
        navTitle: String,
        image: String,
        title: String,
        text: String,
        id: String,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: navTitle)
            // The illustration shrinks on small screens so the copy below it stays whole.
            Image(image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 256, maxHeight: 256)
                .scaleEffect(Self.illustrationScale(image))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                DisplayText(title, accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)
                BodyMText(text, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 32)
            .layoutPriority(1)
            let buttonLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 16))
            buttonLayout {
                buttons()
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    /// Scales each illustration so its drawing fills its box like the zap; the others have wider transparent margins.
    private static func illustrationScale(_ name: String) -> CGFloat {
        switch name {
        case "check": 1.25
        case "cross": 1.4
        case "exclamation-mark": 1.1
        default: 1
        }
    }
}
