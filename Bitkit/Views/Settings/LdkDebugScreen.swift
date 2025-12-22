import SwiftUI

struct LdkDebugScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var nodeUri: String = ""
    @State private var showDeleteConfirmation = false
    @State private var isRestartingNode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "LDK Debug")
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    // Add Peer
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Add Peer")

                        TextField("039b8d4d...a8f3eae3@127.0.0.1:9735", text: $nodeUri)

                        HStack(spacing: 8) {
                            CustomButton(title: "Add Peer", size: .small) {
                                Task {
                                    try await addPeer()
                                }
                            }
                            CustomButton(title: "Paste & Add", size: .small) {
                                Task {
                                    try await pasteAndAddPeer()
                                }
                            }
                        }
                    }

                    // Network Graph Storage
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Network Graph Storage")

                        HStack(spacing: 8) {
                            CustomButton(title: "Log Graph Info", size: .small) {
                                Task {
                                    await logNetworkGraphInfo()
                                }
                            }
                        }
                    }

                    // Node
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Node")

                        HStack(spacing: 8) {
                            CustomButton(title: "Restart", size: .small, isLoading: isRestartingNode) {
                                Task {
                                    await restartNode()
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    func addPeer() async throws {
        do {
            let lnPeer = try LnPeer(connection: nodeUri)
            try await wallet.connectPeer(lnPeer)
            app.toast(type: .success, title: "Peer added", description: "Peer added successfully")
        } catch {
            Logger.error(error, context: "LdkDebugScreen")
            app.toast(type: .error, title: "Error", description: "Failed to add peer: \(error.localizedDescription)")
        }
    }

    func pasteAndAddPeer() async throws {
        guard let pastedText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            app.toast(type: .error, title: "Error", description: "Failed to paste text")
            return
        }
        nodeUri = pastedText
        try await addPeer()
    }

    func logNetworkGraphInfo() async {
        do {
            let lightningService = LightningService.shared
            let info = try await lightningService.logNetworkGraphInfo()
            app.toast(type: .info, title: "Network Graph Info", description: info)
        } catch {
            Logger.error("Failed to log network graph info: \(error)")
        }
    }

    func restartNode() async {
        do {
            isRestartingNode = true
            let lightningService = LightningService.shared
            try await lightningService.restart()
            app.toast(type: .success, title: "Node Restarted", description: "Node restarted successfully")
        } catch {
            Logger.error("Failed to restart node: \(error)")
            app.toast(type: .error, title: "Error", description: "Failed to restart node: \(error.localizedDescription)")
        }

        isRestartingNode = false
    }
}
