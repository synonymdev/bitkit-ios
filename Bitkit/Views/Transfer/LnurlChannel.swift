import BitkitCore
import SwiftUI

struct LnurlChannel: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let channelData: LnurlChannelData

    @State private var isConnecting = false
    @State private var isPeerConnected = false
    @State private var isConnectingPeer = true

    // Parse the node URI to extract node, host, and port
    private var parsedUri: LnPeer {
        parseNodeUri(channelData.uri)
    }

    func parseNodeUri(_ uri: String) -> LnPeer {
        do {
            let lnPeer = try LnPeer(connection: uri)
            return lnPeer
        } catch {
            Logger.error("Failed to parse node URI: \(uri), error: \(error)")
            return LnPeer(nodeId: "", host: "", port: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("other__lnurl_channel_header"))
                .padding(.bottom, 16)

            DisplayText(t("other__lnurl_channel_title"), accentColor: .purpleAccent)
                .padding(.bottom, 8)

            BodyMText(t("other__lnurl_channel_message"))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isConnectingPeer {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    BodyMText("Connecting to peer...", textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if parsedUri.nodeId.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    BodyMText("Failed to parse channel information", textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CaptionMText(t("other__lnurl_channel_lsp"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 48)
                    .padding(.bottom, 16)

                // Node
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(t("other__lnurl_channel_node"), textColor: .textPrimary)
                        Spacer()
                        CaptionBText(parsedUri.nodeId.ellipsis(maxLength: 16), textColor: .textPrimary)
                    }
                    .frame(height: 50)

                    Divider()
                }

                // Host
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(t("other__lnurl_channel_host"), textColor: .textPrimary)
                        Spacer()
                        CaptionBText(parsedUri.host, textColor: .textPrimary)
                    }
                    .frame(height: 50)

                    Divider()
                }

                // Port
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(t("other__lnurl_channel_port"), textColor: .textPrimary)
                        Spacer()
                        CaptionBText(String(parsedUri.port), textColor: .textPrimary)
                    }
                    .frame(height: 50)

                    Divider()
                }
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__cancel"),
                    variant: .secondary,
                    size: .large
                ) {
                    onCancel()
                }

                CustomButton(
                    title: t("common__connect"),
                    variant: .primary,
                    size: .large,
                    isDisabled: parsedUri.nodeId.isEmpty || isConnectingPeer,
                    isLoading: isConnecting
                ) {
                    Task {
                        await onConnect()
                    }
                }
                .accessibilityIdentifier("ConnectButton")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .task {
            await connectToPeer()
        }
    }

    private func onConnect() async {
        guard let nodeId = wallet.nodeId else {
            app.toast(
                type: .error,
                title: "Error",
                description: "Node ID is missing"
            )
            return
        }

        isConnecting = true

        do {
            try await LnurlHelper.handleLnurlChannel(params: channelData, nodeId: nodeId)
            isConnecting = false
            navigation.navigate(.fundManualSuccess)
        } catch {
            isConnecting = false
            app.toast(error)
        }
    }

    private func onCancel() {
        navigation.reset()
    }

    // Connect to the peer before making the channel request
    private func connectToPeer() async {
        // The channelData.uri is the node peer URI (pubkey@host:port)
        guard let peer = try? LnPeer(connection: channelData.uri) else {
            await MainActor.run {
                isConnectingPeer = false
            }
            return
        }

        do {
            try await wallet.connectPeer(peer)
            await MainActor.run {
                isPeerConnected = true
                isConnectingPeer = false
            }
        } catch {
            Logger.error(error, context: "Failed to connect LNURL peer")
            await MainActor.run {
                // Still allow the user to try connecting - peer might already be connected
                isConnectingPeer = false
            }
        }
    }
}
