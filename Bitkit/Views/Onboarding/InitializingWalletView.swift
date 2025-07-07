//
//  InitializingWalletView.swift
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

    private func handleCompletion() {
        timer?.invalidate()
        hapticTimer?.invalidate()
        Haptics.stopHaptics()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Haptics.notify(.success)
            onComplete()
        }
    }

    private func animateSpinnerSequence() {
        // First animation: rotate to -180 degrees over 2.0 seconds
        withAnimation(.easeInOut(duration: 2.0)) {
            rotation = -180
        }

        // After 2.0 seconds, pause for 100ms, then continue to -360 degrees
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 2.0)) {
                    rotation = -360
                }

                // After the full rotation, reset and repeat
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    rotation = 0
                    animateSpinnerSequence()
                }
            }
        }
    }

    private func animateRocketSequence(geometry: GeometryProxy) {
        // Initial haptic
        Haptics.rocket(duration: 2.5)

        // Single continuous animation with custom timing
        let totalDuration: Double = 2.5
        let finalX = geometry.size.width / 2 + 128
        let finalY = -(geometry.size.height * 0.3)

        withAnimation(.easeInOut(duration: totalDuration)) {
            rocketOffset = CGSize(width: finalX, height: finalY)
        }

        // After rocket is off screen, pause then reset and repeat
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) {
            // Pause off screen for 1 second
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Reset to starting position (instant, no animation)
                rocketOffset = CGSize(
                    width: -(geometry.size.width / 2) - 128,
                    height: geometry.size.height * 0.5
                )

                // Start next loop
                animateRocketSequence(geometry: geometry)
            }
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
                    animateSpinnerSequence()
                }

            Text("\(Int(percentage))%")
                .font(.custom(Fonts.bold, size: 48))
                .foregroundColor(.brandAccent)
                .kerning(-1)
                .onAppear {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                        if percentage < 100 {
                            // Base increment speed
                            let baseIncrement: Double = shouldFinish ? 1.2 : 0.5

                            // Progressive slowdown if shouldFinish is false
                            let increment: Double
                            if !shouldFinish {
                                if percentage >= 80 {
                                    increment = baseIncrement * 0.125 // Halved three times (0.5 * 0.5 * 0.5)
                                } else if percentage >= 70 {
                                    increment = baseIncrement * 0.25 // Halved twice (0.5 * 0.5)
                                } else if percentage >= 60 {
                                    increment = baseIncrement * 0.5 // Halved once
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
                Image("rocket2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 256, height: 256)
                    .offset(rocketOffset)
                    .onAppear {
                        // Initial position setup
                        rocketOffset = CGSize(
                            width: -(geometry.size.width / 2) - 70,
                            height: geometry.size.height * 0.4
                        )

                        // Small delay before starting animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Start repeating haptics
                            hapticTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                                Haptics.rocket(duration: 2.5)
                            }
                            // Initial haptic
                            Haptics.rocket(duration: 2.5)

                            // Start the rocket animation sequence
                            animateRocketSequence(geometry: geometry)
                        }
                    }
                    .onDisappear {
                        hapticTimer?.invalidate()
                        hapticTimer = nil
                    }

                // Content second (front)
                VStack(spacing: 32) {
                    spinner

                    DisplayText(localizedString("onboarding__loading_header"))
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

#Preview("Dark") {
    InitializingWalletView(shouldFinish: .constant(false)) {}
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    InitializingWalletView(shouldFinish: .constant(false)) {}
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.light)
}
