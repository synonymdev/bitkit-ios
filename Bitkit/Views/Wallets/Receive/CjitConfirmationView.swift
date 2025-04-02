//
//  CjitConfirmationView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/04/01.
//

import SwiftUI

struct CjitConfirmationView: View {
    let entry: IcJitEntry
    let onCjitCreated: (String) -> Void
    let receiveAmountSats: UInt64
    
    @EnvironmentObject private var currency: CurrencyViewModel
        
    private func formattedNetworkFee() -> String {
        guard let converted = currency.convert(sats: entry.networkFeeSat) else {
            return String(entry.networkFeeSat)
        }
        return "\(converted.symbol)\(converted.formatted)"
    }
    
    private func formattedServiceFee() -> String {
        guard let converted = currency.convert(sats: entry.serviceFeeSat) else {
            return String(entry.serviceFeeSat)
        }
        return "\(converted.symbol)\(converted.formatted)"
    }
    
    
    private func formattedAmountReceive() -> String {
        let sats = receiveAmountSats - entry.feeSat
        if let converted = currency.convert(sats: sats) {
            if currency.primaryDisplay == .bitcoin {
                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                return "\(btcComponents.symbol) \(btcComponents.value)"
            } else {
                return "\(converted.symbol) \(converted.formatted)"
            }
        }
        return String(sats)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                AmountInput(
                    defaultValue: receiveAmountSats,
                    primaryDisplay: $currency.primaryDisplay,
                    overrideSats: .constant(receiveAmountSats),
                    showConversion: true
                ) { _ in
                    // Read-only, so no action needed
                }
                .disabled(true)
                .padding(.vertical, 16)

                BodyMText(
                    localizedString(
                        "wallet__receive_connect_initial",
                        comment: "",
                        variables: [
                            "networkFee": formattedNetworkFee(),
                            "serviceFee": formattedServiceFee()
                        ]
                    ),
                    textColor: .textSecondary,
                    accentColor: .white
                )

                 VStack(alignment: .leading) {
                    BodyMText(NSLocalizedString("wallet__receive_will", comment: "").uppercased(), textColor: .textSecondary)
                    TitleText(formattedAmountReceive(), textColor: .textPrimary)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
           
            Spacer()
            
            Image("lightning")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 256)
                .padding(.horizontal, 16)

            Spacer()
            
            HStack(spacing: 16) {
                NavigationLink(destination: CjitLearnMoreView(entry: entry, receiveAmountSats: receiveAmountSats)) {
                    CustomButton(title: NSLocalizedString("common__learn_more", comment: ""), variant: .secondary)
                }
                
                CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                    onCjitCreated(entry.invoice.request)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .sheetBackground()
        .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 16.0, *)
#Preview("CJIT Confirmation") {
    VStack { }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    CjitConfirmationView(
                        entry: IcJitEntry.mock(),
                        onCjitCreated: { _ in },
                        receiveAmountSats: 12500
                    )
                    .environmentObject(CurrencyViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
    .preferredColorScheme(.dark)
}
