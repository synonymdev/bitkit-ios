import LDKNode
import SwiftUI

struct CloseConnectionConfirmation: View {
    let channel: ChannelDetails

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var app: AppViewModel

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
                CustomButton(
                    title: t("common__cancel"),
                    variant: .secondary,
                    isDisabled: isClosing,
                    shouldExpand: true
                ) {
                    dismiss()
                }

                CustomButton(
                    title: t("lightning__close_button"),
                    isDisabled: isClosing,
                    shouldExpand: true
                ) {
                    Task {
                        await closeChannel()
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private func closeChannel() async {
        isClosing = true

        do {
            // Close the single channel using TransferViewModel
            let failedChannels = try await transfer.closeChannels(channels: [channel])

            if failedChannels.isEmpty {
                // Success - dismiss this view and show success toast
                DispatchQueue.main.async {
                    dismiss()

                    // Show success toast
                    app.toast(
                        type: .success,
                        title: t("lightning__close_success_title"),
                        description: t("lightning__close_success_msg")
                    )
                }
            } else {
                // Failed to close
                app.toast(
                    type: .error,
                    title: t("lightning__close_error"),
                    description: t("lightning__close_error_msg")
                )
            }
        } catch {
            Logger.error("Failed to close channel: \(error)")
            app.toast(
                type: .error,
                title: t("lightning__close_error"),
                description: error.localizedDescription
            )
        }

        isClosing = false
    }
}

#Preview {
    NavigationStack {
        CloseConnectionConfirmation(channel: ChannelDetails.mock())
            .environmentObject(TransferViewModel())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
