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
    
    @EnvironmentObject private var currency: CurrencyViewModel
    
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var overrideSats: UInt64?
    
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
        let sats = entry.channelSizeSat - entry.feeSat
        if let converted = currency.convert(sats: sats) {
            if primaryDisplay == .bitcoin {
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
                    defaultValue: entry.invoice.request.isEmpty ? 0 : entry.channelSizeSat, 
                    primaryDisplay: $primaryDisplay, 
                    overrideSats: $overrideSats, 
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
            
            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                onCjitCreated(entry.invoice.request)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .sheetBackground()
        .navigationTitle(NSLocalizedString("Confirm CJIT", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            primaryDisplay = currency.primaryDisplay
            overrideSats = entry.channelSizeSat
        }
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
                        onCjitCreated: { _ in }
                    )
                    .environmentObject(CurrencyViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
    .preferredColorScheme(.dark)
}
