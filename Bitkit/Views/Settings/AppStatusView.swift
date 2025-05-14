import SwiftUI

struct AppStatusView: View {
    @EnvironmentObject private var wallet: WalletViewModel
    
    var body: some View {
        List {
            // Internet status
            StatusItemView(
                icon: "globe",
                iconBackgroundColor: .green16,
                iconColor: .greenAccent,
                title: NSLocalizedString("settings__status__internet__title", comment: ""),
                status: NSLocalizedString("settings__status__internet__ready", comment: ""),
                statusColor: .greenAccent,
                animateIcon: false,
                animateOpacity: false
            )
            
            // // Bitcoin Node status
            // StatusItemView(
            //     icon: "bitcoin-symbol",
            //     iconBackgroundColor: getStatusBackgroundColor(wallet.nodeLifecycleState),
            //     iconColor: wallet.nodeLifecycleState.statusColor,
            //     title: NSLocalizedString("settings__status__electrum__title", comment: ""),
            //     status: getBitcoinNodeStatus(),
            //     statusColor: wallet.nodeLifecycleState.statusColor,
            //     animateIcon: isStatusPending(wallet.nodeLifecycleState),
            //     animateOpacity: isStatusError(wallet.nodeLifecycleState)
            // )
            
            // // Lightning Node status
            // StatusItemView(
            //     icon: "radio-waves",
            //     iconBackgroundColor: getStatusBackgroundColor(wallet.nodeLifecycleState),
            //     iconColor: wallet.nodeLifecycleState.statusColor,
            //     title: NSLocalizedString("settings__status__lightning_node__title", comment: ""),
            //     status: getLightningNodeStatus(),
            //     statusColor: wallet.nodeLifecycleState.statusColor,
            //     animateIcon: isStatusPending(wallet.nodeLifecycleState),
            //     animateOpacity: isStatusError(wallet.nodeLifecycleState)
            // )
            
            // Lightning Connection status
            lightningConnectionStatusView
        }
        .navigationTitle(NSLocalizedString("settings__status__title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .listStyle(PlainListStyle())
        .onAppear {
            wallet.syncState()
        }
    }
    
    private var lightningConnectionStatusView: some View {
        let hasChannels = (wallet.channelCount > 0)
        let hasUsableChannels = wallet.channels?.contains(where: { $0.isUsable }) ?? false
        
        let connectionColor: Color = {
            if !hasChannels {
                return .redAccent
            } else if hasUsableChannels {
                return .greenAccent
            } else {
                return .yellowAccent
            }
        }()
        
        let iconBackgroundColor: Color = {
            if !hasChannels {
                return .red16
            } else if hasUsableChannels {
                return .green16
            } else {
                return .yellow16
            }
        }()
        
        let connectionStatus: String = {
            if !hasChannels {
                return NSLocalizedString("settings__status__lightning_connection__error", comment: "")
            } else if hasUsableChannels {
                return NSLocalizedString("settings__status__lightning_connection__ready", comment: "")
            } else {
                return NSLocalizedString("settings__status__lightning_connection__pending", comment: "")
            }
        }()
        
        return StatusItemView(
            icon: "lightning-bolt",
            iconBackgroundColor: iconBackgroundColor,
            iconColor: connectionColor,
            title: NSLocalizedString("settings__status__lightning_connection__title", comment: ""),
            status: connectionStatus,
            statusColor: connectionColor,
            animateIcon: hasChannels && !hasUsableChannels,
            animateOpacity: !hasUsableChannels
        )
    }
}

struct StatusItemView: View {
    let icon: String
    let iconBackgroundColor: Color
    let iconColor: Color
    let title: String
    let status: String
    let statusColor: Color
    let animateIcon: Bool
    let animateOpacity: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: icon, 
                iconColor: iconColor,
                backgroundColor: iconBackgroundColor,
                size: 40
            )
            
            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(title)
                CaptionText(status)
            }
            
            Spacer()
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.black)
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.white.opacity(0.1))
    }
}

#Preview {
    NavigationView {
        AppStatusView()
            .environmentObject(WalletViewModel())
    }
} 
