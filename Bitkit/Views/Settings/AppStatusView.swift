import SwiftUI

struct AppStatusView: View {
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        List {
            internetStatusView
            lightningNodeStatusView
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
    
    private var internetStatusView: some View {
        let isConnected = app.networkStatus == .wifi || app.networkStatus == .cellular
        let imageName = isConnected ? "status-internet-green" : "status-internet-red"
        let iconBackgroundColor: Color = isConnected ? .green16 : .red16
        let iconColor: Color = isConnected ? .greenAccent : .redAccent
        let status = isConnected ? NSLocalizedString("settings__status__internet__ready", comment: "Connected") : NSLocalizedString("settings__status__internet__error", comment: "Disconnected")
        let statusColor: Color = isConnected ? .greenAccent : .redAccent
        
        return StatusItemView(
            imageName: imageName,
            iconBackgroundColor: iconBackgroundColor,
            iconColor: iconColor,
            title: NSLocalizedString("settings__status__internet__title", comment: ""),
            status: status,
            statusColor: statusColor
        )
    }
    
    private var lightningNodeStatusView: some View {
        let iconName: String = {
            switch wallet.nodeLifecycleState.statusColor {
            case .greenAccent:
                return "status-node-green"
            case .yellowAccent:
                return "status-node-yellow"
            case .redAccent:
                return "status-node-red"
            default:
                return "status-node-red"
            }
        }()
        
        return StatusItemView(
             imageName: iconName,
             iconBackgroundColor: .green16,
             iconColor: wallet.nodeLifecycleState.statusColor,
             title: NSLocalizedString("settings__status__lightning_node__title", comment: ""),
             status: wallet.nodeLifecycleState.displayState,
             statusColor: wallet.nodeLifecycleState.statusColor
         )
    }
    
    private var lightningConnectionStatusView: some View {
        let hasChannels = (wallet.channelCount > 0)
        let hasUsableChannels = wallet.channels?.contains(where: { $0.isUsable }) ?? false
        let hasReadyChannels = wallet.channels?.contains(where: { $0.isChannelReady }) ?? false

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
        
        let imageName: String = {
            if !hasChannels {
                return "status-lightning-red"
            } else if hasUsableChannels {
                return "status-lightning-green"
            } else {
                return "status-lightning-yellow"
            }
        }()
        
        let connectionStatus: String = {
            if !hasChannels {
                return NSLocalizedString("settings__status__lightning_connection__error", comment: "")
            } else if hasUsableChannels && hasReadyChannels {
                return NSLocalizedString("settings__status__lightning_connection__ready", comment: "")
            } else if !hasUsableChannels && hasReadyChannels {
                return NSLocalizedString("settings__status__lightning_connection__pending", comment: "")
            } else {
                return NSLocalizedString("settings__status__lightning_connection__ready", comment: "")
            }
        }()
        
        return StatusItemView(
            imageName: imageName,
            iconBackgroundColor: iconBackgroundColor,
            iconColor: connectionColor,
            title: NSLocalizedString("settings__status__lightning_connection__title", comment: ""),
            status: connectionStatus,
            statusColor: connectionColor,
        )
    }
}

struct StatusItemView: View {
    let imageName: String
    let iconBackgroundColor: Color
    let iconColor: Color
    let title: String
    let status: String
    let statusColor: Color
    
    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: imageName, 
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
