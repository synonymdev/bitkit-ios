//
//  SendOptionsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SendOptionCard<Destination: View>: View {
    var title: String
    var destination: Destination
    var isButton: Bool = false
    var action: (() -> Void)? = nil
    var iconName: String
    
    var body: some View {
        Group {
            if isButton {
                Button(action: { action?() }) {
                    cardContent
                }
            } else {
                NavigationLink(destination: destination) {
                    cardContent
                }
            }
        }
    }
    
    private var cardContent: some View {
        HStack {
            Image(iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .padding(.trailing, 8)
            SubtitleText(title)
            Spacer()
        }
        .frame(height: 80)
        .padding(.horizontal, 24)
        .background(Color.white06)
        .cornerRadius(8)
    }
}

struct SendOptionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showSendAmountView = false
    @State private var showSendConfirmationView = false

    var body: some View {
        NavigationView {
            sendOptionsContent
        }
    }

    var sendOptionsContent: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                CaptionText(NSLocalizedString("wallet__send_to", comment: "").uppercased())
                    .padding(.horizontal)
                
                VStack(spacing: 12) {
                    SendOptionCard(
                        title: "Paste Invoice", 
                        destination: EmptyView(),
                        isButton: true,
                        action: handlePaste,
                        iconName: "clipboard-brand"
                    )
                    
                    SendOptionCard(
                        title: "Enter Manually", 
                        destination: SendEnterManuallyView(),
                        iconName: "pencil-brand"
                    )
                    
                    SendOptionCard(
                        title: "Scan QR Code", 
                        destination: ScannerView(
                            showSendAmountView: $showSendAmountView,
                            showSendConfirmationView: $showSendConfirmationView,
                            onResultDelay: 0.65
                        ),
                        iconName: "scan-brand"
                    )
                }
                .padding(.horizontal)
                
                Spacer()
            }

            Spacer()
            
            Image("coin-stack-logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(alignment: .bottom)
                .padding(.bottom, 8)
        }
        .sheetBackground()
        .navigationTitle(NSLocalizedString("wallet__send_bitcoin", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.all, edges: .bottom)
        .onAppear {
            wallet.syncState()
        }
        .background(
            NavigationLink(
                destination: SendAmountView(),
                isActive: $showSendAmountView
            ) { EmptyView() }
        )
        .background(
            NavigationLink(
                destination: SendConfirmationView(),
                isActive: $showSendConfirmationView
            ) { EmptyView() }
        )
    }

    func handlePaste() {
        guard let uri = UIPasteboard.general.string else {
            Logger.error("No data in clipboard")
            app.toast(type: .warning, title: "No data in clipboard", description: "")
            return
        }

        Haptics.play(.pastedFromClipboard)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)

                // If nil then it's not an invoice we're dealing with
                if app.invoiceRequiresCustomAmount == true {
                    showSendAmountView = true
                } else if app.invoiceRequiresCustomAmount == false {
                    showSendConfirmationView = true
                }
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(error)
            }
        }
    }
}

@available(iOS 16.0, *)
#Preview {
    VStack { }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    SendOptionsView()
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
    .preferredColorScheme(.dark)
}
