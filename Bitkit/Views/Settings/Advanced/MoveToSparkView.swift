import LDKNode
import SwiftUI

/// Moves the channels' balance to the user's Spark wallet over Lightning, then offers to close the emptied channel.
struct MoveToSparkView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @State private var manager = MoveToSparkManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__move_to_spark__nav_title"))
                .padding(.bottom, 16)

            switch manager.state {
            case .quoting:
                quoting
            case let .confirm(quote, isMoving):
                confirm(quote: quote, isMoving: isMoving)
            case let .done(amountSats, feeSats, closeChannel, hasRest):
                done(amountSats: amountSats, feeSats: feeSats, closeChannel: closeChannel, hasRest: hasRest)
            case let .inFlight(amountSats):
                inFlight(amountSats: amountSats)
            case let .tooLarge(amountSats, smallerSats):
                tooLarge(amountSats: amountSats, smallerSats: smallerSats)
            case let .failed(failure):
                failed(failure)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await manager.start(wallet: wallet)
        }
        .onDisappear {
            // Unlocking rebuilds the screen with the route still in the path; only leaving it ends the move.
            if !navigation.path.contains(.moveToSpark) {
                manager.reset()
            }
        }
    }

    private func header(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText(title, accentColor: .purpleAccent)
                .fixedSize(horizontal: false, vertical: true)
            BodyMText(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func illustration(_ name: String) -> some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 256, maxHeight: 256)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
    }

    private var quoting: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: t("lightning__move_to_spark__confirm_title"), text: t("lightning__move_to_spark__quoting"))
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func confirm(quote: MoveToSparkQuote, isMoving: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: t("lightning__move_to_spark__confirm_title"), text: t("lightning__move_to_spark__confirm_text"))
                .padding(.bottom, 32)
            MoveToSparkAmountRow(label: t("lightning__move_to_spark__amount"), sats: quote.amountSats)
                .accessibilityIdentifier("MoveToSparkAmount")
            MoveToSparkAmountRow(label: t("lightning__move_to_spark__fee"), sats: quote.feeSats)
                .accessibilityIdentifier("MoveToSparkFee")
            illustration("lightning")
            SwipeButton(title: t("lightning__move_to_spark__swipe"), accentColor: .purpleAccent, isLoading: isMoving) {
                await manager.move(wallet: wallet)
            }
            .accessibilityIdentifier("MoveToSparkSwipe")
        }
    }

    private func done(amountSats: UInt64, feeSats: UInt64, closeChannel: ChannelDetails?, hasRest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                title: t("lightning__move_to_spark__done_title"),
                text: hasRest ? t("lightning__move_to_spark__done_rest_text") : t("lightning__move_to_spark__done_text")
            )
            .padding(.bottom, 32)
            MoveToSparkAmountRow(label: t("lightning__move_to_spark__amount"), sats: amountSats)
                .accessibilityIdentifier("MoveToSparkMoved")
            MoveToSparkAmountRow(label: t("lightning__move_to_spark__fee"), sats: feeSats)
                .accessibilityIdentifier("MoveToSparkFeePaid")
            illustration("check")
            HStack(spacing: 16) {
                CustomButton(title: t("common__later"), variant: .secondary) {
                    navigation.navigateBack()
                }
                if hasRest {
                    CustomButton(title: t("lightning__move_to_spark__move_rest")) {
                        await manager.quote(wallet: wallet)
                    }
                    .accessibilityIdentifier("MoveToSparkMoveRest")
                } else {
                    CustomButton(title: t("common__close")) {
                        // Closing returns to Lightning Connections through the channel's detail, as a close from there does.
                        navigation.navigateBack()
                        if navigation.path.last != .connections {
                            navigation.navigate(.connections)
                        }
                        if let closeChannel {
                            navigation.navigate(.connectionDetail(channelId: closeChannel.channelIdString))
                            navigation.navigate(.closeConnection(channel: closeChannel))
                        }
                    }
                    .accessibilityIdentifier("MoveToSparkClose")
                }
            }
        }
    }

    /// While the payment is in flight its amount may still return to the channel, so closing is not offered yet.
    private func inFlight(amountSats: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: t("lightning__move_to_spark__in_flight_title"), text: t("lightning__move_to_spark__in_flight_text"))
                .padding(.bottom, 32)
            MoveToSparkAmountRow(label: t("lightning__move_to_spark__amount"), sats: amountSats)
                .accessibilityIdentifier("MoveToSparkMoved")
            illustration("lightning")
            CustomButton(title: t("common__ok")) {
                navigation.navigateBack()
            }
            .accessibilityIdentifier("MoveToSparkInFlightOk")
        }
    }

    private func tooLarge(amountSats: UInt64, smallerSats: UInt64?) -> some View {
        let next = smallerSats == nil ? t("lightning__move_to_spark__too_large_none") : t("lightning__move_to_spark__too_large_smaller")
        let amount = t("lightning__move_to_spark__too_large_text", variables: ["amount": currency.primaryAmountText(sats: amountSats)])
        return VStack(alignment: .leading, spacing: 0) {
            header(title: t("lightning__move_to_spark__too_large_title"), text: "\(amount) \(next)")
            illustration("exclamation-mark")
            if let smallerSats {
                HStack(spacing: 16) {
                    CustomButton(title: t("common__cancel"), variant: .secondary) {
                        navigation.navigateBack()
                    }
                    CustomButton(title: t("lightning__move_to_spark__move_half")) {
                        await manager.quote(wallet: wallet, targetSats: smallerSats)
                    }
                    .accessibilityIdentifier("MoveToSparkTrySmaller")
                }
            } else {
                CustomButton(title: t("common__back")) {
                    navigation.navigateBack()
                }
            }
        }
    }

    private func failed(_ failure: MoveToSparkFailure) -> some View {
        let text = switch failure {
        case .nothingToMove: t("lightning__move_to_spark__failed_nothing")
        case .sparkUnavailable: t("lightning__move_to_spark__failed_spark")
        case .unknown: t("lightning__move_to_spark__failed_unknown")
        }
        return VStack(alignment: .leading, spacing: 0) {
            header(title: t("lightning__move_to_spark__failed_title"), text: text)
            illustration("cross")
            if failure == .nothingToMove {
                CustomButton(title: t("common__back")) {
                    navigation.navigateBack()
                }
            } else {
                HStack(spacing: 16) {
                    CustomButton(title: t("common__cancel"), variant: .secondary) {
                        navigation.navigateBack()
                    }
                    CustomButton(title: t("common__try_again")) {
                        await manager.quote(wallet: wallet)
                    }
                    .accessibilityIdentifier("MoveToSparkRetry")
                }
            }
        }
    }
}

/// A labelled amount, as the Move to Spark screens list the amount and its routing fee.
struct MoveToSparkAmountRow: View {
    let label: String
    let sats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                CaptionBText(label, textColor: .textPrimary)
                Spacer()
                MoneyText(sats: Int(sats), size: .captionB, symbol: true)
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}
