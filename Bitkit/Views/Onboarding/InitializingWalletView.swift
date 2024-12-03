// ... existing code ...
//
//  LoadingView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/01/17.
//

import SwiftUI

struct InitializingWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @State private var rocketOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Rocket first (back)
                Text("🚀")
                    .font(.system(size: 40))
                    .offset(rocketOffset)
                    .onAppear {
                        // Start from bottom left
                        rocketOffset = CGSize(
                            width: -(geometry.size.width / 2) + 50,
                            height: geometry.size.height / 2 - 50
                        )
                        
                        withAnimation(
                            .linear(duration: 2.0)
                            .repeatForever(autoreverses: false)
                        ) {
                            // Animate to top right
                            rocketOffset = CGSize(
                                width: geometry.size.width / 2 - 50,
                                height: -(geometry.size.height / 2) + 50
                            )
                        }
                    }
                
                // Content second (front)
                VStack(spacing: 24) {
                    Text("Setting up\nyour wallet")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    ProgressView()
                        .scaleEffect(1.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

#Preview {
    InitializingWalletView()
        .environmentObject(WalletViewModel())
}
// ... existing code ... 