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
        guard let channelInfo = channelInfo else {
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
            DisplayText(localizedString("other__lnurl_channel_title"), accentColor: .purpleAccent)
                .padding(.top, 32)
                .padding(.bottom, 8)

            BodyMText(localizedString("other__lnurl_channel_message"))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLoadingChannelInfo {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    BodyMText("Loading channel information...", textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if channelInfo != nil {
                CaptionMText(localizedString("other__lnurl_channel_lsp"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 48)
                    .padding(.bottom, 16)

                // Node
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(localizedString("other__lnurl_channel_node"), textColor: .textPrimary)
                        Spacer()
                        CaptionBText(parsedUri.nodeId.ellipsis(maxLength: 16), textColor: .textPrimary)
                    }
                    .frame(height: 50)

                    Divider()
                }

                // Host
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(localizedString("other__lnurl_channel_host"), textColor: .textPrimary)
                        Spacer()
                        CaptionBText(parsedUri.host, textColor: .textPrimary)
                    }
                    .frame(height: 50)

                    Divider()
                }

                // Port
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        CaptionBText(localizedString("other__lnurl_channel_port"), textColor: .textPrimary)
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
                    BodyMText("Failed to load channel information", textColor: .textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: localizedString("common__cancel"),
                    variant: .secondary,
                    size: .large
                ) {
                    onCancel()
                }

                CustomButton(
                    title: localizedString("common__connect"),
                    variant: .primary,
                    size: .large,
                    isDisabled: channelInfo == nil || isLoadingChannelInfo,
                    isLoading: isConnecting
                ) {
                    Task {
                        await onConnect()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("other__lnurl_channel_header"))
        .backToWalletButton()
        .task {
            await fetchChannelInfo()
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

    // Fetch channel information from the LNURL
    private func fetchChannelInfo() async {
        do {
            let channelInfo = try await LnurlHelper.fetchLnurlChannelInfo(url: channelData.uri)

            await MainActor.run {
                self.channelInfo = channelInfo
                self.isLoadingChannelInfo = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingChannelInfo = false
            }
        }
    }
}
