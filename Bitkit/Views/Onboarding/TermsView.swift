//
//  TermsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/11.
//

import SwiftUI

struct TermsDeclarationText: View {
    var body: some View {
        Text("I declare that I have read and\naccept the [terms of use](https://bitkit.to/terms-of-use).")
            .foregroundColor(.secondary)
            .tint(.brand) // This controls the link color
    }
}

struct PrivacyDeclarationText: View {
    var body: some View {
        Text("I declare that I have read and\naccept the [privacy policy](https://bitkit.to/privacy-policy).")
            .foregroundColor(.secondary)
            .tint(.brand)
    }
}

struct TermsView: View {
    @State private var termsAccepted = false
    @State private var privacyAccepted = false
    @State private var navigateToIntro = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrolling content
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("BITKIT")
                            .font(.largeTitle)
                    .fontWeight(.black)
                        Text("TERMS OF USE")
                            .font(.largeTitle)
                    .fontWeight(.black)
                            .foregroundColor(Color.brand)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    TosContent()
                        .padding(.bottom, 300) // Extra padding for footer
                }
                .padding()
            }
            .background(Color(.systemBackground))
            
            // Gradient overlay
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [
                        Color(.systemBackground).opacity(0),
                        Color(.systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                
                Rectangle()
                    .fill(Color(.systemBackground))
                    .frame(height: 200)
            }
            .frame(maxWidth: .infinity)
            
            // Footer overlay
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    // Terms checkbox
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Terms of Use")
                                .font(.headline)
                            TermsDeclarationText()
                                .font(.subheadline)
                        }
                        
                        Spacer()
                        
                        Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(termsAccepted ? .brand : .gray)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle()) // Makes entire HStack tappable
                    .onTapGesture {
                        termsAccepted.toggle()
                        Haptics.play(.medium)
                    }

                    Divider()
                    
                    // Privacy checkbox
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Privacy Policy")
                                .font(.headline)
                            PrivacyDeclarationText()
                                .font(.subheadline)
                        }
                        
                        Spacer()
                        
                        Image(systemName: privacyAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(privacyAccepted ? .brand : .gray)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle()) // Makes entire HStack tappable
                    .onTapGesture {
                        privacyAccepted.toggle()
                        Haptics.play(.medium)
                    }

                    Divider()
                }
                .padding(.horizontal)
                
                Button(action: {
                    if termsAccepted && privacyAccepted {
                        navigateToIntro = true
                    } else {
                        Haptics.notify(.error)
                    }
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(.gray)
                        .cornerRadius(30)
                }
                .padding(.horizontal)
            }
            .padding(.top)
            .padding(.bottom, 20)
            .background(
                Color(.systemBackground)
                    .shadow(radius: 8, y: -4)
                    .edgesIgnoringSafeArea(.bottom)
            )
            
            NavigationLink(isActive: $navigateToIntro) {
                IntroView()
            } label: {
                EmptyView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
    }
}

#Preview {
    TermsView()
}
