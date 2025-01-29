//
//  TabBar.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct NoAnimationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TabBar: View {
    @EnvironmentObject var app: AppViewModel
    @State private var scaleEffect: CGFloat = 1.0

    var body: some View {
        VStack {
            Spacer()
            if app.showTabBar {
                HStack {
                    Spacer()
                    Button(action: {
                        app.showSendOptionsSheet = true
                        Haptics.play(.openSheet)
                    }, label: {
                        HStack(spacing: 4) {
                            Image("arrow-down")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 16)
                            BodySText("Send")
                        }
                        .foregroundColor(.white)
                    })
                    Spacer()
                    Spacer()
                    Spacer()
                    Button(action: {
                        app.showReceiveSheet = true
                        Haptics.play(.openSheet)
                    }, label: {
                        HStack(spacing: 4) {
                            Image("arrow-down")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 16)
                                .rotationEffect(.degrees(180))
                            BodySText("Receive")
                        }
                        .foregroundColor(.white)
                    })
                    Spacer()
                }
                .frame(height: 56)
                .background(.regularMaterial)
                .cornerRadius(30)
                .overlay {
                    Button(action: {
                        Haptics.play(.openSheet)
                        app.showScanner = true
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            scaleEffect = 1.1
                        }
                        
                        // Reset scale after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                scaleEffect = 1.0
                            }
                        }
                    }, label: {
                        Image("scan")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(Color.gray2)
                            .padding(24)
                            .frame(width: 80, height: 80)
                            .background(Circle().fill(Color.gray6))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white10, lineWidth: 2)
                            )
                            .scaleEffect(scaleEffect)
                    })
                    .buttonStyle(NoAnimationButtonStyle())
                }
                .padding()
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut, value: app.showTabBar)
    }
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.light)
}
