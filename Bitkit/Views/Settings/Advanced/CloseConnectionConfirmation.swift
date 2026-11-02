import LDKNode
import SwiftUI

struct CloseConnectionConfirmation: View {
    let channel: ChannelDetails

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isClosing = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__close_conn"))
                .padding(.bottom, 16)

            BodyMText(t("lightning__close_text"), accentFont: Fonts.bold)

            Spacer()

            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 274, height: 274)
                .padding(.top, 32)

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary, isDisabled: isClosing) {
                    dismiss()
                }

                CustomButton(title: t("lightning__close_button"), isDisabled: isClosing) {
                    Task {
                        await closeChannel()
                    }
                }
                .accessibilityIdentifier("CloseConnectionButton")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    @MainActor
    private func closeChannel() async {
        let expectedPath = navigation.path
        isClosing = true

        do {
            // Close the single channel using TransferViewModel
            let failedChannels = try await transfer.closeChannels(channels: [channel])

            if failedChannels.isEmpty {
                DispatchQueue.main.async {
                    navigation.returnToConnectionsAfterClosing(channelId: channel.channelIdString, from: expectedPath)

                    app.toast(
                        type: .success,
                        title: t("lightning__close_success_title"),
                        description: t("lightning__close_success_msg")
                    )
                }
            } else {
                // Failed to close - check if we can force close
                DispatchQueue.main.async {
                    dismiss()

                    app.toast(
                        type: .error,
                        title: t("lightning__close_error"),
                        description: t("lightning__close_error_msg")
                    )

                    // Store the failed channels for force close
                    transfer.channelsToClose = failedChannels

                    // Show force transfer sheet
                    sheets.showSheet(.forceTransfer)
                }
            }
        } catch {
            Logger.error("Failed to close channel: \(error)")

            // On error, check if we can force close
            DispatchQueue.main.async {
                dismiss()

                app.toast(
                    type: .error,
                    title: t("lightning__close_error"),
                    description: error.localizedDescription
                )

                // Store the channel for force close
                transfer.channelsToClose = [channel]

                // Show force transfer sheet
                sheets.showSheet(.forceTransfer)
            }
        }

        isClosing = false
    }
}

#Preview {
    NavigationStack {
        CloseConnectionConfirmation(channel: ChannelDetails.mock())
            .environmentObject(TransferViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(SheetViewModel())
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
