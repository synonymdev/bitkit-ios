import SwiftUI

struct BackupSettingsView: View {
    var body: some View {
        List {
            NavigationLink(destination: BackupWalletView()) {
                Label {
                    Text("Back up your wallet")
                } icon: {
                    Image(systemName: "arrow.up.doc")
                }
            }

            NavigationLink(destination: RestoreWalletView()) {
                Label {
                    Text("Reset and restore your wallet")
                } icon: {
                    Image(systemName: "arrow.down.doc")
                }
            }
        }
        .navigationTitle("Back Up Or Restore")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    NavigationView {
        BackupSettingsView()
    }
    .preferredColorScheme(.dark)
}
