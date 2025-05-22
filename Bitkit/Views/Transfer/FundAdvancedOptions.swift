//
//  FundAdvancedOptions.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/05/21.
//

import SwiftUI

struct FundAdvancedOptions: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            // Header
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Text("Spending Balance")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            ScrollView {
                VStack(spacing: 24) {
                    // Title
                    DisplayText(
                        NSLocalizedString("lightning__funding_advanced__title", comment: ""),
                        accentColor: .purpleAccent
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Description
                    BodyMText(NSLocalizedString("lightning__funding_advanced__text", comment: ""))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Options
                    VStack(spacing: 8) {
                        NavigationLink(destination: ScannerView(showSendAmountView: .constant(false), showSendConfirmationView: .constant(false))) {
                            RectangleButton(
                                icon: Image("scan")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.purpleAccent),
                                title: NSLocalizedString("lightning__funding_advanced__button1", comment: "")
                            )
                        }
                        
                        NavigationLink(destination: FundManualSetupView()) {
                            RectangleButton(
                                icon: Image("pencil")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.purpleAccent),
                                title: NSLocalizedString("lightning__funding_advanced__button2", comment: "")
                            )
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .navigationBarHidden(true)
        .background(Color.black)
    }
}

#Preview {
    NavigationView {
        FundAdvancedOptions()
            .preferredColorScheme(.dark)
    }
}

