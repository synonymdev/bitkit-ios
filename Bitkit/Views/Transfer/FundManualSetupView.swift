import SwiftUI

struct FundManualSetupView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let initialNodeUri: String?

    @State private var nodeId: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var alertTitle: String = ""

    init(initialNodeUri: String? = nil) {
        self.initialNodeUri = initialNodeUri
    }

    // Test URI: 028a8910b0048630d4eb17af25668cdd7ea6f2d8ae20956e7a06e2ae46ebcb69fc@34.65.86.104:9400
    func pasteLightningNodeUri() {
        guard let pastedText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            alertTitle = NSLocalizedString("wallet__send_clipboard_empty_title", comment: "")
            alertMessage = NSLocalizedString("wallet__send_clipboard_empty_text", comment: "")
            showAlert = true
            return
        }

        parseNodeUri(pastedText)
    }

    func parseNodeUri(_ uri: String) {
        do {
            let lnPeer = try LnPeer(connection: uri)
            nodeId = lnPeer.nodeId
            host = lnPeer.host
            port = String(lnPeer.port)
        } catch {
            alertTitle = "Error"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    var body: some View {
        ZStack {
            VStack {
                ScrollView {
                    VStack(spacing: 12) {
                        // Title
                        DisplayText(
                            NSLocalizedString("lightning__external_manual__title", comment: ""),
                            accentColor: .purpleAccent
                        )

                        // Description
                        BodyMText(NSLocalizedString("lightning__external_manual__text", comment: ""))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)

                        // Node ID field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionText(NSLocalizedString("lightning__external_manual__node_id", comment: "").uppercased())
                            TextField("00000000000000000000000000000000000000000000000000000000000000", text: $nodeId)
                                .lineLimit(2 ... 2)
                        }

                        // Host field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionText(NSLocalizedString("lightning__external_manual__host", comment: "").uppercased())
                            TextField("00.00.00.00", text: $host)
                        }

                        // Port field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionText(NSLocalizedString("lightning__external_manual__port", comment: "").uppercased())
                            TextField("1234", text: $port)
                        }

                        // Paste Node URI button
                        CustomButton(
                            title: NSLocalizedString("lightning__external_manual__paste", comment: ""),
                            variant: .primary,
                            size: .small,
                            icon: Image(systemName: "doc.on.clipboard")
                                .foregroundColor(.white),
                            shouldExpand: false
                        ) {
                            pasteLightningNodeUri()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

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
                        variant: .secondary,
                        destination: ScannerView()
                    )

                    // Continue button
                    CustomButton(
                        title: NSLocalizedString("common__continue", comment: ""),
                        variant: .primary,
                        isDisabled: nodeId.isEmpty || host.isEmpty || port.isEmpty,
                        destination: FundManualAmountView(lnPeer: LnPeer(nodeId: nodeId, host: host, port: UInt16(port) ?? 0))
                    )
                }
                .padding()
                .background(Color.black)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__external__nav_title"))
        .backToWalletButton()
        .background(Color.black)
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text(NSLocalizedString("common__ok", comment: "")))
            )
        }
        .onAppear {
            if let initialNodeUri = initialNodeUri {
                parseNodeUri(initialNodeUri)
            }
        }
    }
}

#Preview {
    NavigationStack {
        FundManualSetupView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
