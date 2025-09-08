import SwiftUI

struct FundManualSetupView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
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
            alertTitle = t("wallet__send_clipboard_empty_title")
            alertMessage = t("wallet__send_clipboard_empty_text")
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
            VStack(spacing: 0) {
                NavigationBar(title: t("lightning__external__nav_title"))
                    .padding(.bottom, 16)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        DisplayText(
                            t("lightning__external_manual__title"),
                            accentColor: .purpleAccent
                        )

                        BodyMText(t("lightning__external_manual__text"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)

                        // Node ID field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("lightning__external_manual__node_id"))
                            TextField("00000000000000000000000000000000000000000000000000000000000000", text: $nodeId)
                                .lineLimit(2 ... 2)
                        }

                        // Host field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("lightning__external_manual__host"))
                            TextField("00.00.00.00", text: $host)
                        }

                        // Port field
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("lightning__external_manual__port"))
                            TextField("9735", text: $port)
                        }

                        // Paste Node URI button
                        CustomButton(
                            title: t("lightning__external_manual__paste"),
                            variant: .primary,
                            size: .small,
                            icon: Image("clipboard")
                                .resizable()
                                .frame(width: 16, height: 16)
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
                }
            }

            // Fixed bottom buttons overlay
            VStack {
                Spacer()

                HStack {
                    CustomButton(
                        title: t("lightning__external_manual__scan"),
                        variant: .secondary,
                    ) {
                        navigation.navigate(.scanner)
                    }

                    CustomButton(
                        title: t("common__continue"),
                        variant: .primary,
                        isDisabled: nodeId.isEmpty || host.isEmpty || port.isEmpty,
                        destination: FundManualAmountView(lnPeer: LnPeer(nodeId: nodeId, host: host, port: UInt16(port) ?? 0))
                    )
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text(t("common__ok")))
            )
        }
        .onAppear {
            if let initialNodeUri {
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
