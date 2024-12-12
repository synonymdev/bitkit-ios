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
    @State private var rotation: Double = 0
    @State private var percentage: Int = 0
    @State private var timer: Timer?
    @State private var hapticTimer: Timer?

    private var rocket: some View {
        Image("rocket")
            .resizable()
            .scaledToFit()
            .frame(width: 300, height: 300)
            .offset(rocketOffset)
    }

    private var spinner: some View {
        ZStack {
            Image("loading-circle")
                .resizable()
                .scaledToFit()
                .frame(width: 192, height: 192)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Text("\(percentage)%")
                .font(.largeTitle)
                .fontWeight(.black)
                .foregroundColor(.brand)
                .onAppear {
                    // Create timer that fires every 0.1 seconds
                    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                        if percentage < 100 {
                            percentage += 1
                        } else {
                            timer?.invalidate()
                        }
                    }
                }
                .onDisappear {
                    timer?.invalidate()
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Rocket first (back)
                rocket
                    .onAppear {
                        // Initial position setup
                        rocketOffset = CGSize(
                            width: -(geometry.size.width / 2) - 150,
                            height: geometry.size.height * 0.4
                        )

                        // Start repeating haptics
                        hapticTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                            Haptics.rocket(duration: 1.6)
                        }
                        // Initial haptic
                        Haptics.rocket(duration: 1.6)

                        withAnimation(
                            .linear(duration: 1.6)
                                .repeatForever(autoreverses: false)
                        ) {
                            rocketOffset = CGSize(
                                width: geometry.size.width / 2 + 150,
                                height: -(geometry.size.height * 0.4)
                            )
                        }
                    }
                    .onDisappear {
                        hapticTimer?.invalidate()
                        hapticTimer = nil
                    }

                // Content second (front)
                VStack(spacing: 24) {
                    spinner

                    VStack(alignment: .leading, spacing: 0) {
                        Text("SETTING UP")
                            .font(.system(size: 44, weight: .black))
                        Text("YOUR WALLET")
                            .font(.system(size: 44, weight: .black))
                            .foregroundColor(.brand)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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
