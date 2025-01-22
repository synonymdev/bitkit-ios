//
//  TermsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/11.
//

import SwiftUI

struct TappableTextModifier: ViewModifier {
    let url: String
    
    func body(content: Content) -> some View {
        Button(action: {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        }) {
            content
        }
    }
}

struct TermsDeclarationText: View {
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        let parts = t.parts("tos_checkbox_value")
        let text = parts.reduce(AttributedString("")) { result, part in
            var current = result
            var partText = AttributedString(part.text)
            if part.isAccent {
                partText.foregroundColor = .brandAccent
                partText.underlineStyle = .single
                
                if let url = URL(string: Env.termsOfServiceUrl) {
                    partText.link = url
                }
            } else {
                partText.foregroundColor = .textSecondary
            }
            current.append(partText)
            return current
        }
        
        Text(text)
            .bodySTextStyle(color: .textSecondary)
            .tint(.brandAccent)
    }
}

struct PrivacyDeclarationText: View {
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        let parts = t.parts("pp_checkbox_value")
        let text = parts.reduce(AttributedString("")) { result, part in
            var current = result
            var partText = AttributedString(part.text)
            if part.isAccent {
                partText.foregroundColor = .brandAccent
                partText.underlineStyle = .single
                
                if let url = URL(string: Env.privacyPolicyUrl) {
                    partText.link = url
                }
            } else {
                partText.foregroundColor = .textSecondary
            }
            current.append(partText)
            return current
        }
        
        Text(text)
            .bodySTextStyle(color: .textSecondary)
            .tint(.brandAccent)
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
                        (Text(t.getPart("tos_header", index: 0)?.text.uppercased() ?? "") + Text(t.getPart("tos_header", index: 1)?.text.uppercased() ?? "").foregroundColor(.brandAccent))
                            .displayTextStyle()
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    TosContent()
                        .bodyMTextStyle()
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
                                .subtitleTextStyle()
                            TermsDeclarationText()
                                .tint(.brandAccent)
                        }
                        
                        Spacer()
                        
                        Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(termsAccepted ? .brandAccent : .textSecondary)
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
                                .subtitleTextStyle()
                            PrivacyDeclarationText()
                                .tint(.brandAccent)
                        }
                        
                        Spacer()
                        
                        Image(systemName: privacyAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(privacyAccepted ? .brandAccent : .textSecondary)
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
                
                CustomButton(
                    title: t("get_started"),
                    variant: termsAccepted && privacyAccepted ? .primary : .secondary,
                    isDisabled: !(termsAccepted && privacyAccepted)
                ) {
                    if termsAccepted && privacyAccepted {
                        navigateToIntro = true
                    } else {
                        Haptics.notify(.error)
                    }
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
        .preferredColorScheme(.dark)
}

#Preview {
    TermsView()
        .preferredColorScheme(.light)
}
