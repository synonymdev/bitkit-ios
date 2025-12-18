import BitkitCore
import SwiftUI

struct LnurlChannel: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let channelData: LnurlChannelData

    @State private var channelInfo: LnurlChannelData?
    @State private var isConnecting = false
    @State private var isLoadingChannelInfo = true

    // Parse the node URI to extract node, host, and port
    private var parsedUri: LnPeer {
        guard let channelInfo else {
            return LnPeer(nodeId: "", host: "", port: 0)
        }

        return parseNodeUri(channelInfo.uri)
    }

    func parseNodeUri(_ uri: String) -> LnPeer {
        do {
            let lnPeer = try LnPeer(connection: uri)
            return lnPeer
        } catch {
            app.toast(error)
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

            if isLoadingChannelInfo {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    BodyMText(t("other__lnurl_channel_loading"), textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if channelInfo != nil {
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
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    BodyMText(t("other__lnurl_channel_load_failed"), textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    isDisabled: channelInfo == nil || isLoadingChannelInfo,
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
            await fetchChannelInfo()
        }
    }

    private func onConnect() async {
        guard let nodeId = wallet.nodeId else {
            app.toast(
                type: .error,
                title: t("common__error"),
                description: t("other__lnurl_channel_node_id_missing")
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

    // Fetch channel information from the LNURL
    private func fetchChannelInfo() async {
        do {
            let channelInfo = try await LnurlHelper.fetchLnurlChannelInfo(url: channelData.uri)

            await MainActor.run {
                self.channelInfo = channelInfo
                isLoadingChannelInfo = false
            }

            await connectToPeerIfNeeded(channelInfo: channelInfo)
        } catch {
            await MainActor.run {
                isLoadingChannelInfo = false
            }
        }
    }

    private func connectToPeerIfNeeded(channelInfo: LnurlChannelData) async {
        guard let peer = try? LnPeer(connection: channelInfo.uri) else {
            return
        }

        do {
            try await wallet.connectPeer(peer)
        } catch {
            Logger.error(error, context: "Failed to connect LNURL peer")
        }
    }
}
