import SwiftUI

struct PaymentProfileView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    
    @State private var enableOnchain = false
    @State private var enableLightning = false
    @State private var pubkyUri = ""
    @State private var isLoading = false
    @State private var showQRCode = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Payment Profile")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Header section
                    VStack(alignment: .leading, spacing: 8) {
                        BodyLText("Share your public payment profile")
                        BodyMText("Let others find and pay you using your Pubky ID. Your profile shows which payment methods you accept.")
                            .foregroundColor(.textSecondary)
                    }
                    .padding(.bottom, 8)
                    
                    // QR Code Section
                    if showQRCode && !pubkyUri.isEmpty {
                        VStack(spacing: 16) {
                            QRCodeArea(uri: pubkyUri)
                            
                            HStack {
                                BodySText(pubkyUri)
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer()
                                
                                Button {
                                    UIPasteboard.general.string = pubkyUri
                                    app.toast(type: .success, title: "Copied to clipboard")
                                } label: {
                                    Image("copy")
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .foregroundColor(.brandAccent)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color.black)
                        .cornerRadius(8)
                    }
                    
                    // Payment Methods Section
                    VStack(alignment: .leading, spacing: 16) {
                        BodyLText("Public Payment Methods")
                            .foregroundColor(.white)
                        
                        // Onchain Toggle
                        HStack {
                            Image("btc")
                                .resizable()
                                .frame(width: 24, height: 24)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                BodyMText("On-chain Bitcoin")
                                    .foregroundColor(.white)
                                BodySText("Accept Bitcoin payments to your savings wallet")
                                    .foregroundColor(.textSecondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $enableOnchain)
                                .labelsHidden()
                                .onChange(of: enableOnchain) { newValue in
                                    Task {
                                        await updatePaymentMethod(method: "onchain", enabled: newValue)
                                    }
                                }
                        }
                        .padding(16)
                        .background(Color.gray900)
                        .cornerRadius(8)
                        
                        // Lightning Toggle
                        HStack {
                            Image("ln")
                                .resizable()
                                .frame(width: 24, height: 24)
                                .foregroundColor(.purpleAccent)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                BodyMText("Lightning Network")
                                    .foregroundColor(.white)
                                BodySText("Accept instant Lightning payments")
                                    .foregroundColor(.textSecondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: $enableLightning)
                                .labelsHidden()
                                .onChange(of: enableLightning) { newValue in
                                    Task {
                                        await updatePaymentMethod(method: "lightning", enabled: newValue)
                                    }
                                }
                        }
                        .padding(16)
                        .background(Color.gray900)
                        .cornerRadius(8)
                    }
                    
                    // Info Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image("info")
                                .resizable()
                                .frame(width: 16, height: 16)
                                .foregroundColor(.brandAccent)
                            BodyMText("About Payment Profiles")
                                .foregroundColor(.brandAccent)
                        }
                        
                        BodySText("When you enable a payment method, it will be published to your Pubky homeserver. Anyone can scan your QR code or lookup your Pubky ID to see which payment methods you accept.")
                            .foregroundColor(.textSecondary)
                    }
                    .padding(16)
                    .background(Color.gray900)
                    .cornerRadius(8)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Task {
                await loadPaymentProfile()
            }
        }
    }
    
    private func loadPaymentProfile() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Get user's Pubky ID (public key)
            // TODO: Get this from the app's key management
            // For now, we'll use a placeholder
            // pubkyUri = "pubky://\(userPublicKey)"
            
            // Check which methods are currently enabled
            // TODO: Call paykit_get_supported_methods_for_key to check current state
            
        } catch {
            app.toast(error)
        }
    }
    
    private func updatePaymentMethod(method: String, enabled: Bool) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            if enabled {
                // Get the appropriate endpoint based on the method
                let endpoint = method == "onchain" ? wallet.onchainAddress : wallet.bolt11
                
                // TODO: Call paykit_set_endpoint(method, endpoint)
                
                app.toast(
                    type: .success,
                    title: "Payment method enabled",
                    description: "\(method.capitalized) is now publicly available"
                )
            } else {
                // TODO: Call paykit_remove_endpoint(method)
                
                app.toast(
                    type: .success,
                    title: "Payment method disabled",
                    description: "\(method.capitalized) removed from public profile"
                )
            }
        } catch {
            // Revert toggle on error
            if method == "onchain" {
                enableOnchain = !enabled
            } else {
                enableLightning = !enabled
            }
            app.toast(error)
        }
    }
}

struct QRCodeArea: View {
    let uri: String
    
    var body: some View {
        if let qrCodeImage = generateQRCode(from: uri) {
            Image(uiImage: qrCodeImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.white)
                .cornerRadius(8)
        } else {
            Rectangle()
                .fill(Color.white)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
                .cornerRadius(8)
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)
        
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("H", forKey: "inputCorrectionLevel")
            
            if let outputImage = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 10, y: 10)
                let scaledImage = outputImage.transformed(by: transform)
                
                let context = CIContext()
                if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                    return UIImage(cgImage: cgImage)
                }
            }
        }
        
        return nil
    }
}

