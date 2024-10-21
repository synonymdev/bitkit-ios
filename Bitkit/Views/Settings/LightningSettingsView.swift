//
//  LightningSettingsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct LightningSettingsView: View {
    var body: some View {
        List {
            Section("LDK") {
                NavigationLink(destination: NodeStateView()) {
                    Text("Node state")
                }
            }

            Section("Blocktank") {
                Button("Register for notifications") {
                    StartupHandler.requestPushNotificationPermision { _, error in
                        // If granted AppDelegate will receive the token and handle registration
                        if let error {
                            Logger.error(error, context: "Failed to request push notification permission")
                        }
                    }
                }

                Button("Self test") {
                    Task {
                        do {
                            try await BlocktankService.shared.selfTest()
                        } catch {
                            Logger.error(error, context: "Failed to self test")
                        }
                    }
                }

                if let peer = Env.trustedLnPeers.first {
                    Button("Open channel to trusted peer") {
                        Task { @MainActor in
                            do {
                                let _ = try await LightningService.shared.openChannel(
                                    peer: peer,
                                    channelAmountSats: 50000,
                                    pushToCounterpartySats: 10000
                                )
                            } catch {
                                Logger.error(error, context: "Failed to open test channel")
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    LightningSettingsView()
}
