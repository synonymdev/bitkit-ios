//
//  SavingsProgressView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/03/21.
//

import SwiftUI

struct SavingsProgressView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel

    @State private var isAnimating = true
    @State private var isProcessComplete = false
    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var transferRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString(isAnimating ? "lightning__savings_progress__title" : "lightning__transfer_success__title_savings", comment: ""), accentColor: .brandAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString(isAnimating ? "lightning__savings_progress__text" : "lightning__transfer_success__text_savings", comment: ""), textColor: .textSecondary, accentColor: .white)

                Spacer()

                if isAnimating {
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
                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()

                if isProcessComplete {
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
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
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
        .task {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)

                try await transfer.closeSelectedChannels()

                withAnimation {
                    isAnimating = false
                    isProcessComplete = true
                }
            } catch {
                app.toast(error)
            }
        }
    }
}

#Preview {
    NavigationView {
        SavingsProgressView()
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
