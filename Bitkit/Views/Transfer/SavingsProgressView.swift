//
//  SavingsProgressView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/03/21.
//

import SwiftUI

enum SavingsProgressState {
    case inProgress
    case success
    case failed
}

struct SavingsProgressContentView: View {
    @EnvironmentObject var app: AppViewModel
    let progressState: SavingsProgressState

    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var transferRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString(
                    {
                        switch progressState {
                        case .inProgress: return "lightning__savings_progress__title"
                        case .failed: return "lightning__savings_interrupted__title"
                        case .success: return "lightning__transfer_success__title_savings"
                        }
                    }(),
                    comment: ""
                ), accentColor: .brandAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString(
                    {
                        switch progressState {
                        case .inProgress: return "lightning__savings_progress__text"
                        case .failed: return "lightning__savings_interrupted__text"
                        case .success: return "lightning__transfer_success__text_savings"
                        }
                    }(),
                    comment: ""
                ), textColor: .textSecondary, accentColor: .white)

                Spacer()

                if progressState == .inProgress {
                    ZStack(alignment: .center) {
                        // Outer ellipse
                        Image("ellipse-outer-brand")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 311, height: 311)
                            .rotationEffect(.degrees(outerRotation))

                        // Inner ellipse
                        Image("ellipse-inner-brand")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 207, height: 207)
                            .rotationEffect(.degrees(innerRotation))

                        // Transfer image
                        Image("transfer")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 256, height: 256)
                            .rotationEffect(.degrees(transferRotation))
                    }
                    .frame(width: 320, height: 320)
                    .clipped()
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            outerRotation = -90
                        }

                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            innerRotation = 120
                        }

                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            transferRotation = 90
                        }
                    }

                } else {
                    Image(progressState == .failed ? "exclamation-mark" : "check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()

                if progressState != .inProgress {
                    CustomButton(
                        title: NSLocalizedString("common__ok", comment: ""),
                        size: .large
                    ) {
                        app.showTransferToSavingsSheet = false
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .navigationTitle(NSLocalizedString(
            progressState == .failed ?
                "lightning__savings_interrupted__nav_title" :
                "lightning__transfer__nav_title",
            comment: ""
        ))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showTransferToSavingsSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

struct SavingsProgressView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @State private var progressState: SavingsProgressState = .inProgress

    var body: some View {
        SavingsProgressContentView(progressState: progressState)
            .task {
                // Disable screen timeout while this view is active
                UIApplication.shared.isIdleTimerDisabled = true

                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)

                    let channelsFailedToCoopClose = try await transfer.closeSelectedChannels()

                    if channelsFailedToCoopClose.isEmpty {
                        // Re-enable screen timeout when we're done
                        UIApplication.shared.isIdleTimerDisabled = false

                        withAnimation {
                            progressState = .success
                        }
                    } else {
                        withAnimation {
                            progressState = .failed
                        }

                        // Start retrying the cooperative close
                        transfer.startCoopCloseRetries(channels: channelsFailedToCoopClose)
                    }

                } catch {
                    app.toast(error)
                }
            }
            .onDisappear {
                // Ensure we re-enable screen timeout when view disappears
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}

#Preview("In Progress") {
    NavigationView {
        SavingsProgressContentView(progressState: .inProgress)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Success") {
    NavigationView {
        SavingsProgressContentView(progressState: .success)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Failed") {
    NavigationView {
        SavingsProgressContentView(progressState: .failed)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
