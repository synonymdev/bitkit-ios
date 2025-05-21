import SwiftUI

struct FundManualSetupView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var nodeId: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    
    var body: some View {
        ZStack {
            VStack {
                // Header
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    Text(NSLocalizedString("lightning__external__nav_title", comment: ""))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                ScrollView {
                    VStack(spacing: 12) {
                        // Title
                        DisplayText(
                            NSLocalizedString("lightning__external_manual__title", comment: ""),
                            accentColor: .purpleAccent
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Description
                        BodyMText(NSLocalizedString("lightning__external_manual__text", comment: ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                        
                        // Node ID field
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("lightning__external_manual__node_id", comment: ""))
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            TextField("000000000000000000000000000000000000000000000000000000000000", text: $nodeId)
                        }
                        
                        // Host field
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("lightning__external_manual__host", comment: ""))
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            TextField("00.00.00.00", text: $host)
                        }
                        
                        // Port field
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("lightning__external_manual__port", comment: ""))
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            TextField("1234", text: $port)
                        }
                        
                        // Paste Node URI button
                        CustomButton(
                            title: NSLocalizedString("lightning__external_manual__paste", comment: ""),
                            variant: .secondary,
                            size: .small,
                            icon: Image(systemName: "doc.on.clipboard")
                                .foregroundColor(.white),
                            shouldExpand: false
                        ) {
                            // Would implement paste logic here
                        }
                        
                        // Add padding at the bottom for the overlay buttons
                        Spacer()
                            .frame(height: 80)
                    }
                    .padding()
                }
            }
            
            // Fixed bottom buttons overlay
            VStack {
                Spacer()
                
                HStack {
                    // Scan QR button
                    CustomButton(
                        title: NSLocalizedString("lightning__external_manual__scan", comment: ""),
                        variant: .secondary
                    ) {
                        // Would implement scan logic here
                    }
                    
                    // Continue button
                    CustomButton(
                        title: NSLocalizedString("common__continue", comment: ""),
                        isDisabled: nodeId.isEmpty || host.isEmpty || port.isEmpty
                    ) {
                        // Would implement continue logic here
                    }
                }
                .padding()
                .background(Color.black)
            }
        }
        .navigationBarHidden(true)
        .background(Color.black)
    }
}

#Preview {
    NavigationView {
        FundManualSetupView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
