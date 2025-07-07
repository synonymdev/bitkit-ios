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
            VStack(spacing: 16) {
                BodyMText(
                    NSLocalizedString("lightning__close_text", comment: ""),
                    textColor: .textSecondary
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)

            Spacer()

            // Warning illustration
            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 274, height: 274)
                .padding(.top, 32)

            Spacer()

            // Bottom buttons
            HStack(spacing: 16) {
                CustomButton(
                    title: NSLocalizedString("common__cancel", comment: ""),
                    variant: .secondary,
                    isDisabled: isClosing,
                    shouldExpand: true
                ) {
                    dismiss()
                }

                CustomButton(
                    title: NSLocalizedString("lightning__close_button", comment: ""),
                    variant: .primary,
                    isDisabled: isClosing,
                    shouldExpand: true
                ) {
                    Task {
                        await closeChannel()
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .navigationTitle(NSLocalizedString("lightning__close_conn", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func closeChannel() async {
        isClosing = true

        do {
            // Close the single channel using TransferViewModel
            let failedChannels = try await transfer.closeChannels(channels: [channel])

            if failedChannels.isEmpty {
                // Success - dismiss this view and show success toast
                DispatchQueue.main.async {
                    self.dismiss()

                    // Show success toast
                    self.app.toast(
                        type: .success,
                        title: NSLocalizedString("lightning__close_success_title", comment: ""),
                        description: NSLocalizedString("lightning__close_success_msg", comment: "")
                    )
                }
            } else {
                // Failed to close
                app.toast(
                    type: .error,
                    title: NSLocalizedString("lightning__close_error", comment: ""),
                    description: NSLocalizedString("lightning__close_error_msg", comment: "")
                )
            }
        } catch {
            Logger.error("Failed to close channel: \(error)")
            app.toast(
                type: .error,
                title: NSLocalizedString("lightning__close_error", comment: ""),
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
