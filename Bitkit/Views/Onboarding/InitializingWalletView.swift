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
    @State private var percentage: Double = 0
    @State private var timer: Timer?
    @State private var hapticTimer: Timer?

    @Binding var shouldFinish: Bool
    let onComplete: () -> Void

    private static let standardDuration: Double = 2.5
    private static let rocketDuration: Double = standardDuration - 0.01

    private var rocket: some View {
        Image("rocket")
            .resizable()
            .scaledToFit()
            .frame(width: 300, height: 300)
            .offset(rocketOffset)
    }

    private func handleCompletion() {
        timer?.invalidate()
        hapticTimer?.invalidate()
        Haptics.stopHaptics()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Haptics.notify(.success)
            onComplete()
        }
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

            Text("\(Int(percentage))%")
                .font(.largeTitle)
                .fontWeight(.black)
                .foregroundColor(.brand)
                .onAppear {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                        if percentage < 100 {
                            // Base increment speed
                            let baseIncrement: Double = shouldFinish ? 1.2 : 0.5

                            // Progressive slowdown if shouldFinish is false
                            let increment: Double
                            if !shouldFinish {
                                if percentage >= 80 {
                                    increment = baseIncrement * 0.125  // Halved three times (0.5 * 0.5 * 0.5)
                                } else if percentage >= 70 {
                                    increment = baseIncrement * 0.25   // Halved twice (0.5 * 0.5)
                                } else if percentage >= 60 {
                                    increment = baseIncrement * 0.5    // Halved once
                                } else {
                                    increment = baseIncrement
                                }
                            } else {
                                increment = baseIncrement
                            }
                            

                            percentage = min(percentage + increment, 100)
                        }
                    }
                }
                .onChange(of: shouldFinish) { finish in
                    if finish && percentage >= 99.9 {
                        percentage = 100
                        handleCompletion()
                    }
                }
                .onChange(of: percentage) { newPercentage in
                    if newPercentage >= 99.9 && shouldFinish {
                        percentage = 100
                        handleCompletion()
                    }
                }
                .onDisappear {
                    timer?.invalidate()
                    hapticTimer?.invalidate()
                    Haptics.stopHaptics()
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
                            height: geometry.size.height * 0.5
                        )

                        // Start repeating haptics
                        hapticTimer = Timer.scheduledTimer(withTimeInterval: Self.standardDuration, repeats: true) { _ in
                            Haptics.rocket(duration: Self.rocketDuration)
                        }
                        // Initial haptic
                        Haptics.rocket(duration: Self.rocketDuration)

                        withAnimation(
                            .linear(duration: Self.standardDuration)
                                .repeatForever(autoreverses: false)
                        ) {
                            rocketOffset = CGSize(
                                width: geometry.size.width / 2 + 150,
                                height: -(geometry.size.height * 0.3)
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
    InitializingWalletView(shouldFinish: .constant(false)) {}
        .environmentObject(WalletViewModel())
}
