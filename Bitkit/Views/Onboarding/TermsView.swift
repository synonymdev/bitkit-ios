//
//  TermsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/11.
//

import SwiftUI

struct TermsDeclarationText: View {
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        let parts = t.parts("tos_checkbox_value")
        parts.reduce(Text("")) { current, part in
            current + Text(part.text)
                .foregroundColor(part.isAccent ? .brand : .secondary)
                .underline(part.isAccent)
        }
        .font(.subheadline)
        .tint(.brand)
    }
}

struct PrivacyDeclarationText: View {
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        let parts = t.parts("pp_checkbox_value")
        parts.reduce(Text("")) { current, part in
            current + Text(part.text)
                .foregroundColor(part.isAccent ? .brand : .secondary)
                .underline(part.isAccent)
        }
        .font(.subheadline)
        .tint(.brand)
    }
}

struct TermsView: View {
    @State private var termsAccepted = false
    @State private var privacyAccepted = false
    @State private var navigateToIntro = false
    
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrolling content
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        let parts = t.parts("tos_header")
                        Text(parts[0].text.uppercased())
                            .font(.largeTitle)
                            .fontWeight(.black)
                            .foregroundColor(.primary) +
                            Text(parts[1].text.uppercased())
                            .font(.largeTitle)
                            .fontWeight(.black)
                            .foregroundColor(.brand)
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
                            Text(t("tos_checkbox"))
                                .font(.headline)
                            TermsDeclarationText()
                                .font(.subheadline)
                                .tint(.brand)
                        }
                        
                        Spacer()
                        
                        Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(termsAccepted ? .brand : .gray)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        termsAccepted.toggle()
                        Haptics.play(.medium)
                    }
                    
                    Divider()
                    
                    // Privacy checkbox
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t("pp_checkbox"))
                                .font(.headline)
                            PrivacyDeclarationText()
                                .font(.subheadline)
                                .tint(.brand)
                        }
                        
                        Spacer()
                        
                        Image(systemName: privacyAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(privacyAccepted ? .brand : .gray)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        privacyAccepted.toggle()
                        Haptics.play(.medium)
                    }
                    
                    Divider()
                }
                .padding(.horizontal)
                
                Button(action: {
                    if termsAccepted, privacyAccepted {
                        navigateToIntro = true
                    } else {
                        Haptics.notify(.error)
                    }
                }) {
                    Text(t("get_started"))
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
